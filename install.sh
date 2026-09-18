#!/usr/bin/env sh
# DeepSeek Token Usage —— macOS 安装脚本
#
# 用法：在本目录执行   bash install.sh
# 作用：把 codexpp/deepseek-token-usage.user.js 装进 Codex++ 的 user_scripts，
#       并在 user_scripts.json 里把它打开（和 Windows 上的 install.ps1 等价）。
#
# Codex++ 的配置目录默认是 ~/Library/Application Support/Codex++；
# 如果它装在别处，可以指定后用，例如：
#   CODEXPP_HOME="$HOME/.config/Codex++" bash install.sh
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
SOURCE="$ROOT/codexpp/deepseek-token-usage.user.js"
if [ ! -f "$SOURCE" ]; then
  echo "未找到插件脚本: $SOURCE" >&2
  exit 1
fi

CODEXPP_HOME=${CODEXPP_HOME:-"$HOME/Library/Application Support/Codex++"}
USER_SCRIPT_DIR="$CODEXPP_HOME/user_scripts"
REGISTRY="$CODEXPP_HOME/user_scripts.json"
TARGET="$USER_SCRIPT_DIR/deepseek-token-usage.js"

if [ ! -d "$CODEXPP_HOME" ]; then
  echo "未找到 Codex++ 配置目录: $CODEXPP_HOME" >&2
  echo "请先安装并启动一次 Codex++；如果目录在别处，用 CODEXPP_HOME 指定。" >&2
  exit 1
fi

mkdir -p "$USER_SCRIPT_DIR"
cp -f "$SOURCE" "$TARGET"
if [ -f "$REGISTRY" ]; then
  cp -f "$REGISTRY" "$REGISTRY.bak"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/register.py" <<'PY'
import json, os, sys

path = sys.argv[1]
data = {}
if os.path.exists(path):
    try:
        with open(path, encoding='utf-8') as handle:
            data = json.load(handle)
    except Exception:
        data = {}
if not isinstance(data, dict):
    data = {}
data['enabled'] = True
scripts = data.get('scripts')
if not isinstance(scripts, dict):
    scripts = {}
scripts['user:deepseek-token-usage.js'] = True
data['scripts'] = scripts
with open(path, 'w', encoding='utf-8') as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write('\n')
PY

cat > "$WORK/register.js" <<'JS'
const fs = require('node:fs');

const path = process.argv[2];
let data = {};
try {
  data = JSON.parse(fs.readFileSync(path, 'utf8'));
} catch (error) {
  data = {};
}
if (typeof data !== 'object' || data === null || Array.isArray(data)) data = {};
data.enabled = true;
if (typeof data.scripts !== 'object' || data.scripts === null || Array.isArray(data.scripts)) {
  data.scripts = {};
}
data.scripts['user:deepseek-token-usage.js'] = true;
fs.writeFileSync(path, JSON.stringify(data, null, 2) + '\n', 'utf8');
JS

if command -v python3 >/dev/null 2>&1; then
  python3 "$WORK/register.py" "$REGISTRY"
elif command -v node >/dev/null 2>&1; then
  node "$WORK/register.js" "$REGISTRY"
else
  echo "脚本已经放好，但这台机器上没有 python3 / node："
  echo "请手动在 $REGISTRY 里加上 \"user:deepseek-token-usage.js\": true"
fi

echo 'DeepSeek Token Usage 已安装。'
echo "脚本: $TARGET"
echo "配置: $REGISTRY"
echo '请重启 Codex / ChatGPT 桌面端。'
