#!/usr/bin/env bash
# DeepSeek 用量面板 · 本机助手看门狗（macOS）
#
# 助手只在 Codex 运行时才有意义：这个看门狗每 3 秒看一眼，Codex 在跑就确保
# 助手在跑，Codex 退出就把助手停掉；它自己不打印任何东西，也不占资源。
#
# 由 install-helper.sh 安装；也可以直接跑：
#   DSTU_NODE=/opt/homebrew/bin/node ./start-helper.sh
#
# 可选环境变量：
#   DSTU_NODE    node 可执行文件路径（默认自动找 PATH、两套 Homebrew 前缀、nvm / fnm / volta 等）
#   DSTU_HELPER  dstu-helper.mjs 的路径（默认与本脚本同目录）
#   DSTU_LOG     运行日志路径（默认写同目录 helper.log）

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="${DSTU_HELPER:-$DIR/dstu-helper.mjs}"
PIDFILE="$DIR/helper.pid"
LOG="${DSTU_LOG:-$DIR/helper.log}"

find_node() {
  if [ -n "${DSTU_NODE:-}" ] && [ -x "${DSTU_NODE}" ]; then printf '%s' "$DSTU_NODE"; return; fi
  # 安装脚本把选中的 node 记在 node-path.txt（可能是它自己装好的便携版）。
  if [ -f "$DIR/node-path.txt" ]; then
    saved="$(head -n 1 "$DIR/node-path.txt" 2>/dev/null || true)"
    if [ -n "$saved" ] && [ -x "$saved" ]; then printf '%s' "$saved"; return; fi
  fi
  # 不同 CPU 架构的常见位置都列上：Apple 芯片 Homebrew 在 /opt/homebrew，
  # Intel Homebrew 在 /usr/local，MacPorts 在 /opt/local，Linux 发行版多在 /usr/bin。
  for candidate in "$(command -v node 2>/dev/null || true)" \
    /opt/homebrew/bin/node /opt/homebrew/opt/node/bin/node \
    /usr/local/bin/node /usr/local/opt/node/bin/node \
    /opt/local/bin/node /usr/bin/node /usr/local/node/bin/node \
    /snap/bin/node /opt/node/bin/node; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then printf '%s' "$candidate"; return; fi
  done
  for candidate in "$HOME"/.nvm/versions/node/*/bin/node \
    "$HOME"/.local/share/fnm/node-versions/*/installation/bin/node \
    "$HOME"/Library/Application\ Support/fnm/node-versions/*/installation/bin/node \
    "$HOME"/.volta/bin/node "$HOME"/.asdf/shims/node "$HOME"/.nodenv/shims/node \
    "$HOME"/.local/bin/node \
    "$HOME"/Library/Application\ Support/Codex++/node-runtime/node-*/bin/node \
    "${XDG_DATA_HOME:-$HOME/.local/share}"/codexpp/node-runtime/node-*/bin/node; do
    if [ -x "$candidate" ]; then printf '%s' "$candidate"; return; fi
  done
  printf '%s' ""
}

# 只看 Codex 桌面端（应用路径 / 进程名）和 codex CLI，别把本目录路径里的
# codex 字样算进去，否则助手会永远停不下来。
codex_running() {
  # 进程名按各平台实际叫法都列一遍：ChatGPT 是 Codex 桌面端，
  # codex-plus-plus 是 Codex++ 本体，codex 是命令行。
  for name in ChatGPT Codex CodexPlusPlus codex-plus-plus Codex++ codex; do
    if pgrep -x "$name" >/dev/null 2>&1; then return 0; fi
  done
  if pgrep -f '/ChatGPT\.app/' >/dev/null 2>&1; then return 0; fi
  if pgrep -f '/Codex\.app/' >/dev/null 2>&1; then return 0; fi
  if pgrep -f '/Codex++\.app/' >/dev/null 2>&1; then return 0; fi
  return 1
}

helper_pid() {
  if [ -f "$PIDFILE" ]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then printf '%s' "$pid"; return; fi
  fi
  printf '%s' ""
}

helper_running() {
  [ -n "$(helper_pid)" ]
}

start_helper() {
  node="$(find_node)"
  if [ -z "$node" ]; then
    printf '%s node 没找到，先装 Node.js 18+ 或设置 DSTU_NODE\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$LOG"
    return
  fi
  ( cd "$DIR" && nohup "$node" "$HELPER" >>"$LOG" 2>&1 & echo $! >"$PIDFILE" )
}

stop_helper() {
  pid="$(helper_pid)"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
}

trap 'stop_helper; exit 0' TERM INT HUP

while :; do
  if codex_running; then
    if ! helper_running && [ -f "$HELPER" ]; then
      start_helper
    fi
  else
    if helper_running; then
      stop_helper
    fi
  fi
  sleep 3
done
