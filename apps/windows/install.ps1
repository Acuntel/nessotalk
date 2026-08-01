[CmdletBinding()]
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$TaskName = 'ptt-dictate'
$AppRoot = if ($env:PTT_DICTATE_HOME) { $env:PTT_DICTATE_HOME } else { Join-Path $env:LOCALAPPDATA 'ptt-dictate' }
$Dll = Join-Path $AppRoot 'ptt-dictate.dll'
$Launcher = Join-Path $AppRoot 'ptt-launcher.vbs'

function Find-DotNetHost {
    $System = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($System -and ((& $System.Source --list-runtimes) -match '^Microsoft\.WindowsDesktop\.App 9\.')) { return $System.Source }
    $Local = Join-Path $PSScriptRoot '.tools\dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $Local) { return $Local }
    $Installed = Join-Path $AppRoot 'dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $Installed) { return $Installed }
    throw 'A .NET 9 Windows Desktop runtime is required. Run setup.ps1 first.'
}

if ($Uninstall) {
    if (Test-Path -LiteralPath $Dll) {
        try { & (Find-DotNetHost) $Dll --send stop | Out-Null } catch { }
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host 'Removed the ptt-dictate scheduled task. App data and models were kept.'
    exit 0
}

if (-not (Test-Path -LiteralPath $Dll)) {
    & (Join-Path $PSScriptRoot 'ptt.ps1') build
}
if (-not (Test-Path -LiteralPath $Launcher)) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ptt-launcher.vbs') -Destination $Launcher -Force
}

$Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$DotNetHost = Find-DotNetHost
$Wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$Action = New-ScheduledTaskAction -Execute $Wscript -Argument "`"$Launcher`" `"$DotNetHost`" `"$Dll`"" -WorkingDirectory $AppRoot
$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $Identity
$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable
$Principal = New-ScheduledTaskPrincipal -UserId $Identity -LogonType Interactive -RunLevel Limited
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    try { & $DotNetHost $Dll --send stop | Out-Null } catch { }
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
}
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal -Description 'Local push-to-talk whisper.cpp dictation daemon' -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host 'Installed and started ptt-dictate for the current Windows user.'
