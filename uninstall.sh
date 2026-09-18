#!/usr/bin/env sh
# DeepSeek Token Usage —— macOS 卸载脚本
#
# 用法：在本目录执行   bash uninstall.sh
set -eu

CODEXPP_HOME=${CODEXPP_HOME:-"$HOME/Library/Application Support/Codex++"}
USER_SCRIPT_DIR="$CODEXPP_HOME/user_scripts"
REGISTRY="$CODEXPP_HOME/user_scripts.json"
TARGET="$USER_SCRIPT_DIR/deepseek-token-usage.js"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/unregister.py" <<'PY'
import json, os, sys

path = sys.argv[1]
if os.path.exists(path):
    try:
        with open(path, encoding='utf-8') as handle:
            data = json.load(handle)
    except Exception:
        data = None
    if isinstance(data, dict):
        scripts = data.get('scripts')
        if isinstance(scripts, dict):
            scripts.pop('user:deepseek-token-usage.js', None)
        with open(path, 'w', encoding='utf-8') as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
            handle.write('\n')
PY

cat > "$WORK/unregister.js" <<'JS'
const fs = require('node:fs');

const path = process.argv[2];
let data = null;
try {
  data = JSON.parse(fs.readFileSync(path, 'utf8'));
} catch (error) {
  data = null;
}
if (data && typeof data === 'object' && !Array.isArray(data)) {
  if (typeof data.scripts === 'object' && data.scripts !== null && !Array.isArray(data.scripts)) {
    delete data.scripts['user:deepseek-token-usage.js'];
  }
  fs.writeFileSync(path, JSON.stringify(data, null, 2) + '\n', 'utf8');
}
JS

if [ -f "$REGISTRY" ]; then
  cp -f "$REGISTRY" "$REGISTRY.bak"
  if command -v python3 >/dev/null 2>&1; then
    python3 "$WORK/unregister.py" "$REGISTRY"
  elif command -v node >/dev/null 2>&1; then
    node "$WORK/unregister.js" "$REGISTRY"
  else
    echo "提示：请手动在 $REGISTRY 里删掉 \"user:deepseek-token-usage.js\" 这一项。"
  fi
fi

if [ -f "$TARGET" ]; then
  rm -f "$TARGET"
fi

echo 'DeepSeek Token Usage 已卸载，请重启 Codex。'
