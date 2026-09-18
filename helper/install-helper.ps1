<#
 * DeepSeek 用量面板 · 本机助手一键安装 / 卸载 / 查看状态
 *
 * 助手只负责把 DeepSeek 账户余额送进面板：Codex 在跑的时候每 5 分钟读一次，
 * 面板点「刷新余额」时立刻补一次。token 用量和费用统计不需要它，不装也不影响。
 * 看门狗只在 Codex 运行时让助手跑，Codex 退出就把助手停掉，平时不占资源。
 *
 * 用法：
 *   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-helper.ps1             安装并启动
 *   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-helper.ps1 -Status     查看状态
 *   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-helper.ps1 -Uninstall  卸载
 *
 * 不下载仓库、直接从网络跑也可以（面板「复制安装命令」给的就是这条）：
 *   $p = Join-Path $env:TEMP 'dstu-helper-install.ps1'
 *   irm https://raw.githubusercontent.com/Saydness/codexpp-deepseek-token-usage/main/helper/install-helper.ps1 -OutFile $p
 *   & $p
 *
 * 安装位置：%LOCALAPPDATA%\Codex++\dstu-helper\
 * 自启动：  「启动」文件夹中的「DeepSeek 用量助手.lnk」（指向 start-helper.vbs）
 * 不需要管理员权限；不写注册表、不建计划任务，卸载时把这两处一并清掉。
 *
 * 支持的机器：x64 与 ARM64 的 Windows 都一样能装——脚本只用系统自带的
 * PowerShell / wscript，node.exe 会去 PATH、Program Files、nvm-windows、
 * Volta、Scoop、Chocolatey 等常见位置找，不挑架构也不挑装法。
 #>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$NoStart,
    [string]$Source = ''
)

$ErrorActionPreference = 'Stop'

$HelperFiles = @('dstu-helper.mjs', 'balance_sources.mjs', 'set_balance_key.ps1', 'start-helper.vbs')
$DefaultSourceUrl = 'https://raw.githubusercontent.com/Saydness/codexpp-deepseek-token-usage/main/helper'
$CodexPlusDir = Join-Path $env:LOCALAPPDATA 'Codex++'
$InstallDir = Join-Path $CodexPlusDir 'dstu-helper'
$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'DeepSeek 用量助手.lnk'
$WatchdogPath = Join-Path $InstallDir 'start-helper.vbs'
$HelperPath = Join-Path $InstallDir 'dstu-helper.mjs'
$KeyStorePath = Join-Path $CodexPlusDir 'deepseek-balance.key'

function Get-MatchingProcess([string]$Needle) {
    $items = @()
    try {
        $items = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + $Needle + '*') }
    } catch {
        $items = @()
    }
    return @($items)
}

function Get-NodeExe {
    $command = Get-Command node -ErrorAction SilentlyContinue
    if ($command -and $command.Source) { return $command.Source }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe')
    }
    # 版本管理器 / 包管理器把 node 放在这些地方：nvm-windows、Volta、Scoop、fnm、Chocolatey。
    if ($env:NVM_HOME) { $candidates += (Join-Path $env:NVM_HOME 'node.exe') }
    if ($env:NVM_SYMLINK) { $candidates += (Join-Path $env:NVM_SYMLINK 'node.exe') }
    $candidates += @(
        (Join-Path $env:APPDATA 'nvm\node.exe'),
        (Join-Path $env:LOCALAPPDATA 'Volta\bin\node.exe'),
        (Join-Path $env:USERPROFILE 'scoop\shims\node.exe'),
        (Join-Path $env:USERPROFILE 'scoop\apps\nodejs\current\node.exe'),
        (Join-Path $env:ProgramData 'chocolatey\bin\node.exe'),
        (Join-Path $env:LOCALAPPDATA 'fnm_multishells\node.exe'),
        'C:\nodejs\node.exe'
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return ''
}

# 这台机器是什么架构：x64 的老机器、ARM64 的新机器（x64 程序走兼容层）都要说清楚。
function Get-ArchText {
    $processArch = $env:PROCESSOR_ARCHITECTURE
    $isArm = ($processArch -eq 'ARM64') -or ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64')
    $bits = if ([Environment]::Is64BitOperatingSystem) { '64 位' } else { '32 位' }
    if ($isArm) { return ('Windows on ARM / ARM64（' + $bits + '，x64 程序走兼容层）') }
    if ($processArch) { return ('Windows ' + $processArch + '（' + $bits + '）') }
    return ('Windows（' + $bits + '）')
}

function Get-ProcessIdText($items) {
    if (-not $items -or $items.Count -eq 0) { return '未运行' }
    $ids = ($items | ForEach-Object { $_.ProcessId }) -join ', '
    return ('运行中 (PID ' + $ids + ')')
}

function Show-Status {
    $installed = Test-Path -LiteralPath $InstallDir
    Write-Host ''
    Write-Host 'DeepSeek 用量助手 · 状态' -ForegroundColor Cyan
    Write-Host ('  系统架构 : {0}' -f (Get-ArchText))
    Write-Host ('  安装目录 : {0}  {1}' -f $InstallDir, $(if ($installed) { '[已安装]' } else { '[未安装]' }))
    if ($installed) {
        foreach ($name in $HelperFiles) {
            $present = Test-Path -LiteralPath (Join-Path $InstallDir $name)
            Write-Host ('    - {0,-24} {1}' -f $name, $(if ($present) { 'ok' } else { '缺失' }))
        }
    }
    Write-Host ('  开机启动 : {0}  {1}' -f $StartupLink, $(if (Test-Path -LiteralPath $StartupLink) { '[已配置]' } else { '[未配置]' }))
    Write-Host ('  看门狗   : {0}' -f (Get-ProcessIdText (Get-MatchingProcess 'start-helper.vbs')))
    Write-Host ('  助手进程 : {0}' -f (Get-ProcessIdText (Get-MatchingProcess 'dstu-helper.mjs')))
    $nodeExe = Get-NodeExe
    if ($nodeExe) {
        $nodeArch = ''
        try { $nodeArch = (@(& $nodeExe -p 'process.arch' 2>$null) | Select-Object -First 1) } catch { $nodeArch = '' }
        Write-Host ('  Node.js  : {0}（{1}）' -f $nodeExe, $(if ($nodeArch) { $nodeArch } else { '架构未知' }))
    } else {
        Write-Host '  Node.js  : 没找到（助手要 Node.js 18+）'
        Write-Host '             装法： winget install OpenJS.NodeJS.LTS ｜ 或到 https://nodejs.org 下安装包（x64 / ARM64 各有一版）'
    }
    Write-Host ('  已存 Key : {0}' -f $(if (Test-Path -LiteralPath $KeyStorePath) { '有（DPAPI 加密）' } else { '没有（面板里填一次，或让它读 Codex 自己的 Key）' }))
    Write-Host ''
}

function Install-Helper {
    $useUrl = $false
    $base = $Source
    if (-not $base) {
        if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'dstu-helper.mjs'))) {
            $base = $PSScriptRoot
        } else {
            $base = $DefaultSourceUrl
            $useUrl = $true
        }
    } elseif ($base -match '^https?://') {
        $useUrl = $true
    }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Write-Host ('从 {0} 安装到 {1}' -f $base, $InstallDir)

    foreach ($name in $HelperFiles) {
        $target = Join-Path $InstallDir $name
        if ($useUrl) {
            $url = ($base.TrimEnd('/')) + '/' + $name
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            } catch {
                # PowerShell 7 已经不需要手动设 TLS。
            }
            Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing
        } else {
            Copy-Item -LiteralPath (Join-Path $base $name) -Destination $target -Force
        }
        if (-not (Test-Path -LiteralPath $target)) { throw ('缺少文件：' + $name) }
    }

    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($StartupLink)
    $link.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $link.Arguments = '"' + $WatchdogPath + '"'
    $link.WorkingDirectory = $InstallDir
    $link.Description = 'DeepSeek 用量助手：Codex 启动时读余额，退出就停'
    $link.Save()

    if (-not $NoStart) {
        $watchdogs = Get-MatchingProcess 'start-helper.vbs'
        if ($watchdogs.Count -eq 0) {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + $WatchdogPath + '"') -WindowStyle Hidden
        }
    }

    if (-not (Get-NodeExe)) {
        Write-Host ''
        Write-Host '提示：这台机器还没装 Node.js，助手暂时起不来；装好 Node.js 18+ 后不用重装，重启 Codex 即可。' -ForegroundColor Yellow
        Write-Host '      winget install OpenJS.NodeJS.LTS   （没有 winget 就到 nodejs.org 下安装包）'
    }
    Write-Host '已安装。' -ForegroundColor Green
    Write-Host '助手会跟着 Codex 自动启停，面板上会显示「运行中」。'
    Write-Host '不需要时运行： powershell -NoProfile -ExecutionPolicy Bypass -File .\install-helper.ps1 -Uninstall'
}

function Uninstall-Helper {
    foreach ($needle in @('start-helper.vbs', 'dstu-helper.mjs')) {
        foreach ($item in (Get-MatchingProcess $needle)) {
            try { Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
    }

    if (Test-Path -LiteralPath $StartupLink) {
        Remove-Item -LiteralPath $StartupLink -Force
        Write-Host ('已删除启动项：{0}' -f $StartupLink)
    }

    if (Test-Path -LiteralPath $InstallDir) {
        $resolved = [System.IO.Path]::GetFullPath($InstallDir)
        $allowed = [System.IO.Path]::GetFullPath($CodexPlusDir) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($allowed, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ('安装目录不在预期范围内，已放弃删除：' + $resolved)
        }
        [System.IO.Directory]::Delete($resolved, $true)
        Write-Host ('已删除安装目录：{0}' -f $resolved)
    }

    if (Test-Path -LiteralPath $KeyStorePath) {
        Write-Host ('已保存的 Key 保留在：{0}（要一起删，运行 set_balance_key.ps1 -Clear）' -f $KeyStorePath)
    }
    Write-Host '已卸载。面板不受影响，余额用手动记录即可。' -ForegroundColor Green
}

if ($Uninstall) {
    Uninstall-Helper
} elseif ($Status) {
    Show-Status
} else {
    Install-Helper
    Show-Status
}
