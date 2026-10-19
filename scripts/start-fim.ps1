<#
  start-fim.ps1 - fill-in-the-middle autocomplete for llama-vscode, via llama-server on port 8012.
  Uses local GGUF files (not -hf), so nothing is downloaded again.

  Examples:
    .\start-fim.ps1          # GPU: Qwen2.5-Coder-1.5B Q8_0
    .\start-fim.ps1 -Cpu     # CPU: Qwen2.5-Coder-0.5B Q8_0 (no VRAM)
    .\start-fim.ps1 -DryRun  # print the command only
#>
[CmdletBinding()]
param(
    [switch]$Cpu,
    [int]$Port = 8012,
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot 'env.ps1')
. (Join-Path $PSScriptRoot 'lib-launch.ps1')

if ($Cpu) {
    $Model = [IO.Path]::Combine($G, 'ggml-org\Qwen2.5-Coder-0.5B-Q8_0-GGUF\qwen2.5-coder-0.5b-q8_0.gguf')
    # -dev none: don't touch the GPU at all, the VRAM belongs to the main model
    $a = @('-m', $Model, '-ngl', '0', '-dev', 'none', '-c', '4096', '-ub', '1024', '-b', '1024',
           '--cache-reuse', '256', '-t', '4')
    $mode = 'CPU 0.5B'
} else {
    $Model = [IO.Path]::Combine($G, 'ggml-org\Qwen2.5-Coder-1.5B-Q8_0-GGUF\qwen2.5-coder-1.5b-q8_0.gguf')
    $a = @('-m', $Model, '-ngl', '99', '-c', '8192', '-ub', '1024', '-b', '1024', '--cache-reuse', '256')
    $mode = 'GPU 1.5B'
}
$a += @('--host', '127.0.0.1', '--port', "$Port")

# --- Preflight ---
$exe = [IO.Path]::Combine($L, 'llama-server.exe')
Assert-LaunchReady -Exe $exe -Model $Model -ModelHint '(still downloading? the hf download commands are in the README)' -Port $Port -DryRun:$DryRun

Write-Host "FIM    : $mode | $(Split-Path $Model -Leaf) | port $Port"
Write-Host "Command:"
Write-Host "  & '$exe' $($a -join ' ')" -ForegroundColor Cyan
if ($DryRun) { exit 0 }

try { $Host.UI.RawUI.WindowTitle = "local-ai FIM :$Port ($mode)" } catch {}
& $exe @a
exit $LASTEXITCODE
