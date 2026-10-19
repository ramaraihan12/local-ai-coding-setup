# Why this stack

What I wanted: a coding agent in the terminal and autocomplete in VS Code on a laptop with a 6 GB GPU and 16 GB of
RAM. Free, no subscription, no cloud model, and nothing running unless I start it, because the same laptop is my
gaming machine.

## llama.cpp as the main engine

The models worth using as an agent are 26-35B mixture-of-experts models, and they only fit if part of each model
sits in system RAM. llama.cpp's `llama-server` can do that per layer (`-ncmoe`), and it has everything else a small
GPU needs: q8_0 KV cache, a single slot (`-np 1`), a cap on the host prompt cache (`-cram`), an OpenAI-compatible API
and a built-in web UI on the same port. Ollama 0.40 has no user control over expert offload, so the big models run
there badly or not at all. See [presets.md](presets.md) for how the numbers were picked.

## Ollama on the side

Ollama is still the easiest way to serve the 9B fast model and an embedding model, and other tools talk to it out of
the box. It runs only when something needs it: the scripts start it through Explorer on demand and `ai-off` closes
it again.

## MoE models at 2-3 bits

16 GB of RAM is the real ceiling. Windows, VS Code and a browser take 4-6 GB, which leaves room for model files of
about 12 GB at most. That rules out Q4 of the 35B models (over 20 GB) and makes dense models above ~12B too slow,
because most of their weights would be read from DDR4 for every token. A 2-3 bit MoE model with ~3-4B active
parameters runs at 27-39 tok/s here ([benchmarks.md](benchmarks.md)). Low quants are fragile, though, which is why
the default was picked by an [A/B test on real tasks](ab-test.md) and not by benchmarks.

## Pi as the agent

On a 64K context the agent's own prompt matters. Some popular agents send 7K to 30K+ tokens of system prompt and tool
definitions before you type anything. Pi starts small, so I could add things on top and still keep most of the
window for code:

| Mode | First request | First turn, cold / warm prompt cache |
|---|---|---|
| default (9 Superpowers skills + bootstrap + Context7 + web search) | 6,189 tokens | 54.7 s / 11.6 s |
| `-Lite` (built-in tools and AGENTS.md only) | 2,260 tokens | 14.3 s / 6.6 s |

Measured with Gemma on a trivial prompt ("answer: ok"). Switching between the two modes throws away the prompt cache, so I pick
one per session.

The launcher (`scripts/pi-local.ps1`) is the only way I start Pi. It hides every cloud API key from the Pi process
(except the optional Context7 key), sets `PI_OFFLINE=1`, turns telemetry and version checks off, and restores the
environment when Pi exits. The built-in llama.cpp integration is disabled in `settings.json` because it can download
and swap models on its own.

## A permission gate in front of the tools

Pi's bash tool runs whatever the model writes, and the web search server feeds it text from random pages. A prompt
injection in a fetched page could make the model push code, delete files or read keys. The
[permission gate](../configs/pi/extensions/permission-gate.ts) checks every tool call before it runs: risky shell
commands (network writes, `git push`, `ssh`, `rm -rf`, `migrate:fresh`, `DROP TABLE`, reading keys, persistent system
changes) and writes outside the project folder or to `.env`, `.ssh`, `.git/hooks` or Pi's own config.

In the terminal UI it asks: deny, allow once, or allow that pattern for the session. In non-interactive runs (`-p`,
`--mode json`) it blocks and tells the model to ask the user. In live runs it blocked a `git push` and an `ssh` and
had no false positives on a normal coding task and a web research task. It matches command text, so it is an
emergency brake, not a sandbox.

## llama-vscode for autocomplete

The official ggml-org extension, talking fill-in-the-middle to `llama-server` on :8012. As of October 2026 there is
still no small FIM model from the Qwen3 generation, so Qwen2.5-Coder base (0.5B on the CPU, 1.5B on the GPU) is it.
Only one autocomplete provider should be installed; each one loads its own model and fires its own requests.

## Native Windows, nothing autostarts

Everything runs natively. WSL2 only sees half the RAM by default, which is fatal for expert offload. Nothing starts
at boot or login: `ai-on` / `ai-fast` start the servers in their own windows and `ai-off` stops all of it and prints
the VRAM in use, which should be 0 MiB before I open a game.

## What goes over the network

The models never leave the laptop. Context7 (library docs) and the web search server do go out to the internet, and
`ai-pi -Lite` turns both off. There is no cloud model in the loop and the launcher keeps cloud keys out of Pi on
purpose.
