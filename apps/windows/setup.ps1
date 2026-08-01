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

& (Join-Path $ProjectRoot 'ptt.ps1') build
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE." }
Write-Host ''
Write-Host 'Setup complete. Next:'
Write-Host '  .\ptt.ps1 devices'
Write-Host '  .\ptt.ps1 miccheck'
Write-Host '  .\ptt.ps1 install'
