# DeepSeek Token Usage for Codex++

一个运行在 Codex++ 里的 DeepSeek API token 用量与费用面板。

## 功能

- 自动捕获 Codex 会话中的 DeepSeek token 使用数据；
- 支持按天、按月查看 token 用量和费用；
- 每个请求优先使用该请求携带的模型，按照不同模型的官方费率分别计算；
- 区分缓存命中、缓存未命中、输出 tokens 和思考 tokens；
- 按北京时间峰谷时段计算费用；
- 图表柱和费用点支持鼠标悬浮查看节点用量；
- 面板四边和四个角都可以拖动缩放，位置和大小会记住；
- 可收起成仅显示 token 用量和费用的 mini 状态条；
- 首次打开强制显示完整面板。

## 环境要求

- Windows
- 已安装 Codex++ 和 Codex 桌面端

插件本身是 Codex++ 用户脚本，不需要 Python、Node.js 或额外后台服务。

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

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

然后重启 Codex。

## 隐私说明

- 插件只在 Codex 本机页面中运行，不启动后台服务，不发送遥测；
- 不读取、不保存 API Key；
- 不读取、不保存聊天正文、提示词或完整响应；
- 只记录模型名、token 数量、费用、时间等统计字段；
- 数据保存在 Codex 本机本地存储中；
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
