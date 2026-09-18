#!/usr/bin/env bash
# DeepSeek 用量面板 · 本机助手一键安装 / 卸载 / 查看状态（macOS）
#
# 助手只负责把 DeepSeek 账户余额送进面板：Codex 在跑的时候每 5 分钟读一次，
# 面板点「刷新余额」时立刻补一次。token 用量和费用统计不需要它，不装也不影响。
# 看门狗只在 Codex 运行时让助手跑，Codex 退出就把助手停掉，平时不占资源。
#
# 用法：
#   bash install-helper.sh              安装并启动
#   bash install-helper.sh -Status      查看状态
#   bash install-helper.sh -Uninstall   卸载
#
# 不下载仓库、直接从网络跑也可以（面板「复制安装命令」给的就是这条）：
#   curl -fsSL https://raw.githubusercontent.com/Saydness/codexpp-deepseek-token-usage/main/helper/install-helper.sh | bash
#
# 安装位置：~/Library/Application Support/Codex++/dstu-helper
# 自启动：  ~/Library/LaunchAgents/com.saydness.dstu-helper.plist
# 不需要管理员权限；卸载时把这些一并清掉（已经存好的余额 Key 会保留）。
#
# 支持的机器：Codex++ 的两种 macOS 安装包（Apple 芯片 arm64、Intel x86_64）都用这一份。
# 脚本只用系统自带的 sh、curl、pgrep 这类命令，node 的位置自动去找（含 Homebrew 两套
# 前缀和 nvm / fnm / volta 等）。先检测：有 18+ 的 node 就直接用，没有才装
# （优先 Homebrew，其次官方压缩包，都不需要管理员权限）。

set -u

HELPER_FILES="dstu-helper.mjs balance_sources.mjs start-helper.sh"
DEFAULT_SOURCE_URL="https://raw.githubusercontent.com/Saydness/codexpp-deepseek-token-usage/main/helper"
LABEL="com.saydness.dstu-helper"

OS="$(uname -s)"
case "$OS" in
  Darwin) PLATFORM="mac" ;;
  Linux) PLATFORM="linux" ;;
  *) PLATFORM="unix" ;;
esac

if [ "$PLATFORM" = "mac" ]; then
  INSTALL_DIR="$HOME/Library/Application Support/Codex++/dstu-helper"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
else
  INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/codexpp/dstu-helper"
  UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  UNIT="$UNIT_DIR/dstu-helper.service"
  DESKTOP_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/dstu-helper.desktop"
fi

MODE="install"
NO_START=""
SOURCE=""
for arg in "$@"; do
  case "$arg" in
    -Uninstall|--uninstall|-u) MODE="uninstall" ;;
    -Status|--status|-s) MODE="status" ;;
    -NoStart|--no-start) NO_START="1" ;;
    -Source=*|--source=*) SOURCE="${arg#*=}" ;;
    *) printf '未知参数：%s\n' "$arg"; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

find_node() {
  if [ -n "${DSTU_NODE:-}" ] && [ -x "${DSTU_NODE}" ]; then printf '%s' "$DSTU_NODE"; return; fi
  # 先看 PATH，再按不同 CPU 架构的常见位置找：Apple 芯片的 Homebrew 在 /opt/homebrew，
  # Intel 的 Homebrew 在 /usr/local，MacPorts 在 /opt/local，Linux 发行版多在 /usr/bin。
  for candidate in "$(command -v node 2>/dev/null || true)" \
    /opt/homebrew/bin/node /opt/homebrew/opt/node/bin/node \
    /usr/local/bin/node /usr/local/opt/node/bin/node \
    /opt/local/bin/node /usr/bin/node /usr/local/node/bin/node \
    /snap/bin/node /opt/node/bin/node /opt/nvm/versions/node/*/bin/node; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then printf '%s' "$candidate"; return; fi
  done
  # 版本管理器：nvm / fnm / volta / asdf / nodenv / nix，装在哪个架构都能被认出来。
  for candidate in "$HOME"/.nvm/versions/node/*/bin/node \
    "$HOME"/.local/share/fnm/node-versions/*/installation/bin/node \
    "$HOME"/Library/Application\ Support/fnm/node-versions/*/installation/bin/node \
    "$HOME"/.volta/bin/node "$HOME"/.asdf/shims/node "$HOME"/.nodenv/shims/node \
    "$HOME"/.local/bin/node "$HOME"/.nix-profile/bin/node \
    "$HOME"/Library/Application\ Support/Codex++/node-runtime/node-*/bin/node \
    "${XDG_DATA_HOME:-$HOME/.local/share}"/codexpp/node-runtime/node-*/bin/node \
    /run/current-system/sw/bin/node; do
    if [ -x "$candidate" ]; then printf '%s' "$candidate"; return; fi
  done
  printf '%s' ""
}

# 助手自带的 node 放这里（官方压缩包解压出来的，不碰系统目录、不需要管理员）。
node_runtime_root() {
  if [ "$PLATFORM" = "mac" ]; then
    printf '%s' "$HOME/Library/Application Support/Codex++/node-runtime"
  else
    printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}/codexpp/node-runtime"
  fi
}

node_major() {
  node_bin="$1"
  if [ -n "$node_bin" ]; then
    "$node_bin" -p 'process.versions.node.split(".")[0]' 2>/dev/null || printf '0'
  else
    printf '0'
  fi
}

download_file() {
  # 第一个参数是输出路径，后面几个候选地址依次试；成功时把用上的地址放进 DL_OK_URL。
  out="$1"; shift
  for url in "$@"; do
    say "  下载 $url"
    if have curl; then
      if curl -fsSL --connect-timeout 20 -o "$out" "$url"; then DL_OK_URL="$url"; return 0; fi
    elif have wget; then
      if wget -q --timeout=30 -O "$out" "$url"; then DL_OK_URL="$url"; return 0; fi
    fi
    say "  这条下不动，换下一条"
  done
  return 1
}

# 结果放在 NODE_RESOLVED 里（不用 stdout：调用处要把函数输出和日志分开）。
NODE_RESOLVED=""

install_node_runtime() {
  # 先检测：已经有能用的 node 就用现成的，什么都不装。
  NODE_RESOLVED=""
  found="$(find_node)"
  if [ -n "$found" ]; then
    major="$(node_major "$found")"
    if [ "$major" -ge 18 ] 2>/dev/null; then
      say "  检测到 Node.js：$found（$("$found" -v 2>/dev/null || printf '版本未知')）——直接使用，不再安装"
      NODE_RESOLVED="$found"
      return 0
    fi
    say "  检测到 Node.js：$found，但版本低于 18，助手用不了，继续装新的"
  else
    say '  检测 Node.js：没装'
  fi
  say '  助手需要 Node.js 18+，这里替你先装好（只装一次）。'

  # 1) 有 Homebrew 就交给它（macOS 上最常见，装完系统里也能用）
  if have brew; then
    say '  用 Homebrew 安装：brew install node'
    if HOMEBREW_NO_AUTO_UPDATE=1 brew install node >/dev/null 2>&1; then
      found="$(find_node)"
      if [ -n "$found" ] && [ "$(node_major "$found")" -ge 18 ] 2>/dev/null; then
        NODE_RESOLVED="$found"
        return 0
      fi
    fi
    say '  Homebrew 这条没成功，改用官方压缩包（不需要管理员权限）'
  fi

  # 2) 官方压缩包：按 CPU 架构挑对的那份，解压进本机目录
  arch="$(uname -m)"
  if [ "$PLATFORM" = "mac" ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = "1" ]; then
    arch="arm64"
  fi
  case "$arch" in
    arm64|aarch64) pkg_arch="darwin-arm64"; [ "$PLATFORM" = "mac" ] || pkg_arch="linux-arm64" ;;
    x86_64|amd64) pkg_arch="darwin-x64"; [ "$PLATFORM" = "mac" ] || pkg_arch="linux-x64" ;;
    armv7l) pkg_arch="linux-armv7l" ;;
    *) pkg_arch="darwin-x64"; [ "$PLATFORM" = "mac" ] || pkg_arch="linux-x64" ;;
  esac
  version="${DSTU_NODE_VERSION:-}"
  if [ -z "$version" ]; then
    version="$(curl -fsSL --connect-timeout 15 https://nodejs.org/dist/index.json 2>/dev/null | tr '}' '\n' | grep -m1 '"lts":"[A-Za-z]' | sed -n 's/.*"version":"\(v[0-9][0-9.]*\)".*/\1/p' || true)"
  fi
  [ -n "$version" ] || version="v22.20.0"
  tarball="node-$version-$pkg_arch.tar.gz"
  tmp="${TMPDIR:-/tmp}"
  if ! download_file "$tmp/$tarball" \
    "https://nodejs.org/dist/$version/$tarball" \
    "https://npmmirror.com/mirrors/node/$version/$tarball"; then
    say '  下载失败：检查网络后重跑本脚本即可（也可以先 brew install node）'
    return 1
  fi
  root="$(node_runtime_root)"
  mkdir -p "$root"
  if ! tar -xzf "$tmp/$tarball" -C "$root" 2>/dev/null; then
    say '  解压失败，助手先跳过；装了 Node.js 18+ 之后重启 Codex 即可'
    rm -f "$tmp/$tarball"
    return 1
  fi
  rm -f "$tmp/$tarball"
  portable="$root/node-$version-$pkg_arch/bin/node"
  if [ -x "$portable" ]; then
    NODE_RESOLVED="$portable"
    return 0
  fi
  return 1
}

# 这台机器是什么架构、node 又是什么架构：两个都对上才最稳，对不上也能跑（Rosetta / 兼容层）。
machine_arch() {
  machine="$(uname -m 2>/dev/null || printf '未知')"
  if [ "$PLATFORM" = "mac" ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = "1" ]; then
    printf 'arm64（Apple 芯片）'
    return
  fi
  case "$machine" in
    arm64|aarch64) printf 'ARM64' ;;
    x86_64|amd64) printf 'x86_64' ;;
    armv7l|armv6l) printf '%s' "$machine" ;;
    *) printf '%s' "$machine" ;;
  esac
}

node_arch() {
  node_bin="$1"
  if [ -n "$node_bin" ]; then
    "$node_bin" -p 'process.arch' 2>/dev/null || printf '未知'
  else
    printf '未装 node'
  fi
}

watchdog_running() { pgrep -f 'start-helper.sh' >/dev/null 2>&1; }
helper_running() { pgrep -f 'dstu-helper.mjs' >/dev/null 2>&1; }

say_status_line() {
  name="$1"
  if [ -f "$INSTALL_DIR/$name" ]; then
    say "    - $name   ok"
  else
    say "    - $name   缺失"
  fi
}

show_status() {
  say ""
  say "DeepSeek 用量助手 · 状态（$OS）"
  say "  系统架构 : $OS $(machine_arch)"
  if [ -d "$INSTALL_DIR" ]; then
    say "  安装目录 : $INSTALL_DIR  [已安装]"
    for name in $HELPER_FILES; do say_status_line "$name"; done
  else
    say "  安装目录 : $INSTALL_DIR  [未安装]"
  fi
  if [ "$PLATFORM" = "mac" ]; then
    if [ -f "$PLIST" ]; then say "  开机启动 : $PLIST  [已配置]"; else say "  开机启动 : $PLIST  [未配置]"; fi
  elif have systemctl; then
    if [ -f "$UNIT" ]; then say "  开机启动 : $UNIT  [已配置]"; else say "  开机启动 : $UNIT  [未配置]"; fi
  else
    if [ -f "$DESKTOP_FILE" ]; then say "  开机启动 : $DESKTOP_FILE  [已配置]"; else say "  开机启动 : 未配置（没有 systemd，可在桌面自启动里加 start-helper.sh）"; fi
  fi
  if watchdog_running; then say "  看门狗   : 运行中"; else say "  看门狗   : 未运行"; fi
  if helper_running; then say "  助手进程 : 运行中"; else say "  助手进程 : 未运行"; fi
  node="$(find_node)"
  if [ -n "$node" ]; then
    say "  Node.js  : $node（$(node_arch "$node")）"
  else
    say "  Node.js  : 没找到（助手要 Node.js 18+）"
    say "             macOS 装法： brew install node ｜ 各家 Linux 用发行版仓库装 nodejs"
  fi
  if [ "$PLATFORM" = "mac" ] && have security; then
    if security find-generic-password -s deepseek-balance >/dev/null 2>&1; then
      say "  已存 Key : 有（登录钥匙串）"
    else
      say "  已存 Key : 没有（面板里填一次，或让它读 Codex 自己的 Key）"
    fi
  fi
  say ""
}

write_mac_plist() {
  mkdir -p "$(dirname "$PLIST")"
  cat >"$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$INSTALL_DIR/start-helper.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>WorkingDirectory</key><string>$INSTALL_DIR</string>
  <key>StandardOutPath</key><string>$INSTALL_DIR/watchdog.log</string>
  <key>StandardErrorPath</key><string>$INSTALL_DIR/watchdog.log</string>
</dict>
</plist>
PLIST_EOF
}

start_autostart() {
  if [ "$PLATFORM" = "mac" ]; then
    write_mac_plist
    launchctl unload "$PLIST" >/dev/null 2>&1 || true
    if ! launchctl load "$PLIST" >/dev/null 2>&1; then
      launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
    fi
  elif have systemctl && systemctl --user show-environment >/dev/null 2>&1; then
    mkdir -p "$UNIT_DIR"
    cat >"$UNIT" <<UNIT_EOF
[Unit]
Description=DeepSeek usage panel helper (balance reader)

[Service]
ExecStart=/bin/bash $INSTALL_DIR/start-helper.sh
WorkingDirectory=$INSTALL_DIR
Restart=always

[Install]
WantedBy=default.target
UNIT_EOF
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable --now dstu-helper.service >/dev/null 2>&1 || true
    if have loginctl && ! loginctl show-user "$(id -u)" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
      say "提示（可跳过）：想让助手在你退出桌面后也保持待命，执行一次 loginctl enable-linger $USER"
    fi
  else
    mkdir -p "$(dirname "$DESKTOP_FILE")"
    cat >"$DESKTOP_FILE" <<DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=DeepSeek 用量助手
Comment=读取 DeepSeek 账户余额，Codex 退出就停
Exec=/bin/bash $INSTALL_DIR/start-helper.sh
X-GNOME-Autostart-enabled=true
DESKTOP_EOF
    if [ -z "$NO_START" ]; then
      ( cd "$INSTALL_DIR" && nohup /bin/bash "$INSTALL_DIR/start-helper.sh" >>"$INSTALL_DIR/watchdog.log" 2>&1 & )
    fi
  fi
}

do_install() {
  src="$SOURCE"
  src_is_url=""
  if [ -z "$src" ]; then
    self_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
    if [ -n "$self_dir" ] && [ -f "$self_dir/dstu-helper.mjs" ]; then
      src="$self_dir"
    else
      src="$DEFAULT_SOURCE_URL"
      src_is_url="1"
    fi
  elif printf '%s' "$src" | grep -Eq '^https?://'; then
    src_is_url="1"
  fi

  mkdir -p "$INSTALL_DIR"
  say "从 $src 安装到 $INSTALL_DIR"
  for name in $HELPER_FILES; do
    target="$INSTALL_DIR/$name"
    if [ -n "$src_is_url" ]; then
      if have curl; then
        curl -fsSL "${src%/}/$name" -o "$target"
      else
        wget -qO "$target" "${src%/}/$name"
      fi
    else
      cp "$src/$name" "$target"
    fi
    if [ ! -f "$target" ]; then say "缺少文件：$name"; exit 1; fi
  done
  chmod +x "$INSTALL_DIR/start-helper.sh" 2>/dev/null || true

  # 缺 Node.js 就在这里补上（有就跳过），用户只需要把这一个脚本跑起来。
  install_node_runtime || true
  if [ -n "$NODE_RESOLVED" ]; then
    printf '%s\n' "$NODE_RESOLVED" >"$INSTALL_DIR/node-path.txt"
  fi

  start_autostart

  if [ -z "$NODE_RESOLVED" ]; then
    say ""
    say "提示：Node.js 没装成功（网络不通或被取消），助手暂时起不来；"
    say "      装上 Node.js 18+ 后不用重装本助手，重启 Codex 即可。"
    say "      macOS：brew install node，或到 https://nodejs.org 下安装包（Intel 与 Apple 芯片各有一版）。"
  else
    say "  助手用的 Node.js：$NODE_RESOLVED"
  fi
  say "已安装。"
  say "助手会跟着 Codex 自动启停，面板上会显示「运行中」。"
  say "不需要时运行： bash install-helper.sh -Uninstall"
}

do_uninstall() {
  if [ "$PLATFORM" = "mac" ]; then
    launchctl unload "$PLIST" >/dev/null 2>&1 || true
    launchctl remove "$LABEL" >/dev/null 2>&1 || true
    if [ -f "$PLIST" ]; then rm -f "$PLIST"; say "已删除启动项：$PLIST"; fi
  else
    systemctl --user disable --now dstu-helper.service >/dev/null 2>&1 || true
    if [ -f "$UNIT" ]; then rm -f "$UNIT"; say "已删除服务：$UNIT"; fi
    if [ -f "$DESKTOP_FILE" ]; then rm -f "$DESKTOP_FILE"; say "已删除自启动项：$DESKTOP_FILE"; fi
  fi

  pkill -f 'start-helper.sh' >/dev/null 2>&1 || true
  pkill -f 'dstu-helper.mjs' >/dev/null 2>&1 || true
  sleep 1
  pkill -9 -f 'start-helper.sh' >/dev/null 2>&1 || true
  pkill -9 -f 'dstu-helper.mjs' >/dev/null 2>&1 || true

  if [ -d "$INSTALL_DIR" ]; then
    case "$INSTALL_DIR" in
      "$HOME"/*dstu-helper)
        rm -rf "$INSTALL_DIR"
        say "已删除安装目录：$INSTALL_DIR"
        ;;
      *)
        say "安装目录不在预期范围内，已放弃删除：$INSTALL_DIR"
        ;;
    esac
  fi
  say "已卸载。面板不受影响，余额用手动记录即可。"
}

case "$MODE" in
  install) do_install; show_status ;;
  uninstall) do_uninstall ;;
  status) show_status ;;
esac
