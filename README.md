# local-ai-coding-setup

[![ci](https://github.com/ramaraihan12/local-ai-coding-setup/actions/workflows/ci.yml/badge.svg)](https://github.com/ramaraihan12/local-ai-coding-setup/actions/workflows/ci.yml)

The free, fully local AI coding setup I run every day on my ASUS TUF A15 (FA506QM): Ryzen 9 5900HX, RTX 3060 Laptop
6 GB, 16 GB RAM, Windows 11. A coding agent in the terminal plus autocomplete in VS Code, with no subscription and no
cloud model. This is the cleaned-up public version: scripts, configs and measurements. The models (about 28 GiB) live
outside the repo, in `C:\AI` by default.

## How it works

- `llama-server` from llama.cpp runs the main model on `:8080` (OpenAI-compatible API, model alias `local`).
- A second `llama-server` on `:8012` serves fill-in-the-middle autocomplete to the llama-vscode extension. It runs
  on the CPU by default, so the GPU stays with the main model.
- Ollama on `:11434` serves the same 9B fast model for `ai-pi -Fast`. It starts on demand, never at boot.
- [Pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) is the terminal agent. I always start it
  through `scripts/pi-local.ps1`, which hides cloud API keys from the session and turns off telemetry and version
  checks. A permission gate extension asks before risky commands (git push, ssh, `rm -rf`, `migrate:fresh`, writes
  outside the project) and blocks them in non-interactive runs.
- The big models are mixture-of-experts. `-ncmoe N` keeps the expert weights of the first N layers in system RAM
  and the rest on the GPU, which is how a 10 GiB model runs next to 6 GB of VRAM.
- The NVIDIA driver is set to "Prefer No Sysmem Fallback" (`scripts/nvidia-sysmem.py`), so a config that doesn't
  fit fails to load instead of quietly spilling into system RAM.

| Folder | Contents |
|---|---|
| `scripts/` | start/stop/status scripts, the Pi launcher, PowerShell shortcuts, the NVIDIA sysmem tool |
| `configs/` | Pi (models, settings, MCP servers, global rules, extensions, prompt templates), Ollama Modelfiles, VS Code |
| `docs/` | [why this stack](docs/why-this-stack.md), [presets and the 6 GB fit](docs/presets.md), [benchmarks](docs/benchmarks.md), [A/B test](docs/ab-test.md) |
| `tests/` | permission gate tests |

## Models and numbers

Measured with llama.cpp b11429 (CUDA 12.4), 64K context (32K for the 9B), q8_0 KV cache, flash attention, 12
threads, and a prompt of about 8K tokens of real PHP code. The agent rows had autocomplete on the CPU.

| Role | Model | Fit | Generation | Cold 8K prompt | VRAM peak |
|---|---|---|---|---|---|
| Agent (default) | Gemma-4-26B-A4B-it, UD-IQ3_S, 10.5 GiB | experts of 24 layers on CPU | 27-28 tok/s | 282 tok/s | 5265 MiB |
| Agent (kept for comparison) | Qwen3.6-35B-A3B, UD-IQ2_M, 10.7 GiB | experts of 28 layers on CPU, `-lm none` | 36.5-38.7 tok/s | 390 tok/s | 5427 MiB |
| Fast mode | Qwen3.5-9B, IQ4_XS, 4.8 GiB | fully on GPU | ~55 tok/s (~57 via Ollama) | ~1000-1500 tok/s | 5321 MiB |
| Autocomplete | Qwen2.5-Coder 0.5B Q8_0 (CPU) / 1.5B Q8_0 (GPU) | | 0.45-0.52 s / 0.12-0.22 s per request | | 0 / 2053 MiB |

The Qwen3.6 row was measured with Chrome open, the Gemma row with it closed. Lower `-ncmoe` values ran out of
memory (Qwen3.6 at 24, 26 and 27, Gemma at 20). The prompt cache helps a lot: a second Qwen3.6 call with the same
8K prefix took about 11 s instead of 45-71 s. The GPU peaked at 77 °C with no throttling.

Speed alone didn't pick the default. I ran each model through Pi on five tasks in a clone of a real Laravel app
(1053 tests green at baseline): add a unique validation rule with tests, fix a bug from a failing test, refactor a
controller into a service, add a migration + model + factory + test, and explain a route's flow without editing.
A task passes when hidden tests pass (a 10-point rubric for the explain task). The score is a blind 1-5 review of
the diff, given without knowing which model wrote it.

| Model | Passed | Median time, passed tasks | Review score (tasks 1-4) |
|---|---|---|---|
| Gemma-4-26B-A4B | 4/5 | 255 s | 4.0 |
| Qwen3.5-9B | 4/5 | 65 s | 3.0 |
| Qwen3.6-35B-A3B | 3/5 | 142 s | 3.7 (3 tasks) |
| gpt-oss-20b | 0/4 | - | - |

No model produced a broken tool call. Gemma and the 9B tied on passes; Gemma won on review score and had no hidden
bugs in production code, so it became the default. gpt-oss never edited a file (three timeouts and one run out of
tokens while thinking), so I deleted it. Method and per-task data: [docs/ab-test.md](docs/ab-test.md).

## Run it

Windows 11, PowerShell 7 or 5.1, an NVIDIA GPU, Node 24, Python with `uv`. Versions I use: llama.cpp b11429,
Ollama 0.40.1, Pi 1.1.0, llama-vscode 0.0.68. Models and llama.cpp go under `C:\AI`; to use another folder, set
`[Environment]::SetEnvironmentVariable('AI_ROOT', 'D:\AI', 'User')` once and swap the paths below.

1. Unzip `llama-b11429-bin-win-cuda-12.4-x64.zip` and `cudart-llama-bin-win-cuda-12.4-x64.zip` from the llama.cpp
   release tag `b11429` into `C:\AI\llama.cpp`.
2. Download the models with the `hf` CLI ([checksums](docs/presets.md#files-and-checksums)):
   ```powershell
   $G = "C:\AI\models\gguf"
   hf download unsloth/gemma-4-26B-A4B-it-GGUF --include "gemma-4-26B-A4B-it-UD-IQ3_S.gguf" --local-dir "$G\unsloth\gemma-4-26B-A4B-it-GGUF"
   hf download unsloth/Qwen3.5-9B-GGUF --include "Qwen3.5-9B-IQ4_XS.gguf" --local-dir "$G\unsloth\Qwen3.5-9B-GGUF"
   hf download ggml-org/Qwen2.5-Coder-0.5B-Q8_0-GGUF --include "qwen2.5-coder-0.5b-q8_0.gguf" --local-dir "$G\ggml-org\Qwen2.5-Coder-0.5B-Q8_0-GGUF"
   hf download ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF --include "qwen2.5-coder-1.5b-q8_0.gguf" --local-dir "$G\ggml-org\Qwen2.5-Coder-1.5B-Q8_0-GGUF"
   ```
3. Install Ollama (`winget install --id Ollama.Ollama -e`), turn off its autostart, set `OLLAMA_MODELS=C:\AI\models\ollama`,
   then `ollama create qwen3.5-9b:iq4xs -f configs\ollama\Modelfile.qwen35-9b`.
4. Optional: add `llama-server.exe` and `llama-bench.exe` in NVIDIA Control Panel > Program Settings once, then
   `python -I scripts\nvidia-sysmem.py --apply` (`--check` only reads).
5. Pi: `npm i -g @earendil-works/pi-coding-agent@1.1.0`, ripgrep and fd from winget, then
   `pi install git:github.com/obra/superpowers@v7.0.0` and copy the config:
   ```powershell
   $A = "$env:USERPROFILE\.pi\agent"; New-Item -ItemType Directory -Force $A | Out-Null
   Copy-Item configs\pi\models.json, configs\pi\settings.json, configs\pi\mcp.json $A
   Copy-Item configs\pi\global-rules.md "$A\AGENTS.md"
   Copy-Item configs\pi\extensions, configs\pi\prompts, configs\pi\mcp-servers $A -Recurse -Force
   uv tool install "duckduckgo-mcp-server[browser]==0.7.0" --with "ddgs==9.16.0"
   ```
   `AGENTS.md` holds my global rules for the agent (Git Bash paths, mostly Laravel projects), so edit it to fit. A
   free `CONTEXT7_API_KEY` is optional; without it Context7 runs anonymously with a lower limit.
6. VS Code: install llama-vscode and copy `configs/vscode/settings.json` into your user settings.
7. Add one line to `$PROFILE` (works in pwsh 7 and 5.1):
   `$s = '<clone>\scripts\ai-shortcuts.ps1'; if (Test-Path -LiteralPath $s) { . $s }`

Daily use:

```powershell
ai-on            # autocomplete on CPU (:8012) + Gemma (:8080), waits until healthy
ai-fast          # same, with Qwen3.5-9B fully on the GPU instead
ai-pi            # Pi in the current folder; ai-pi -Lite skips skills and MCP for a smaller prompt
ai-status        # servers, loaded models, VRAM, RAM
ai-off           # stop everything; VRAM should read 0 MiB
```

The shortcuts wrap `start-agent.ps1`, `start-fast.ps1`, `pi-local.ps1`, `status-ai.ps1` and `stop-ai.ps1 -All`.
`ai-on -Preset qwen36` and `ai-on -FimGpu` switch the model or move autocomplete to the GPU. `-DryRun` on any start
script prints what it would run without starting anything. Inside Pi, `/research <question>` and
`/docs <library> <question>` are prompt templates for web research and library docs.

## Tests

```powershell
node tests/permission-gate.test.mjs   # 254 checks, no model needed (Node 23.6+ runs the .ts directly)
```

CI runs it on a Windows runner, along with PSScriptAnalyzer on `scripts/` (the rules I skip are listed with reasons
in `PSScriptAnalyzerSettings.psd1`) and dry runs of the start scripts.

## Notes

- RAM is the real limit, not VRAM. With the MoE models loaded through mmap, free RAM drops below 300 MB (67 MB at
  worst). `-lm none` keeps about 2.4 GB free and doubles cold prompt speed, but adds ~7 GB of commit charge, so the
  pagefile has to be system managed. I've only measured that for Qwen3.6 so far.
- The 9B is about 4x faster per task, but it left a bug that passed the tests (an attribute with the wrong
  namespace, so `fillable` was empty) and answered a "latest PHP version" question wrongly after searching. I use
  it for small things and review everything it writes.
- Thinking can eat the whole 8192-token output budget before any edit. Qwen3.6 failed an A/B task that way, and
  Gemma did it once in a later run. Pi's bash also doesn't close stdin, so a command that waits for input hangs
  until the timeout.
- "Local" means the models. Context7 docs and web search in Pi go over the network (`-Lite` turns them off), and
  the permission gate is an emergency brake against prompt injection, not a sandbox.
- It's Windows only (NVAPI, the Ollama tray app, Windows paths in the gate), and the laptop is also my gaming
  machine, so nothing autostarts. `ai-off` before playing.
