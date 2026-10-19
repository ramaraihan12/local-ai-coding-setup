# Benchmarks

Everything here was measured on the laptop the setup runs on: ASUS TUF A15 (FA506QM), Ryzen 9 5900HX, RTX 3060
Laptop 6 GB, 16 GB RAM (15.4 GB visible), Windows 11.

Conditions: llama.cpp b11429 (CUDA 12.4), NVIDIA driver 616.92 with "Prefer No Sysmem Fallback" set for
llama-server and llama-bench (so a config that doesn't fit fails with OOM instead of spilling into system RAM, see
[presets.md](presets.md)). AC power, Armoury Crate Turbo. 9.6-10.9 GB of RAM free at the start, Chrome closed.

Server tests used ctx 65536, KV cache q8_0, `-fa on -np 1 -cram 2048 -b 2048 -ub 512 -t 12`, and a realistic
prompt: 30,000 characters of PHP from a real Laravel app (7,337-8,121 tokens depending on the tokenizer) plus a
question, `max_tokens` 300.

## llama-bench sweeps

pp512 / tg128 in tok/s. "OOM" means that `-ncmoe` value didn't fit.

| Model | Quant | `-ncmoe` | `-t` | KV | pp512 | tg128 | VRAM peak (MiB) | RAM min (MB) |
|---|---|---|---|---|---|---|---|---|
| Qwen3.5-9B | IQ4_XS | 0 (dense, all on GPU) | 8 | f16 | 1681 | 57.8 | - | - |
| Qwen3.6-35B-A3B | UD-IQ2_M | 40 | 8 | q8_0 | 171 (cold) | 26.1 | 2103 | 1167 |
| Qwen3.6-35B-A3B | UD-IQ2_M | 36 | 8 | q8_0 | 129 (cold) | 30.5 | 3063 | 806 |
| Qwen3.6-35B-A3B | UD-IQ2_M | 32 | 8 | q8_0 | 143 (cold) | 33.0 | 4021 | 541 |
| Qwen3.6-35B-A3B | UD-IQ2_M | 28 | 8 / 12 / 16 | q8_0 | 375 / 396 / 423 | 35.7 / **39.1** / 36.6 | 4939 | 217 |
| Qwen3.6-35B-A3B | UD-IQ2_M | 28, depth 16K | 12 | q8_0 | 426 | 36.2 (36.1 at depth 0) | 5117 | 187 |
| Qwen3.6-35B-A3B | UD-IQ2_M | 24 | 8 | q8_0 | OOM (compute buffer) | | | |
| gpt-oss-20b | MXFP4 | 24 / 19 / 16 | 12 | f16 | 308 / 316 / 348 | 18.0 / 21.4 / 24.8 | 1833 / 3851 / 5065 | 472 |
| gpt-oss-20b | MXFP4 | 12 | 12 | | OOM (6.1 GB model buffer) | | | |
| Gemma-4-26B-A4B | UD-IQ3_S | 30 / 24 | 12 | q8_0 | 249 / 254 | 25.5 / 31.5 | 2721 / 4519 | 650 |
| Gemma-4-26B-A4B | UD-IQ3_S | 20 | 12 | | OOM (compute buffer) | | | |

The "cold" pp512 numbers are misleading: the model is memory-mapped lazily, so expert layers are read from the NVMe
the first time they are used. Warm numbers are in the `-t` row. 12 threads was the best for generation.

## Server runs with autocomplete loaded

Coder on :8080 next to the FIM server on :8012. Prompt = the 8K-token PHP prompt above, cold.

| Scenario | Model | `-ncmoe` | Cold 8K prompt (tok/s) | Generation, call 1 / call 2 (tok/s) | VRAM peak (MiB) | RAM min (MB) | GPU max (°C) |
|---|---|---|---|---|---|---|---|
| FIM on GPU + coder `--fit` | Qwen3.6 | auto (~34) | 170 | 32.2 / 32.4 | 5962 (FIM 2053) | 102 | 73 |
| FIM on GPU + coder | Qwen3.6 | 35 | 126 | 30.8 / 32.0 | 5830 | 74 | 72 |
| FIM on CPU + coder | Qwen3.6 | **28** | **211** | **37.7 / 37.4** (35.0 while FIM runs) | 5425 | 67 | 75 |
| FIM on CPU + coder | gpt-oss-20b | 17 | 243 | 22.3 / 19.6 | 5311 | 282 | 69 |
| FIM on CPU + coder, reasoning off | Gemma-4-26B-A4B | 24 | 282 | 28.0 / 27.0 | 5265 | 182 | 70 |

- `--fit` picked `-ngl 41` with the experts of blocks 6-40 on the CPU (about `-ncmoe` 34-35) and left only ~180 MiB
  of VRAM free, even though its margin is supposed to be 1024 MiB. The presets use fixed values instead.
- Qwen3.6 at `-ncmoe` 26 and 27 failed with `failed to create context`. 28 leaves ~720 MiB free.
- **Prompt cache works.** A second call with the same 8K prefix: Qwen3.6 processed only 514 new tokens (it is a
  hybrid model and rolls back to a checkpoint) and took 11 s instead of 45-71 s. gpt-oss reprocessed 15 tokens,
  Gemma 21.
- **Autocomplete** (`/infill`, ~18 tokens): GPU 1.5B 120-220 ms. CPU 0.5B 450-520 ms with the coder idle, 630-680 ms
  while the coder is generating (FIM 65 -> 52 tok/s, coder 37.5 -> 35.0 tok/s).
- **Thermals:** GPU max 77 °C, ~79 W. No throttling.

## RAM

RAM is the real limit, not VRAM. While a MoE coder runs, available RAM drops to 70-300 MB (15.1-15.3 of 15.4 GB in
use) with 5-10K page reads per second (~20-40 MB/s), mostly the memory-mapped model being re-read from the NVMe. The
pagefile only held 0.9-1.2 GB. gpt-oss and Gemma show the same pattern, so switching models doesn't fix it. Only the
dense 9B, fully in VRAM, runs without RAM pressure.

## Same test with Chrome open

FIM on CPU + Qwen3.6 `-ncmoe 28`, same 8K prompt, Chrome open (12-13 processes, ~1 GB). Call 3 reuses the prefix and
generates 800 tokens.

| Variant | Flags | Load | Cold 8K prompt | Generation c1 / c2 / c3 (tok/s) | RAM available min | Page reads/s, prompt / gen | VRAM peak | Commit max |
|---|---|---|---|---|---|---|---|---|
| V0 | `-cram 2048`, mmap | 7.9 s | 174 tok/s | 36.4 / 38.6 / 38.5 | 219 MB | 29.5K / 0.85K | 5425 MiB | 17.6 GB |
| V1 | `-cram 512`, mmap | 10.5 s | 192 tok/s | 38.3 / 38.4 / 38.0 | 77 MB | 27.3K / 1.3K | 5425 MiB | 17.6 GB |
| **V2** | `-cram 512 -lm none` | 12.2 s | **390 tok/s** | 38.7 / 36.5 / 38.6 | **2457 MB** | **3.0K** / 2.8K | 5427 MiB | 24.5 GB |

V2 became the `qwen36` preset: cold prompts twice as fast and ~2.4 GB of RAM left free. The cost is ~7 GB more
commit charge, so the pagefile has to be system managed. `-cram 512` and 2048 made no difference within one
conversation, so 512 is the cap now.

After these runs the A/B test on real tasks moved the default to Gemma ([ab-test.md](ab-test.md)). Gemma with
`-lm none` is not measured yet.

## Fast mode (9B)

Qwen3.5-9B IQ4_XS fully on the GPU: ~55 tok/s through llama-server, ~1000-1500 tok/s prompt, 5321 MiB VRAM at ctx
32768. Through Ollama with `num_gpu 99`: ~56-57 tok/s, 5317 MiB. Ollama's default fit only put 23 of 33 layers on the
GPU and ran at 15-19 tok/s.
