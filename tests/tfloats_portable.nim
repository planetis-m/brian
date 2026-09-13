## Differential test for the portable wide multiply. 32-bit targets take this
## path, so it is compared against the compiler's 128-bit product on the host.

import brian_float
import std/assertions

proc next(state: var uint64): uint64 {.inline.} =
  state = state xor (state shl 13)
  state = state xor (state shr 7)
  state = state xor (state shl 17)
  state

var state = 0x9e3779b97f4a7c15'u64
for _ in 0 ..< 200_000:
  let a = next(state)
  let b = next(state)
  doAssert portableMultiplyWide(a, b) == multiplyWide(a, b)

for (a, b) in [
    (0'u64, 0'u64),
    (0'u64, high(uint64)),
    (1'u64, high(uint64)),
    (high(uint64), high(uint64)),
    (0xffffffff'u64, 0xffffffff'u64),
    (1'u64 shl 63, 3'u64)]:
  doAssert portableMultiplyWide(a, b) == multiplyWide(a, b)
