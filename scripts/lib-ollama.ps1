<#
  lib-ollama.ps1 - shared Ollama helpers (dot-source: . (Join-Path $PSScriptRoot 'lib-ollama.ps1')).
  Used by start-fast.ps1 -Ollama, pi-local.ps1 -Fast, stop-ai.ps1 -All and status-ai.ps1.

  Ollama does NOT autostart (the laptop is also for gaming). Start-OllamaOnDemand starts it only when
  needed, through Explorer, so the app inherits the user environment (OLLAMA_MODELS, CONTEXT_LENGTH, ...).
  Calling Start-Process on "ollama app.exe" directly from a shell starts the tray app WITHOUT its server.
#>

$OllamaUrl = 'http://127.0.0.1:11434'
$OllamaDir = Join-Path $env:LOCALAPPDATA 'Programs\Ollama'
$OllamaApp = Join-Path $OllamaDir 'ollama app.exe'
$OllamaExe = Join-Path $OllamaDir 'ollama.exe'

function Test-OllamaApi([int]$TimeoutSec = 2) {
    try {
        $null = Invoke-RestMethod "$OllamaUrl/api/version" -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $true
    } catch { return $false }
}

# Every process started from the Ollama install folder (ollama app.exe, ollama.exe, bundled runners).
function Get-OllamaProcess {
    $root = $OllamaDir.TrimEnd('\') + '\'
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and ([string]$_.ExecutablePath).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
    })
}

function Wait-OllamaApi([int]$TimeoutSec = 30) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (Test-OllamaApi) { return $true }
        Start-Sleep -Milliseconds 700
    }
    return $false
}

# Make sure the Ollama API answers; if it doesn't, start the app through Explorer and wait (max $TimeoutSec).
# Returns $true when the API is ready.
function Start-OllamaOnDemand([int]$TimeoutSec = 30, [switch]$DryRun) {
    if (Test-OllamaApi) { return $true }
    if (-not (Test-Path -LiteralPath $OllamaApp)) {
        Write-Host "FAILED: Ollama app not found: $OllamaApp" -ForegroundColor Red
        return $false
    }
    if ($DryRun) {
        Write-Host "Ollama is not running -> would start it with: explorer.exe `"$OllamaApp`"" -ForegroundColor Cyan
        return $true
    }
    $running = @(Get-OllamaProcess | Where-Object { $_.Name -eq 'ollama app.exe' })
    if ($running.Count -gt 0) {
        # The app is there (maybe still starting): give it a moment first.
        Write-Host "Ollama app is running but the API doesn't answer yet; waiting..." -ForegroundColor Yellow
        if (Wait-OllamaApi 10) { return $true }
        # App without a server (e.g. launched straight from a shell) -> close it and restart through Explorer.
        Write-Host "API still down -> restarting the Ollama app." -ForegroundColor Yellow
        foreach ($p in (Get-OllamaProcess | Sort-Object { if ($_.Name -eq 'ollama app.exe') { 0 } else { 1 } })) {
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {}
        }
        Start-Sleep -Seconds 1
    }
    Write-Host "Ollama is not running -> starting it through Explorer (max $TimeoutSec s)..."
    try {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $OllamaApp + '"') -ErrorAction Stop
    } catch {
        Write-Host "FAILED to start Ollama: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    if (Wait-OllamaApi $TimeoutSec) {
        Write-Host "Ollama ready ($OllamaUrl)." -ForegroundColor Green
        return $true
    }
    Write-Host "FAILED: Ollama did not answer on $OllamaUrl after $TimeoutSec s." -ForegroundColor Red
    return $false
}

# Close the Ollama app completely (tray app first so it can't restart the server, then the rest).
function Stop-OllamaApp {
    $procs = @(Get-OllamaProcess | Sort-Object { if ($_.Name -eq 'ollama app.exe') { 0 } else { 1 } })
    if ($procs.Count -eq 0) { Write-Host "Ollama app is not running."; return }
    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            Write-Host "Stopped: $($p.Name) PID $($p.ProcessId)"
        } catch {
            if (Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue) {
                Write-Host "FAILED to stop $($p.Name) PID $($p.ProcessId): $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}
