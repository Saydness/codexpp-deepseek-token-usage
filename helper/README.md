# 本机助手（可选）

面板里的「账户余额」由这个助手提供。**token 用量与费用统计不需要它**，不装也不影响。

## 为什么需要它

Codex 页面被安全策略禁止联网（CSP 加上跨域限制），面板自己请求不了 DeepSeek 的余额接口。助手跑在页面之外，读到余额后只把一个数字通过 Codex 的本地调试端口交给面板。

## 文件

- `dstu-helper.mjs`：助手本体，每 15 秒心跳、每 5 分钟读一次余额，面板点「刷新余额」时立刻重读；每读到一次余额还会往同目录的 `balance.log` 追加一行本机流水；
- `balance_sources.mjs`：余额来源的解析与请求；
- `set_balance_key.ps1`：Windows 上用 DPAPI（当前用户）保存 / 查看 / 清除 Key；
- `install-helper.ps1` + `start-helper.vbs`：Windows 的一键安装脚本与看门狗（Codex 启动时拉起助手，退出就停）；
- `install-helper.sh` + `start-helper.sh`：macOS 的一键安装脚本与看门狗；
- `安装本机助手.cmd` / `安装本机助手.command`：Windows / macOS 上直接双击安装（卸载同理）。

## 支持的机器

Codex++ 目前只发布三种安装包：Windows x64、macOS x64（Intel）、macOS arm64（Apple 芯片），
本助手把这三处都覆盖到；不用挑对应的安装包，脚本只用系统自带的东西（sh / curl / pgrep、
PowerShell / wscript）。面板里的「命令给哪个系统」默认自动识别，认错了可以手动换。

| 系统 | 架构 | 说明 |
| --- | --- | --- |
| Windows | x64 | 最常见的情况 |
| Windows | ARM64（骁龙本等） | Codex++ 本身是 x64 程序，走系统兼容层；助手是脚本 + Node，原生 ARM64 版 node 也照用 |
| macOS | Apple 芯片（arm64） | Homebrew 的 `/opt/homebrew` 前缀也认；终端跑在 Rosetta 下同样能认出是 Apple 芯片 |
| macOS | Intel（x86_64） | Homebrew 的 `/usr/local` 前缀、MacPorts 的 `/opt/local` 都认 |

## 依赖是先检测、后安装

安装脚本不会闷头装东西，顺序是这样：

1. 先找这台机器上已有的 Node.js（PATH、两套 Homebrew 前缀、MacPorts，以及 nvm / fnm /
   volta / asdf / nodenv / Scoop / Chocolatey / nvm-windows，还有之前装过的便携版）；
2. 找到且版本 ≥ 18：**直接使用，什么都不装**，脚本会打印用的是哪一个；
3. 没找到，或者版本低于 18：才替用户补上——
   - Windows：先试 `winget install OpenJS.NodeJS.LTS`（可能弹一次 UAC 授权），走不通就下载
     官方便携包解压到 `%LOCALAPPDATA%\Codex++\node-runtime`（不需要管理员权限，也不动系统 PATH）；
   - macOS：先试 `brew install node`，走不通就下载官方压缩包解压到
     `~/Library/Application Support/Codex++/node-runtime`（同样不需要管理员权限）。

用哪个 node 会记进安装目录的 `node-path.txt`，看门狗优先按它启动助手；装完无需重启电脑。

`-Status` 会把「系统架构」和「node 架构」一起打出来。两边对不上也能跑
（例如 Apple 芯片上装了 x64 的 node，走 Rosetta），只是建议换成对应的原生版本，更省电也更快。

## 运行

需要 Node.js 18 以上。**一键安装**（推荐，装完不用再管）：

```text
Windows : powershell -NoProfile -ExecutionPolicy Bypass -File .\install-helper.ps1
macOS   : bash install-helper.sh
```

也可以不下载仓库，直接在面板里点「一键安装（交给 Codex）」——面板会把安装请求写进 Codex
对话框并直接发送，由 Codex 在本机执行，剩下全自动（缺 Node.js 时脚本自己补，见上一节）。
想自己动手就点「复制安装命令」，粘到系统终端回车，效果一样：

```text
Windows → PowerShell 窗口    （脚本在内存里直接跑，不落地文件）
macOS   → 终端               （curl -fsSL …/install-helper.sh | bash）
```

面板里那一行「命令给哪个系统」可以手动换（自动识别 / Windows / macOS），
所以给另一台机器准备命令也不用改脚本。

安装脚本做的事：把助手文件放进本机目录（Windows `%LOCALAPPDATA%\Codex++\dstu-helper`、
macOS `~/Library/Application Support/Codex++/dstu-helper`），
再登记一个开机自启（Windows 是「启动」文件夹里的快捷方式，macOS 是 LaunchAgent），
最后把看门狗拉起来。看门狗每 3 秒看一眼：Codex 在跑就确保助手在跑，Codex 不在就把助手停掉，
所以退出 Codex 后不会留下常驻进程。卸载：

```text
Windows : powershell -NoProfile -ExecutionPolicy Bypass -File .\install-helper.ps1 -Uninstall
macOS   : bash install-helper.sh -Uninstall
```

手动跑（临时用一下）也可以：

```text
node dstu-helper.mjs
```

## 余额来源

按顺序尝试，先成功先用。面板上没有 Key 输入框（1.19.6 起连「填 Key」控件都撤了），
这一整套都在助手这边完成。

| 顺序 | 来源 | 说明 |
| --- | --- | --- |
| 1 | 本机代理 | 需要自己设置 `DSTU_BALANCE_URL` 指向代理的余额接口；它复用真实流量里的鉴权，不需要 Key |
| 2 | 环境变量 | `DEEPSEEK_API_KEY` |
| 3 | Codex 的 `env_key` | `config.toml` 里 `env_key` 指到的环境变量 |
| 4 | `~/.codex/auth.json` | Codex 自己保存的 Key |
| 5 | 本机加密保存的 Key | Windows：用 `set_balance_key.ps1` 存一次，助手用 DPAPI 加密存到 `%LOCALAPPDATA%\Codex++\deepseek-balance.key`；macOS：存进登录钥匙串（`security add-generic-password -a codexpp -s deepseek-balance -w`，助手直接读得到） |

## 余额流水（`balance.log`）

助手会把每次读到的余额写成一行本机流水，格式和你自己写的脚本一致：

```text
2026-09-20 14:35:02,8055.14,helper
2026-09-20 14:40:02,8054.90,helper
```

- **写**：默认写助手目录下的 `balance.log`（可用 `DSTU_BALANCE_LOG` 改路径）；文件很小，
  每 5 分钟一行，一年也就几百 KB，不会自动清理。
- **读**：启动时把日志整段补一次、之后每 15 分钟补增量，回填进面板的余额历史
  （面板按「同一时刻、或同一分钟内同一金额」去重，重复导入不会翻倍）。
- 除了自己这份，还会读这几个位置（存在哪个读哪个）：`DSTU_BALANCE_LOG_EXTRA` 里用
  系统路径分隔符列出的文件、桌面上的 `balance/balance.log`（含 OneDrive 桌面）、
  文档目录下的 `balance/balance.log`。所以用户以前用手写脚本攒的余额日志会被自动接上，
  面板没有快照的那几天也能补成真实数据。
- **写不进去怎么办**：看门狗如果是在 Codex 的沙箱里被拉起来的（用面板「一键安装」时
  会出现这种情况，沙箱里网络能通、但一个文件都写不了），流水就写不出本机。助手会把
  这件事报在面板状态行上（「本机余额流水写不进去…」），照提示在普通 PowerShell / 终端里
  重跑一次安装命令即可：看门狗换成你终端里的进程后，写权限就正常了。余额和用量统计
  不受影响，只是本机流水暂时没有。

## 环境变量

| 变量 | 默认值 | 作用 |
| --- | --- | --- |
| `DSTU_CDP` | `http://127.0.0.1:9229` | Codex 的本地调试端口 |
| `DSTU_BALANCE_URL` | 空 | 本机代理的余额接口地址；不设就跳过这一来源 |
| `DSTU_USAGE_LOG` | 空 | 可选的用量日志（JSONL），会把日志里的记录补进面板 |
| `DSTU_BALANCE_LOG` | 助手目录下的 `balance.log` | 本机余额流水写到哪 |
| `DSTU_BALANCE_LOG_EXTRA` | 空 | 额外要回读的余额日志路径（多个用系统路径分隔符隔开） |
| `DSTU_BALANCE_LOG_INTERVAL_MS` | `900000` | 回填余额日志的间隔（15 分钟） |
| `DSTU_BALANCE_LOG_LIMIT` | `1500` | 启动时最多回填多少条（防止日志特别长时卡顿） |
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
