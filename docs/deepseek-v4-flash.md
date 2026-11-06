# DeepSeek-V4-Flash-0731 on gfx906

`v5` (llama.cpp b12128) knows two DeepSeek layouts: `deepseek41` (V4.1-Flash-1017) and `deepseek4`
(V4-Flash-0731). This page is about the second one, the July release, measured on a single MI50.

## The model

From the GGUF header of `unsloth/DeepSeek-V4-Flash-0731-GGUF`, `UD-IQ2_XXS`:

| | |
| --- | --- |
| `general.architecture` | `deepseek4` |
| Layers | 43 |
| Experts | 256, **6 active** + 1 shared |
| Hidden / expert FFN | 4096 / 2048 |
| Context | 1 048 576 (`rope.scaling.original_context_length` 65 536) |
| Attention | 64 heads, 1 KV head, K/V length 512, sliding window 128 |
| DSA indexer | 64 heads, key length 128, top-k 512 |
| Hyper-connections | 4, 20 Sinkhorn iterations |
| Size, `UD-IQ2_XXS` | 90.85 GB (84.6 GiB) in 3 shards, 2.0625 bpw |

Quant sizes from the same repo, for scale:

| Quant | Size | Note |
| --- | ---: | --- |
| `UD-IQ1_S` | 82.5 GB | smallest, weakest on prose |
| `UD-IQ1_M` | 86.9 GB | |
| `UD-IQ2_XXS` | 90.9 GB | what is measured below |
| `UD-Q2_K_XL` | 96.8 GB | different quant mix, worth an A/B |
| `UD-IQ3_XXS` | 104.2 GB | |
| `UD-Q4_K_XL` | 155.1 GB | needs ~2x the memory |
| `MXFP4` (bartowski) | 156.4 GB | one 4-shard set; MXFP4 has no hardware support on gfx906, so it is the slowest option here |

The DSpark MTP head is a **separate file** in both repos (10.9 GB at `Q8_0`), not included in the
quants.

## Running it

The weights do not fit in 32 GB of VRAM, and they do not need to: MoE experts can live in host
memory and be read per token. `-cmoe` keeps **every** expert on the CPU and leaves attention, dense
and norms on the card. That is the configuration that works.

```bash
docker run -d --name dsv4 \
  --device=/dev/kfd --device=/dev/dri --group-add video \
  -v /home/models/gguf:/models:ro \
  -v /home/dsv4-work:/work \
  -p 8080:8080 \
  xxdoman/llama-mi50-rocm7.2:v5 \
  -m /models/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf \
  -ngl 99 -cmoe \
  -c 131072 -ub 128 -b 256 \
  --flash-attn on --jinja --host 0.0.0.0 --port 8080
```

`-c` is your call. 131 072 is a sane interactive setting; the model nominally allows 1M, but every
extra token of context is KV that has to be allocated, and prefill on this card is the slow part.

### Tuning `--n-cpu-moe` instead of `-cmoe`

`--n-cpu-moe N` keeps the experts of the first N layers on the CPU and puts the rest on the card. On
a 32 GB MI50 an attempt with `--n-cpu-moe 30` (so ~13 layers' experts on the card) died on a
**1.9 GB compute-buffer allocation**, not on the weights: the compute buffer and the KV of a large
context need room too. If you want experts on the card, walk N down in steps and watch VRAM, rather
than assuming the weights are the whole budget.

## What it measured

One MI50 32 GB, 80 W power cap, host with 61 GB of RAM (so the model is bigger than RAM + VRAM and
part of it is read from NVMe through mmap):

| Setting | Prompt | Generation |
| --- | ---: | ---: |
| `v5`, `-cmoe -c 1024` | 3.4 tok/s | 3.4 tok/s |
| `v5`, `-cmoe -c 973824` (API call) | 3.9 tok/s | 2.2 tok/s |
| older host build, 0.8.0-dev | 1.9 tok/s | 1.9 tok/s |

The first token of `"hello"` came back coherent every time — the model is not borderline, it is just
slow when every expert is read from RAM. VRAM sat at **11.4 GB** with `-cmoe` and a 1M context
allocated, which is the dense weights, the KV and the compute buffers.

On a box where the experts fit — 2x MI50 32 GB and 128 GB of RAM is the natural shape for
`UD-IQ2_XXS` — roughly 30 layers of experts stay resident in VRAM and the rest in RAM, and none of it
is read from disk. That is a different speed class from the numbers above; nobody has measured it
yet, so this page will not claim one.

## Two things that are not blockers

**The lightning indexer.** In llama.cpp the DSA indexer has two kernels: a WMMA one that is compiled
only for NVIDIA (`#if !defined(GGML_USE_HIP)`), and a `vec` kernel that is what HIP gets. So the
architecture runs on gfx906 without a tensor-core path, just slower than on a card that has one.

**The tokenizer / chat template.** The 0731 release ships no Jinja template upstream; llama.cpp has
its own for the family and `--jinja` applies it. Reasoning output is separate from the answer, so
budget tokens accordingly — a 32-token smoke test ends inside the thinking block and shows you no
answer at all.

## What this does *not* mean

This is llama.cpp running DeepSeek-V4-Flash on gfx906. It says nothing about the Strata engine:
`strata-dsv41` knows only `deepseek41`, and the 0731 layout exists upstream as CUDA-only patches
(Strata issues #4820 and #3589). Two different engines, two different answers to "does it run".
