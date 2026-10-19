# Shared paths, dot-sourced by every script in this folder.
# AI_ROOT holds llama.cpp and the models (default C:\AI). If yours lives somewhere else, set it once:
#   [Environment]::SetEnvironmentVariable('AI_ROOT', 'D:\AI', 'User')
$AiRoot = if ($env:AI_ROOT) { $env:AI_ROOT } else { 'C:\AI' }
$W = Split-Path -Parent $PSScriptRoot       # this repo
$L = Join-Path $AiRoot 'llama.cpp'          # llama-server.exe, llama-bench.exe
$G = Join-Path $AiRoot 'models\gguf'        # GGUF files, same layout as `hf download --local-dir`
$ProgressPreference = 'SilentlyContinue'
