#!/usr/bin/env bash
#
# bootstrap.sh
# 新机器一键初始化：安装依赖 → 配置 AK → 填写服务器信息 → 设置 cron
#
# Usage: bash bootstrap.sh

set -euo pipefail

CONF_FILE="$HOME/.config/aliyun-sg.conf"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[bootstrap]${NC} $*"; }
warn()  { echo -e "${YELLOW}[bootstrap]${NC} $*"; }

echo "============================================"
echo "  阿里云 ECS SSH 一键初始化"
echo "============================================"
echo ""

# ══════════════════════════════════════════════
#  Step 1: 安装依赖
# ══════════════════════════════════════════════
info "Step 1/4: 检查依赖..."

need_install=""
for cmd in curl jq; do
    if command -v "$cmd" &>/dev/null; then
        info "  ✓ $cmd"
    else
        info "  ✗ $cmd 缺失"
        need_install="$need_install $cmd"
    fi
done

if command -v aliyun &>/dev/null; then
    info "  ✓ aliyun ($(aliyun version 2>/dev/null | head -1))"
else
    info "  ✗ aliyun 缺失"
    need_install="$need_install aliyun"
fi

if [[ -n "$need_install" ]]; then
    echo ""
    read -r -p "是否自动安装缺失的依赖？[Y/n] " go
    if [[ ! "$go" =~ ^[Nn]$ ]]; then
        for dep in $need_install; do
            case "$dep" in
                curl|jq)
                    info "安装 $dep ..."
                    sudo apt install -y "$dep" || warn "$dep 安装失败，请手动安装"
                    ;;
                aliyun)
                    info "安装 aliyun CLI ..."
                    sudo /bin/bash -c "$(curl -fsSL https://aliyuncli.alicdn.com/install.sh)"
                    ;;
            esac
        done
    fi
fi

# ══════════════════════════════════════════════
#  Step 2: 配置 AccessKey
# ══════════════════════════════════════════════
echo ""
info "Step 2/4: 配置 AccessKey..."

if aliyun configure list 2>/dev/null | grep -q 'access_key_id'; then
    info "  ✓ AccessKey 已配置"
else
    warn "  未检测到 AccessKey 配置，即将进入交互配置"
    echo "  需要 AccessKey ID 和 AccessKey Secret"
    echo "  获取地址: https://ram.console.aliyun.com/users"
    echo ""
    aliyun configure
fi

# ══════════════════════════════════════════════
#  Step 3: 创建配置文件
# ══════════════════════════════════════════════
echo ""
info "Step 3/4: 配置服务器信息..."

if [[ -f "$CONF_FILE" ]]; then
    info "  ✓ $CONF_FILE 已存在"
else
    warn "  未找到配置文件，准备交互创建..."
    echo ""

    read -r -p "ECS 公网 IP: " host_ip
    read -r -p "SSH 用户名 (默认 ecs-user): " ssh_user
    ssh_user="${ssh_user:-ecs-user}"
    read -r -p "安全组 ID (格式 sg-xxxx): " sg_id
    read -r -p "地域 (默认 cn-wulanchabu): " region
    region="${region:-cn-wulanchabu}"

    mkdir -p "$(dirname "$CONF_FILE")"
    cat > "$CONF_FILE" <<EOF
# ═══════════════════════════════════════════════════════════════
#  aliyun ECS SSH 配置文件
#  由 init-aliyun-ssh.sh / update-aliyun-sg.sh 共用
#
#  ⚠️  此文件包含敏感信息，请勿提交到公开仓库或分享给他人
# ═══════════════════════════════════════════════════════════════

# ECS 公网 IP（在阿里云 ECS 控制台 → 实例 → IP 地址 查看）
HOST_IP="${host_ip}"

# SSH 登录用户名（阿里云 Ubuntu 默认 root，Alibaba Cloud Linux 默认 ecs-user）
REMOTE_USER="${ssh_user}"

# 安全组 ID（在阿里云 ECS 控制台 → 安全组 查看）
SECURITY_GROUP_ID="${sg_id}"

# 地域（在阿里云 ECS 控制台 → 实例详情 查看）
REGION="${region}"
EOF
    info "  ✓ 已创建 $CONF_FILE"
fi

# ══════════════════════════════════════════════
#  Step 4: 设置 cron 定时任务
# ══════════════════════════════════════════════
echo ""
info "Step 4/4: 设置 cron..."

SCRIPT_PATH="$(dirname "$(readlink -f "$0")")/update-aliyun-sg.sh"
CRON_LINE="*/5 * * * * /bin/bash ${SCRIPT_PATH} >> /tmp/aliyun-sg-update.log 2>&1"

if crontab -l 2>/dev/null | grep -qF "update-aliyun-sg.sh"; then
    info "  ✓ cron 已配置"
else
    read -r -p "是否添加定时任务（每5分钟更新IP）？[Y/n] " go
    if [[ ! "$go" =~ ^[Nn]$ ]]; then
        (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
        info "  ✓ cron 已添加"
    else
        info "  已跳过 cron 设置，后续可手动添加："
        echo "  $CRON_LINE"
    fi
fi

# ══════════════════════════════════════════════
#  完成
# ══════════════════════════════════════════════
echo ""
echo "============================================"
echo "  初始化完成！"
echo "============================================"
echo ""
echo "后续操作："
echo "  bash $(dirname "$(readlink -f "$0")")/init-aliyun-ssh.sh   # 配置密钥和 SSH config"
echo "  bash ${SCRIPT_PATH}                                        # 首次更新安全组规则"
echo ""
