#!/usr/bin/env bash
#
# update-aliyun-sg.sh
# 动态更新阿里云安全组 SSH(22) 入方向规则，适配家庭宽带动态 IP
#
# 策略：先添加新 IP 规则，再删除旧 IP 规则（零空窗）
# 规则通过 Description="HomeDynamicIP" 标记，只操作自己的规则
#
# 前置条件：
#   1. 安装 aliyun CLI：pip install aliyun-python-sdk-ecs 或通过包管理器
#   2. 配置 AK/SK：aliyun configure
#   3. 安全组 ID 填入下方 SG_ID
#
# Usage：
#   手动：bash update-aliyun-sg.sh
#   cron：*/5 * * * * /bin/bash /path/to/update-aliyun-sg.sh >> /tmp/aliyun-sg-update.log 2>&1

set -euo pipefail

# ═══════════════════════════════════════════
#  配置区域 — 按实际情况修改
# ═══════════════════════════════════════════
# 从配置文件读取敏感信息
CONF_FILE="$HOME/.config/aliyun-sg.conf"
if [[ -f "$CONF_FILE" ]]; then
    source "$CONF_FILE"
else
    cat >&2 <<EOF
[ERROR] 配置文件不存在: ${CONF_FILE}

请创建该文件并填入以下内容（按实际情况修改）：

  SECURITY_GROUP_ID="<安全组ID，格式 sg-xxxxxx>"
  REGION="<地域，如 cn-wulanchabu>"

参考模板：~/.config/aliyun-sg.conf 已配置的机器
EOF
    exit 1
fi

PORT="22"                             # 需要开放的端口
DESCRIPTION="HomeDynamicIP"           # 规则描述标记，用于识别脚本管理的规则
CACHE_FILE="/tmp/current_aliyun_ip"   # 本地 IP 缓存
LOG_TAG="[aliyun-sg-update]"

# ═══════════════════════════════════════════
#  颜色输出
# ═══════════════════════════════════════════
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}${LOG_TAG}${NC}  $*"; }
warn()  { echo -e "${YELLOW}${LOG_TAG}${NC}  $*"; }
error() { echo -e "${RED}${LOG_TAG}${NC} $*" >&2; }

# ═══════════════════════════════════════════
#  1. 前置检查
# ═══════════════════════════════════════════
check_deps() {
    if ! command -v aliyun &>/dev/null; then
        error "aliyun CLI 未安装，请先安装：pip install aliyun-cli"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        error "jq 未安装，请先安装：apt install jq / brew install jq"
        exit 1
    fi

    if ! command -v curl &>/dev/null; then
        error "curl 未安装"
        exit 1
    fi
}

# ═══════════════════════════════════════════
#  2. 获取当前公网 IP（多源冗余）
# ═══════════════════════════════════════════
get_public_ip() {
    local ip=""
    local timeout=5

    # 依次尝试多个服务
    ip=$(curl -s --connect-timeout "$timeout" cip.cc 2>/dev/null | head -1 | awk '{print $NF}') || true
    if [[ -z "$ip" ]]; then
        ip=$(curl -s --connect-timeout "$timeout" ifconfig.me 2>/dev/null) || true
    fi
    if [[ -z "$ip" ]]; then
        ip=$(curl -s --connect-timeout "$timeout" ipinfo.io/ip 2>/dev/null) || true
    fi
    if [[ -z "$ip" ]]; then
        ip=$(curl -s --connect-timeout "$timeout" icanhazip.com 2>/dev/null) || true
    fi
    if [[ -z "$ip" ]]; then
        ip=$(curl -s --connect-timeout "$timeout" checkip.amazonaws.com 2>/dev/null) || true
    fi

    if [[ -z "$ip" ]] || ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "获取公网 IP 失败（返回值: ${ip:-空}）"
        exit 1
    fi

    echo "$ip"
}

# ═══════════════════════════════════════════
#  3. 查询安全组中脚本管理的规则
#     返回格式：每行 "SourceCidrIp"
# ═══════════════════════════════════════════
get_managed_rules() {
    local json
    json=$(aliyun ecs DescribeSecurityGroupAttribute \
        --SecurityGroupId "$SECURITY_GROUP_ID" \
        --RegionId "$REGION" 2>&1) || {
        error "查询安全组规则失败"
        error "aliyun 输出: $json"
        exit 1
    }

    echo "$json" | jq -r \
        --arg desc "$DESCRIPTION" \
        --arg port "$PORT" \
        '.Permissions.Permission[]?
         | select(.Description == $desc and .PortRange == "\($port)/\($port)" and .IpProtocol == "TCP" and .Direction == "ingress")
         | .SourceCidrIp'
}

# ═══════════════════════════════════════════
#  4. 添加新规则
# ═══════════════════════════════════════════
add_rule() {
    local ip_cidr="$1"
    info "添加新规则: SourceCidrIp=${ip_cidr}"

    local output
    output=$(aliyun ecs AuthorizeSecurityGroup \
        --RegionId "$REGION" \
        --SecurityGroupId "$SECURITY_GROUP_ID" \
        --IpProtocol tcp \
        --PortRange "${PORT}/${PORT}" \
        --SourceCidrIp "$ip_cidr" \
        --Description "$DESCRIPTION" 2>&1) || {
        error "添加规则失败"
        error "aliyun 输出: $output"
        return 1
    }
    info "添加成功"
}

# ═══════════════════════════════════════════
#  5. 删除旧规则
# ═══════════════════════════════════════════
remove_rule() {
    local ip_cidr="$1"
    info "删除旧规则: SourceCidrIp=${ip_cidr}"

    local output
    output=$(aliyun ecs RevokeSecurityGroup \
        --RegionId "$REGION" \
        --SecurityGroupId "$SECURITY_GROUP_ID" \
        --IpProtocol tcp \
        --PortRange "${PORT}/${PORT}" \
        --SourceCidrIp "$ip_cidr" 2>&1) || {
        # 规则可能已被手动删除，不算致命错误
        warn "删除旧规则时出错（可能已被删除）: $output"
    }
}

# ═══════════════════════════════════════════
#  6. 主流程
# ═══════════════════════════════════════════
main() {
    check_deps

    # 获取当前公网 IP
    local new_ip
    new_ip=$(get_public_ip)
    local new_cidr="${new_ip}/32"

    # 读取本地缓存
    local old_ip=""
    if [[ -f "$CACHE_FILE" ]]; then
        old_ip=$(cat "$CACHE_FILE" 2>/dev/null || true)
    fi

    # 如果 IP 没变，直接结束
    if [[ "$new_ip" == "$old_ip" ]]; then
        info "公网 IP 未变化 (${new_ip})，无需更新"
        exit 0
    fi

    info "检测到 IP 变化: ${old_ip:-<首次运行>} → ${new_ip}"

    # 查询阿里云上现有的脚本管理规则
    local existing_rules
    existing_rules=$(get_managed_rules)

    local need_add=true
    local rules_to_remove=()

    # 遍历现有规则
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == "$new_cidr" ]]; then
            # 新 IP 已经在规则中，无需添加
            need_add=false
            info "规则已存在: ${new_cidr}"
        else
            # 旧 IP 需要删除
            rules_to_remove+=("$line")
        fi
    done <<< "$existing_rules"

    # 先添加新规则（保证连接不断）
    if $need_add; then
        add_rule "$new_cidr"
    fi

    # 再删除旧规则
    for rule in "${rules_to_remove[@]}"; do
        remove_rule "$rule"
    done

    # 更新本地缓存
    echo "$new_ip" > "$CACHE_FILE"
    info "缓存已更新: ${new_ip}"

    # 最终确认：新规则已就位
    if $need_add; then
        info "安全组已更新，当前 IP ${new_ip} 可访问 SSH(${PORT})"
    fi
}

main "$@"
