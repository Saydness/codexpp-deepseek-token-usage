# 本机助手（可选）

面板里的「账户余额」由这个助手提供。**token 用量与费用统计不需要它**，不装也不影响。

## 为什么需要它

Codex 页面被安全策略禁止联网（CSP 加上跨域限制），面板自己请求不了 DeepSeek 的余额接口。助手跑在页面之外，读到余额后只把一个数字通过 Codex 的本地调试端口交给面板。

## 文件

- `dstu-helper.mjs`：助手本体，每 15 秒心跳、每 5 分钟读一次余额，面板点「刷新余额」时立刻重读；
- `balance_sources.mjs`：余额来源的解析与请求；
- `set_balance_key.ps1`：用 Windows DPAPI（当前用户）保存 / 查看 / 清除 Key；
- `start-helper.vbs`：看门狗，Codex 启动时拉起助手，Codex 退出就停掉，平时不占资源。

## 运行

需要 Node.js 18 以上。手动跑：

```powershell
node helper\dstu-helper.mjs
```

想让它跟着 Codex 自动启停：按 Win+R 输入 `shell:startup`，把 `start-helper.vbs` 的快捷方式放进打开的文件夹。看门狗每 3 秒看一眼：Codex 在跑就确保助手在跑，Codex 不在就把助手停掉，所以退出 Codex 后不会留下常驻进程。

## 余额来源

按顺序尝试，先成功先用；面板「说明」里可以指定只用某一种。

| 顺序 | 来源 | 说明 |
| --- | --- | --- |
| 1 | 本机代理 | 需要自己设置 `DSTU_BALANCE_URL` 指向代理的余额接口；它复用真实流量里的鉴权，不需要 Key |
| 2 | 环境变量 | `DEEPSEEK_API_KEY` |
| 3 | Codex 的 `env_key` | `config.toml` 里 `env_key` 指到的环境变量 |
| 4 | `~/.codex/auth.json` | Codex 自己保存的 Key |
| 5 | 本机加密保存的 Key | 在面板里填一次，助手用 DPAPI 加密存到 `%LOCALAPPDATA%\Codex++\deepseek-balance.key` |

## 环境变量

| 变量 | 默认值 | 作用 |
| --- | --- | --- |
| `DSTU_CDP` | `http://127.0.0.1:9229` | Codex 的本地调试端口 |
| `DSTU_BALANCE_URL` | 空 | 本机代理的余额接口地址；不设就跳过这一来源 |
| `DSTU_USAGE_LOG` | 空 | 可选的用量日志（JSONL），会把日志里的记录补进面板 |
| `DSTU_KEY_STORE` | `%LOCALAPPDATA%\Codex++\deepseek-balance.key` | 加密保存 Key 的位置 |
| `DSTU_POLL_MS` | `15000` | 心跳间隔 |
| `DSTU_BALANCE_INTERVAL_MS` | `300000` | 自动读余额的间隔 |
| `DSTU_LOG` | 空 | 设了才把运行日志落盘，否则只打印到控制台 |
| `DSTU_NODE` / `DSTU_HELPER` | 自动 | 看门狗用的 node.exe / 助手脚本路径 |

## Key 的管理

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

## 隐私

- Key 从不写进日志、从不发给页面，也不进面板的本地存储；
- 落盘的是 DPAPI 加密串，只有当前 Windows 用户能解；
- 面板只会收到余额数字、币种和来源名称；
- 助手只在设了 `DSTU_BALANCE_URL` 时访问本机代理，否则只访问 `https://api.deepseek.com/user/balance`。
