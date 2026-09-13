param(
    [string]$Package = "com.notion.app",
    [string]$OutDir = "",
    [string]$Adb = "adb",
    [switch]$Clear,
    [switch]$Follow
)

$ErrorActionPreference = "Stop"

function New-DefaultOutDir {
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    return Join-Path (Get-Location) "artifacts\adb-crash-logs\$timestamp"
}

function Write-TextFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [AllowNull()][object]$Content
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    if ($null -eq $Content) {
        "" | Set-Content -Path $Path -Encoding UTF8
    } elseif ($Content -is [array]) {
        $Content | Set-Content -Path $Path -Encoding UTF8
    } else {
        [string]$Content | Set-Content -Path $Path -Encoding UTF8
    }
}

function Invoke-AdbCapture {
    param(
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [Parameter(Mandatory=$true)][string]$Name
    )

    $path = Join-Path $OutDir $Name
    try {
        $output = & $Adb @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $header = @(
            "> adb $($Arguments -join ' ')",
            "> exit=$exitCode",
            ""
        )
        Write-TextFile -Path $path -Content ($header + $output)
    } catch {
        Write-TextFile -Path $path -Content @(
            "> adb $($Arguments -join ' ')",
            "> failed=$($_.Exception.Message)"
        )
    }
}

function Select-LogContext {
    param(
        [Parameter(Mandatory=$true)][object[]]$Lines,
        [Parameter(Mandatory=$true)][string]$Pattern,
        [int]$Before = 30,
        [int]$After = 100
    )

    if ($Lines.Count -eq 0) { return @() }

    $selected = New-Object bool[] $Lines.Count
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ([string]$Lines[$i] -match $Pattern) {
            $start = [Math]::Max(0, $i - $Before)
            $end = [Math]::Min($Lines.Count - 1, $i + $After)
            for ($j = $start; $j -le $end; $j++) {
                $selected[$j] = $true
            }
        }
    }

    $result = New-Object System.Collections.Generic.List[string]
    $lastWasGap = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($selected[$i]) {
            if ($lastWasGap) {
                $result.Add("--- omitted unrelated log lines ---")
                $lastWasGap = $false
            }
            $result.Add([string]$Lines[$i])
        } else {
            $lastWasGap = $true
        }
    }
    return $result.ToArray()
}

$adbCommand = Get-Command $Adb -ErrorAction SilentlyContinue
if ($null -eq $adbCommand) {
    throw "未找到 adb。请先安装 Android platform-tools，并确认 adb 在 PATH 中。"
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = New-DefaultOutDir
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$modes = @()
if ($Clear) { $modes += "Clear" }
if ($Follow) { $modes += "Follow" }
if ($modes.Count -eq 0) { $modes += "Dump" }

Write-TextFile -Path (Join-Path $OutDir "host.txt") -Content @(
    "hostTime=$(Get-Date -Format o)",
    "package=$Package",
    "adb=$($adbCommand.Source)",
    "mode=$($modes -join ',')"
)

Invoke-AdbCapture -Arguments @("devices", "-l") -Name "adb-devices.txt"

if ($Clear) {
    & $Adb logcat -c | Out-Null
    Write-Host "已清空设备 logcat 缓冲区。"
    if (-not $Follow) {
        Write-Host "现在请复现闪退；闪退后再运行："
        Write-Host "  powershell -ExecutionPolicy Bypass -File tools\collect_android_crash_logs.ps1"
        Write-Host "输出目录：$OutDir"
        return
    }
}

if ($Follow) {
    $livePath = Join-Path $OutDir "logcat-live.txt"
    Write-Host "开始实时采集 logcat：$livePath"
    Write-Host "请现在在手机上复现闪退；闪退发生后按 Ctrl+C 停止脚本，然后把输出目录发出来。"
    & $Adb logcat -v threadtime 2>&1 | Tee-Object -FilePath $livePath
    return
}

Invoke-AdbCapture -Arguments @("get-state") -Name "adb-state.txt"
Invoke-AdbCapture -Arguments @("shell", "date") -Name "device-date.txt"
Invoke-AdbCapture -Arguments @("shell", "getprop") -Name "device-getprop.txt"
Invoke-AdbCapture -Arguments @("shell", "pidof", $Package) -Name "app-pid.txt"
Invoke-AdbCapture -Arguments @("shell", "dumpsys", "package", $Package) -Name "dumpsys-package.txt"
Invoke-AdbCapture -Arguments @("shell", "dumpsys", "activity", "processes") -Name "dumpsys-activity-processes.txt"
Invoke-AdbCapture -Arguments @("shell", "dumpsys", "activity", "exit-info", $Package) -Name "dumpsys-activity-exit-info.txt"
Invoke-AdbCapture -Arguments @("shell", "dumpsys", "dropbox", "--print", "data_app_crash", "data_app_native_crash", "data_app_anr", "system_app_crash", "system_app_native_crash", "system_app_anr") -Name "dumpsys-dropbox-crashes.txt"

$logcatPath = Join-Path $OutDir "logcat-full.txt"
try {
    $logcat = & $Adb logcat -d -v threadtime 2>&1
    Write-TextFile -Path $logcatPath -Content $logcat

    $escapedPackage = [regex]::Escape($Package)
    $pattern = "($escapedPackage|AndroidRuntime|FATAL EXCEPTION|Fatal signal|SIGSEGV|SIGABRT|crash_dump|tombstone|DEBUG\s*:|libc\s*:|chromium|AwBrowser|WebView|RenderProcess|ActivityManager|am_crash|ANR|Input dispatching timed out|lowmemorykiller|ApplicationExitInfo)"
    $filtered = Select-LogContext -Lines $logcat -Pattern $pattern
    Write-TextFile -Path (Join-Path $OutDir "logcat-crash-context.txt") -Content $filtered
} catch {
    Write-TextFile -Path $logcatPath -Content "采集 logcat 失败：$($_.Exception.Message)"
}

$zipPath = "$OutDir.zip"
try {
    if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path (Join-Path $OutDir "*") -DestinationPath $zipPath -Force
    Write-Host "采集完成：$OutDir"
    Write-Host "压缩包：$zipPath"
} catch {
    Write-Host "采集完成：$OutDir"
    Write-Host "压缩失败：$($_.Exception.Message)"
}
