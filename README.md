# DeepSeek Token Usage for Codex++

一个运行在 Codex++ 里的 DeepSeek API token 用量与费用面板。

## 功能

- 自动捕获 Codex 会话中的 DeepSeek token 使用数据；
- 支持按天、按月查看 token 用量和费用，打开面板默认落在当天；
- 每个请求优先使用该请求携带的模型，按照不同模型的官方费率分别计算；
- 区分缓存命中、缓存未命中、输出 tokens 和思考 tokens；
- 按北京时间峰谷时段计算费用；
- 图表柱和费用点支持鼠标悬浮查看该节点的用量；
- 面板四边和四个角都可以拖动缩放，位置和大小会记住；
- 可收起成仅显示 token 用量和费用的 mini 状态条；
- 每次 Codex 启动后的第一次打开都显示完整面板，之后才记住你自己收起的 mini 状态；
- 可选：账户余额、每日收盘余额与余额消耗（面板本身不依赖助手；想让余额全自动更新，可以用面板里的一键命令装个小助手，见下）。

## 环境要求

- 已安装 Codex++ 和 Codex 桌面端（Codex++ 目前发布的安装包：Windows x64、macOS x64、macOS arm64）；
- 面板是 Codex++ 用户脚本，跟着 Codex++ 的三份安装包走：Windows x64、macOS Intel、macOS Apple 芯片都能跑；

面板本身是 Codex++ 用户脚本，不需要 Python 或 Node.js，也不直接联网：查余额的活由下面那个**可选**的本机助手在本机完成（面板上没有手填入口：不装助手，余额就一直是空的）。

只有下面那个**可选**的本机助手需要 Node.js 18 以上；Windows 用 PowerShell / wscript，
macOS 用 sh / curl。安装脚本会先检查这台机器：现成的 Node.js 能直接用就什么都不装，
没有（或版本太老）才替用户补上，全程不用管理员权限。

## 安装

下载或克隆本仓库后，在仓库根目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

安装完成后重启 Codex / ChatGPT 桌面端。

打开 Codex 后，点击顶栏右侧带有费用金额的 DeepSeek 入口，即可打开面板。

## 手动安装

如果不想运行安装脚本，可以手动复制：

```text
codexpp\deepseek-token-usage.user.js
```

到：

```text
%APPDATA%\Codex++\user_scripts\deepseek-token-usage.js
```

然后在 `%APPDATA%\Codex++\user_scripts.json` 中加入：

```json
{
  "enabled": true,
  "scripts": {
    "user:deepseek-token-usage.js": true
  }
}
```

如果文件中已有其他脚本，请保留原有条目，只增加上面这一项。

## 采集范围（读了什么、不读什么）

面板只观察、不改写：包装 `fetch` / `XMLHttpRequest` / `WebSocket` 只为读统计字段，请求和响应都原样放行。判定按「这次调用是不是 DeepSeek 的」来做，会去读正文的只有两类：

| 读 | 条件 |
| --- | --- |
| ✅ | 主机名里带 `deepseek` 的地址（例如 `api.deepseek.com`） |
| ✅ | 路径是 OpenAI 兼容的 completions 端点（`/chat/completions`、`/completions`、`/beta/chat/completions`），**并且请求体里点名了 deepseek 模型**——本地中转、自建代理走的就是这个路径，靠模型名认归属 |

明确不读的：`127.0.0.1`（或任何主机）上非 completions 路径的接口、`/responses`（OpenAI Responses API）、发给其它模型（例如 `gpt-*`）的 completions 调用、以及从没出现 deepseek 模型名的 WebSocket 连接。WebSocket 首帧认出归属后，同一条连接的后续帧继续解析（流式分片通常只有首帧带模型名，否则会漏掉末尾的 usage），其余连接一帧都不读。读到的内容只用来提取模型名、token 数量和时间戳，请求体只做一次「有没有 deepseek」的子串判断，不保存。

另外，面板还会监听 Codex 页面自身发出的消息事件（`postMessage` / `codex-message-from-view`），从中只取 token 用量、模型、时间戳这些字段——这部分不涉及任何 HTTP 响应。

## 账户余额（可选）

「账户余额」卡片显示当前余额、今日消耗、昨日消耗、本月消耗，以及每天的收盘余额 / 余额消耗 / 费率估算对照表。

面板本体在 Codex 页面里，被安全策略挡住（CSP 禁止联网，实测 `fetch` 直接报 `Failed to fetch`），所以余额这块交给可选的**本机助手**去查：它在本机用 GET 打 DeepSeek 的余额接口，把数字推给面板。装一次之后，Codex 运行时每 5 分钟自动更新一次，点「刷新余额」立刻补一次。**不用用户自己填 Key**：助手会先找本机已经有的 Key（顺序见下面「可选增强：`helper/`」里的表），一个都找不到时余额会读不到，那就把 Key 放到其中任一个来源里。

面板上没有手动填余额的入口：卡片上的数字全部由本机助手写入。
装了下面的本机助手之后，卡片上的「刷新余额」会重新出现（点了它立刻重读一次），余额也会每 5 分钟自动更新一次。

面板页里那条直连查询通道暂停中：Codex++ 的网络桥只放行 **POST**，而 DeepSeek 的余额接口只认 **GET**，两边对不上；代码一行没删，桥放开 GET 就会自动恢复。面板上没有 Key 输入区：Key 由助手在本机自己找（顺序见下面「可选增强：`helper/`」里的表），面板从头到尾不接触 Key。

（助手查余额的频率：Codex 运行时每 5 分钟一次，点「刷新余额」立刻补一次，Codex 退出就停。面板页内直连查询在桥能用时的频率是：打开面板时一次、之后每 15 分钟一次，两次之间至少隔 30 秒，页面在后台时不查。）

余额只认**查到的数字**（接口返回的、历史导入的），面板不会拿本机 token 用量去推算或扣减余额——同一个 DeepSeek 账户可能多台机器共用，按本机用量算出来的余额会偏；卡片上的「今日消耗 / 本月消耗」是两次真实快照相减得到的，仍然是查到的值。

不想用余额功能，在面板里取消勾选「启用余额统计」即可，用量与费用统计不受影响。

### 可选增强：`helper/`

仓库里的 `helper/` 是本机小工具，**面板的余额完全靠它**（用量与费用统计不需要它）：它在本机用 GET 查余额，把数字推给面板；Key 由它自己找，一般不用你填（实在要存也可以用 Windows DPAPI / macOS 钥匙串存一把）：

```text
helper/
├─ dstu-helper.mjs       # 本体：定时读余额、把数字推给面板
├─ balance_sources.mjs   # 余额来源解析
├─ set_balance_key.ps1   # Windows：用 DPAPI 保存 / 查看 / 清除 Key
├─ install-helper.ps1    # Windows：一键安装 / 卸载（PowerShell）
├─ start-helper.vbs      # Windows：随 Codex 启停的看门狗
├─ install-helper.sh     # macOS：一键安装 / 卸载
├─ start-helper.sh       # macOS：随 Codex 启停的看门狗
└─ README.md
```

需要 Node.js 18 以上——没装也没关系，安装脚本会替你装。**一键安装**：面板「设置 → 本机助手」
里点「一键安装（交给 Codex）」，安装请求会直接写进 Codex 对话框并由它在本机执行，用户不用
复制粘贴；也可以点「复制安装命令」自己粘（命令按当前系统给，也能手动切换系统）：

```text
# 下载了仓库：在仓库根目录执行
Windows : powershell -NoProfile -ExecutionPolicy Bypass -File .\helper\install-helper.ps1
macOS   : bash helper/install-helper.sh

# 没下载仓库：把面板复制到的那条粘进系统终端回车即可（脚本直接在内存里跑，不用先存文件）
Windows（PowerShell）: powershell -NoProfile -ExecutionPolicy Bypass -Command "…（面板复制的那条）"
macOS（终端）:        (curl -fsSL …/install-helper.sh || curl -fsSL …镜像…) | bash
```

Windows 上也可以直接双击 `helper\安装本机助手.cmd`，macOS 上双击 `helper\安装本机助手.command`。
安装脚本会把文件放到本机目录、登记开机自启，并立刻拉起看门狗：Codex 启动时它才去读余额，
Codex 退出后助手一起停，平时不占资源；卸载加 `-Uninstall` 即可还原。

#### 支持的系统与架构

| 系统 | 架构 | 装法与说明 |
| --- | --- | --- |
| Windows | x64 | PowerShell 一键安装；用「启动」文件夹里的快捷方式自启 |
| Windows | ARM64（骁龙本等） | 同一套命令：Codex++ 本体是 x64 程序，走系统兼容层；助手是脚本 + Node，原生 ARM64 版 node 也照用 |
| macOS | Apple 芯片（arm64） | 同一套 sh 脚本；Homebrew 的 `/opt/homebrew` 前缀也认 |
| macOS | Intel（x86_64） | 同一套 sh 脚本；Homebrew `/usr/local`、MacPorts `/opt/local` 都认 |

node 的位置是自动找的：PATH、两套 Homebrew 前缀、MacPorts，以及
nvm / fnm / volta / asdf / nodenv / nvm-windows / Scoop / Chocolatey 这些装法都会去找。
顺序是「先检测、后安装」：找到 18 以上的现成 node 就直接用；没找到才装，Windows 先试
winget、不成改用便携版（解压在本机目录），macOS 先试 Homebrew、不成改用官方安装包。
`install-helper.sh -Status`（Windows 用 `install-helper.ps1 -Status`）会把「系统架构」和
「node 架构」一起打出来；两边对不上也能跑（例如 Apple 芯片上装了 x64 的 node，走 Rosetta），
只是建议换成对应的原生版本，更省电也更快。

只想临时用一下，也可以手动启动：

```text
node helper/dstu-helper.mjs
```

余额来源按顺序尝试：

| 顺序 | 来源 | 说明 |
|---|---|---|
| 1 | 本机代理 | 需要自己设置 `DSTU_BALANCE_URL` 指向代理的余额接口 |
| 2 | `DEEPSEEK_API_KEY` | 环境变量里的 Key |
| 3 | Codex 配置的 `env_key` | `config.toml` 里 `env_key` 指到的环境变量 |
| 4 | `~/.codex/auth.json` | Codex 自己保存的 Key |
| 5 | 本机加密保存的 Key | Windows：用 helper 里的 `set_balance_key.ps1` 存一次（DPAPI 加密到 `%LOCALAPPDATA%`）；macOS：存进登录钥匙串 |

助手只在 Codex 运行时才工作，Codex 退出它就停；不装它，面板的用量与费用统计不受影响，只是余额会一直空着。

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

然后重启 Codex。如果装过本机助手，用它自己的卸载命令还原（Windows `… -Uninstall`、
macOS `bash install-helper.sh -Uninstall`）；存过的 Key 按需自行删除：
Windows 是 `%LOCALAPPDATA%\Codex++\deepseek-balance.key`，macOS 在登录钥匙串里
（`security delete-generic-password -a codexpp -s deepseek-balance`）。

## 隐私说明

- 面板只在 Codex 本机页面中运行，不发送遥测，自己也不能联网；装了可选的本机助手时，是助手在这台电脑上发请求（只打向 `https://api.deepseek.com/user/balance`，或你自己用 `DSTU_BALANCE_URL` 指的代理地址），把余额数字交给面板；
- 面板不收集、不保存 API Key（1.19.6 起连输入框都没有了）：余额由可选的本机助手读取，Key 由助手自己从 Codex 配置或系统钥匙串里取，不写日志、不随脚本上传；
- 不读取、不保存聊天正文、提示词或完整响应；
- 只记录模型名、token 数量、费用、时间等统计字段，保存在 Codex 本机本地存储里；
- 可选的本机助手才会联网（DeepSeek 余额接口，或你自己配置的代理地址），它只把余额数字交给面板；Key 在 Windows 上用 DPAPI、macOS 上用登录钥匙串按当前用户加密保存，从不写进日志；
- 代码中不包含任何机器 IP、用户名、服务器地址或密钥。

## 费率说明

当前内置的是 2026-09-10 起的 DeepSeek 官方 CNY 费率：

| 模型 | 时段 | 缓存命中 | 缓存未命中 | 输出 |
|---|---|---|---:|---:|---:|
| DeepSeek Flash | 空闲 | 0.02 | 1 | 4 |
| DeepSeek Flash | 高峰 | 0.04 | 2 | 8 |
| DeepSeek V4 Pro | 空闲 | 0.15 | 4.5 | 13.5 |
| DeepSeek V4 Pro | 高峰 | 0.30 | 9 | 27 |

单位为元 / 百万 tokens。费率调整后可在源码顶部的 `RATE_TABLE` 中更新。

## License

MIT
