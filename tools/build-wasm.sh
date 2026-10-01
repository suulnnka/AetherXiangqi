#!/bin/bash
# 构建 wasm 引擎并放到页面可引用的位置。与 build.zig 的 wasm 目标等价:
#   zig build-exe src/wasm.zig -O ReleaseFast -target wasm32-freestanding \
#     -fstrip -fno-entry -rdynamic -femit-bin=wasm/aetherx.wasm
set -e
cd "$(dirname "$0")/.."
mkdir -p wasm
zig build-exe src/wasm.zig -O ReleaseFast -target wasm32-freestanding \
  -fstrip -fno-entry -rdynamic -femit-bin=wasm/aetherx.wasm
echo "wasm/aetherx.wasm: $(stat -c%s wasm/aetherx.wasm) bytes, gzip $(gzip -c wasm/aetherx.wasm | wc -c) bytes"
