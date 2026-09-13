# Streamlined float conversion

`readFloat` scans digits once and makes one `tryFastFloat`/stdlib decision.
The private helper owns signed zero, exact small-number scaling, cached-power
rounding and the decision to fall back. The digit loop uses a `10^18` threshold
and an explicit `complete` flag, eliminating both the digit counter and its
old `20` sentinel. Grammar, public API and runtime dependencies are unchanged.

Unlike `07d7c00`, the cached converter needs only one 64-by-64 multiply and a
64-bit power per exponent. Its wider uncertainty interval sends a few more
rounding boundaries to the existing exact stdlib converter. The power's binary
exponent is computed arithmetically instead of stored. Native multiplication
uses `__uint128_t` only for 64-bit GCC/Clang, with standard C casts and passed
Nim symbols; the portable 32-bit-limb implementation remains intact.

## Cachegrind comparison

Measured 2026-09-13 on x86_64, Intel Core Ultra 5 225H, Nim 2.3.1
(`261d5356b0f87fc9b735b4c9d19fb7b407ac3c83`), GCC 16.2.1 20260819 and
Valgrind 3.27.1. These are instruction counts, not timings. Each column uses
identical source workloads, input and build flags in this checkout.

| Workload | Master `d175ea1` | Original `07d7c00` | Streamlined | vs master | vs original |
| --- | ---: | ---: | ---: | ---: | ---: |
| `floats_fast` | 33,011,764 | 32,611,764 | 32,611,915 | -1.21% | +0.0005% |
| `floats_fallback` | 300,753,069 | 77,331,721 | 65,831,876 | -78.11% | -14.87% |
| `strings_plain` | 47,411,927 | 47,411,927 | 47,412,090 | +0.0003% | +0.0003% |
| `objects_known` | 131,308,616 | 131,308,616 | 131,308,779 | +0.0001% | +0.0001% |
| `integers` | 38,824,251 | 38,824,251 | 38,824,392 | +0.0004% | +0.0004% |
| `kostya_orc` | 4,168,543,939 | 2,014,501,981 | 1,892,343,639 | -54.60% | -6.06% |
| `kostya_arc` | 4,170,941,142 | 1,990,286,397 | 1,900,937,276 | -54.42% | -4.49% |

The tiny positive guard differences are at most 163 instructions for the entire
process, below startup noise. Fast floats match the original patch; fallback
floats and both Kostya configurations improve substantially.

Checksums match all three revisions: `1250.0`, `51.75691602819178`, `3700`,
`300`, `39199050`, and, for both Kostya memory managers:

```text
(x: -4.996779998147934e-30, y: 4.9972761614424696e+30, z: 0.4995172230528198)
```

The old `/tmp/1.json` and untracked Kostya harness were unavailable. The committed
harness follows the upstream typed coordinate-averaging workload, with
Cachegrind instrumentation around `calc` only. `bench/kostya/generate.py`
reproduces the upstream schema, 524,288 coordinates, coordinate scales, ignored
names/options and pretty printing with a fixed Python seed of `20260913`.
The resulting `/tmp/1.json` SHA-256 is:

```text
c79f2e9f167f9fa8f4b7f72d8dea8bac274f6f1a6b31c13e3e67ac104c806bc8
```

These fresh Kostya counts should not be compared directly with the earlier
RapidJSON result, which used a different payload and compiler context.

## Experiments, one dimension at a time

All rows below use the focused release flags described under Reproduction.

| Experiment | Fast floats | Fallback floats | Decision |
| --- | ---: | ---: | --- |
| Original patch | 32,611,764 | 77,331,721 | Reference |
| Single helper, explicit completeness, standard C casts | 34,111,746 | 75,431,707 | Fast-float overhead needs addressing |
| Remove Clinger from that helper | 40,811,756 | 74,731,707 | Reject: fast floats +19.64% vs helper |
| Restore Clinger; threshold accumulation replaces digit counter | 32,911,770 | 67,531,721 | Keep |
| Derive exponent; remove exponent field | 32,811,764 | 66,831,721 | Keep |
| One 64-bit cached power and multiply; wider fallback interval | 32,811,925 | 65,931,876 | Keep |
| Unsigned span length, proven by cursor order | 32,611,925 | 65,831,866 | Keep |
| Emit through `hi`/`lo` Nim symbols instead of C tuple fields | 32,611,915 | 65,831,876 | Final |
| Remove Clinger from final one-multiply algorithm | 37,911,925 | 65,331,866 | Reject: fast floats +16.25% |

Both attempts to use cached conversion for small significands regress fast
floats. The retained design therefore has one accumulation operation, one
conversion helper and one exact fallback. Zero and Clinger remain private to
the helper. No assembler path or unchecked pragma was introduced.

The unsigned span length removes a checked signed subtraction that generated
release C showed was evaluated before the helper, including on the smallest
numbers. Both cursor positions are nonnegative and the end is at least the
start. No checks elsewhere were disabled.

The one-multiply experiment is inspired by fast_float's approximate product
and rare fallback approach, but uses its own conservative interval test and
Brian's existing fallback rather than porting a new exact converter.

### Executable sections

`size -A` on the release `floats_fallback` executable, bytes:

| Variant | `.text` | `.rodata` | Cached-power array |
| --- | ---: | ---: | ---: |
| Master | 29,570 | 12,784 | 0 |
| Original patch | 30,338 | 28,464 | 15,624 |
| Threshold accumulation, original table | 30,306 | 28,464 | 15,624 |
| Derived exponent, two-word table | 30,338 | 23,248 | 10,416 |
| One-word table | 30,290 | 18,032 | 5,208 |
| Final | 30,274 | 18,032 | 5,208 |

Final vs original saves 64 bytes of `.text` and 10,432 bytes of `.rodata`.
The table itself saves 10,416 bytes; the remainder is alignment. The final
array is 5,208 bytes on both 32- and 64-bit targets, without tuple padding.
An `int16` exponent is unnecessary: deriving it improves both instructions
and space compared with the original field.

## Rounding argument and compatibility

For decimal exponent `q`, the generator stores
`C = floor(10^q / 2^e)`, where `e = floor(log2(10^q)) - 63` and
`2^63 <= C < 2^64`. Exact Python integer arithmetic checks normalization,
downward rounding, and the exponent identity
`floor(log2(10^q)) = floor(q * 217706 / 65536)` for every `q` in `-342..308`.
Nim uses arithmetic right shift so negative products round down.

For nonzero significand `s`, let `shift = clz(s)`, `w = s << shift`, and
`P = w*C`, represented by the wide multiply's high and low words. The exact
scaled decimal is in `[P, P+w)`. Since `w < 2^64`, the true high word is at
most one greater than the computed high word. Its leading bit is at position
126 or 127; retaining 53 bits discards 10 or 11 bits of the high word.

Let `halfway` be the midpoint of those discarded bits and `remainder` their
computed value. Reject either of these cases:

- `remainder == halfway - 1`: the interval could reach or cross a halfway tie.
- `remainder == halfway` and the low word is zero: the lower endpoint is a tie.

Otherwise the entire interval rounds to one binary64 value. Round upward when
`remainder >= halfway`, account for mantissa carry, and construct its bits.
If the interval crosses a power-of-two boundary, that same carry produces the
correct exponent. Subnormal results and overflow remain on stdlib fallback.
A carry to minimum normal is safe: rounding upward at the finer hypothetical
normal spacing also rounds upward at subnormal spacing.

The original patch's 64-byte guard is retained on cached conversion to preserve
stdlib's bounded scratch-buffer behavior and keep saturated scan counters out
of conversion. Incomplete significands always use stdlib. The original zero
and Clinger eligibility is retained, including long spellings they accepted.
The `10^18` accumulation threshold stores at most 19 significant digits and
naturally absorbs leading zeros; any subsequent digit marks it incomplete.

The native and portable tests preserve the entire reverted regression corpus:
exact bits, opposite halfway ties, subnormals, overflow, all cached exponents,
20,000 seeded decimals, long significands/spellings, permissive grammar and
error cases. New regressions exercise threshold completeness, neighbors of
halfway ties at different scales, and signed zeros inside/outside Clinger.
Numeric fixtures compare binary64 with `parseutils.parseFloat` and
`std/json.parseJson`, and compare binary32 narrowing.

Existing compatibility exceptions remain explicit: permissive zero-like tokens
and signed zero with huge exponents preserve Brian's old behavior even when
stdlib differs. Large integer-spelling fixtures use `e0` to select std/json's
float reader instead of its overflowing integer reader. These are fixture
clarifications, not parser behavior changes.

## Validation and portability

- `nim c -r -d:release tests/tester.nim`: all 21 configurations pass, covering
  debug/release/danger, both SSO variants, native/forced portable multiplication,
  and both ASan variants. Existing ASan configuration is unchanged.
- The expanded float corpus passes as an actual ARM EABI5 32-bit static Linux
  executable under `qemu-arm-static` 10.2.2, compiled with
  `--cpu:arm --os:linux`, GCC cross 16.1.1 and an ARM hard-float glibc 2.41 sysroot.
  This build does **not** define `brianPortableMultiply`: target width selects it.
- Generated ARM C contains the limb operations and no `__uint128_t`, `__int128`
  or native product emit. Native generated C contains the intended wide multiply
  with `unsigned long long` casts and no Nim-internal types in the emit block.
- ESP32-S3 hardware/FreeRTOS and ARM64 were not executed in this environment.
  No ESP-specific code, 32-bit native emit or assembly was added.
- Generator reproduces the committed table; `git diff --check` passes.

## Reproduction

Run from the repository root. Each probe inherits `bench/config.nims` and the
ancestor `clean-design-rewrite/nim.cfg`: `--mm:atomicArc`, `-d:useMalloc`,
`--threads:on`, `--passC:-DCURL_DISABLE_TYPECHECK`, `--passL:-lcurl`, and Atlas
search paths. System configs are `/usr/lib64/nim/config/nim.cfg` and
`/usr/lib64/nim/config/config.nims`. All revisions use the same context.

```sh
python3 tools/generate_float_powers.py
python3 bench/kostya/generate.py
python3 bench/measure_float_path.py /tmp/brian-float-results
nim c -r -d:release tests/tester.nim
```

The measurement script records the exact command, compiler config messages,
Cachegrind output, checksum and ELF section sizes for each executable. Focused
builds use `nim c --forceBuild:on -d:release -g`, distinct caches and outputs.
The initial focused measurements also used fresh distinct caches; subsequent
builds explicitly force recompilation to avoid stale C after failed builds.
Kostya uses this separate configuration, with `arc` for the second build:

```sh
nim c --forceBuild:on -d:danger --mm:orc --opt:speed \
  --passC:'-Wall -Wextra -pedantic -Wcast-align -O3 -march=native -flto=auto -Wa,-mbranches-within-32B-boundaries' \
  --passL:'-march=native -flto=auto' bench/kostya/kostya_brian.nim
```

Release and danger are never combined. Profiling uses:

```sh
valgrind --tool=cachegrind --cache-sim=no --branch-sim=no \
  --cachegrind-out-file=/tmp/probe.cg /path/to/probe
```

For Kostya add `--instr-at-start=no`; its harness enables instrumentation only
around `calc`, excluding file reading and smoke checks.

The ARM cross-build skips the x86 host's ancestor configuration, in particular
its unrelated `-lcurl`. Its exact successful command, using the sysroot
extracted under `/tmp/brian-arm` from Debian's `libc6-armhf-cross`,
`libc6-dev-armhf-cross` (2.41-11cross1), and `linux-libc-dev-armhf-cross`
(6.12.38-1cross1) packages:

```sh
nim c --cpu:arm --os:linux --cc:gcc \
  --gcc.exe:arm-linux-gnu-gcc --gcc.linkerexe:arm-linux-gnu-gcc \
  --skipParentCfg:on --mm:arc -d:useMalloc -d:release \
  --passC:'--sysroot=/tmp/brian-arm -isystem /tmp/brian-arm/usr/arm-linux-gnueabihf/include' \
  --passL:'--sysroot=/tmp/brian-arm -B/tmp/brian-arm/usr/arm-linux-gnueabihf/lib -L/tmp/brian-arm/usr/arm-linux-gnueabihf/lib -static -fno-link-libatomic' \
  --nimcache:/tmp/brian-float-v2/arm-cache \
  -o:/tmp/brian-float-v2/arm-corpus tests/tfloats.nim
qemu-arm-static /tmp/brian-float-v2/arm-corpus
```

`-fno-link-libatomic` suppresses GCC 16's automatic link to the cross-package's
missing `libatomic_asneeded`; no atomic symbols are unresolved and no source
or check is disabled. The ARM build retains threads enabled by system config.

Raw logs, binaries and generated C for this run are in `/tmp/brian-float-v2/`;
`matrix.log`, `arm-build.log` and `arm-run.log` record validation.

## References

- [fast_float decimal conversion](https://github.com/fastfloat/fast_float/blob/main/include/fast_float/decimal_to_binary.h)
- [fast_float parsing pipeline](https://github.com/fastfloat/fast_float/blob/main/include/fast_float/parse_number.h)
- [Kostya typed coordinate workload](https://github.com/kostya/benchmarks/blob/master/json/test_jsony.nim)
- [Kostya input generator](https://github.com/kostya/benchmarks/blob/master/json/generate_json.rb)
