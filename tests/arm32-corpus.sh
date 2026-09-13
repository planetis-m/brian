#!/usr/bin/env bash
# Cross-target float-conversion checks under qemu.
#
# Usage: tests/arm32-corpus.sh [WORK_DIR] [CORPORA_DIR]
#
#   WORK_DIR     scratch and log directory (default: /tmp/brian-arm32)
#   CORPORA_DIR  corpora written by `python3 bench/float_coverage.py`
#                (optional; coverage checks are skipped when unset or empty)
#
# The sysroots are expected to be already extracted. Nothing here downloads,
# extracts or pins a toolchain; it only runs the cross compiler and emulator.
# When the sysroot must be rebuilt, the original armhf files came from Debian's
# cross-toolchain-base packages (2.41-11cross1, glibc 2.41):
#
#   libc6-armhf-cross_2.41-11cross1_all.deb
#   libc6-dev-armhf-cross_2.41-11cross1_all.deb
#   linux-libc-dev-armhf-cross_6.12.38-1cross1_all.deb
#
# from https://deb.debian.org/debian/pool/main/c/cross-toolchain-base/ .
# The compiler was Red Hat Cross GCC 16.1.1 (`arm-linux-gnu-gcc`, configured
# hard-float for armv7-a/vfpv3-d16) and the emulator `qemu-arm-static` 10.2.2.
#
# Environment:
#   BRIAN_ARM_SYSROOT    armhf sysroot (default /tmp/brian-arm/usr/arm-linux-gnueabihf)
#   BRIAN_ARM64_GCC      aarch64 cross compiler (default aarch64-linux-gnu-gcc)
#   BRIAN_ARM64_SYSROOT  aarch64 sysroot (default /tmp/brian-arm64/usr/aarch64-linux-gnu)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=${1:-/tmp/brian-arm32}
CORPORA=${2:-}

ARM_SYSROOT=${BRIAN_ARM_SYSROOT:-/tmp/brian-arm/usr/arm-linux-gnueabihf}
ARM64_GCC=${BRIAN_ARM64_GCC:-aarch64-linux-gnu-gcc}
ARM64_SYSROOT=${BRIAN_ARM64_SYSROOT:-/tmp/brian-arm64/usr/aarch64-linux-gnu}

mkdir -p "$WORK"

# The sysroot root is the multiarch subdirectory, so the compiler needs its
# include and library directories named explicitly. `-fno-link-libatomic`
# suppresses GCC 16's automatic link to the cross package's missing
# `libatomic_asneeded`; no atomic symbols are left unresolved.
arm32_flags() {
  local sysroot=$1
  printf '%s\0' \
    --cpu:arm --os:linux --cc:gcc \
    --gcc.exe:arm-linux-gnu-gcc --gcc.linkerexe:arm-linux-gnu-gcc \
    --skipParentCfg:on --mm:arc -d:useMalloc -d:release \
    "--passC:--sysroot=$sysroot -isystem $sysroot/include" \
    "--passL:--sysroot=$sysroot -B$sysroot/lib -L$sysroot/lib -static -fno-link-libatomic"
}

arm64_flags() {
  local gcc=$1 sysroot=$2
  printf '%s\0' \
    --cpu:arm64 --os:linux --cc:gcc \
    "--gcc.exe:$gcc" "--gcc.linkerexe:$gcc" \
    --skipParentCfg:on --mm:arc -d:useMalloc -d:release \
    "--passC:--sysroot=$sysroot -isystem $sysroot/include" \
    "--passL:--sysroot=$sysroot -B$sysroot/lib -L$sysroot/lib -static -fno-link-libatomic"
}

read_flags() { local -n out=$1; shift; mapfile -d '' out < <("$@"); }

build_and_run() {
  local arch=$1 qemu=$2 label=$3; shift 3
  local -a flags=("$@")
  local bin="$WORK/$arch-tfloats"
  echo "building tfloats.nim for $arch" >&2
  nim c "${flags[@]}" --nimcache:"$WORK/$arch-tfloats-cache" \
    -o:"$bin" "$ROOT/tests/tfloats.nim" > "$WORK/$arch-build.log" 2>&1 \
    || { cat "$WORK/$arch-build.log" >&2; echo "$label build failed" >&2; return 1; }
  "$qemu" "$bin" >> "$WORK/$arch-run.log" 2>&1 \
    || { echo "$label tfloats run failed; see $WORK/$arch-run.log" >&2; return 1; }
  echo "PASS tfloats.nim ($label)" >> "$WORK/$arch-run.log"

  [ -n "$CORPORA" ] && [ -d "$CORPORA" ] || return 0
  compgen -G "$CORPORA/*.txt" > /dev/null || return 0

  local cov="$WORK/$arch-coverage"
  echo "building float_coverage.nim for $arch" >&2
  nim c "${flags[@]}" --threads:on -d:brianFloatStats -d:brianFloatVerify \
    --path:"$ROOT/src" --nimcache:"$WORK/$arch-coverage-cache" -o:"$cov" \
    "$ROOT/bench/float_coverage.nim" > "$WORK/$arch-coverage-build.log" 2>&1 \
    || { cat "$WORK/$arch-coverage-build.log" >&2; echo "$label coverage build failed" >&2; return 1; }
  : > "$WORK/$arch-coverage.log"
  local corpus
  for corpus in "$CORPORA"/*.txt; do
    echo "== $(basename "$corpus") ==" >> "$WORK/$arch-coverage.log"
    "$qemu" "$cov" "$corpus" >> "$WORK/$arch-coverage.log" 2>&1 \
      || { echo "$label coverage run failed on $corpus" >&2; return 1; }
  done
}

{
  echo "host: $(uname -srm)"
  echo "nim: $(nim --version | head -1)"
  echo "arm32 compiler: $(arm-linux-gnu-gcc -dumpmachine) $(arm-linux-gnu-gcc --version | head -1)"
  echo "arm32 emulator: $(qemu-arm-static --version | head -1)"
  echo "arm32 sysroot: $ARM_SYSROOT"
  echo "arm64 compiler: $($ARM64_GCC --version 2>/dev/null | head -1 || echo unavailable)"
  echo "arm64 emulator: $(qemu-aarch64-static --version | head -1)"
  echo "arm64 sysroot: $ARM64_SYSROOT"
} > "$WORK/toolchain.log"
cat "$WORK/toolchain.log"

: > "$WORK/arm32-build.log"; : > "$WORK/arm32-run.log"
read_flags ARM_FLAGS arm32_flags "$ARM_SYSROOT"
build_and_run arm32 qemu-arm-static "ARM32" "${ARM_FLAGS[@]}"

status=0
if command -v "$ARM64_GCC" >/dev/null 2>&1 && \
   [ -f "$ARM64_SYSROOT/lib/libc.so.6" ] && [ -f "$ARM64_SYSROOT/include/stdio.h" ]; then
  : > "$WORK/arm64-build.log"; : > "$WORK/arm64-run.log"
  read_flags ARM64_FLAGS arm64_flags "$ARM64_GCC" "$ARM64_SYSROOT"
  build_and_run arm64 qemu-aarch64-static "ARM64" "${ARM64_FLAGS[@]}" || status=1
else
  echo "ARM64 skipped: $ARM64_GCC or a sysroot at $ARM64_SYSROOT is unavailable" >&2
  echo "ARM64 skipped: toolchain/sysroot unavailable" >> "$WORK/arm64-run.log"
fi

{
  echo
  echo "binary sha256:"
  sha256sum "$WORK"/arm32-tfloats "$WORK"/arm64-tfloats 2>/dev/null || true
} >> "$WORK/toolchain.log"

echo "logs in $WORK" >&2
exit $status
