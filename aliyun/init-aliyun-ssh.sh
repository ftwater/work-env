#!/usr/bin/env bash
#
# init-aliyun-ssh.sh
# 初始化阿里云服务器 SSH 配置：创建密钥对、更新 ~/.ssh/config、配置免密登录
#
# Usage: bash init-aliyun-ssh.sh

set -euo pipefail

SSH_DIR="$HOME/.ssh"
CONFIG_FILE="$SSH_DIR/config"
HOST_ALIAS="aliyun"

# 从配置文件读取敏感信息
CONF_FILE="$HOME/.config/aliyun-sg.conf"
if [[ -f "$CONF_FILE" ]]; then
    source "$CONF_FILE"
else
    cat >&2 <<EOF
[ERROR] 配置文件不存在: ${CONF_FILE}

请创建该文件并填入以下内容（按实际情况修改）：

  HOST_IP="<ECS公网IP>"
  REMOTE_USER="ecs-user"

参考模板：~/.config/aliyun-sg.conf 已配置的机器
EOF
    exit 1
fi

KEY_FILE="$SSH_DIR/$HOST_ALIAS"
PUB_FILE="$SSH_DIR/${HOST_ALIAS}.pub"

# ── 颜色输出 ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── 1. 确保 .ssh 目录存在 ─────────────────────────────────
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# ── 2. 处理 config 中已有的 Host aliyun ─────────────────────
if [[ -f "$CONFIG_FILE" ]] && grep -qE "^[[:space:]]*Host[[:space:]]+${HOST_ALIAS}[[:space:]]*$" "$CONFIG_FILE"; then
    warn "~/.ssh/config 中已存在 Host ${HOST_ALIAS} 配置段"
    warn "现有配置内容："
    echo "  ----------------------------------------"
    awk "/^[[:space:]]*Host[[:space:]]+${HOST_ALIAS}[[:space:]]*$/{found=1; print; next} found && /^[[:space:]]*Host[[:space:]]+/{found=0} found" "$CONFIG_FILE" | sed 's/^/  /'
    echo "  ----------------------------------------"
    read -r -p "是否覆盖？[y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "保持现有配置，退出。"
        exit 0
    fi
    # 删除旧 Host aliyun 段（从匹配行到下一个 Host 或 EOF）
    # 方案：用 awk，输出时跳过整个 Host aliyun 段
    tmpconfig=$(mktemp)
    awk -v host="${HOST_ALIAS}" '
        $0 ~ "^[[:space:]]*Host[[:space:]]+"host"[[:space:]]*$" { skip=1; next }
        skip && /^[[:space:]]*Host[[:space:]]+/ { skip=0 }
        !skip
    ' "$CONFIG_FILE" > "$tmpconfig"
    mv "$tmpconfig" "$CONFIG_FILE"
    info "已删除旧的 Host ${HOST_ALIAS} 配置段"
fi

# ── 3. 交互式输入密钥 ─────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo "  步骤 1：输入私钥"
echo "══════════════════════════════════════════"
echo "将私钥内容粘贴到终端，然后按 Enter 再按 Ctrl+D 结束："
echo "（如果私钥有 passphrase，请一并粘贴完整内容）"
echo "──────────────────────────────────────────"

# 使用 cat 读取，原样保存（多行、特殊字符都不丢失）
cat > "$KEY_FILE"

# 检查是否粘贴了内容
if [[ ! -s "$KEY_FILE" ]]; then
    error "私钥文件为空，退出。"
    exit 1
fi

# 修正私钥格式：确保以正确的开头，以正确的结尾
# 有些粘贴可能会缺少首尾行或多了空行
content=$(cat "$KEY_FILE")
# 移除首尾空白
content=$(echo "$content" | sed -e '/^[[:space:]]*$/d')
echo "$content" > "$KEY_FILE"

# 检查是否看起来像私钥
if ! grep -qE "^(-----BEGIN |ssh-)" "$KEY_FILE"; then
    warn "私钥内容看起来不标准，请确认格式正确。（应该是 PEM 或 OpenSSH 格式）"
fi

echo ""
echo "══════════════════════════════════════════"
echo "  步骤 2：输入公钥"
echo "══════════════════════════════════════════"
echo "将公钥内容粘贴到终端，然后按 Enter 再按 Ctrl+D 结束："
echo "──────────────────────────────────────────"

cat > "$PUB_FILE"

if [[ ! -s "$PUB_FILE" ]]; then
    error "公钥文件为空，退出。"
    rm -f "$KEY_FILE"
    exit 1
fi

# 清理公钥首尾空白
pubcontent=$(cat "$PUB_FILE")
pubcontent=$(echo "$pubcontent" | sed -e '/^[[:space:]]*$/d')
echo "$pubcontent" > "$PUB_FILE"

# ── 4. 设置权限 ──────────────────────────────────────────
chmod 600 "$KEY_FILE"
chmod 644 "$PUB_FILE"
info "私钥权限已设为 600：${KEY_FILE}"
info "公钥权限已设为 644：${PUB_FILE}"

# ── 5. 更新 SSH config ───────────────────────────────────
echo ""
info "更新 ~/.ssh/config ..."

HOST_BLOCK="
Host ${HOST_ALIAS}
    HostName ${HOST_IP}
    User ${REMOTE_USER}
    IdentityFile ${KEY_FILE}
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
"

if [[ ! -f "$CONFIG_FILE" ]]; then
    # config 不存在，直接创建
    echo "$HOST_BLOCK" | sed '1d' > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    info "已创建 ~/.ssh/config 并添加 Host ${HOST_ALIAS} 配置"
else
    # 删除文件末尾多余空行后追加
    sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$CONFIG_FILE" 2>/dev/null || true
    echo "$HOST_BLOCK" >> "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    info "已追加 Host ${HOST_ALIAS} 到 ~/.ssh/config"
fi

# ── 6. 检查→配置免密登录 ──────────────────────────────────
echo ""
info "检查免密登录状态 ..."

if ssh -o BatchMode=yes -o ConnectTimeout=5 "${REMOTE_USER}@${HOST_IP}" 'echo ok' 2>/dev/null; then
    info "服务器已配置免密登录，无需重复操作。"
else
    warn "免密登录未配置，即将使用 ssh-copy-id 上传公钥。"
    echo "  目标：${REMOTE_USER}@${HOST_IP}"
    echo "  密钥：${PUB_FILE}"
    echo ""
    read -r -p "是否继续？[Y/n] " go
    if [[ "$go" =~ ^[Nn]$ ]]; then
        info "跳过免密配置，脚本结束。"
        exit 0
    fi

    if ssh-copy-id -i "$PUB_FILE" "${REMOTE_USER}@${HOST_IP}"; then
        info "ssh-copy-id 执行成功"
    else
        error "ssh-copy-id 执行失败，请手动检查："
        echo "  ssh-copy-id -i ${PUB_FILE} ${REMOTE_USER}@${HOST_IP}"
        exit 1
    fi

    # 验证
    echo ""
    info "验证免密登录 ..."
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${REMOTE_USER}@${HOST_IP}" 'echo ok' 2>/dev/null; then
        info "免密登录验证通过 ✓"
    else
        warn "免密登录验证失败，请手动排查"
    fi
fi

# ── 7. 完成 ──────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo "  SSH 初始化完成"
echo "══════════════════════════════════════════"
echo "现在可以用以下命令连接服务器："
echo ""
echo "  ssh ${HOST_ALIAS}"
echo ""
