<#
  stop-ai.ps1 - stop every llama-server started from $AI_ROOT\llama.cpp and unload Ollama models.
  Default: the Ollama app is NOT closed (models are only unloaded).
  -All   : after unloading, close the Ollama app too (ollama app.exe + ollama.exe) -> ready for gaming.

  Examples:
    .\stop-ai.ps1
    .\stop-ai.ps1 -All          # everything off, including the Ollama tray app
    .\stop-ai.ps1 -KeepOllama   # llama-server only, Ollama models (e.g. embed-cpu) stay loaded
#>
[CmdletBinding()]
param([switch]$KeepOllama, [switch]$All)

. (Join-Path $PSScriptRoot 'env.ps1')
. (Join-Path $PSScriptRoot 'lib-ollama.ps1')   # Stop-OllamaApp

if ($All -and $KeepOllama) {
    Write-Host "Note: -All ignores -KeepOllama." -ForegroundColor Yellow
    $KeepOllama = $false
}

$llamaRoot = $L.TrimEnd('\') + '\'

# --- llama-server ---
Write-Host "== llama-server ==" -ForegroundColor Green
$procs = @(Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'")
if ($procs.Count -eq 0) { Write-Host "No llama-server running." }
foreach ($p in $procs) {
    $cl = [string]$p.CommandLine
    $port = if ($cl -match '--port\s+(\d+)') { $Matches[1] } else { '8080?' }
    $model = if ($cl -match '-m\s+("?)([^"\s]+)\1') { Split-Path $Matches[2] -Leaf } else { '?' }
    $path = [string]$p.ExecutablePath
    if (-not $path -or -not $path.StartsWith($llamaRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "Skipped: PID $($p.ProcessId) is not from $L ($path)" -ForegroundColor Yellow
        continue
    }
    try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
        Write-Host "Stopped: llama-server PID $($p.ProcessId) port $port model $model"
    } catch {
        Write-Host "FAILED to stop PID $($p.ProcessId): $($_.Exception.Message)" -ForegroundColor Red
    }
}

# --- Ollama ---
Write-Host "== Ollama ==" -ForegroundColor Green
if ($KeepOllama) {
    Write-Host "Skipped (-KeepOllama)."
} else {
    $ollama = (Get-Command ollama.exe -ErrorAction SilentlyContinue).Source
    if (-not $ollama) { $ollama = $OllamaExe }
    $ps = $null
    try { $ps = Invoke-RestMethod "$OllamaUrl/api/ps" -UseBasicParsing -TimeoutSec 5 } catch {}
    if ($null -eq $ps) {
        Write-Host "Ollama does not respond on :11434 (nothing to unload)."
    } elseif (@($ps.models).Count -eq 0) {
        Write-Host "No Ollama model loaded."
    } else {
        foreach ($m in @($ps.models)) {
            if (Test-Path -LiteralPath $ollama) {
                & $ollama stop $m.name 2>&1 | Out-Null
            } else {
                # fallback: unload through the API
                $body = @{ model = $m.name; keep_alive = 0 } | ConvertTo-Json -Compress
                try { $null = Invoke-RestMethod "$OllamaUrl/api/generate" -Method Post -Body $body -ContentType 'application/json' -UseBasicParsing -TimeoutSec 30 } catch {}
            }
            Write-Host "Unloaded: $($m.name)"
        }
    }
}

if ($All) {
    Write-Host "== Ollama app (-All) ==" -ForegroundColor Green
    Stop-OllamaApp
}

# --- VRAM afterwards (wait up to ~6 s for the driver to release it) ---
$used = $null; $total = $null
for ($i = 0; $i -lt 6; $i++) {
    Start-Sleep -Seconds 1
    $q = & nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>$null
    if (-not $q) { break }
    $parts = ([string]@($q)[0]) -split ',\s*'
    $used = [int]$parts[0]; $total = [int]$parts[1]
    if ($used -eq 0) { break }
}
if ($null -ne $used) { Write-Host "VRAM: $used MiB (total $total MiB)" } else { Write-Host "VRAM: ? (nvidia-smi not available)" }
