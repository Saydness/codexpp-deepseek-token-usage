# 本机助手（可选）

面板里的「账户余额」由这个助手提供。**token 用量与费用统计不需要它**，不装也不影响。

## 为什么需要它

Codex 页面被安全策略禁止联网（CSP 加上跨域限制），面板自己请求不了 DeepSeek 的余额接口。助手跑在页面之外，读到余额后只把一个数字通过 Codex 的本地调试端口交给面板。

## 文件

- `dstu-helper.mjs`：助手本体，每 15 秒心跳、每 5 分钟读一次余额，面板点「刷新余额」时立刻重读；
- `balance_sources.mjs`：余额来源的解析与请求；
- `set_balance_key.ps1`：Windows 上用 DPAPI（当前用户）保存 / 查看 / 清除 Key；
- `install-helper.ps1` + `start-helper.vbs`：Windows 的一键安装脚本与看门狗（Codex 启动时拉起助手，退出就停）；
- `install-helper.sh` + `start-helper.sh`：macOS / Linux 的一键安装脚本与看门狗；
- `安装本机助手.cmd` / `安装本机助手.command`：Windows / macOS 上直接双击安装（卸载同理）。

## 支持的机器

不用挑对应的安装包：脚本只用系统自带的东西（sh / curl / pgrep、PowerShell / wscript），
Node.js 装在哪由脚本自己找。面板里的「命令给哪个系统」默认自动识别，认错了可以手动换。

| 系统 | 架构 | 说明 |
| --- | --- | --- |
| Windows | x64 | 最常见的情况 |
| Windows | ARM64（骁龙本等） | Codex++ 本身是 x64 程序，走系统兼容层；助手是脚本 + Node，原生 ARM64 版 node 也照用 |
| macOS | Apple 芯片（arm64） | Homebrew 的 `/opt/homebrew` 前缀也认；终端跑在 Rosetta 下同样能认出是 Apple 芯片 |
| macOS | Intel（x86_64） | Homebrew 的 `/usr/local` 前缀、MacPorts 的 `/opt/local` 都认 |
| Linux | x86_64 / ARM64 / armv7 | Ubuntu / Debian、Fedora、Arch 都行；自启动优先 systemd 用户服务，没有 systemd 就退回桌面自启动 |
| WSL | x86_64 / ARM64 | 走 Linux 分支，装法一致 |

node 的常见装法（PATH 之外的 nvm / fnm / volta / asdf / nodenv / Scoop / Chocolatey /
nvm-windows 也都会去找）：Windows `winget install OpenJS.NodeJS.LTS` 或到 nodejs.org 下安装包
（x64 与 ARM64 各有一版）；macOS `brew install node`；Linux 用发行版仓库
（`sudo apt install nodejs npm` / `sudo dnf install nodejs` / `sudo pacman -S nodejs npm`）。

`-Status` 会把「系统架构」和「node 架构」一起打出来。两边对不上也能跑
（例如 Apple 芯片上装了 x64 的 node，走 Rosetta），只是建议换成对应的原生版本，更省电也更快。

## 运行

需要 Node.js 18 以上。**一键安装**（推荐，装完不用再管）：

```text
Windows   : powershell -NoProfile -ExecutionPolicy Bypass -File .\install-helper.ps1
macOS/Linux: bash install-helper.sh
```

也可以不下载仓库，直接在面板里点「复制安装命令」，把它粘到系统终端回车：

```text
Windows    → PowerShell 窗口    （irm 下载 install-helper.ps1 后执行）
macOS/Linux→ 终端               （curl -fsSL …/install-helper.sh | bash）
```

面板里那一行「命令给哪个系统」可以手动换（自动识别 / Windows / macOS / Linux），
所以给另一台机器准备命令也不用改脚本。

安装脚本做的事：把助手文件放进本机目录（Windows `%LOCALAPPDATA%\Codex++\dstu-helper`、
macOS `~/Library/Application Support/Codex++/dstu-helper`、Linux `~/.local/share/codexpp/dstu-helper`），
再登记一个开机自启（Windows 是「启动」文件夹里的快捷方式，macOS 是 LaunchAgent，Linux 优先 systemd 用户服务），
最后把看门狗拉起来。看门狗每 3 秒看一眼：Codex 在跑就确保助手在跑，Codex 不在就把助手停掉，
所以退出 Codex 后不会留下常驻进程。卸载：

```text
Windows   : powershell -NoProfile -ExecutionPolicy Bypass -File .\install-helper.ps1 -Uninstall
macOS/Linux: bash install-helper.sh -Uninstall
```

手动跑（临时用一下）也可以：

```text
node dstu-helper.mjs
```

## 余额来源

按顺序尝试，先成功先用；面板「说明」里可以指定只用某一种。

| 顺序 | 来源 | 说明 |
| --- | --- | --- |
| 1 | 本机代理 | 需要自己设置 `DSTU_BALANCE_URL` 指向代理的余额接口；它复用真实流量里的鉴权，不需要 Key |
| 2 | 环境变量 | `DEEPSEEK_API_KEY` |
| 3 | Codex 的 `env_key` | `config.toml` 里 `env_key` 指到的环境变量 |
| 4 | `~/.codex/auth.json` | Codex 自己保存的 Key |
| 5 | 本机加密保存的 Key | Windows：在面板里填一次，助手用 DPAPI 加密存到 `%LOCALAPPDATA%\Codex++\deepseek-balance.key`；macOS：存进登录钥匙串（`security add-generic-password -a codexpp -s deepseek-balance -w`，助手直接读得到）；Linux：没有本机加密保存，用前四条来源 |

## 环境变量

| 变量 | 默认值 | 作用 |
| --- | --- | --- |
| `DSTU_CDP` | `http://127.0.0.1:9229` | Codex 的本地调试端口 |
| `DSTU_BALANCE_URL` | 空 | 本机代理的余额接口地址；不设就跳过这一来源 |
| `DSTU_USAGE_LOG` | 空 | 可选的用量日志（JSONL），会把日志里的记录补进面板 |
| `DSTU_KEY_STORE` | Windows `%LOCALAPPDATA%\Codex++\deepseek-balance.key`；macOS `~/Library/Application Support/Codex++/deepseek-balance.key`（实际读钥匙串） | 加密保存 Key 的位置 |
| `DSTU_POLL_MS` | `15000` | 心跳间隔 |
| `DSTU_BALANCE_INTERVAL_MS` | `300000` | 自动读余额的间隔 |
| `DSTU_LOG` | 空 | 设了才把运行日志落盘，否则只打印到控制台 |
| `DSTU_NODE` / `DSTU_HELPER` | 自动 | 看门狗用的 node.exe / 助手脚本路径 |

## Key 的管理

Windows（DPAPI 加密串落盘，只有本机、本 Windows 账户能解开）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File helper\set_balance_key.ps1 -Status   # 有没有存过
powershell -NoProfile -ExecutionPolicy Bypass -File helper\set_balance_key.ps1 -Print    # 打印出来（不带换行）
powershell -NoProfile -ExecutionPolicy Bypass -File helper\set_balance_key.ps1 -Clear    # 删掉
powershell -NoProfile -ExecutionPolicy Bypass -File helper\set_balance_key.ps1           # 掩码输入并保存
```

面板上的「保存 Key」按钮走的也是同一套流程：Key 经内存交给助手后立刻从页面清掉，落盘的是加密串。用管道保存时 Key 不会出现在命令行里：

```powershell
"你的Key" | powershell -NoProfile -ExecutionPolicy Bypass -File helper\set_balance_key.ps1
```

macOS（登录钥匙串，Key 不在普通文件里；面板里直接填的 Key 只留在本次运行的内存里）：

```bash
security add-generic-password -a codexpp -s deepseek-balance -w          # 交互式输入，存进钥匙串
security find-generic-password -a codexpp -s deepseek-balance -w         # 读出来看看
security delete-generic-password -a codexpp -s deepseek-balance          # 删掉
```

## 隐私

- Key 从不写进日志、从不发给页面，也不进面板的本地存储；
- Windows 上落盘的是 DPAPI 加密串，只有当前 Windows 用户能解；macOS 上用登录钥匙串，不写明文文件；
- 面板只会收到余额数字、币种和来源名称；
- 助手只在设了 `DSTU_BALANCE_URL` 时访问本机代理，否则只访问 `https://api.deepseek.com/user/balance`。
