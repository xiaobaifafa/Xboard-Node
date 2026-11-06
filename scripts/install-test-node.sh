#!/usr/bin/env bash
set -Eeuo pipefail

# One-command installer for the already-built test binaries on this VPS.
# Usage:
# curl -fsSL URL | sudo bash -s -- --mode node --panel URL --token TOKEN --node-id ID [--kernel xray|singbox]

MODE=""
PANEL_URL=""
TOKEN=""
NODE_ID=""
KERNEL="xray"

BIN="/usr/local/bin/xboard-node"
XBCTL="/opt/xboard-node-test/xbctl-linux-amd64"
CONF="/etc/xboard-node/config.yml"
ENV_FILE="/etc/xboard-node/node.env"
SERVICE_FILE="/etc/systemd/system/xboard-node.service"

fail() { echo "[ERROR] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)     [[ $# -ge 2 ]] || fail "--mode 缺少参数"; MODE="$2"; shift 2 ;;
    --panel)    [[ $# -ge 2 ]] || fail "--panel 缺少参数"; PANEL_URL="$2"; shift 2 ;;
    --token)    [[ $# -ge 2 ]] || fail "--token 缺少参数"; TOKEN="$2"; shift 2 ;;
    --node-id)  [[ $# -ge 2 ]] || fail "--node-id 缺少参数"; NODE_ID="$2"; shift 2 ;;
    --kernel)   [[ $# -ge 2 ]] || fail "--kernel 缺少参数"; KERNEL="$2"; shift 2 ;;
    -h|--help)
      echo "用法: bash -s -- --mode node --panel PANEL_URL --token TOKEN --node-id NODE_ID [--kernel xray|singbox]"
      exit 0
      ;;
    *) fail "未知参数: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || fail "请使用 root 或 sudo 执行"
[[ "$MODE" == "node" ]] || fail "当前测试脚本只支持 --mode node"
[[ -n "$PANEL_URL" && -n "$TOKEN" && -n "$NODE_ID" ]] || fail "缺少参数。必需：--mode node --panel URL --token TOKEN --node-id ID"
[[ "$PANEL_URL" =~ ^https?://[^/]+/?$ ]] || fail "--panel 请填写面板根地址，例如 https://panel.example.com/"
[[ "$NODE_ID" =~ ^[0-9]+$ ]] || fail "--node-id 必须是数字"
[[ "$KERNEL" == "xray" || "$KERNEL" == "singbox" ]] || fail "--kernel 只能是 xray 或 singbox"
[[ -x "$BIN" ]] || fail "找不到已编译节点程序：$BIN"
[[ -x "$XBCTL" ]] || fail "找不到 xbctl：$XBCTL"

command -v systemctl >/dev/null 2>&1 || fail "系统不支持 systemd"
mkdir -p /etc/xboard-node

echo "[STEP] 生成节点配置"
"$XBCTL" config init \
  --mode node \
  --panel-url "$PANEL_URL" \
  --token "$TOKEN" \
  --node-id "$NODE_ID" \
  --output "$CONF"

INSTANCE_ID="$(awk '/^[[:space:]]*-[[:space:]]*id:/ {print $3; exit}' "$CONF")"
ENV_KEY="$(awk '/token_env:/ {print $2; exit}' "$CONF")"
[[ -n "$INSTANCE_ID" && -n "$ENV_KEY" ]] || fail "读取生成配置失败"

sed -i -E "s/^([[:space:]]*type:).*/\\1 \"$KERNEL\"/" "$CONF"
mkdir -p "/etc/xboard-node/instances/$INSTANCE_ID"

# Token is stored in a root-only EnvironmentFile, not in the YAML config.
umask 077
printf '%s=%s\n' "$ENV_KEY" "$TOKEN" > "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "[STEP] 配置 systemd 服务"
systemctl stop xboard-node.service >/dev/null 2>&1 || true
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
systemctl enable xboard-node.service >/dev/null
systemctl reset-failed xboard-node.service >/dev/null 2>&1 || true
systemctl restart xboard-node.service
sleep 5

echo
echo "===== 服务状态 ====="
systemctl status xboard-node.service --no-pager -l || true
echo
echo "===== 最近 60 行日志 ====="
journalctl -u xboard-node.service -n 60 --no-pager || true

if ! systemctl is-active --quiet xboard-node.service; then
  fail "节点服务未保持运行，请查看上方日志"
fi

echo
echo "[OK] 服务进程正在运行。请以日志中的面板握手、内核启动和节点配置更新结果判断是否真正启动成功。"
