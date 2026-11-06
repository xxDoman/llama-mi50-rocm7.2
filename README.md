# llama.cpp for AMD gfx906 — MI50 / MI60 / Radeon VII

Prebuilt, self-contained Docker image of [llama.cpp](https://github.com/ggml-org/llama.cpp) for the
gfx906 cards, published as [`xxdoman/llama-mi50-rocm7.2`](https://hub.docker.com/r/xxdoman/llama-mi50-rocm7.2):

```
docker pull xxdoman/llama-mi50-rocm7.2:v5
```

One image = `llama-server` + `llama-cli` + `llama-bench` on ROCm 7.2.1 with a **rocBLAS built for
gfx906** and a **complete set of CPU backend variants**. No model is baked in.

**Cards:** AMD Instinct **MI50 / MI60** and **Radeon VII** (Vega 20, `gfx906`). The HIP backend is
compiled for `gfx906` only — for gfx11/gfx12 you need a binary built for that architecture.

---

## The current release: `v5` (llama.cpp b12128)

| | |
| --- | --- |
| Image tag | `xxdoman/llama-mi50-rocm7.2:v5`, alias `:latest` (14 GB) |
| Upstream | llama.cpp **b12128**, commit `a01dff9`, `0.9.0-dev`, libggml 0.29.0 |
| Published | 2026-11-05 |
| Built with | `-DGGML_HIP=ON -DAMDGPU_TARGETS=gfx906 -DBUILD_SHARED_LIBS=ON -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON -DLLAMA_CURL=OFF`, no local patches |
| Base | `rocm/dev-ubuntu-24.04:7.2.1` |
| Architectures | 171 model architectures |

**What `v5` changed over `v4` (b11857):** the CPU backend is no longer one binary. It ships 14
`libggml-cpu-<arch>.so` variants — `x64, sse42, sandybridge, ivybridge, piledriver, haswell,
skylakex, cannonlake, cascadelake, icelake, cooperlake, zen4, alderlake, sapphirerapids` — and the
loader picks the best one for the host at start-up. Up to `v4` there was a single variant compiled
for x86-64-v3, which ggml refuses to register on anything older than Haswell
(`make_cpu_buft_list: no CPU backend found`). New architectures in `v5` include **`lfm3`**,
**`deepseek41`** and **`deepseek4`**.

**Why the image exists at all:** AMD stopped shipping gfx906 kernels in rocBLAS with ROCm 6.5. On
these cards the stock packages give you either a crash or a software fallback. This image carries
a **patched rocBLAS 5.2.0** built from source for gfx906 (156 kernels) on ROCm 7.2.1, which is what
makes GEMM — and therefore the whole thing — usable on an MI50.

---

## Tags

| Tag | Engine |
| --- | --- |
| `v5` / `latest` | llama.cpp **b12128** (`0.9.0-dev`, 05.11.2026), 171 architectures, 14 CPU variants, libggml 0.29.0 |
| `v4` | llama.cpp **b11857** (24.10.2026), 163 architectures, MoE expert cache, native speculative decoding, **single** CPU variant |
| `v4-web` | the `v4` engine plus a browser configurator on `:8090` (scans `/models`, verdict per file, start/stop, live log, per-card power cap) |
| `v3` | llama.cpp `0.6.0-dev` (mainline `48e9857`, 13.10.2026), MoE expert cache and native MTP as stock upstream |
| `v2` | llama.cpp `0.5.0-dev` plus our own MTP/NextN patches |
| `v1` | llama.cpp `b8233`, libggml 0.9.7 |

`v4` and older are kept because stacks were deployed on them, not because they are better.

---

## Measured on one MI50 32 GB (ROCm 7.2.1)

| Model | Quant | Prompt processing | Generation | Tag |
| --- | --- | ---: | ---: | --- |
| LFM3-Omni-2B | Q4_K_M | 2068 tok/s (pp128) | 163.3 tok/s (tg32) | `v5` |
| Bielik-11B-v3 | Q6_K (8.5 GB) | 390 tok/s (pp128) | 48.1 tok/s (tg32) | `v5` |
| Flint 40B-A2.5B | UD-Q4_K_XL (25 GB) | — | ~52 tok/s | `v4` |
| Ornith-1.5-35B-A3B | Q4_K_M | ~599 tok/s (pp512) | ~48.6 tok/s (tg128) | `v4`, **80 W cap** |
| DeepSeek-V4-Flash-0731 | UD-IQ2_XXS (85 GiB) | — | ~3.4 tok/s | `v5`, `-cmoe`, 80 W, experts in RAM |

`llama-bench -p 128 -n 32 -r 2`, `-ngl 99`, one card. Numbers move with the power cap, the quant and
the context, so treat them as a band, not a spec. The Ornith and DeepSeek rows were measured at an
**80 W cap** (silent night setting); raise the cap for more throughput.

---

## DeepSeek-V4-Flash on gfx906

Both DeepSeek layouts work in this image: `deepseek41` (V4.1-Flash-1017) and `deepseek4`
(V4-Flash-0731). The 0731 release is the interesting one, because its GGUFs fit consumer-sized
machines if the experts live in RAM. Full recipe with numbers: [docs/deepseek-v4-flash.md](docs/deepseek-v4-flash.md).

Short version — 85 GiB of weights on a card with 32 GB of VRAM, so the experts go to the CPU:

```bash
docker run -d --name dsv4 \
  --device=/dev/kfd --device=/dev/dri --group-add video \
  -v /home/models/gguf:/models:ro \
  -p 8080:8080 \
  xxdoman/llama-mi50-rocm7.2:v5 \
  -m /models/DeepSeek-V4-Flash-0731-UD-IQ2_XXS-00001-of-00003.gguf \
  -ngl 99 -cmoe -c 131072 -ub 128 -b 256 --flash-attn on --host 0.0.0.0 --port 8080
```

`-cmoe` keeps every MoE expert in host memory and leaves attention, dense and norms on the card.
Without it the engine tries to place 85 GiB of weights in 32 GB of VRAM and dies on a compute-buffer
allocation before it logs anything useful.

Two limits worth knowing. The DSpark MTP head is a **separate 10.9 GB file**, not part of the quants
— add it later with `--spec-type draft-dspark -md <file>` if you want it. And the lightning indexer
(DSA) has a HIP path: the WMMA kernel is NVIDIA-only, but the `vec` kernel used on AMD compiles and
runs for gfx906, so the architecture is not blocked by it.

---

## Prerequisites

- **OS:** any Linux with the `amdgpu` driver; Ubuntu 24.04 is what this is tested on.
- **GPU:** MI50 / MI60 / Radeon VII (`gfx906`). `/dev/kfd` and `/dev/dri` must be exposed.
- **CPU:** any x86-64 — since `v5` the image carries variants for pre-Haswell hosts.
- **Model directory:** put `.gguf` files flat in one directory and mount it at `/models`.

```bash
sudo mkdir -p /home/models/gguf && sudo chmod -R 777 /home/models
```

---

## Running

```bash
docker run -d --name llmi50 \
  --restart unless-stopped \
  --device=/dev/kfd \
  --device-cgroup-rule='c 226:* rmw' \
  -v /dev/dri:/dev/dri \
  -v /home/models/gguf:/models:ro \
  -p 8080:8080 \
  xxdoman/llama-mi50-rocm7.2:v5 \
  -m /models/your-model.gguf \
  -ngl 99 -t 12 --host 0.0.0.0 --port 8080
```

The image has `ENTRYPOINT /app/llama-server`, so anything after the tag is a llama-server argument.
To run a different binary, override the entrypoint:

```bash
docker run --rm --device=/dev/kfd --device=/dev/dri --group-add video \
  -v /home/models/gguf:/models:ro \
  --entrypoint /app/llama-bench xxdoman/llama-mi50-rocm7.2:v5 \
  -m /models/your-model.gguf -p 128 -n 32 -r 2 -ngl 99
```

### Options worth knowing

- `-ngl 99` — all layers to the GPU. Lower it when the model exceeds VRAM.
- `-c N` — context. On a 32 GB card, `-c 32768` to `-c 131072` is the usual range for a 30-70B quant.
- `--n-cpu-moe N` (or `-cmoe` for all layers) — keep MoE experts in CPU memory. This is the knob for
  MoE models bigger than VRAM: attention, dense and norms stay on the card, only the experts go to RAM.
- `--moe-cache-mib N` — device cache for the experts of the CPU-resident layers, so the second and
  later passes over the same experts skip the host→device copy. Off by default.
- `--flash-attn on|off` — Flash Attention; on by default in the entrypoint's CMD.
- `--spec-type draft-mtp -md <head>.gguf` (and `draft-dflash`, `draft-dspark`, `draft-simple`,
  `ngram-*`) — native speculative decoding. Measure it: on small active-parameter MoEs a deep draft
  can cost more than it earns.
- Power cap by hand: `echo 80000000 | sudo tee /sys/class/drm/card*/device/hwmon/hwmon*/power1_cap`.
  An MI50 idles at ~23 W and will sit under 80 W only if you cap it — the default cap is 225 W.

---

## Inside the image

- `HSA_OVERRIDE_GFX_VERSION=9.0.6`, `HIP_VISIBLE_DEVICES=0`, `LD_LIBRARY_PATH=/app:/opt/rocm/lib`.
- `/app/llama-server`, `/app/llama-cli`, `/app/llama-bench`; model path `/models`; port `8080`.
- CPU backends are **dynamic plugins** (`GGML_BACKEND_DL=ON`): `libggml-hip.so` plus 14
  `libggml-cpu-<arch>.so`, all in `/app`. The start-up log names the pair that was chosen:
  `load_backend: loaded ROCm backend from /app/libggml-hip.so` /
  `load_backend: loaded CPU backend from /app/libggml-cpu-alderlake.so`.
- Built with `LLAMA_CURL=OFF` — the image never downloads anything by itself.
- **No `rocm-smi` inside.** Installing it drags in `rocm-core`, which would overwrite `/opt/rocm`
  together with the patched gfx906 rocBLAS this image is built on. Read VRAM and power from the
  amdgpu sysfs, or from the host.

---

## Testing

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello"}]}'
```

OpenAI-compatible (`/v1/chat/completions`, `/v1/models`, `/v1/embeddings`) plus the native
`/completion` endpoint and a built-in web chat at `http://localhost:8080/`.

---

## Known limits

- The HIP backend is `gfx906`-only. A wave32 card (gfx10/gfx11/gfx12) is not covered by this image.
- Not every architecture is in mainline llama.cpp: `sensenova_loop` is **not** in `b12128` and fails
  with `unknown model architecture`. Check `llama-arch.cpp` in the release you need before pulling a
  model that only exists as a brand-new architecture.
- ROCm's own gfx906 support ended; everything here relies on the rocBLAS built into the image. Do not
  replace `/opt/rocm` inside it.

---

**Maintained by:** [xxDoman](https://github.com/xxDoman) · **Image:** [xxdoman/llama-mi50-rocm7.2](https://hub.docker.com/r/xxdoman/llama-mi50-rocm7.2) · **Built on:** llama.cpp (MIT), ROCm 7.2.1
