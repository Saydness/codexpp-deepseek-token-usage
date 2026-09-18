#!/bin/bash
# 双击运行：卸载本机助手（macOS）。
cd "$(dirname "$0")" || exit 1
bash ./install-helper.sh -Uninstall "$@"
echo
read -n 1 -s -r -p "按任意键关闭…"
