<#
.SYNOPSIS
    通过 root adb 直接读取 Notion Lite 的 App 内日志文件（无需配置远程日志/OpenList）。

.DESCRIPTION
    本 App 的性能探针（PERF_COLLECT_SCRIPT）与 WebView 事件都写入
    <filesDir>/notion_app_native_crash.log；Dart 层调试日志写入
    <app_flutter>/notion_app_debug.log（需 App 内开启调试日志开关）。

    设备已 root（Magisk）时，用 `su -c cat` 直接读取，比远程日志上传更完整、更及时。
    未 root 时本脚本会失败并给出提示。

    与 tools/collect_android_crash_logs.ps1 的区别：那个抓 logcat / dumpsys，
    本脚本抓 App 自己的内部日志文件。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\pull_app_internal_logs.ps1
    powershell -ExecutionPolicy Bypass -File tools\pull_app_internal_logs.ps1 -Clear
#>
param(
    [string]$Package = "com.notion.app",
    [string]$OutDir = "",
    [string]$Adb = "adb",
    [switch]$Clear,
    [switch]$NoRoot
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function New-DefaultOutDir {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    return Join-Path (Get-Location) "artifacts\device-app-logs\$timestamp"
}

# 用 .NET Process 直接取原始字节，避免 PowerShell 5.1 原生命令管道的编码损坏（中文会乱码）。
function Invoke-AdbBinary {
    param([string[]]$Arguments)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:AdbPath
    $psi.Arguments = ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return @{ Text = $stdout; Error = $stderr; ExitCode = $proc.ExitCode }
}

function Save-Text {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8NoBom)
}

# --- 定位 adb ---
$adbCmd = Get-Command $Adb -ErrorAction SilentlyContinue
if ($null -eq $adbCmd) {
    throw "未找到 adb。请安装 Android platform-tools 并确认 adb 在 PATH 中。"
}
$script:AdbPath = $adbCmd.Source

if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = New-DefaultOutDir }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host "adb      : $($adbCmd.Source)"
Write-Host "package  : $Package"
Write-Host "outDir   : $OutDir"

# --- 设备与 root 状态 ---
$devices = Invoke-AdbBinary -Arguments @("devices", "-l")
Save-Text -Path (Join-Path $OutDir "adb-devices.txt") -Content $devices.Text
if ($devices.Text -notmatch "\sdevice\s") {
    throw "没有处于 device 状态的设备。请确认 USB 调试已授权：`n$($devices.Text)"
}

$idOut = Invoke-AdbBinary -Arguments @("shell", "su", "-c", "id")
$isRoot = ($idOut.Text -match "uid=0")
Save-Text -Path (Join-Path $OutDir "root-check.txt") -Content @(
    "su -c id => $($idOut.Text.Trim())",
    "isRoot=$isRoot"
) -join "`n"

if ($NoRoot -or -not $isRoot) {
    Write-Warning "未获得 root（su -c id 未返回 uid=0）。本脚本依赖 root 直读 App 私有目录。"
    Write-Warning "若不想 root，请在 App 内配置『远程日志』(OpenList) 后上传，再从服务器拉取。"
}

# --- 待抓取的文件（相对 App 私有目录）---
$dataDir = "/data/data/$Package"
$targets = @(
    @{ Remote = "$dataDir/files/notion_app_native_crash.log"; Name = "notion_app_native_crash.log" },
    @{ Remote = "$dataDir/app_flutter/notion_app_debug.log"; Name = "notion_app_debug.log" },
    @{ Remote = "$dataDir/files/notion_app_debug.log"; Name = "notion_app_debug.files.log" }
)

$summary = New-Object System.Collections.Generic.List[string]

foreach ($t in $targets) {
    $exists = Invoke-AdbBinary -Arguments @("shell", "su", "-c", "test -f '$($t.Remote)' && echo YES || echo NO")
    if ($exists.Text.Trim() -ne "YES") {
        $summary.Add("$($t.Name)`tMISSING`t$($t.Remote)")
        continue
    }

    $sizeOut = Invoke-AdbBinary -Arguments @("shell", "su", "-c", "wc -c < '$($t.Remote)'")
    $size = ($sizeOut.Text -replace '\D', '')

    $pulled = Invoke-AdbBinary -Arguments @("exec-out", "su", "-c", "cat '$($t.Remote)'")
    $dest = Join-Path $OutDir $t.Name
    [System.IO.File]::WriteAllText($dest, $pulled.Text, $Utf8NoBom)

    $summary.Add("$($t.Name)`tOK`t${size}B`t$($t.Remote)")
    Write-Host ("pulled {0} ({1} bytes)" -f $t.Name, $size)
}

# --- 可选：清空基线 ---
if ($Clear) {
    foreach ($t in $targets) {
        Invoke-AdbBinary -Arguments @("shell", "su", "-c", "rm -f '$($t.Remote)'") | Out-Null
    }
    $summary.Add("CLEARED`t基线已清空（App 下次写入会自动重建）")
    Write-Host "已清空 App 内日志，建立干净基线。"
}

Save-Text -Path (Join-Path $OutDir "summary.tsv") -Content ($summary -join "`n")
Write-Host "采集完成：$OutDir"
