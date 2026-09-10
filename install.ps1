$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $root 'codexpp\deepseek-token-usage.user.js'
if (-not (Test-Path -LiteralPath $source)) {
    throw "未找到插件脚本: $source"
}

$appData = [Environment]::GetFolderPath('ApplicationData')
$codexPlusRoot = Join-Path $appData 'Codex++'
$userScriptDir = Join-Path $codexPlusRoot 'user_scripts'
$registryPath = Join-Path $codexPlusRoot 'user_scripts.json'
$target = Join-Path $userScriptDir 'deepseek-token-usage.js'

if (-not (Test-Path -LiteralPath $codexPlusRoot)) {
    throw "未找到 Codex++ 配置目录: $codexPlusRoot。请先安装并启动 Codex++。"
}

New-Item -ItemType Directory -Path $userScriptDir -Force | Out-Null
Copy-Item -LiteralPath $source -Destination $target -Force

if (Test-Path -LiteralPath $registryPath) {
    Copy-Item -LiteralPath $registryPath -Destination ($registryPath + '.bak') -Force
    $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    $registry = [pscustomobject]@{ enabled = $true; scripts = [pscustomobject]@{} }
}

if ($null -eq $registry.scripts) {
    $registry | Add-Member -NotePropertyName scripts -NotePropertyValue ([pscustomobject]@{}) -Force
}
$registry.enabled = $true
$registry.scripts | Add-Member -NotePropertyName 'user:deepseek-token-usage.js' -NotePropertyValue $true -Force

$registry |
    ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $registryPath -Encoding UTF8

Write-Host 'DeepSeek Token Usage 已安装。'
Write-Host "脚本: $target"
Write-Host "配置: $registryPath"
Write-Host '请重启 Codex / ChatGPT 桌面端。'
