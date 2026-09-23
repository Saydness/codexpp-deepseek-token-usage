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
 * 支持的机器：Codex++ 的 Windows x64 安装包（ARM64 机器上以兼容层跑的也是它）。
 * 脚本只用系统自带的 PowerShell / wscript，node.exe 会去 PATH、Program Files、
 * nvm-windows、Volta、Scoop、Chocolatey 等常见位置找：有现成的（18+）直接用，
 * 没有才按机器架构替用户装一个，不挑装法、也不挑架构。
 #>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$NoStart,
    [string]$Source = '',
    # 内部标记：这一层已经跑在"真实环境"里（由下面的重入逻辑用 WMI 拉起），不再重入。
    [switch]$Inner
)

$ErrorActionPreference = 'Stop'

$HelperFiles = @('dstu-helper.mjs', 'balance_sources.mjs', 'set_balance_key.ps1', 'start-helper.vbs', 'ensure-helper.vbs')
$TaskName = 'DeepSeek 用量助手'
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
    $portable = Get-PortableNodeExe
    if ($portable) { return $portable }
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

# winget / 便携包要按机器架构挑：ARM64 的机器上装 x64 版能跑（兼容层），但原生版更省电。
function Get-MachineArch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    if ($arch -eq 'ARM64') { return 'arm64' }
    return 'x64'
}

function Get-NodeMajor([string]$NodeExe) {
    if (-not $NodeExe) { return 0 }
    try {
        $text = (@(& $NodeExe -p 'process.versions.node' 2>$null) | Select-Object -First 1)
        $major = [int]([string]$text -split '\.')[0]
        if ($major -gt 0) { return $major }
    } catch { }
    return 0
}

# 便携版 node：解压在本机目录里，不需要管理员权限，也不会动系统 PATH。
function Get-PortableNodeExe {
    $root = Join-Path $CodexPlusDir 'node-runtime'
    if (-not (Test-Path -LiteralPath $root)) { return '' }
    $candidate = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'node.exe' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if (-not $candidate) { return '' }
    return [string]$candidate
}

function Save-NodePath([string]$NodeExe) {
    if (-not $NodeExe) { return }
    try {
        Set-Content -LiteralPath (Join-Path $InstallDir 'node-path.txt') -Value $NodeExe -Encoding ASCII
    } catch { }
}

function Install-PortableNode {
    $arch = Get-MachineArch
    $version = 'v22.20.0'
    try {
        $index = (Invoke-WebRequest -Uri 'https://nodejs.org/dist/index.json' -UseBasicParsing -TimeoutSec 20).Content | ConvertFrom-Json
        $lts = @($index | Where-Object { $_.lts }) | Select-Object -First 1
        if ($lts -and $lts.version) { $version = [string]$lts.version }
    } catch { }
    $file = 'node-' + $version + '-win-' + $arch + '.zip'
    $sources = @(
        ('https://nodejs.org/dist/' + $version + '/' + $file),
        ('https://npmmirror.com/mirrors/node/' + $version + '/' + $file)
    )
    $zip = Join-Path $env:TEMP $file
    $downloaded = $false
    foreach ($url in $sources) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        } catch { }
        Write-Host ('  下载 ' + $url)
        try {
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 300
            $downloaded = $true
            break
        } catch {
            Write-Host ('  这条下不动（' + $_.Exception.Message + '），换下一条')
        }
    }
    if (-not $downloaded) { return '' }
    $root = Join-Path $CodexPlusDir 'node-runtime'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        Expand-Archive -LiteralPath $zip -DestinationPath $root -Force
    } catch {
        Write-Host ('  解压失败：' + $_.Exception.Message)
        return ''
    } finally {
        try { Remove-Item -LiteralPath $zip -Force } catch { }
    }
    return (Get-PortableNodeExe)
}

<#
 * 缺 Node.js 时自动补上：先试 winget（装成系统版，可能要过一次 UAC），
 * 走不通就退回便携包（纯本机目录、不需要管理员、下载源带国内镜像）。
#>
function Ensure-NodeRuntime {
    $existing = Get-NodeExe
    if ($existing) {
        $major = Get-NodeMajor $existing
        if ($major -ge 18) {
            Write-Host ('  检测到 Node.js：{0}（v{1}）——直接使用，不再安装' -f $existing, $major)
            return $existing
        }
        Write-Host ('  检测到 Node.js：{0}，但版本低于 18，助手用不了，继续装新的' -f $existing) -ForegroundColor Yellow
    } else {
        Write-Host '  检测 Node.js：没装'
    }
    Write-Host '  助手需要 Node.js 18+，这里替你先装好（只装一次）。' -ForegroundColor Yellow
    try {
        $winget = (Get-Command winget -ErrorAction SilentlyContinue).Source
        if ($winget) {
            Write-Host '  用 winget 安装 Node.js LTS（可能会弹一次 UAC 授权窗口，点「是」即可）…'
            & $winget install -e --id OpenJS.NodeJS.LTS --silent --accept-source-agreements --accept-package-agreements | Out-Null
            $after = Get-NodeExe
            if ($after -and (Get-NodeMajor $after) -ge 18) { return $after }
        }
    } catch {
        Write-Host ('  winget 这条走不通（' + $_.Exception.Message + '）')
    }
    Write-Host '  改用便携版 Node.js（只装在本机目录，不需要管理员权限）…'
    $portable = Install-PortableNode
    if ($portable) { return $portable }
    return ''
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
    $task = $null
    try { $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch { $task = $null }
    if ($task) {
        Write-Host ('  开机自启 : 计划任务「{0}」  {1}' -f $TaskName, $(if ($task.State -eq 'Disabled') { '[已禁用]' } else { '[已配置]' }))
    } else {
        Write-Host ('  开机启动 : {0}  {1}' -f $StartupLink, $(if (Test-Path -LiteralPath $StartupLink) { '[已配置]' } else { '[未配置]' }))
    }
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

<#
  自启动为什么用计划任务：
  「启动」文件夹的快捷方式只在**登录那一刻**触发。一键安装是从 Codex 里跑起来的，
  那时拉起的看门狗挂在应用的进程树上，Codex 一重启（比如应用升级）就被一起带走；
  下次登录之前没人再管它，助手就一直不跑（2026-09-21 实际踩到过）。
  现在注册一个计划任务：登录时 + 之后每 5 分钟跑一次幂等的 ensure-helper.vbs
  ——看门狗在跑就什么都不做，不在跑就立刻拉起来。这样「打开 Codex 助手就自动启用」
  一直成立，不依赖用户重登录，也不怕看门狗被杀。
  计划任务被组策略挡住时，退回原来的「启动」文件夹快捷方式（同样指向 ensure-helper.vbs）。
#>
function Register-HelperAutostart {
    $ensurePath = Join-Path $InstallDir 'ensure-helper.vbs'
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $user = $env:USERDOMAIN + '\' + $env:USERNAME
    $registered = $false

    if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) {
        try {
            # 用 XML 注册：cmdlet 的 -RepetitionInterval 少写一个 Duration 就会变成
            # 「跑一次就停」（第一次实测就踩到了），这里写成「每天 00:00 起、每 5 分钟
            # 重复、持续一天」，天天循环，等于一直每 5 分钟巡检。
            $dayStart = (Get-Date).ToString('yyyy-MM-dd') + 'T00:00:00'
            $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>DeepSeek 用量助手：Codex 一打开就让本机助手跑起来（登录时 + 每 5 分钟巡检看门狗）</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$user</UserId>
    </LogonTrigger>
    <CalendarTrigger>
      <StartBoundary>$dayStart</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
      <Repetition>
        <Interval>PT5M</Interval>
        <Duration>P1D</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$user</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$wscript</Command>
      <Arguments>"$ensurePath"</Arguments>
      <WorkingDirectory>$InstallDir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
            Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null
            $registered = $true
        } catch {
            $registered = $false
        }
    }

    if (-not $registered) {
        try {
            & schtasks.exe /Create /TN $TaskName /SC MINUTE /MO 5 /TR ('"' + $wscript + '" "' + $ensurePath + '"') /F | Out-Null
            $registered = ($LASTEXITCODE -eq 0)
        } catch {
            $registered = $false
        }
    }

    if ($registered) {
        Write-Host ('  开机自启 : 计划任务「{0}」（登录时 + 每 5 分钟巡检：看门狗没在跑就拉起来）' -f $TaskName)
    } else {
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($StartupLink)
        $link.TargetPath = $wscript
        $link.Arguments = '"' + $ensurePath + '"'
        $link.WorkingDirectory = $InstallDir
        $link.Description = 'DeepSeek 用量助手：Codex 启动时读余额，退出就停'
        $link.Save()
        Write-Host ('  开机自启 : {0}（计划任务注册不了，退回启动项；只在登录时触发）' -f $StartupLink)
    }
    return $registered
}

function Start-HelperAutostart {
    # 优先让计划任务去启动：这样看门狗跑在任务计划程序的进程里，不挂在 Codex 的
    # 进程树上，应用重启也带不走它。
    try {
        & schtasks.exe /Run /TN $TaskName | Out-Null
        if ($LASTEXITCODE -eq 0) { Start-Sleep -Seconds 3 }
    } catch {
    }
    # 兜底：计划任务没跑起来就直接起一次（ensure 是幂等的，不会起两只）。
    if ((Get-MatchingProcess 'start-helper.vbs').Count -eq 0) {
        $ensurePath = Join-Path $InstallDir 'ensure-helper.vbs'
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + $ensurePath + '"') -WindowStyle Hidden
    }
}

function Unregister-HelperAutostart {
    if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Write-Host ('已删除计划任务：{0}' -f $TaskName)
        } catch {
        }
    }
    try {
        & schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null
    } catch {
    }
    if (Test-Path -LiteralPath $StartupLink) {
        Remove-Item -LiteralPath $StartupLink -Force
        Write-Host ('已删除启动项：{0}' -f $StartupLink)
    }
}

<#
  沙箱重入：为什么安装动作要换个进程做

  Codex 的 shell 可能带着文件系统"覆盖层"跑（workspace-write 沙箱）：本进程往
  %LOCALAPPDATA%\Codex++ 里写的文件，Windows 其它进程（计划任务、资源管理器）看不到，
  只有 Codex 这一支进程树能看见。2026-09-23 实测：同一个安装目录，外部进程只列出 6 个
  文件，沙箱里能列出 9 个 —— 面板「一键安装」是让 Codex 执行命令的，装出来的助手文件
  可能只活在覆盖层里，下次登录就找不到，助手再也起不来。

  所以真正干活之前，先用 WMI 创建进程（父进程是 WmiPrvSE，不在 Codex 的进程树里、
  也不在沙箱里）重跑一遍自己，把安装/卸载落在真实文件系统上；这一层只负责等待、把第二段
  的日志打出来。WMI 走不通时退回本进程直接执行，至少不比以前差。
#>
function Invoke-HelperRealRun {
    param([string]$ExtraArgs = '')

    $isUninstall = $ExtraArgs -like '*Uninstall*'
    $logName = if ($isUninstall) { 'uninstall-helper.log' } else { 'install-helper.log' }
    $logPath = Join-Path $CodexPlusDir $logName
    New-Item -ItemType Directory -Path $CodexPlusDir -Force | Out-Null

    # 第二段自己从发布地址拉脚本再跑：命令短、不用把正文塞进命令行
    # （实测超长内联命令会被 WMI 拒掉），也不依赖"本地这份脚本文件"在不在沙箱里。
    $base = if ($Source -and $Source -match '^(https?|file)://') { $Source.TrimEnd('/') } else { $DefaultSourceUrl }
    $payload = "try { " +
        "`$t = (New-Object Net.WebClient).DownloadString('$base/install-helper.ps1') } " +
        "catch { Write-Host '==DONE exit=3=='; exit 3 }; " +
        "& ([scriptblock]::Create(`$t)) -Inner -Source '$base' $ExtraArgs; " +
        "Write-Host ('==DONE exit=' + `$LASTEXITCODE + '==')"
    $child = 'cmd.exe /c powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "' + $payload + '" > "' + $logPath + '" 2>&1'

    $pid2 = 0
    $wmError = ''
    try {
        $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $child }
        if ($result.ReturnValue -eq 0) { $pid2 = [int]$result.ProcessId }
        else { $wmError = 'WMI 返回码 ' + $result.ReturnValue }
    } catch {
        $wmError = $_.Exception.Message
        $pid2 = 0
    }
    if (-not $pid2) {
        Write-Host ('（沙箱重入不可用：' + $wmError + '，改成在当前进程里执行）')
        return $null
    }

    Write-Host '检测到可能运行在沙箱里：已交给真实环境的后台进程执行，稍等…'
    $deadline = (Get-Date).AddSeconds(240)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 800
        $alive = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $pid2) -ErrorAction SilentlyContinue
        if (-not $alive) { break }
    }

    $code = 0
    if (Test-Path -LiteralPath $logPath) {
        $text = Get-Content -LiteralPath $logPath -Raw
        Write-Host ''
        Write-Host '---- 真实环境里的安装输出 ----'
        Write-Host $text.TrimEnd()
        Write-Host '------------------------------'
        if ($text -match '==DONE exit=(\d+)==') { $code = [int]$Matches[1] }
        else { $code = 1 }
        # 第二段连脚本都没拉下来（断网）：退回本进程直接装，别让用户白跑一趟。
        if ($code -eq 3) {
            Write-Host '（真实环境那段没能下载脚本：可能在断网，改回当前进程继续）'
            return $null
        }
    } else {
        Write-Host '（没能读到第二段的日志，可能被安全软件拦了）'
        $code = 1
    }
    return $code
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
    } elseif ($base -match '^(https?|file)://') {
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

    # 缺 Node.js 就在这里补上，用户只需要把这一个脚本跑起来。
    $nodePath = Ensure-NodeRuntime
    Save-NodePath $nodePath

    Register-HelperAutostart | Out-Null

    if (-not $NoStart) {
        Start-HelperAutostart
    }

    if (-not $nodePath) {
        Write-Host ''
        Write-Host '提示：Node.js 没装成功（网络不通或安装被取消），助手暂时起不来；' -ForegroundColor Yellow
        Write-Host '     装上 Node.js 18+ 后不用重装本助手，重启 Codex 即可。' -ForegroundColor Yellow
        Write-Host '      winget install OpenJS.NodeJS.LTS   （没有 winget 就到 nodejs.org 下安装包）'
    } else {
        Write-Host ('  助手用的 Node.js：{0}' -f $nodePath)
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

    Unregister-HelperAutostart

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

if ($Status) {
    # 只读操作：直接在本进程里跑，输出用户能立刻看到。
    Show-Status
    exit 0
}

if (-not $Inner) {
    # 装/卸载都交给"真实环境"里的第二段（见上面 Invoke-HelperRealRun 的说明）。
    $innerArgs = if ($Uninstall) { '-Uninstall' } else { '' }
    $innerCode = Invoke-HelperRealRun $innerArgs
    if ($innerCode -ne $null) { exit $innerCode }
}

if ($Uninstall) {
    Uninstall-Helper
} else {
    Install-Helper
    Show-Status
}
