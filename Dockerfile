# llama.cpp b12128 for AMD gfx906 (MI50 / MI60 / Radeon VII)
#
# Layers on the v4 tag, because that image carries the rocBLAS 5.2.0 built from source for gfx906
# (stock ROCm ships no gfx906 GEMM kernels since 6.5) together with ROCm 7.2.1 and the amdgpu
# userland. Everything on top of it is the new engine.
#
# Build:
#   ./build.sh /path/to/llama.cpp          # produces out/bin and out/lib
#   docker build -t xxdoman/llama-mi50-rocm7.2:v5 .
#
# The release gate is in build.sh: fewer than 10 libggml-cpu-<arch>.so variants and it refuses to
# produce output, because a single x86-64-v3 CPU backend breaks on pre-Haswell hosts.

FROM xxdoman/llama-mi50-rocm7.2:v4
WORKDIR /app

# Drop the previous engine, keep the ROCm userland and the patched rocBLAS underneath.
RUN rm -f /app/llama-* /app/libggml* /app/libllama* /app/libmtmd*

COPY out/bin/llama-server /app/llama-server
COPY out/bin/llama-cli    /app/llama-cli
COPY out/bin/llama-bench  /app/llama-bench
COPY out/lib/             /app/

ENV HSA_OVERRIDE_GFX_VERSION=9.0.6 \
    LD_LIBRARY_PATH=/app:/opt/rocm/lib:/opt/rocm/lib64

EXPOSE 8080
ENTRYPOINT ["/app/llama-server"]
CMD ["-m", "/models/model.gguf", "-ngl", "99", "--host", "0.0.0.0", "--port", "8080"]
