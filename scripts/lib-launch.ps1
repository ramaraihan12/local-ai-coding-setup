<#
  lib-launch.ps1 - helpers shared by the start-*.ps1 scripts. Dot-source it after env.ps1:
    . (Join-Path $PSScriptRoot 'lib-launch.ps1')
#>

function Stop-WithError([string]$Msg) {
    Write-Host "FAILED: $Msg" -ForegroundColor Red
    exit 1
}

# Checks before starting llama-server: the exe, the model file and a free port. A dry run only warns, so the
# command still gets printed on a machine without llama.cpp or the models (CI, a fresh clone).
function Assert-LaunchReady {
    param([string]$Exe, [string]$Model, [string]$ModelHint, [int]$Port, [switch]$DryRun)
    $problems = @()
    if (-not (Test-Path -LiteralPath $Exe)) { $problems += "llama-server not found: $Exe" }
    if (-not (Test-Path -LiteralPath $Model)) { $problems += "model file missing: $Model`n       $ModelHint" }
    $busy = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
        Where-Object { $_.Port -eq $Port }
    if ($busy) {
        $owner = ''
        try {
            $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -First 1
            $owner = " by $((Get-Process -Id $c.OwningProcess -ErrorAction Stop).ProcessName) (PID $($c.OwningProcess))"
        } catch {}
        $problems += "port $Port is already in use$owner. Run stop-ai.ps1 first or pick another -Port."
    }
    foreach ($p in $problems) {
        if ($DryRun) { Write-Host "WARNING: $p" -ForegroundColor Yellow } else { Stop-WithError $p }
    }
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

# Parameter names (-Preset, -Ngram) stay as they are; values become '...' literals.
function ConvertTo-PsArgs([object[]]$Items) {
    (@($Items) | Where-Object { $null -ne $_ } | ForEach-Object {
        $s = [string]$_
        if ($s -match '^-[A-Za-z]\w*:?$') { $s } else { "'" + ($s -replace "'", "''") + "'" }
    }) -join ' '
}

# Run a script from this folder in a new window, with the same PowerShell edition as the caller.
function Start-AiWindow([string]$Script, [object[]]$ArgList, [switch]$DryRun) {
    $cmd = "& '" + ($Script -replace "'", "''") + "' " + (ConvertTo-PsArgs $ArgList)
    Write-Host "New window: $cmd" -ForegroundColor Cyan
    if ($DryRun) { return }
    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
    # -EncodedCommand avoids quoting problems (JSON in -Kwargs and so on)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $null = Start-Process -FilePath $psExe -WorkingDirectory $W -PassThru `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-EncodedCommand', $enc)
}
