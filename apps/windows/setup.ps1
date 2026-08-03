[CmdletBinding()]
param(
    [switch]$BuildOnly,
    [switch]$SkipModel,
    [switch]$InstallFfmpeg
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = $PSScriptRoot
$AppRoot = if ($env:PTT_DICTATE_HOME) { $env:PTT_DICTATE_HOME } else { Join-Path $env:LOCALAPPDATA 'ptt-dictate' }
$ModelRoot = Join-Path $AppRoot 'models'
$WhisperRoot = Join-Path $AppRoot 'whisper'
$ToolsRoot = Join-Path $ProjectRoot '.tools'
$DotNetRoot = Join-Path $ToolsRoot 'dotnet'
$DotNet = Join-Path $DotNetRoot 'dotnet.exe'

New-Item -ItemType Directory -Force -Path $AppRoot, $ModelRoot, $WhisperRoot, $ToolsRoot | Out-Null

$SystemDotNet = Get-Command dotnet -ErrorAction SilentlyContinue
$HasSdk = $false
if ($SystemDotNet) { $HasSdk = [bool](& $SystemDotNet.Source --list-sdks) }
if (-not $HasSdk -and -not (Test-Path -LiteralPath $DotNet)) {
    Write-Host 'Installing a private .NET 9 SDK under .tools (no administrator access required)...'
    $Installer = Join-Path $ToolsRoot 'dotnet-install.ps1'
    Invoke-WebRequest -UseBasicParsing 'https://dot.net/v1/dotnet-install.ps1' -OutFile $Installer
    & $Installer -Channel '9.0' -InstallDir $DotNetRoot -NoPath
}

if (-not $BuildOnly) {
    Write-Host 'Downloading the latest official whisper.cpp Windows x64 release...'
    $Release = Invoke-RestMethod -Headers @{ 'User-Agent' = 'ptt-dictate-setup' } 'https://api.github.com/repos/ggml-org/whisper.cpp/releases/latest'
    $Asset = $Release.assets | Where-Object name -eq 'whisper-bin-x64.zip' | Select-Object -First 1
    if (-not $Asset) { throw 'The latest whisper.cpp release has no whisper-bin-x64.zip asset.' }
    $Archive = Join-Path $ToolsRoot 'whisper-bin-x64.zip'
    Invoke-WebRequest -UseBasicParsing $Asset.browser_download_url -OutFile $Archive
    $Extracted = Join-Path $ToolsRoot 'whisper-extracted'
    if (Test-Path -LiteralPath $Extracted) { Remove-Item -LiteralPath $Extracted -Recurse -Force }
    Expand-Archive -LiteralPath $Archive -DestinationPath $Extracted -Force
    Get-ChildItem -LiteralPath $Extracted -File -Recurse | Copy-Item -Destination $WhisperRoot -Force

    if (-not $SkipModel) {
        $Models = @{
            'ggml-large-v3-turbo-q5_0.bin' = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true'
            'ggml-silero-v6.2.0.bin' = 'https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin?download=true'
        }
        foreach ($Entry in $Models.GetEnumerator()) {
            $Destination = Join-Path $ModelRoot $Entry.Key
            if (-not (Test-Path -LiteralPath $Destination)) {
                Write-Host "Downloading $($Entry.Key)..."
                Invoke-WebRequest -UseBasicParsing $Entry.Value -OutFile $Destination
            }
        }
    }

    if ($InstallFfmpeg -and -not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget is required for -InstallFfmpeg.' }
        winget install --id Gyan.FFmpeg.Essentials --exact --accept-package-agreements --accept-source-agreements
    }
}

$Config = Join-Path $AppRoot 'config'
if (-not (Test-Path -LiteralPath $Config)) {
    Copy-Item -LiteralPath (Join-Path $ProjectRoot 'config.example') -Destination $Config
}
else {
    $ConfigText = Get-Content -Raw -LiteralPath $Config
    $MigratedConfig = $ConfigText.Replace('ggml-silero-v5.1.2.bin', 'ggml-silero-v6.2.0.bin')
    if ($MigratedConfig -ne $ConfigText) {
        Set-Content -LiteralPath $Config -Value $MigratedConfig -Encoding utf8
        Write-Host 'Updated config from the retired Silero v5.1.2 model to v6.2.0.'
    }
}

# The download ships a LICENSE_KEY file next to this script for a purchased copy, so the
# user never has to find or type a key. If present, write it into the config.
$LicenseKeyValue = $null
$LicenseKeyFile = Get-ChildItem -Path $ProjectRoot -Filter 'LICENSE_KEY*' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if ($LicenseKeyFile) {
    $Candidate = (Get-Content -Raw -LiteralPath $LicenseKeyFile.FullName).Trim()
    if ($Candidate) {
        $LicenseKeyValue = $Candidate
        $ConfigText = Get-Content -Raw -LiteralPath $Config
        if ($ConfigText -match '(?m)^LICENSE_KEY=.*$') {
            $ConfigText = $ConfigText -replace '(?m)^LICENSE_KEY=.*$', "LICENSE_KEY=$LicenseKeyValue"
        }
        else {
            $ConfigText = $ConfigText.TrimEnd() + "`nLICENSE_KEY=$LicenseKeyValue`n"
        }
        Set-Content -LiteralPath $Config -Value $ConfigText -Encoding utf8
        Write-Host "Applied the license key from $($LicenseKeyFile.Name) to the config."
    }
}

& (Join-Path $ProjectRoot 'ptt.ps1') build
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE." }

& (Join-Path $ProjectRoot 'install.ps1')

$ConfigText = Get-Content -Raw -LiteralPath $Config
$HotkeyMatch = [regex]::Match($ConfigText, '(?m)^HOTKEY=(.+)$')
$HotkeyDisplay = if ($HotkeyMatch.Success) { $HotkeyMatch.Groups[1].Value.Trim() } else { 'RightCtrl' }
$LicenseKeyMatch = [regex]::Match($ConfigText, '(?m)^LICENSE_KEY=(.*)$')
$HasLicenseKey = $LicenseKeyMatch.Success -and $LicenseKeyMatch.Groups[1].Value.Trim().Length -gt 0

Write-Host ''
Write-Host '============================================================'
Write-Host ' Setup complete. ptt-dictate is installed and running.'
Write-Host '============================================================'
Write-Host ''
Write-Host 'What happens next:'
Write-Host "  1. ptt-dictate is already running in your system tray. Look for its icon near the clock."
Write-Host "  2. Click into any text box, browser, or document where you want text to appear."
Write-Host "  3. Tap $HotkeyDisplay once to start recording, then speak."
Write-Host "  4. Tap $HotkeyDisplay again to stop. Your words are transcribed locally and pasted automatically."
Write-Host "  5. Press Escape at any point while recording to cancel. Nothing will be transcribed or pasted."
Write-Host ''
Write-Host 'Give it a try now: click into any text box and tap the hotkey.'
Write-Host ''
Write-Host 'Useful commands, run from this folder:'
Write-Host '  .\ptt.ps1 devices      Lists microphones and shows which one is selected.'
Write-Host '  .\ptt.ps1 miccheck     Records a short test clip and prints the transcript.'
Write-Host '  .\ptt.ps1 log          Tails the daemon log.'
Write-Host '  .\ptt.ps1 uninstall    Removes the scheduled task that starts ptt-dictate at login.'
Write-Host ''
if (-not $HasLicenseKey) {
    Write-Host 'No license key is set. Recording will refuse to start until you activate your'
    Write-Host 'copy. Visit nesso.tech to get a license key, then add it to:'
    Write-Host "  $Config"
    Write-Host ''
}
