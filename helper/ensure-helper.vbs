' DeepSeek Token Usage - one-shot "make sure the watchdog is alive" script.
'
' start-helper.vbs (the watchdog) is what actually starts the node helper when
' Codex comes up and stops it when Codex exits. This script only guarantees that
' the watchdog itself is running, so "open Codex -> helper is up" keeps holding
' even if the watchdog was killed (Codex restarting, task manager, antivirus) or
' was started inside Codex's own process tree by the installer.
'
' Registered as a scheduled task (at logon, then repeated every few minutes).
' Running it while everything is already up does nothing - it is idempotent.
' Everything here stays ASCII on purpose: WSH reads .vbs files as ANSI, and
' non-ASCII bytes can swallow the closing quote of a string literal.

Option Explicit

Dim sh, fso, wmi, baseDir, watchdogPath, wscriptPath, logPath
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
Set wmi = GetObject("winmgmts:\\.\root\cimv2")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
watchdogPath = fso.BuildPath(baseDir, "start-helper.vbs")
wscriptPath = fso.BuildPath(sh.ExpandEnvironmentStrings("%SystemRoot%"), "System32\wscript.exe")
logPath = fso.BuildPath(baseDir, "ensure-helper.log")

' Nothing to do when the helper is not installed, or Codex is not running:
' the helper only matters while Codex is up.
If Not fso.FileExists(watchdogPath) Then
    LogLine "start-helper.vbs missing next to this script, nothing to do"
    WScript.Quit 0
End If
If Not IsCodexRunning() Then
    LogLine "Codex not running, nothing to do"
    WScript.Quit 0
End If
If IsWatchdogRunning() Then
    LogLine "watchdog already running"
    WScript.Quit 0
End If

' The startup shortcut and the scheduled task can both land here at logon;
' wait a moment and check once more so we never start two watchdogs.
WScript.Sleep 400
If IsWatchdogRunning() Then
    LogLine "watchdog already running (second check)"
    WScript.Quit 0
End If

' Start it through WMI rather than sh.Run: the new process becomes a child of
' WmiPrvSE, which keeps it out of the scheduled task's process tree (children die
' with the task instance) and out of Codex's process tree (children die when the
' app restarts).
StartWatchdog()

Function StartWatchdog()
    Dim startup, wmiProc, pid
    pid = 0
    On Error Resume Next
    Set startup = GetObject("winmgmts:Win32_ProcessStartup").SpawnInstance_
    startup.ShowWindow = 0
    Set wmiProc = GetObject("winmgmts:\\.\root\cimv2:Win32_Process")
    wmiProc.Create """" & wscriptPath & """ """ & watchdogPath & """", startup, pid
    If Err.Number <> 0 Then
        LogLine "WMI start failed: " & Err.Number & " " & Err.Description
        pid = 0
    End If
    On Error GoTo 0
    If pid = 0 Then
        ' Fall back to a plain launch: at least this session works, and the next
        ' logon / task run retries anyway.
        On Error Resume Next
        sh.CurrentDirectory = baseDir
        sh.Run """" & wscriptPath & """ """ & watchdogPath & """", 0, False
        If Err.Number <> 0 Then
            LogLine "plain start failed: " & Err.Number & " " & Err.Description
        Else
            LogLine "watchdog started (plain launch)"
        End If
        On Error GoTo 0
    Else
        LogLine "watchdog started (pid " & pid & ")"
    End If
End Function

' One line per run (time + what happened); the file is trimmed at 100 KB.
Sub LogLine(message)
    Dim file, stream
    On Error Resume Next
    If fso.FileExists(logPath) Then
        Set file = fso.GetFile(logPath)
        If file.Size > 102400 Then
            Set stream = file.OpenAsTextStream(2)
            stream.Close
        End If
    End If
    Set stream = fso.OpenTextFile(logPath, 8, True)
    stream.WriteLine Now & "  " & message
    stream.Close
    If Err.Number <> 0 Then Err.Clear
    On Error GoTo 0
End Sub

Function IsCodexRunning()
    Dim procs, p
    IsCodexRunning = False
    Set procs = wmi.ExecQuery("SELECT Name FROM Win32_Process WHERE Name='ChatGPT.exe' OR Name='codex.exe' OR Name='codex-plus-plus.exe' OR Name='CodexPlusPlus.exe'")
    For Each p In procs
        IsCodexRunning = True
        Exit Function
    Next
End Function

Function IsWatchdogRunning()
    Dim procs, p
    IsWatchdogRunning = False
    Set procs = wmi.ExecQuery("SELECT CommandLine FROM Win32_Process WHERE Name='wscript.exe'")
    For Each p In procs
        If Not IsNull(p.CommandLine) Then
            If InStr(1, p.CommandLine, "start-helper.vbs", 1) > 0 Then
                IsWatchdogRunning = True
                Exit Function
            End If
        End If
    Next
End Function
