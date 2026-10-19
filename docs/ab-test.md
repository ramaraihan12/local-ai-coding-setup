# A/B test: local models on real coding tasks

Tokens per second don't tell you whether a model can finish a task through an agent. So I ran each candidate model
through Pi on the same five tasks in a clone of a real Laravel app (multi-tenant, 1053 tests green at baseline) and
let hidden tests decide. The app is private, so this page has the method and the numbers, but no prompts, diffs or
transcripts. For the same reason the test runner script isn't in this repo: it is wired to that app's paths and tests.

## Setup

| | |
|---|---|
| Servers | llama-server b11429. CPU autocomplete (0.5B) on :8012 + the coder on :8080, one model at a time |
| Presets | `gemma` ncmoe 24, `--reasoning off` · `qwen36` ncmoe 28, `-lm none` · `gptoss` ncmoe 17, `reasoning_effort` high · `qwen9b` fully on GPU, ctx 32768. All others ctx 65536, KV q8_0, `-np 1 -t 12 -cram 512` |
| Agent | Pi 1.1.0 through `pi-local.ps1 --no-skills --no-mcp --mode json` (non-interactive). Pi's default thinking level for every model, maxTokens 8192 |
| Project | the clone is reset to the baseline commit before every task; its push URL is disabled |
| Limits | 15 minutes per task; a model stops after 2 timeouts in a row |
| Pass | hidden "judge" tests are copied in only after the agent is done, then run with the related existing tests. The explain task uses a 10-point rubric instead (pass at 6, minus 1 per invented claim) |
| Review | each diff got a blind 1-5 score (tasks 1-4) without knowing which model wrote it |
| Verdict | the first run counts; reruns are extra information |

Before any model ran, the runner was checked both ways: with nothing changed all 5 tasks fail, with the reference
solutions applied all 5 pass.

## The five tasks

1. **Validation.** Make a field unique in a FormRequest (the record being updated may keep its own name), then write
   a feature test that follows the project's test conventions. Judge: 4 new tests plus an existing auth test file,
   15 tests.
2. **Bug fix.** The runner injects a one-character bug in a service (`>` became `>=`) and commits it, so the working
   tree looks clean. The prompt only says some tests in one file now fail and the fix must be as small as possible
   without touching tests. Judge: three related test files, 39 tests.
3. **Refactor.** Move everything inside a controller's `DB::transaction` into a new service class. Behavior must not
   change. Judge: structure checks plus HTTP behavior tests and the existing tests, 14 tests.
4. **New entity.** Tenant migration, model, factory, a relation on an existing model and a feature test. Judge:
   migration in the tenant folder, columns, foreign key with cascade, factory, relations both ways, casts, 8 tests.
5. **Explain.** Describe the full path of one POST route (middleware, controller, services, checks, database writes,
   responses on success and failure) in about 400 words, without editing anything.

## Results, first run

Tool calls count every call, with the number that returned an error in brackets. Most of those errors are red test
runs while the model works, not broken calls.

| Model | Task | Passed | Judge tests | Wall (s) | Output tokens | Tool calls | Score |
|---|---|---|---|---|---|---|---|
| gemma | 1 | yes | 15/15 | 169.9 | 2837 | 8 (1) | 4 |
| gemma | 2 | yes | 39/39 | 257.2 | 6034 | 7 (1) | 5 |
| gemma | 3 | yes | 14/14 | 289.2 | 7207 | 7 (0) | 4 |
| gemma | 4 | yes | 8/8 | 252.7 | 5189 | 24 (6) | 3 |
| gemma | 5 | no | | 221.9 | 4688 | 9 (0) | 3/10 |
| qwen9b | 1 | yes | 15/15 | 58.3 | 2434 | 8 (0) | 4 |
| qwen9b | 2 | yes | 39/39 | 45.9 | 1234 | 7 (2) | 5 |
| qwen9b | 3 | no | 3/14 | 900.6 (timeout, bash hung) | 6889 | 23 (2) | 1 |
| qwen9b | 4 | yes | 8/8 | 142.6 | 5692 | 29 (6) | 2 |
| qwen9b | 5 | yes | | 71.2 | 2320 | 14 (0) | 7/10 |
| qwen36 | 1 | yes | 15/15 | 141.9 | 2625 | 17 (1) | 5 |
| qwen36 | 2 | no | 26/39 | 586.7 (output limit, spent on thinking) | 17294 | 8 (1) | no diff |
| qwen36 | 3 | yes | 14/14 | 240.6 | 3972 | 19 (2) | 2 |
| qwen36 | 4 | yes | 8/8 | 131.0 | 2777 | 19 (1) | 4 |
| qwen36 | 5 | no | | 99.7 | 1778 | 10 (0) | 1/10 |
| gpt-oss-20b | 1 | no | 13/15 | 900.9 (timeout) | 11367 | 58 (2) | - |
| gpt-oss-20b | 2 | no | 26/39 | 795.4 (output limit) | 15466 | 12 (1) | - |
| gpt-oss-20b | 3 | no | 13/14 | 900.7 (timeout) | 10909 | 37 (3) | - |
| gpt-oss-20b | 4 | no | 5/8 | 900.8 (timeout) | 13700 | 35 (3) | - |
| gpt-oss-20b | 5 | not run (stopped after two timeouts) | | | | | |

The failed judge counts for gpt-oss and qwen36 are exactly the baseline numbers: no progress at all. qwen9b task 3
is the exception, its changes broke things.

## Per model

| Model | Passed | Broken tool calls | Timeouts / output limit | Median time, passed tasks | Total wall | Review score (tasks 1-4) | Explain rubric |
|---|---|---|---|---|---|---|---|
| **gemma** | **4/5** | 0 | 0 / 0 | 255 s | 19.8 min | **4.0** | 3/10 |
| qwen9b | **4/5** | 0 | 1 / 0 | **65 s** | 20.3 min | 3.0 | **7/10** |
| qwen36 | 3/5 | 0 | 0 / 1 | 142 s | 20.0 min | 3.7 (3 tasks) | 1/10 |
| gpt-oss-20b | 0/4 | 0 | 3 / 1 | - | 58.3 min (4 tasks) | - | - |

"Broken" means an unknown tool, a schema validation error, or a tool call leaked as plain text. There were none,
for all four model families, and no loops either. Resources with CPU autocomplete: VRAM 5.27-5.4 GB for every
model; minimum free RAM ~300 MB for gemma (mmap), ~330 MB for qwen36 (`-lm none`), ~800 MB for gpt-oss and ~2.8 GB
for the 9B. No OOM, no CUDA errors.

## Reruns (don't change the verdict)

| Model | Task | Change | Result |
|---|---|---|---|
| qwen36 | 2 | maxTokens 16384 | timeout after 900.8 s. It found the bad line but the edit failed (text mismatch) and it kept rerunning tests. ~80K characters of thinking |
| gemma | 2 | maxTokens 16384 (control) | passed in 323.5 s, same one-line revert as the first run |
| qwen9b | 3 | same config | passed 14/14 in 189.9 s, no hung bash. Not reviewed |

## What I saw

- **gemma** was the slowest model that passed, but consistent, and its production code was right in every task. It
  was the only one that kept the `DB::transaction` in the refactor. Its explanation was shallow (3/10) but had zero
  invented claims.
- **qwen9b** is about 4x faster and wrote the best explanation. But it left a bug that passed the tests: in task 4
  it used a PHP attribute from the wrong namespace, so `fillable` was empty and `create()` outside the factory failed.
  Its first refactor run was badly broken (an import removed, the unique rule and the transaction gone). It can also
  invent business rules. I review everything it writes.
- **qwen36** at IQ2_M spent its whole output budget thinking on task 2 and never edited, and 16384 tokens didn't
  help. Its refactor passed the tests but dropped the transaction, so the update is no longer atomic. Its explanation
  mangled identifiers and invented a column. My guess is the 2-bit quant.
- **gpt-oss-20b** (reasoning high) never edited a file: endless read-only exploration (58 tool calls on task 1, one
  file read 7 times) or thinking until the output limit. I deleted the GGUF and kept the preset.
- Pi's bash doesn't close stdin, so a command that asks a question hangs until the timeout. In qwen9b's task 3 a
  mistyped artisan command triggered "Did you mean ...?" and sat there for ~12 minutes.

## Decision

The ranking rule was: tasks passed, then broken tool calls, then review score, then speed. gemma and the 9B tie on
the first two, and the review score picks gemma (4.0 vs 3.0). The app is live, so a bug that slips past the tests
costs more than waiting a few minutes. Result: gemma is the agent default, the 9B stays as fast mode, qwen36 is kept
for comparison.

## Safety during the runs

- SSH keys for the app's servers were moved out of the way while the agents ran and restored afterwards.
- The original repository was compared against a snapshot after every model. It never changed.
- I read through the transcripts: no ssh, scp or push, and no access outside the clone.

The [permission gate](../configs/pi/extensions/permission-gate.ts) came after this test, so these runs didn't rely on
it.

## Not done yet

- gemma with `-lm none`: with mmap its minimum free RAM was only ~300 MB.
- gemma next to the GPU autocomplete needs a measured `-ncmoe`.
- A higher qwen36 quant if RAM allows; IQ2_M mangles identifiers.
- One run per task is noisy. Repeating the explain task and the tasks that differed would help.
