#!/usr/bin/env bash
set -Eeuo pipefail

# Xboard-Node test installer.
# Usage: install-test-node.sh PANEL_URL TOKEN NODE_ID [xray|singbox]

PANEL_URL="${1:-}"
TOKEN="${2:-}"
NODE_ID="${3:-}"
KERNEL="${4:-xray}"

BIN="/usr/local/bin/xboard-node"
XBCTL="/opt/xboard-node-test/xbctl-linux-amd64"
CONF="/etc/xboard-node/config.yml"
ENV_FILE="/etc/xboard-node/node.env"
SERVICE_FILE="/etc/systemd/system/xboard-node.service"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "请使用 root 执行"
[[ -n "$PANEL_URL" && -n "$TOKEN" && -n "$NODE_ID" ]] || fail "用法: $0 PANEL_URL TOKEN NODE_ID [xray|singbox]"
[[ "$PANEL_URL" =~ ^https?://[^/]+/?$ ]] || fail "PANEL_URL 必须是面板根地址，例如 https://panel.example.com"
[[ "$TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]] || fail "TOKEN 含有不支持的字符；请使用面板生成的原始节点 Token"
[[ "$NODE_ID" =~ ^[0-9]+$ ]] || fail "NODE_ID 必须是数字"
[[ "$KERNEL" == "xray" || "$KERNEL" == "singbox" ]] || fail "内核只能填写 xray 或 singbox"
[[ -x "$BIN" ]] || fail "找不到已编译的节点程序 $BIN"
[[ -x "$XBCTL" ]] || fail "找不到 xbctl $XBCTL；请先把编译好的 xbctl 上传到 /opt/xboard-node-test/"

command -v systemctl >/dev/null || fail "当前系统不支持 systemd"

mkdir -p /etc/xboard-node
"$XBCTL" config init --mode node --panel-url "$PANEL_URL" --token "$TOKEN" --node-id "$NODE_ID" --output "$CONF"

INSTANCE_ID="$(awk '/^[[:space:]]*-[[:space:]]*id:/ {print $3; exit}' "$CONF")"
ENV_KEY="$(awk '/token_env:/ {print $2; exit}' "$CONF")"
[[ -n "$INSTANCE_ID" && -n "$ENV_KEY" ]] || fail "读取生成的节点配置失败"

# Select the requested embedded kernel.
sed -i -E "s/^([[:space:]]*type:).*/\\1 \"$KERNEL\"/" "$CONF"
mkdir -p "/etc/xboard-node/instances/$INSTANCE_ID"

# Keep the panel token out of the YAML file and restrict its permissions.
umask 077
printf '%s=%s\n' "$ENV_KEY" "$TOKEN" > "$ENV_FILE"
chmod 600 "$ENV_FILE"

# Stop an older instance before replacing its service definition.
systemctl stop xboard-node 2>/dev/null || true
cat > "$SERVICE_FILE" <<'UNIT'
[Unit]
Description=Xboard Node Test
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/xboard-node
EnvironmentFile=/etc/xboard-node/node.env
ExecStart=/usr/local/bin/xboard-node -c /etc/xboard-node/config.yml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable xboard-node
systemctl restart xboard-node
sleep 5

echo
echo "===== 节点服务状态 ====="
systemctl status xboard-node --no-pager -l || true
echo
echo "===== 最近 60 行日志 ====="
journalctl -u xboard-node -n 60 --no-pager || true

if ! systemctl is-active --quiet xboard-node; then
  fail "服务未保持运行；请根据上方日志排查面板握手或内核初始化错误"
fi

echo
echo "服务进程已运行。请继续检查日志中的 panel handshake、kernel/Xray 启动及节点配置更新结果；服务 active 本身不代表流量测试通过。"
