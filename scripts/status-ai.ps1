<#
  status-ai.ps1 - state of the local AI stack: llama-server :8080/:8012, Ollama, VRAM, RAM, processes.
  Example: .\status-ai.ps1
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'env.ps1')
. (Join-Path $PSScriptRoot 'lib-ollama.ps1')   # Get-OllamaProcess, Test-OllamaApi

function Get-ServerStatus([int]$Port, [string]$Name) {
    $state = 'off'
    try {
        $r = Invoke-WebRequest "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 3
        if ($r.StatusCode -eq 200) { $state = 'OK' }
    } catch {
        $resp = $_.Exception.Response
        if ($resp -and [int]$resp.StatusCode -eq 503) { $state = 'loading' }
    }
    $models = ''
    if ($state -eq 'OK') {
        try {
            $m = Invoke-RestMethod "http://127.0.0.1:$Port/v1/models" -UseBasicParsing -TimeoutSec 3
            $models = (@($m.data) | ForEach-Object { $_.id }) -join ', '
        } catch {}
        if (-not $models) { $models = '(empty - llama-server without -m / router mode?)' }
    }
    $color = switch ($state) { 'OK' { 'Green' } 'loading' { 'Yellow' } default { 'DarkGray' } }
    $line = ':{0,-5} {1,-8} {2,-8}' -f $Port, $Name, $state
    if ($models) { $line += " model: $models" }
    Write-Host $line -ForegroundColor $color
}

Write-Host "== llama-server ==" -ForegroundColor Green
Get-ServerStatus 8080 'coder'
Get-ServerStatus 8012 'fim'

Write-Host "== llama-server processes ==" -ForegroundColor Green
$procs = @(Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'")
if ($procs.Count -eq 0) { Write-Host "(none)" }
foreach ($p in $procs) {
    $ws = 0
    try { $ws = [math]::Round((Get-Process -Id $p.ProcessId -ErrorAction Stop).WorkingSet64 / 1MB) } catch {}
    Write-Host ("PID {0}  RAM(WS) {1} MB" -f $p.ProcessId, $ws)
    Write-Host ("  {0}" -f $p.CommandLine) -ForegroundColor DarkCyan
}

Write-Host "== Ollama ==" -ForegroundColor Green
$oprocs = @(Get-OllamaProcess)
if ($oprocs.Count -eq 0) {
    Write-Host "Ollama app: not running" -ForegroundColor DarkGray
} else {
    $list = ($oprocs | ForEach-Object { "$($_.Name) PID $($_.ProcessId)" }) -join ', '
    Write-Host "Ollama app: RUNNING ($list)  -> close it with stop-ai.ps1 -All" -ForegroundColor Yellow
}
$ollama = (Get-Command ollama.exe -ErrorAction SilentlyContinue).Source
if (-not $ollama) { $ollama = $OllamaExe }
$up = Test-OllamaApi 3
if (-not $up) {
    Write-Host "Ollama does not respond on :11434."
} elseif (Test-Path -LiteralPath $ollama) {
    & $ollama ps 2>&1 | ForEach-Object { Write-Host "$_" }
} else {
    Write-Host "Ollama is up, but ollama.exe was not found for 'ollama ps'."
}

Write-Host "== GPU ==" -ForegroundColor Green
$vram = & nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>$null
if ($vram) { Write-Host "VRAM (used, total): $vram" } else { Write-Host "nvidia-smi not available." }

Write-Host "== RAM ==" -ForegroundColor Green
$os = Get-CimInstance Win32_OperatingSystem
$free = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
$total = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
Write-Host "RAM free: $free GB of $total GB"
