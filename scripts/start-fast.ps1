<#
  start-fast.ps1 - fast mode: FIM on the CPU (0.5B on :8012, no VRAM) + the 9B model.
  Default : 9B via llama-server on :8080 (start-coder.ps1 -Preset qwen9b), in a new window.
  -Ollama : 9B via Ollama (qwen3.5-9b:iq4xs), only warmed up (loaded); :8080 is not used.
            The Ollama app is started automatically (through Explorer, lib-ollama.ps1) if it isn't running.
  Extra arguments go to start-coder.ps1 (default mode only).

  Examples:
    .\start-fast.ps1
    .\start-fast.ps1 -Ctx 16384
    .\start-fast.ps1 -Ollama
    .\start-fast.ps1 -DryRun
#>
param([switch]$Ollama, [switch]$DryRun)   # remaining arguments are in $args -> start-coder.ps1

. (Join-Path $PSScriptRoot 'env.ps1')
. (Join-Path $PSScriptRoot 'lib-ollama.ps1')   # $OllamaUrl, Start-OllamaOnDemand

$OllamaModel = 'qwen3.5-9b:iq4xs'

$psExe = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }

function ConvertTo-PsArgs([object[]]$Items) {
    ($Items | ForEach-Object {
        $s = [string]$_
        if ($s -match '^-[A-Za-z]\w*:?$') { $s } else { "'" + ($s -replace "'", "''") + "'" }
    }) -join ' '
}

function Start-AiWindow([string]$Script, [object[]]$ArgList) {
    $cmd = "& '" + ($Script -replace "'", "''") + "' " + (ConvertTo-PsArgs $ArgList)
    Write-Host "New window: $cmd" -ForegroundColor Cyan
    if ($DryRun) { return }
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $null = Start-Process -FilePath $psExe -WorkingDirectory $W -PassThru `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-EncodedCommand', $enc)
}

function Test-Health([int]$Port) {
    try {
        $r = Invoke-WebRequest "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 2
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Wait-Health([int]$Port, [int]$TimeoutSec = 60) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (Test-Health $Port) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

Write-Host "== Fast mode ==" -ForegroundColor Green
# 1) FIM on the CPU
if (Test-Health 8012) {
    Write-Host "FIM :8012 already running, skipped."
} else {
    Start-AiWindow (Join-Path $PSScriptRoot 'start-fim.ps1') @('-Cpu')
    if (-not $DryRun) {
        Write-Host "Waiting for FIM :8012 (max 60 s)..."
        if (Wait-Health 8012 60) { Write-Host "FIM ready." -ForegroundColor Green }
        else { Write-Host "WARNING: FIM not healthy after 60 s (check the FIM window). Continuing." -ForegroundColor Yellow }
    }
}

# 2) The 9B model
if (-not $Ollama) {
    Start-AiWindow (Join-Path $PSScriptRoot 'start-coder.ps1') (@('-Preset', 'qwen9b') + $args)
    if (-not $DryRun) { Write-Host "The 9B model is loading in a new window (:8080). Check with: .\status-ai.ps1" }
    return
}

Write-Host "Ollama warm-up: $OllamaModel"
if ($DryRun) { $null = Start-OllamaOnDemand -DryRun; return }
if ($args.Count -gt 0) { Write-Host "Note: extra arguments ($($args -join ' ')) are ignored with -Ollama." -ForegroundColor Yellow }
if (Test-Health 8080) {
    Write-Host "WARNING: llama-server :8080 is still running and holding VRAM; the Ollama model (num_gpu 99) may fail to load (OOM)." -ForegroundColor Yellow
}
if (-not (Start-OllamaOnDemand 30)) { exit 1 }
try {
    $tags = Invoke-RestMethod "$OllamaUrl/api/tags" -UseBasicParsing -TimeoutSec 5
} catch {
    Write-Host "FAILED: Ollama does not respond on $OllamaUrl ($($_.Exception.Message))." -ForegroundColor Red
    exit 1
}
$exists = @($tags.models | Where-Object { $_.name -eq $OllamaModel -or $_.model -eq $OllamaModel }).Count -gt 0
if (-not $exists) {
    Write-Host "NOTE: model '$OllamaModel' is not in Ollama yet (create it from configs\ollama\Modelfile.qwen35-9b). Warm-up skipped." -ForegroundColor Yellow
    exit 0
}
# empty prompt = load the model only; keep_alive 30m so it isn't unloaded right away
$body = @{ model = $OllamaModel; prompt = ''; keep_alive = '30m' } | ConvertTo-Json -Compress
try {
    $null = Invoke-RestMethod "$OllamaUrl/api/generate" -Method Post -Body $body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 300
    Write-Host "Ollama: $OllamaModel loaded (keep_alive 30m)." -ForegroundColor Green
} catch {
    Write-Host "FAILED Ollama warm-up: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
