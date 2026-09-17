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
- 首次打开显示完整面板；
- 可选：账户余额、每日收盘余额与余额消耗（面板自己查，不需要额外装助手，见下）。

## 环境要求

- Windows
- 已安装 Codex++ 和 Codex 桌面端

面板本身是 Codex++ 用户脚本，不需要 Python 或 Node.js，也不直接联网：查余额时只借用 Codex++ 自己的网络桥发一次请求。

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

## 账户余额（可选）

「账户余额」卡片显示当前余额、今日消耗、昨日消耗、本月消耗，以及每天的收盘余额 / 余额消耗 / 费率估算对照表。余额由**面板自己查**，不需要额外装任何随 Codex 启动的助手程序：

| Key 来源 | 面板怎么做 | 要动手吗 |
| --- | --- | --- |
| 自动（默认） | 读 Codex++ 设置里那把中转 Key（`/settings/get` 的 `relayApiKey`），也就是 Codex 正在用的 Key | 不用 |
| 我自己填 | 打开面板的「设置」，粘一次 `sk-...`，默认只存在本次运行的页面内存里 | 填一次 |
| 拖入 auth.json | 把 `%USERPROFILE%\.codex\auth.json` 直接拖到面板上，面板读里面的 Key | 拖一次 |

查询频率：打开面板时一次，之后每 15 分钟一次，两次之间至少隔 30 秒，页面在后台时不查。

有个限制要说清楚：Codex 页面被安全策略挡住、不能直接联网，面板只能借 Codex++ 的网络桥出去，而这条桥目前只允许 **POST** 请求；DeepSeek 查余额的接口只认 **GET**。两者对不上，所以在这版 Codex++ 上面板直连会查不到余额，卡片上会写明这是桥的限制。等 Codex++ 放开 GET，或者你的 Key 指向一个 POST 也能返回余额的中转站，同一套代码不用改就会自动生效。

查不到也不影响使用：在面板上填一次当前余额点「记录余额」就行。余额只认**查到的数字**（接口返回的、历史导入的、手动记录的），面板不会拿本机 token 用量去推算或扣减余额——同一个 DeepSeek 账户可能多台机器共用，按本机用量算出来的余额会偏；卡片上的「今日消耗 / 本月消耗」是两次真实快照相减得到的，仍然是查到的值。

不想用余额功能，在面板里取消勾选「启用余额统计」即可，用量与费用统计不受影响。

### 可选增强：`helper/`

仓库里的 `helper/` 是早期版本留下的本机小工具，**现在的面板不需要它**，不装也能正常用。它适合想让余额全自动更新的用户（自己搭了中转站，或者愿意让它用 Windows DPAPI 保存一把 Key）：

```text
helper/
├─ dstu-helper.mjs       # 本体：定时读余额、把数字推给面板
├─ balance_sources.mjs   # 余额来源解析
├─ set_balance_key.ps1   # 用 Windows DPAPI 保存 / 查看 / 清除 Key
├─ start-helper.vbs      # 随 Codex 启停的看门狗
└─ README.md
```

需要 Node.js 18 以上，手动启动：

```powershell
node helper\dstu-helper.mjs
```

想让它跟着 Codex 自动启停，把 `helper\start-helper.vbs` 的快捷方式放进 `shell:startup`：Codex 启动时它才去读余额，Codex 退出后助手一起停，平时不占资源。

余额来源按顺序尝试：

| 顺序 | 来源 | 说明 |
|---|---|---|
| 1 | 本机代理 | 需要自己设置 `DSTU_BALANCE_URL` 指向代理的余额接口 |
| 2 | `DEEPSEEK_API_KEY` | 环境变量里的 Key |
| 3 | Codex 配置的 `env_key` | `config.toml` 里 `env_key` 指到的环境变量 |
| 4 | `~/.codex/auth.json` | Codex 自己保存的 Key |
| 5 | 本机加密保存的 Key | 在面板里填一次 Key，由助手用 DPAPI 加密存到本机 |

助手只在 Codex 运行时才工作，Codex 退出它就停；不装它，面板的用量与费用统计、以及手动记录的余额都不受影响。

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

然后重启 Codex。如果装过本机助手，再删掉 `%LOCALAPPDATA%\Codex++\deepseek-balance.key` 即可。

## 隐私说明

- 面板只在 Codex 本机页面中运行，不发送遥测；它自己不能联网，查余额时是借 Codex++ 的网络桥把请求转发出去，请求只打向你自己 Key 对应的地址（默认 `https://api.deepseek.com/user/balance`）；
- 面板默认不保存 API Key：填进「API Key」框的 Key 只留在页面内存里，关掉 Codex 就没了；只有你主动勾上「把 Key 记在本机」才会写进 Codex 本机存储。Key 不写日志、不随脚本上传；
- 不读取、不保存聊天正文、提示词或完整响应；
- 只记录模型名、token 数量、费用、时间等统计字段，保存在 Codex 本机本地存储里；
- 可选的本机助手才会联网（DeepSeek 余额接口，或你自己配置的代理地址），它只把余额数字交给面板；Key 用 Windows DPAPI 按当前用户加密保存，从不写进日志；
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
