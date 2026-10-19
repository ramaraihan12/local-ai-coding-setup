# Model presets and how they fit in 6 GB

The GPU is an RTX 3060 Laptop with 6 GB, of which about 5.1 GB is usable for models. The agent models are 10-11 GiB
files. Two things make that work: keeping part of each mixture-of-experts model in system RAM, and making sure
nothing silently spills over when it doesn't fit.

## The `-ncmoe` trick

The big models are mixture-of-experts (MoE). Qwen3.6-35B-A3B has 35B parameters but only ~3B are active per token,
Gemma-4-26B-A4B ~4B. The expert weights are most of the file, and each token only touches a few experts.

`-ncmoe N` (`--n-cpu-moe`) keeps the expert weights of the first N layers in system RAM and runs those expert
matmuls on the CPU. Attention, the shared weights and the KV cache stay on the GPU. A higher N frees VRAM and costs
speed. Qwen3.6 tg128 at 8 threads went 26.1 -> 30.5 -> 33.0 -> 35.7 tok/s for N = 40, 36, 32, 28.

So the job is to find the lowest N that doesn't run out of memory, with the autocomplete server already loaded,
because it takes its share first. The values in `start-coder.ps1` come from that sweep ([benchmarks.md](benchmarks.md)):

| Preset | Value | What happened below it |
|---|---|---|
| gemma | 24 | 20 ran out of memory in llama-bench; 21-23 not tried |
| qwen36 | 28 (35 with GPU autocomplete) | 26 and 27 failed with `failed to create context` next to the CPU autocomplete, 24 ran out of memory in llama-bench |
| gptoss | 17 | 16 loaded in llama-bench at a short context, 12 ran out of memory; 17 is what ran at 64K next to the CPU autocomplete |

`-Ncmoe -1` sends no `-ngl`/`-ncmoe` and lets llama.cpp's `--fit` choose. It works, but it left only ~180 MiB of VRAM
free, so I don't use it.

## Sysmem fallback off

On Windows the NVIDIA driver lets CUDA allocations overflow into shared system memory over PCIe. A config that
doesn't fit still "works", just several times slower, and a `-ncmoe` sweep gives you fake numbers instead of an error.

"CUDA - Sysmem Fallback Policy = Prefer No Sysmem Fallback" turns that off per program. I set it on three driver
profiles: `llama-server.exe`, `llama-bench.exe` and the predefined Ollama profile. Now a config that doesn't fit
fails to load, which is what you want while tuning.

`scripts/nvidia-sysmem.py` reads (`--check`, the default) or sets (`--apply`) that value through NVAPI, the same
calls NVIDIA Profile Inspector makes. It never touches the global profile. The two llama.cpp profiles have to exist
first: add both .exe files once in NVIDIA Control Panel > Manage 3D settings > Program Settings. You can also just
set the option there by hand and click Apply.

## Coder presets (`start-coder.ps1`, port 8080)

| Preset | GGUF | Size | `-ncmoe` (CPU FIM / GPU FIM) | ctx | Extra | VRAM peak |
|---|---|---|---|---|---|---|
| `gemma` (default) | gemma-4-26B-A4B-it-UD-IQ3_S | 10.5 GiB | 24 / 24 (GPU FIM not measured, prints a warning) | 65536 | `--reasoning off` | 5265 MiB |
| `qwen36` | Qwen3.6-35B-A3B-UD-IQ2_M | 10.7 GiB | 28 / 35 | 65536 | `-lm none` | 5427 MiB |
| `gptoss` | gpt-oss-20b-MXFP4 | 11.3 GiB | 17 / 17 | 65536 | `reasoning_effort` high | 5311 MiB |
| `qwen9b` | Qwen3.5-9B-IQ4_XS | 4.8 GiB | all on GPU | 32768 | | 5321 MiB |

Every preset also gets `-ngl 99 -fa on -ctk q8_0 -ctv q8_0 -np 1 -cram 512 -t 12 -b 2048 -ub 512 --no-mmproj`,
listens on 127.0.0.1 only and uses the model alias `local`. Explicit parameters always win over the preset.

- **KV cache q8_0**: half the size of f16 with very little loss. q4_0 is reported to hurt tool calling.
- **`-np 1`**: the default is automatic and more slots multiply the KV cache.
- **`-cram 512`**: the host prompt cache defaults to 8 GiB, half my RAM. 512 MiB was as fast as 2048 in a
  conversation.
- **`-t 12`**: best for generation (39.1 tok/s vs 35.7 at 8 threads and 36.6 at 16).
- **`--no-mmproj`**: text only, no vision projector.
- **`-lm none`** (qwen36 only): loads the model instead of memory-mapping it. With Chrome open it kept ~2.4 GB of RAM
  free instead of under 300 MB and doubled cold prompt speed, at the cost of ~7 GB more commit charge, so the
  pagefile has to be system managed. Not measured for the other presets yet.
- **`--reasoning off`** (gemma): see thinking below.

The `gptoss` preset is kept even though it went 0/4 in the [A/B test](ab-test.md). Without the file the script stops
and prints the download command.

## Autocomplete (`start-fim.ps1`, port 8012)

| Mode | Model | Where | VRAM | Latency per request |
|---|---|---|---|---|
| default (`-Cpu`) | Qwen2.5-Coder-0.5B Q8_0 | CPU only (`-dev none`, 4 threads, ctx 4096) | 0 | 0.45-0.52 s (0.63-0.68 s while the coder generates) |
| `-FimGpu` | Qwen2.5-Coder-1.5B Q8_0 | GPU, ctx 8192 | ~2053 MiB | 0.12-0.22 s |

The GPU version is nicer to type with, but its 2 GB push Qwen3.6 from `-ncmoe 28` to 35 and cost ~17% generation
speed (30.8-32 vs 37-38 tok/s), so autocomplete runs on the CPU by default. Both are base models: instruct variants
are trained for chat and break fill-in-the-middle output. `start-agent.ps1` starts autocomplete first and waits for
`/health`, so the two servers don't fight over VRAM while loading.

## Ollama

Ollama only serves the 9B fast model (`ai-pi -Fast`) and an embedding model. It never autostarts.

- `Modelfile.qwen35-9b` builds `qwen3.5-9b:iq4xs` from the same GGUF. Ollama's own fit keeps a 1024 MiB margin and
  only put 23 of 33 layers on the GPU (15-19 tok/s). `num_gpu 99` forces all layers: 5317 MiB at 32K context,
  ~56-57 tok/s. It needs an empty GPU, so stop llama-server first.
- `Modelfile.embed-cpu` pins `qwen3-embedding:0.6b` to the CPU (`num_gpu 0`) so it never competes for VRAM.
- User environment I set: `OLLAMA_MODELS=C:\AI\models\ollama`, `OLLAMA_CONTEXT_LENGTH=32768`,
  `OLLAMA_KV_CACHE_TYPE=q8_0`, `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=2`.
  Changing "Model location" or "Context length" in the Ollama GUI overwrites those, so I leave the GUI alone.
- `lib-ollama.ps1` starts the app through Explorer. Started directly from a shell, the tray app comes up without its
  server.

## Thinking

- Qwen3.5 and Qwen3.6 think by default. `enable_thinking` in `--chat-template-kwargs` still works in b11429 but is
  deprecated, so the scripts use `--reasoning off`. `reasoning_effort` (gpt-oss) still goes through the kwargs.
- Pi sends `enable_thinking: true` whenever its thinking level isn't `off`, which overrides the server's
  `--reasoning off`. So Gemma does think through Pi unless you start it with `ai-pi --thinking off`. That flag works
  for both providers: llama.cpp gets it through `chat_template_kwargs`, Ollama through `reasoning_effort: "none"`.
- Thinking can use the whole 8192-token output budget before the model edits anything. Raising the budget to 16384
  didn't help in the A/B test.

## Files and checksums

Sizes and SHA256 from the Hugging Face API, matched after download. Check one with
`(Get-FileHash <file>).Hash`.

| Repo | File | Bytes | SHA256 |
|---|---|---:|---|
| unsloth/gemma-4-26B-A4B-it-GGUF | gemma-4-26B-A4B-it-UD-IQ3_S.gguf | 11,289,671,136 | `878be93f9c238ea853b3fd1eb602637ce3cf1cddea56dc345d9a7bf2d6093e29` |
| unsloth/Qwen3.6-35B-A3B-GGUF | Qwen3.6-35B-A3B-UD-IQ2_M.gguf | 11,522,702,304 | `2be7ef1ed7e1af8b10d3829102cf9a6c2bd5ddb64d675b4ece23a60799403d43` |
| unsloth/Qwen3.5-9B-GGUF | Qwen3.5-9B-IQ4_XS.gguf | 5,168,653,536 | `7e918aeca06c52bcb528ea6b04b4ec957e75ee8c0a73138854c0dfcf371ea429` |
| ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF | qwen2.5-coder-1.5b-q8_0.gguf | 1,646,573,056 | `29871c94d15727a6e243f79a37113d4ae625a6215b5e800bf41a23af2da32832` |
| ggml-org/Qwen2.5-Coder-0.5B-Q8_0-GGUF | qwen2.5-coder-0.5b-q8_0.gguf | 531,068,128 | `d0f8cd6c49bab52a0abdbe47948518b1f4d9b1a8a2a6825099cea31cea10ac56` |
| ggml-org/gpt-oss-20b-GGUF (optional) | gpt-oss-20b-MXFP4.gguf | 12,109,566,624 | `27cd6c432c7672cb812a92f611cf3ba7bbc35928262bb1e1253ff4ee6ae35901` |
