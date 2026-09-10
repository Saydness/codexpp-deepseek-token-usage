$ErrorActionPreference = 'Stop'

$appData = [Environment]::GetFolderPath('ApplicationData')
$codexPlusRoot = Join-Path $appData 'Codex++'
$userScriptDir = Join-Path $codexPlusRoot 'user_scripts'
$registryPath = Join-Path $codexPlusRoot 'user_scripts.json'
$target = Join-Path $userScriptDir 'deepseek-token-usage.js'

if (Test-Path -LiteralPath $registryPath) {
    Copy-Item -LiteralPath $registryPath -Destination ($registryPath + '.bak') -Force
    $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -ne $registry.scripts) {
        $registry.scripts.PSObject.Properties.Remove('user:deepseek-token-usage.js')
    }
    $registry |
        ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $registryPath -Encoding UTF8
}

if (Test-Path -LiteralPath $target) {
    Remove-Item -LiteralPath $target -Force
}

Write-Host 'DeepSeek Token Usage 已卸载，请重启 Codex。'
