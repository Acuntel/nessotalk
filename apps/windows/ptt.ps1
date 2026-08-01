[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status', 'log', 'build', 'miccheck', 'devices', 'tap', 'install', 'uninstall', 'setup', 'test')]
    [string]$Command = 'status',

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
$AppRoot = if ($env:PTT_DICTATE_HOME) { $env:PTT_DICTATE_HOME } else { Join-Path $env:LOCALAPPDATA 'ptt-dictate' }
$Dll = Join-Path $AppRoot 'ptt-dictate.dll'
$StandaloneExe = Join-Path $AppRoot 'ptt-dictate-standalone.exe'
$Launcher = Join-Path $AppRoot 'ptt-launcher.vbs'
$Log = Join-Path $AppRoot 'ptt.log'
$TaskName = 'ptt-dictate'

function Find-DotNet {
    $Local = Join-Path $ProjectRoot '.tools\dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $Local) { return $Local }
    $CommandInfo = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($CommandInfo -and (& $CommandInfo.Source --list-sdks)) { return $CommandInfo.Source }
    throw 'A .NET 9 SDK is required. Run: .\setup.ps1 -BuildOnly'
}

function Find-DotNetHost {
    $System = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($System -and ((& $System.Source --list-runtimes) -match '^Microsoft\.WindowsDesktop\.App 9\.')) { return $System.Source }
    $Local = Join-Path $ProjectRoot '.tools\dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $Local) { return $Local }
    $Installed = Join-Path $AppRoot 'dotnet\dotnet.exe'
    if (Test-Path -LiteralPath $Installed) { return $Installed }
    throw 'A .NET 9 Windows Desktop runtime is required. Run: .\setup.ps1 -BuildOnly'
}

function Invoke-App([string[]]$AppArgs) {
    if (-not (Test-Path -LiteralPath $Dll)) {
        throw "ptt-dictate is not built. Run: .\ptt.ps1 build"
    }
    $DotNetHost = Find-DotNetHost
    & $DotNetHost $Dll @AppArgs
    if ($LASTEXITCODE -ne 0) { throw "ptt-dictate command failed with exit code $LASTEXITCODE." }
}

switch ($Command) {
    'build' {
        $DotNet = Find-DotNet
        $RuntimePublish = Join-Path $ProjectRoot 'artifacts\runtime'
        $StandalonePublish = Join-Path $ProjectRoot 'artifacts\publish'
        & $DotNet publish (Join-Path $ProjectRoot 'ptt-dictate.csproj') -c Release -r win-x64 --self-contained false -o $RuntimePublish
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        & $DotNet publish (Join-Path $ProjectRoot 'ptt-dictate.csproj') -c Release -r win-x64 --self-contained true -o $StandalonePublish /p:PublishSingleFile=true /p:IncludeNativeLibrariesForSelfExtract=true
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        if (Test-Path -LiteralPath $Dll) {
            try { Invoke-App @('--send', 'stop') | Out-Null; Start-Sleep -Milliseconds 800 } catch { }
        }
        New-Item -ItemType Directory -Force -Path $AppRoot | Out-Null
        Get-ChildItem -LiteralPath $RuntimePublish -File | Copy-Item -Destination $AppRoot -Force
        Copy-Item -LiteralPath (Join-Path $StandalonePublish 'ptt-dictate.exe') -Destination $StandaloneExe -Force
        Copy-Item -LiteralPath (Join-Path $ProjectRoot 'ptt-launcher.vbs') -Destination $Launcher -Force
        $Config = Join-Path $AppRoot 'config'
        if (-not (Test-Path -LiteralPath $Config)) {
            Copy-Item -LiteralPath (Join-Path $ProjectRoot 'config.example') -Destination $Config
        }
        Write-Host "Built $Dll (runtime-hosted) and $StandaloneExe"
        $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($Task) { Start-ScheduledTask -TaskName $TaskName }
    }
    'start' {
        if (-not (Test-Path -LiteralPath $Dll)) { & $PSCommandPath build }
        $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($Task) { Start-ScheduledTask -TaskName $TaskName }
        else {
            $DotNetHost = Find-DotNetHost
            Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList @("`"$Launcher`"", "`"$DotNetHost`"", "`"$Dll`"") -WorkingDirectory $AppRoot -WindowStyle Hidden
        }
        Start-Sleep -Milliseconds 500
        Invoke-App @('--send', 'status')
    }
    'stop' { Invoke-App @('--send', 'stop') }
    'restart' {
        try { Invoke-App @('--send', 'stop') | Out-Null } catch { }
        Start-Sleep -Milliseconds 700
        & $PSCommandPath start
    }
    'status' {
        if (-not (Test-Path -LiteralPath $Dll)) { Write-Host 'not built'; exit 1 }
        Invoke-App @('--send', 'status')
    }
    'log' {
        if (-not (Test-Path -LiteralPath $Log)) { New-Item -ItemType File -Force -Path $Log | Out-Null }
        Get-Content -LiteralPath $Log -Tail 80 -Wait
    }
    'miccheck' { Invoke-App @('--miccheck') }
    'devices' { Invoke-App @('--devices') }
    'tap' { Invoke-App @('--send', 'tap') }
    'test' { Invoke-App @('--self-test') }
    'install' { & (Join-Path $ProjectRoot 'install.ps1') }
    'uninstall' { & (Join-Path $ProjectRoot 'install.ps1') -Uninstall }
    'setup' { & (Join-Path $ProjectRoot 'setup.ps1') @RemainingArgs }
}
