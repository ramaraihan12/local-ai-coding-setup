<#
  start-coder.ps1 - main (agent) model via llama-server, default port 8080, model alias "local".

  Examples:
    .\start-coder.ps1                          # default gemma: gemma-4-26B-A4B, ncmoe 24, reasoning off
    .\start-coder.ps1 -Preset qwen36           # Qwen3.6-35B-A3B UD-IQ2_M, ncmoe 28, ctx 65536, -lm none (optional download)
    .\start-coder.ps1 -Preset qwen36 -FimGpu   # same, but ncmoe 35 (the 1.5B FIM takes ~2 GB of VRAM)
    .\start-coder.ps1 -Preset gptoss           # gpt-oss-20b, ncmoe 17 (not in the default download list)
    .\start-coder.ps1 -Preset qwen9b -Ctx 8192 # Qwen3.5-9B fully on the GPU
    .\start-coder.ps1 -Ncmoe -1                # send no -ngl/-ncmoe and let --fit decide (leaves very little VRAM)
    .\start-coder.ps1 -Ncmoe 30 -Ngram         # + ngram-simple speculative decoding
    .\start-coder.ps1 -Preset qwen9b -Reasoning off   # turn thinking off (Qwen thinks by default)
    .\start-coder.ps1 -CacheRam 2048 -LoadMode auto   # old behaviour (mmap, 2 GB prompt cache)
    .\start-coder.ps1 -DryRun                  # print the command, start nothing

  Explicit parameters always beat preset values.
  The ncmoe values come from the benchmark in docs\benchmarks.md: with FIM on the CPU, qwen36 28 / gptoss 17 /
  gemma 24 (one step lower runs out of memory). -FimGpu only moves qwen36 to 35; gptoss and gemma next to the
  GPU FIM are not measured yet (they probably need a higher -Ncmoe).
#>
[CmdletBinding()]
param(
    [string]$Model,
    [ValidateSet('qwen36', 'gptoss', 'gemma', 'qwen9b')]
    [string]$Preset,
    [int]$Ncmoe = 28,          # -1 = automatic (--fit); the real default comes from the preset, see $presetVals
    [int]$Ctx = 65536,
    [string]$Alias = 'local',
    [string]$Kwargs,           # JSON for --chat-template-kwargs
    [ValidateSet('on', 'off', 'auto')]
    [string]$Reasoning,        # --reasoning (replaces the deprecated enable_thinking kwarg)
    [int]$Threads = 12,        # measured best for generation (8: -9%, 16: -6%)
    [switch]$FimGpu,           # FIM runs on the GPU (start-fim.ps1 without -Cpu) -> qwen36 ncmoe 35; gemma/gptoss unchanged (not measured)
    [int]$CacheRam = 512,      # -cram (MiB) cap for the prompt cache in RAM; 0 = off (512 was as fast as 2048 in my tests)
    [ValidateSet('auto', 'none', 'mmap', 'mlock', 'mmap+mlock', 'dio')]
    [string]$LoadMode,         # -lm; default per preset (qwen36: none); 'auto' = not sent (llama.cpp uses mmap)
    [switch]$Ngram,
    [int]$Port = 8080,
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot 'env.ps1')

$modelPaths = @{
    qwen36 = [IO.Path]::Combine($G, 'unsloth\Qwen3.6-35B-A3B-GGUF\Qwen3.6-35B-A3B-UD-IQ2_M.gguf')
    gptoss = [IO.Path]::Combine($G, 'ggml-org\gpt-oss-20b-GGUF\gpt-oss-20b-MXFP4.gguf')
    gemma  = [IO.Path]::Combine($G, 'unsloth\gemma-4-26B-A4B-it-GGUF\gemma-4-26B-A4B-it-UD-IQ3_S.gguf')
    qwen9b = [IO.Path]::Combine($G, 'unsloth\Qwen3.5-9B-GGUF\Qwen3.5-9B-IQ4_XS.gguf')
}
# Per-preset defaults (ctx 65536, KV q8_0, FIM on the CPU).
# NcmoeFimGpu = value used with -FimGpu (only qwen36 is measured; the others repeat the CPU-FIM value).
# LoadMode: qwen36 'none' (with Chrome open: cold 8K prompt 2x faster and ~2.4 GB of RAM left free instead of
#           0.1-0.2 GB with mmap, same generation speed, but ~7 GB more commit charge). Others not measured -> auto.
# llama.cpp b11429: the {"enable_thinking":false} kwarg still works but is deprecated -> use --reasoning off.
#                   The reasoning_effort kwarg is not deprecated.
$presetVals = @{
    qwen36 = @{ Ncmoe = 28; NcmoeFimGpu = 35; Ctx = 65536; Kwargs = '';                            Reasoning = '';    LoadMode = 'none' }
    gptoss = @{ Ncmoe = 17; NcmoeFimGpu = 17; Ctx = 65536; Kwargs = '{"reasoning_effort":"high"}'; Reasoning = '';    LoadMode = 'auto' }
    gemma  = @{ Ncmoe = 24; NcmoeFimGpu = 24; Ctx = 65536; Kwargs = '';                            Reasoning = 'off'; LoadMode = 'auto' }
    qwen9b = @{ Ncmoe = 0;  NcmoeFimGpu = 0;  Ctx = 32768; Kwargs = '';                            Reasoning = '';    LoadMode = 'auto' }
}

# gemma won the A/B test on real coding tasks (docs\ab-test.md), so it is the default.
$p = if ($Preset) { $Preset } else { 'gemma' }
# Presets whose GGUF is not in the normal download list (the script still knows them)
$optionalPresets = @{
    qwen36 = 'is an optional download (kept for comparison). Download it (11.5 GB) with:' +
             "`n       hf download unsloth/Qwen3.6-35B-A3B-GGUF --include `"Qwen3.6-35B-A3B-UD-IQ2_M.gguf`" --local-dir `"$G\unsloth\Qwen3.6-35B-A3B-GGUF`""
    gptoss ='is not in the default download list (it went 0/4 in the A/B test). Download it (12.1 GB) with:' +
             "`n       hf download ggml-org/gpt-oss-20b-GGUF --include `"gpt-oss-20b-MXFP4.gguf`" --local-dir `"$G\ggml-org\gpt-oss-20b-GGUF`""
}
if (-not $PSBoundParameters.ContainsKey('Model'))     { $Model     = $modelPaths[$p] }
if (-not $PSBoundParameters.ContainsKey('Ncmoe')) {
    $Ncmoe = if ($FimGpu) { $presetVals[$p].NcmoeFimGpu } else { $presetVals[$p].Ncmoe }
    if ($FimGpu -and ($p -eq 'gptoss' -or $p -eq 'gemma')) {
        Write-Host "WARNING: -FimGpu with preset $p is not measured; ncmoe $Ncmoe may run out of memory next to the GPU FIM. Consider a higher -Ncmoe." -ForegroundColor Yellow
    }
}
if (-not $PSBoundParameters.ContainsKey('Ctx'))       { $Ctx       = $presetVals[$p].Ctx }
if (-not $PSBoundParameters.ContainsKey('Kwargs'))    { $Kwargs    = $presetVals[$p].Kwargs }
# ValidateSet stays attached to the variable, so never assign it an empty string
if (-not $PSBoundParameters.ContainsKey('Reasoning') -and $presetVals[$p].Reasoning) { $Reasoning = $presetVals[$p].Reasoning }
if (-not $PSBoundParameters.ContainsKey('LoadMode')) {
    # custom -Model: keep the llama.cpp default
    $LoadMode = if ($PSBoundParameters.ContainsKey('Model')) { 'auto' } else { $presetVals[$p].LoadMode }
}

function Stop-WithError([string]$Msg) {
    Write-Host "FAILED: $Msg" -ForegroundColor Red
    exit 1
}

# --- Preflight ---
$exe = [IO.Path]::Combine($L, 'llama-server.exe')
if (-not (Test-Path -LiteralPath $exe)) { Stop-WithError "llama-server not found: $exe" }
if (-not (Test-Path -LiteralPath $Model)) {
    if (-not $PSBoundParameters.ContainsKey('Model') -and $optionalPresets.ContainsKey($p)) {
        Stop-WithError "model file for preset $p not found: $Model`n       Preset $p $($optionalPresets[$p])"
    }
    Stop-WithError "model file missing: $Model`n       (still downloading? the hf download commands are in the README)"
}
$busy = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
    Where-Object { $_.Port -eq $Port }
if ($busy) {
    $owner = ''
    try {
        $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -First 1
        $owner = " by $((Get-Process -Id $c.OwningProcess -ErrorAction Stop).ProcessName) (PID $($c.OwningProcess))"
    } catch {}
    Stop-WithError "port $Port is already in use$owner. Run stop-ai.ps1 first or pick another -Port."
}
if ($Kwargs) {
    try { $null = $Kwargs | ConvertFrom-Json -ErrorAction Stop }
    catch { Stop-WithError "-Kwargs is not valid JSON: $Kwargs" }
}

# --- Build the argument list ---
$a = @('-m', $Model)
if ($Ncmoe -ge 0) {
    $a += @('-ngl', '99')
    if ($Ncmoe -gt 0) { $a += @('-ncmoe', "$Ncmoe") }
}
$a += @('-c', "$Ctx", '-fa', 'on', '-ctk', 'q8_0', '-ctv', 'q8_0', '-np', '1', '-cram', "$CacheRam",
        '-t', "$Threads", '-b', '2048', '-ub', '512', '--no-mmproj',
        '--host', '127.0.0.1', '--port', "$Port", '--alias', $Alias)
if ($LoadMode -ne 'auto') { $a += @('-lm', $LoadMode) }
if ($Ngram) { $a += @('--spec-type', 'ngram-simple') }
if ($Reasoning) { $a += @('--reasoning', $Reasoning) }
if ($Kwargs) {
    $k = $Kwargs
    # PowerShell < 7.3 drops the quotes when calling a native exe, so escape them by hand
    if ($PSVersionTable.PSVersion -lt [version]'7.3') { $k = $k -replace '"', '\"' }
    $a += @('--chat-template-kwargs', $k)
}

$label = if ($PSBoundParameters.ContainsKey('Model')) { 'custom' } else { $p }
$ncTxt = if ($Ncmoe -lt 0) { 'auto (--fit)' } else { "$Ncmoe" }
$rTxt = if ($Reasoning) { $Reasoning } else { 'default' }
$fimTxt = if ($FimGpu) { 'GPU' } else { 'CPU' }
Write-Host "Coder  : $label | $(Split-Path $Model -Leaf) | ncmoe $ncTxt (FIM $fimTxt) | ctx $Ctx | t $Threads | cram $CacheRam | lm $LoadMode | reasoning $rTxt | port $Port | alias $Alias"
$shown = ($a | ForEach-Object { if ($_ -match '[\s"]') { "'$_'" } else { $_ } }) -join ' '
Write-Host "Command:"
Write-Host "  & '$exe' $shown" -ForegroundColor Cyan
if ($DryRun) { exit 0 }

try { $Host.UI.RawUI.WindowTitle = "local-ai coder :$Port ($label)" } catch {}
& $exe @a
exit $LASTEXITCODE
