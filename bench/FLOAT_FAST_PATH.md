# PR: accelerate float conversion with conservative cached powers

Scientific notation and long significands previously required copying the
number token and rescanning it through Nim's float converter. The new private
Eisel–Lemire-style conversion reuses the existing significand and decimal
exponent, multiplying by a cached 128-bit power and accepting only unambiguous
binary64 rounding. The Clinger path, grammar, error messages, public API and
stdlib fallback remain in place. There is no new runtime or build dependency.

## Cachegrind results

Measured 2026-09-11 against source baseline `f1d9683`, with Nim 2.3.1
(`c87926d`) and Valgrind 3.27.1. These are instruction counts, not timings.

| Workload | Before | After | Change |
| --- | ---: | ---: | ---: |
| `floats_fast` | 33,008,602 | 32,608,602 | -1.21% |
| `floats_fallback` | 300,049,911 | 77,328,563 | -74.23% |
| `strings_plain` | 47,408,178 | 47,408,178 | +0.00% |
| `objects_known` | 131,304,867 | 131,304,867 | +0.00% |
| `integers` | 38,821,081 | 38,821,081 | +0.00% |
| `kostya_orc` | 4,181,910,484 | 2,001,148,808 | -52.15% |
| `kostya_arc` | 4,177,397,180 | 2,000,624,546 | -52.11% |

Both Kostya builds are below the 2.6 billion merge gate and the recorded
RapidJSON Precise result of 3,038,329,919. Every focused benchmark meets the
1% regression gate. These fresh baselines differ slightly from the handoff's
older counts; before and after here use identical commands and input.

All checksums are unchanged: `1250.0` (fast floats), `51.75691602819178`
(fallback floats), `3700` (strings), `300` (objects), `39199050` (integers),
and the following Kostya output under both memory managers:

```text
(x: -4.998120755439264e-30, y: 5.00116543624176e+30, z: 0.500091935597192)
```

The existing `/tmp/1.json` payload has SHA-256
`e46db1a86ca42beafba15a70c01fbe1c54bbdb19618c473827bfd99fb0464350`.

## Rounding argument and compatibility

The generator uses exact Python integer arithmetic to store
`C = floor(10^q / 2^e)` with `2^127 <= C < 2^128`. Its assertions verify
normalization and the downward rounding interval. The committed table is
used directly; Python is only needed to regenerate it.

For a nonzero significand normalized to a 64-bit integer `w`, two wide
multiplications compute `P = floor(w*C / 2^64)`. Dropping the lowest product
word loses less than one unit; truncating the cached power contributes less
than one more. Therefore the exact scaled decimal is in `[P, P+2)`.

The converter extracts the leading 53 bits. It falls back if this interval
could touch a halfway boundary, including exact ties, and otherwise rounds
to the unique nearest binary64 value. Mantissa carry adjusts the exponent.
Subnormals and overflow remain on the stdlib fallback when the resulting
exponent is outside the normal range. A carry to minimum normal is safe:
any value that rounds up to it at this finer spacing also rounds up at the
subnormal spacing.

The digit counter now marks significands exceeding 19 digits as incomplete.
Only spellings of at most 64 bytes enter the new converter. This conservative
limit preserves the stdlib converter's bounded scratch-buffer behavior on
long leading-zero spellings, and prevents Brian's saturated scan counters
from being mistaken for complete exponents. Those cases retain their old
results even where the stdlib result differs from exact decimal arithmetic.
The existing Clinger and zero paths are unchanged.

The multiplication uses GCC/Clang's native 128-bit integer on 64-bit targets
and a portable 32-bit-limb implementation elsewhere. Both are covered by the
same regression corpus, with no unchecked pragmas. The general cached-power
approach is described in [Lemire's float parsing paper](https://arxiv.org/abs/2101.11408);
this implementation uses a conservative interval test and retains fallback.

## Validation

- `nim c -r -d:release tests/tester.nim`: all 21 configurations pass,
  including debug/release/danger, both SSO variants and both ASan variants.
- The native and portable multiplication paths both run exact-bit fixtures,
  halfway cases, normal/subnormal/overflow boundaries, every cached exponent,
  20,000 seeded decimal cases, long significands, long leading-zero spellings,
  huge exponents and permissive/error grammar checks.
- Valid numeric cases compare binary64 bits against both `parseutils.parseFloat`
  and `std/json.parseJson`, and check binary32 narrowing as well.
- Separate old/new executable comparison: 100,654 inputs, zero mismatches in
  returned binary64 bits or acceptance, including signed zeros and long inputs.
- Generated release C inspected: native wide multiply is emitted; no checks
  were disabled. `git diff --check` passes.

## Reproduction

Build each focused program separately with `nim c -d:release -g`, including
`floats_fast`, `floats_fallback`, `strings_plain`, `objects_known`, `integers`.
The focused builds inherit this checkout's parent configuration
(`--mm:atomicArc`, `-d:useMalloc`, threads on). Kostya explicitly overrides the
memory manager with `--mm:orc` or `--mm:arc` and uses:

```sh
nim c -d:danger --mm:orc --opt:speed \
  --passC:'-Wall -Wextra -pedantic -Wcast-align -O3 -march=native -flto=auto -Wa,-mbranches-within-32B-boundaries' \
  --passL:'-march=native -flto=auto' bench/kostya/kostya_brian.nim
```

Use `--mm:arc` for the second build. Release and danger are never combined.
Profile each executable with:

```sh
valgrind --tool=cachegrind --cache-sim=no --branch-sim=no \
  --cachegrind-out-file=/dev/null ./executable
```

Kostya's instrumentation excludes file reading and measures `calc` only.
Raw build/profile logs are in `/tmp/brian-float-baseline/` and
`/tmp/brian-float-verified/`; the final matrix log is
`/tmp/brian-float-matrix-verified.log`.
