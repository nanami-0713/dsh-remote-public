#!/bin/bash
# 一键启动 DSH + bridge，方便 Mac 重启后恢复远程连接。
# 用法: bash start_dsh_remote.sh
# 建议先通过环境变量指定实际路径，例如：
#   DSH_BIN=/path/to/dsh NODE_BIN=/path/to/node BRIDGE_JS=/path/to/bridge/server.js bash start_dsh_remote.sh

set -u

DSH_BIN="${DSH_BIN:-/path/to/dsh}"
NODE_BIN="${NODE_BIN:-/path/to/node}"
BRIDGE_JS="${BRIDGE_JS:-/path/to/dsh-remote/bridge/server.js}"
DSH_WORKDIR="${DSH_WORKDIR:-$HOME}"
BRIDGE_WORKDIR="$(dirname "$BRIDGE_JS")"
LOG_DIR="$HOME/.dsh"
mkdir -p "$LOG_DIR"

echo "==> 检查 DSH (127.0.0.1:3080) ..."
if lsof -nP -iTCP:3080 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "    DSH 已在运行"
else
  echo "    DSH 未运行，正在启动..."
  cd "$DSH_WORKDIR"
  nohup "$DSH_BIN" web > "$LOG_DIR/dsh-web.log" 2>&1 &
  sleep 3
fi

echo "==> 检查 bridge (0.0.0.0:8787) ..."
if lsof -nP -iTCP:8787 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "    bridge 已在运行"
else
  echo "    bridge 未运行，正在启动..."
  cd "$BRIDGE_WORKDIR"
  nohup "$NODE_BIN" "$BRIDGE_JS" > "$LOG_DIR/dsh-bridge.log" 2>&1 &
  sleep 2
fi

echo "==> 验证 DSH ..."
curl -sS -m 3 -o /dev/null -w "    DSH HTTP %{http_code}\n" http://127.0.0.1:3080/ || echo "    DSH 启动失败，请查看 $LOG_DIR/dsh-web.log"

echo "==> 验证 bridge ..."
curl -sS -m 3 http://127.0.0.1:8787/health && echo || echo "    bridge 启动失败，请查看 $LOG_DIR/dsh-bridge.log"

echo "==> Tailscale ..."
if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
  TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
  echo "    Tailscale IP: ${TS_IP:-未知}"
  echo ""
  echo "手机 App 填写:"
  echo "  服务器地址: http://${TS_IP:-<Tailscale IP>}:8787"
  echo "  Token: 查看 bridge/config.json"
else
  echo "    Tailscale 未运行，请先执行:"
  echo "    sudo brew services start tailscale"
fi

echo ""
echo "完成。如果手机还连不上，检查手机 Tailscale App 是否已连接。"
