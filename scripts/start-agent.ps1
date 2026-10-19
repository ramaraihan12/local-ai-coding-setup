<#
  start-agent.ps1 - agent mode: FIM (:8012) + main model (:8080), each in its own new window.
  Default : FIM on the CPU (start-fim.ps1 -Cpu, 0.5B, no VRAM) + coder with preset gemma (ncmoe 24).
  -FimGpu : FIM on the GPU (1.5B, ~2 GB VRAM, snappier autocomplete) + coder -FimGpu. Only qwen36 is measured
            (ncmoe 35, use -Preset qwen36); gemma stays at ncmoe 24 with a warning (not measured, may OOM).
  Order: FIM first, wait until /health is OK (max ~60 s), then the main model, so they don't fight over VRAM
  while loading.
  Any extra arguments go to start-coder.ps1 untouched (an explicit -Ncmoe still wins).

  Examples:
    .\start-agent.ps1
    .\start-agent.ps1 -FimGpu
    .\start-agent.ps1 -Preset qwen36
    .\start-agent.ps1 -Ncmoe 32 -Ngram
    .\start-agent.ps1 -DryRun     # print the window commands only, run nothing
#>
param([switch]$FimGpu, [switch]$DryRun)   # remaining arguments are in $args -> start-coder.ps1

. (Join-Path $PSScriptRoot 'env.ps1')

# Same PowerShell edition as the caller (pwsh 7 or Windows PowerShell 5.1)
$psExe = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }

function ConvertTo-PsArgs([object[]]$Items) {
    # parameter names (-Preset, -Ngram) as they are; values become '...' literals
    (@($Items) | Where-Object { $null -ne $_ } | ForEach-Object {
        $s = [string]$_
        if ($s -match '^-[A-Za-z]\w*:?$') { $s } else { "'" + ($s -replace "'", "''") + "'" }
    }) -join ' '
}

function Start-AiWindow([string]$Script, [object[]]$ArgList) {
    $cmd = "& '" + ($Script -replace "'", "''") + "' " + (ConvertTo-PsArgs $ArgList)
    Write-Host "New window: $cmd" -ForegroundColor Cyan
    if ($DryRun) { return }
    # -EncodedCommand avoids quoting problems (JSON in -Kwargs and so on)
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

# (don't write $x = if (...) { @() }: an empty array becomes $null)
$fimArgs   = @('-Cpu')
$coderArgs = @($args)
$fimTxt    = 'CPU 0.5B'
if ($FimGpu) {
    $fimArgs   = @()
    $coderArgs = @('-FimGpu') + @($args)
    $fimTxt    = 'GPU 1.5B'
}

Write-Host "== Agent mode (FIM $fimTxt) ==" -ForegroundColor Green
# 1) FIM
if (Test-Health 8012) {
    Write-Host "FIM :8012 already running, skipped (make sure it is the right kind: $fimTxt; see status-ai.ps1)." -ForegroundColor Yellow
} else {
    Start-AiWindow (Join-Path $PSScriptRoot 'start-fim.ps1') $fimArgs
    if (-not $DryRun) {
        Write-Host "Waiting for FIM :8012 (max 60 s)..."
        if (Wait-Health 8012 60) { Write-Host "FIM ready." -ForegroundColor Green }
        else { Write-Host "WARNING: FIM not healthy after 60 s (check the FIM window). Starting the main model anyway." -ForegroundColor Yellow }
    }
}

# 2) Main model (extra arguments passed through)
Start-AiWindow (Join-Path $PSScriptRoot 'start-coder.ps1') $coderArgs
if (-not $DryRun) {
    Write-Host "The main model is loading in a new window. Check with: .\status-ai.ps1"
}
