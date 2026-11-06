#!/usr/bin/env bash
# Build llama.cpp b12128 (v5) for gfx906 in the ROCm dev container.
#
#   ./build.sh /path/with/a/llama.cpp/checkout
#
# Result: out/bin (llama-server, llama-cli, llama-bench) and out/lib (libggml-hip.so plus the
# 14 libggml-cpu-<arch>.so variants). Dockerfile copies both into the image.
#
# Why the flags matter:
#   GGML_HIP=ON + AMDGPU_TARGETS=gfx906   this runs on Vega 20 only
#   GGML_BACKEND_DL=ON                    backends as plugins, discovered next to the binary
#   GGML_CPU_ALL_VARIANTS=ON              one libggml-cpu-<arch>.so per CPU generation, chosen by
#                                         CPUID at start-up; without it a pre-Haswell host fails with
#                                         "make_cpu_buft_list: no CPU backend found"
#   LLAMA_CURL=OFF                        the image never downloads anything by itself
set -euo pipefail

SRC="${1:-$(pwd)/llama.cpp}"
WORK="${2:-$(pwd)}"
LLAMA_COMMIT="${LLAMA_COMMIT:-a01dff9}"
IMAGE="${IMAGE:-rocm/dev-ubuntu-24.04:7.2.1}"

if [ ! -d "$SRC/.git" ]; then
    echo "no llama.cpp checkout at $SRC" >&2
    exit 2
fi

cat > "$WORK/build-in-container.sh" <<'EOS'
set -e
export DEBIAN_FRONTEND=noninteractive
echo "=== [1/6] deps ==="
apt-get update -qq
apt-get install -y -qq cmake ninja-build git build-essential ccache file \
  rocblas-dev hipblas-dev hipblaslt-dev 2>&1 | tail -3

echo "=== [2/6] tree ==="
git config --global --add safe.directory /src/llama.cpp
cd /src/llama.cpp
git log -1 --pretty='HEAD %h %ad %s' --date=short

echo "=== [3/6] configure ==="
rm -rf build && mkdir -p build && cd build
cmake .. \
  -DGGML_HIP=ON \
  -DAMDGPU_TARGETS=gfx906 \
  -DGPU_TARGETS=gfx906 \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_HIP_UMA=OFF \
  -DCMAKE_HIP_COMPILER=/opt/rocm/lib/llvm/bin/clang++ \
  -DCMAKE_PREFIX_PATH=/opt/rocm \
  -DLLAMA_CURL=OFF \
  -DBUILD_SHARED_LIBS=ON \
  -DGGML_BACKEND_DL=ON \
  -DGGML_CPU_ALL_VARIANTS=ON > /src/build-configure.log 2>&1

echo "=== [4/6] build ==="
cmake --build . --config Release -j"$(nproc)" \
  --target llama-server llama-cli llama-bench > /src/build-build.log 2>&1 || {
    tail -50 /src/build-build.log; exit 1; }

echo "=== [5/6] result -> /src/out ==="
rm -rf /src/out && mkdir -p /src/out/bin /src/out/lib
cp bin/llama-server bin/llama-cli bin/llama-bench /src/out/bin/
cp -a bin/*.so bin/*.so.* /src/out/lib/ 2>/dev/null || true

echo "=== [6/6] release gate: CPU variants ==="
VAR=$(ls /src/out/lib/libggml-cpu-*.so 2>/dev/null | wc -l)
echo "    libggml-cpu-<arch>.so variants: $VAR (need >= 10)"
[ "$VAR" -lt 10 ] && { echo "FAIL: incomplete CPU variant set, image must not ship"; exit 3; }
LD_LIBRARY_PATH=/src/out/lib /src/out/bin/llama-server --version 2>&1 | head -3
echo "############ DONE $(date '+%F %T') ############"
EOS

docker run --rm --network host --name llama-build \
  -v "$SRC":/src/llama.cpp \
  -v "$WORK":/src \
  -v "$WORK/build-in-container.sh":/build.sh:ro \
  "$IMAGE" bash /build.sh

echo "built: $WORK/out/bin/llama-server"
echo "note:  the published image layers this on the v4 tag, which carries the rocBLAS 5.2.0"
echo "       built from source for gfx906. Rebuilding that from scratch is a separate job."
