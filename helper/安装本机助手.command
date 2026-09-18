#!/bin/bash
# 双击运行：安装 DeepSeek 用量面板的本机助手（macOS）。
# 如果系统提示「无法打开」，在「终端」里先执行 chmod +x 本文件，或改用：
#   curl -fsSL https://raw.githubusercontent.com/Saydness/codexpp-deepseek-token-usage/main/helper/install-helper.sh | bash
cd "$(dirname "$0")" || exit 1
bash ./install-helper.sh "$@"
status=$?
echo
if [ $status -eq 0 ]; then echo "完成，可以关掉这个窗口了。"; else echo "安装失败（退出码 $status）。"; fi
read -n 1 -s -r -p "按任意键关闭…"
