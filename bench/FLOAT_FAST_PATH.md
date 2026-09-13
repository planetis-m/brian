# Float conversion fast path

This records the one-word experiment at `d01ccc0` and the two-word product that
the subsequent [coverage audit](FLOAT_COVERAGE.md) restored. The one-word table
sent more near-tie values to the exact stdlib fallback; the audit contains the
per-corpus evidence and the current results. The initial one-word measurements
below remain as experiment history.

`readFloat` scans digits once and makes one `tryFastFloat`/stdlib decision.
The private helper owns signed zero, exact small-number scaling, cached-power
rounding and the decision to fall back. The digit loop uses a `10^18` threshold
and an explicit `complete` flag, eliminating both the digit counter and its
old `20` sentinel. Grammar, public API and runtime dependencies are unchanged.

The cached converter uses a 128-bit power per exponent (`hi`/`lo` words) and two
64-by-64 multiplies, adding the high word of the second product as a carry. Its
tighter uncertainty interval sends fewer rounding boundaries to the existing
exact stdlib converter than the one-word product at `d01ccc0`, at the cost of
one extra multiply per cached conversion. The power's binary exponent is
computed arithmetically instead of stored. Native multiplication uses
`__uint128_t` only for 64-bit GCC/Clang, with standard C casts and passed Nim
symbols; the portable 32-bit-limb implementation remains intact.

## Cachegrind comparison

Measured 2026-09-13 on x86_64, Intel Core Ultra 5 225H, Nim 2.3.1
(`261d5356b0f87fc9b735b4c9d19fb7b407ac3c83`), GCC 16.2.1 20260819 and
Valgrind 3.27.1. These are instruction counts, not timings. All four revisions
were built in one session with `bench/measure_float_path.py`, using identical
source workloads, input and build flags in this checkout.

| Workload | Master `d175ea1` | Original `07d7c00` | One-word `d01ccc0` | Two-word | vs master | vs original | vs one-word |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `floats_fast` | 32,953,110 | 32,553,110 | 32,553,110 | 32,753,096 | -0.61% | +0.61% | +0.61% |
| `floats_fallback` | 299,994,037 | 77,272,689 | 65,772,689 | 66,672,675 | -77.78% | -13.72% | +1.37% |
| `strings_plain` | 47,352,905 | 47,352,905 | 47,352,905 | 47,352,905 | 0.00% | 0.00% | 0.00% |
| `objects_known` | 131,250,093 | 131,250,093 | 131,250,093 | 131,250,093 | 0.00% | 0.00% | 0.00% |
| `integers` | 38,765,167 | 38,765,167 | 38,765,167 | 38,765,181 | +0.00004% | +0.00004% | +0.00004% |
| `kostya_orc` | 4,170,941,110 | 1,987,140,703 | 1,898,315,996 | 1,902,072,532 | -54.40% | -4.28% | +0.20% |
| `kostya_arc` | 4,171,848,810 | 1,990,286,448 | 1,896,061,597 | 1,900,340,578 | -54.45% | -4.52% | +0.23% |

The two-word restore costs about 1.37% on `floats_fallback` relative to the
reverted one-word form, yet stays 77.78% below master and 13.72% below the
original patch. `floats_fast` climbs 0.61% over the one-word form because every
cached conversion pays the second multiply; the fallback workload also routes
most values through the fast path, so the same premium applies there. The guard
workloads are byte-identical except for 14 instructions in `integers`, and both
Kostya configurations stay within 0.23% of the one-word counts. The focused
float benchmarks support the restore and no guard regresses.

Checksums match all four revisions: `1250.0`, `51.75691602819178`, `3700`,
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

Rows one through eight were recorded during the one-word development session and
are retained as history. The restore row uses the fresh four-revision run from
the comparison above.

| Experiment | Fast floats | Fallback floats | Decision |
| --- | ---: | ---: | --- |
| Original patch | 32,611,764 | 77,331,721 | Reference |
| Single helper, explicit completeness, standard C casts | 34,111,746 | 75,431,707 | Fast-float overhead needs addressing |
| Remove Clinger from that helper | 40,811,756 | 74,731,707 | Reject: fast floats +19.64% vs helper |
| Restore Clinger; threshold accumulation replaces digit counter | 32,911,770 | 67,531,721 | Keep |
| Derive exponent; remove exponent field | 32,811,764 | 66,831,721 | Keep |
| One 64-bit cached power and multiply; wider fallback interval | 32,811,925 | 65,931,876 | Keep |
| Unsigned span length, proven by cursor order | 32,611,925 | 65,831,866 | Keep |
| Emit through `hi`/`lo` Nim symbols instead of C tuple fields | 32,611,915 | 65,831,876 | Keep as one-word; reverted below |
| Remove Clinger from final one-multiply algorithm | 37,911,925 | 65,331,866 | Reject: fast floats +16.25% |
| Restore two-word cached product (128-bit power) | 32,753,096 | 66,672,675 | Final: tighter interval, fewer fallbacks |

Both attempts to use cached conversion for small significands regress fast
floats. The retained design therefore has one accumulation operation, one
conversion helper and one exact fallback. Zero and Clinger remain private to
the helper. No assembler path or unchecked pragma was introduced.

The unsigned span length removes a checked signed subtraction that generated
release C showed was evaluated before the helper, including on the smallest
numbers. Both cursor positions are nonnegative and the end is at least the
start. No checks elsewhere were disabled.

The cached-product work is inspired by fast_float's approximate product and
rare fallback approach, but uses its own conservative interval test and Brian's
existing fallback rather than porting a new exact converter. The two-word form
spends one extra multiply to shrink the interval and recover near-tie values the
one-word form rejected; the [coverage audit](FLOAT_COVERAGE.md) quantifies that
tradeoff on halfway-dense corpora.

### Executable sections

`size -A` on the release `floats_fallback` executable, bytes:

| Variant | `.text` | `.rodata` | Cached-power array |
| --- | ---: | ---: | ---: |
| Master `d175ea1` | 29,570 | 12,784 | 0 |
| Original `07d7c00` | 30,338 | 28,464 | 15,624 |
| One-word `d01ccc0` | 30,274 | 18,032 | 5,208 |
| Two-word (final) | 30,242 | 23,248 | 10,416 |

The final table is 651 entries of `tuple[hi, lo: uint64]`, 16 bytes each on both
32- and 64-bit targets, versus 8 bytes for the one-word `uint64` powers. Final
versus original saves 96 bytes of `.text` and 5,216 bytes of `.rodata`. Relative
to the reverted one-word form it spends 5,208 extra bytes of `.rodata`; the size
table is a record, not the decision, which the coverage audit carries. An
`int16` exponent is unnecessary: deriving it improves both instructions and
space compared with the original field.

## Rounding argument and compatibility

For decimal exponent `q`, the generator stores
`C = floor(10^q / 2^e)`, where `e = floor(log2(10^q)) - 127` and
`2^127 <= C < 2^128`. Exact Python integer arithmetic checks normalization,
downward rounding, and the exponent identity
`floor(log2(10^q)) = floor(q * 217706 / 65536)` for every `q` in `-342..308`.
Nim uses arithmetic right shift so negative products round down.

For nonzero significand `s`, let `shift = clz(s)`, `w = s << shift`, and
`P = w*C`, formed from two wide multiplies: the high product `w*C.hi`, then the
high word of `w*C.lo` added as a carry. The cached power is rounded down with
error < 1, and discarding the low product word adds error < 1, so the exact
scaled product lies in `[P, P+2)` in low-word units. Retaining 53 bits discards
10 or 11 bits of the high word.

Let `halfway` be the midpoint of those discarded bits and `remainder` their
computed value. Reject either of these cases:

- `remainder == halfway - 1` and the low word is at least `2^64 - 2`: the
  interval could reach or cross a halfway tie.
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

- `nim c -r -d:release tests/tester.nim`: the tester matrix passes, covering
  debug/release/danger, both SSO variants, native/forced portable multiplication,
  and both ASan variants. Existing ASan configuration is unchanged.
- The expanded float corpus and the full 697,852-value coverage corpus pass as
  actual ARM EABI5 32-bit static Linux executables under `qemu-arm-static`
  10.2.2, compiled with `--cpu:arm --os:linux`, GCC cross 16.1.1 and an ARM
  hard-float glibc 2.41 sysroot. This build does **not** define
  `brianPortableMultiply`: target width selects it. Logs are in `bench/logs/`.
- Generated ARM C contains the limb operations and no `__uint128_t`, `__int128`
  or native product emit. Native generated C contains the intended wide multiply
  with `unsigned long long` casts and no Nim-internal types in the emit block.
- ARM64 was not executed: no `aarch64-linux-gnu-gcc` or AArch64 sysroot is
  installed in this environment. `tests/arm32-corpus.sh` already carries the
  guarded `--cpu:arm64` path and will run it unchanged once both are present;
  `bench/logs/arm64-run.log` records the skip. ESP32-S3 hardware/FreeRTOS was
  likewise not executed. No ESP-specific code, 32-bit native emit or assembly
  was added.
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
python3 bench/float_coverage.py /tmp/brian-coverage
python3 bench/measure_float_path.py /tmp/brian-float-results
nim c -r -d:release tests/tester.nim
tests/arm32-corpus.sh /tmp/brian-arm32 /tmp/brian-coverage
```

The measurement script records the exact command, compiler config messages,
Cachegrind output, checksum and ELF section sizes for each executable. Focused
builds use `nim c --forceBuild:on -d:release -g`, distinct caches and outputs.
The coverage script reconstructs the one-word candidate in its output directory
and reports per-corpus verification checksums and Cachegrind counts; see
[the coverage audit](FLOAT_COVERAGE.md). Kostya uses this separate
configuration, with `arc` for the second build:

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
its unrelated `-lcurl`. `tests/arm32-corpus.sh` runs the exact successful
command, taking the multiarch sysroot from `BRIAN_ARM_SYSROOT` (default
`/tmp/brian-arm/usr/arm-linux-gnueabihf`, extracted from Debian's
`libc6-armhf-cross`, `libc6-dev-armhf-cross` (2.41-11cross1) and
`linux-libc-dev-armhf-cross` (6.12.38-1cross1) packages):

```sh
SYSROOT=${BRIAN_ARM_SYSROOT:-/tmp/brian-arm/usr/arm-linux-gnueabihf}
nim c --cpu:arm --os:linux --cc:gcc \
  --gcc.exe:arm-linux-gnu-gcc --gcc.linkerexe:arm-linux-gnu-gcc \
  --skipParentCfg:on --mm:arc -d:useMalloc -d:release \
  --passC:"--sysroot=$SYSROOT -isystem $SYSROOT/include" \
  --passL:"--sysroot=$SYSROOT -B$SYSROOT/lib -L$SYSROOT/lib -static -fno-link-libatomic" \
  -o:/tmp/brian-arm32/arm32-tfloats tests/tfloats.nim
qemu-arm-static /tmp/brian-arm32/arm32-tfloats
```

`-fno-link-libatomic` suppresses GCC 16's automatic link to the cross-package's
missing `libatomic_asneeded`; no atomic symbols are unresolved and no source
or check is disabled. The ARM build retains threads enabled by system config.
The script builds the same binary plus the coverage probe and runs both under
`qemu-arm-static`.

## References

- [fast_float decimal conversion](https://github.com/fastfloat/fast_float/blob/main/include/fast_float/decimal_to_binary.h)
- [fast_float parsing pipeline](https://github.com/fastfloat/fast_float/blob/main/include/fast_float/parse_number.h)
- [Kostya typed coordinate workload](https://github.com/kostya/benchmarks/blob/master/json/test_jsony.nim)
- [Kostya input generator](https://github.com/kostya/benchmarks/blob/master/json/generate_json.rb)
