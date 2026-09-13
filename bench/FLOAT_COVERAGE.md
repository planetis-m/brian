# Float conversion coverage audit

This audit compares the cached-power product reverted at `d01ccc0` (one 64-bit
power word and one wide multiply) with the two-word product restored in the
working tree. Both retain `readFloat`'s single `tryFastFloat`/stdlib fork and
the same numeric grammar; only the cached-power interval test differs.

The one-word table was `array[-342..308, uint64]` (5,208 bytes, 64-byte powers).
The two-word table is `array[-342..308, tuple[hi, lo: uint64]]` (10,416 bytes,
128-bit powers). `tools/generate_float_powers.py` reproduces the committed
two-word array; `bench/float_coverage.py` reconstructs the one-word candidate in
its output directory and never edits production source.

## Method

From the repository root:

```sh
python3 bench/float_coverage.py /tmp/brian-coverage
```

The script writes the corpora below, then for each variant (`one_word`,
`two_word`):

1. builds a probe against the corpora with `-d:brianFloatStats
   -d:brianFloatVerify -d:release --mm:arc -d:useMalloc --threads:on
   --skipParentCfg:on`;
2. runs every corpus, asserting each parsed binary64 equals the bit pattern
   recorded for the random corpora and, for every corpus, equals both
   `std/parseutils.parseFloat` and `std/json.parseJson`;
3. rebuilds with `-d:brianFloatProfile`, which brackets the parse loop with
   `CACHEGRIND_START_INSTRUMENTATION`/`STOP`, and runs each corpus under
   Cachegrind with `--cache-sim=no --branch-sim=no --instr-at-start=no`.

The absolute include in the generated probe prevents an ancestor `nim.cfg` from
silently loading production source for both variants. Both builds use the same
flags, so per-corpus counts are comparable. Instruction counts, not wall clock,
drive the decision.

## Corpora

| Corpus | Values | Bytes | SHA-256 |
| --- | ---: | ---: | --- |
| `random_17digits` | 200,000 | 4,789,832 | `ee2880fd973d29d6219251735b8ddbeb715c096ae51c6e2a44e0d0453187983d` |
| `shortest_roundtrip` | 200,000 | 4,690,303 | `03cbb85adbf5c25688c8cbd861c492b35c21201f7b47bbbd782e5e6cc5068cff` |
| `random_decimals` | 200,000 | 3,121,726 | `2634b455c335e6e9ffb8eca1373b5e4ed6331c7b8ae963886bd3cf63be3424e2` |
| `compact_halfway_neighbors` | 60,000 | 1,278,000 | `13e9330091e91c0c4a9094ec25ca5a760973a103e39f8d526dc0ce83c81fca5c` |
| `exact_halfway_neighbors` | 30,000 | 8,644,650 | `5bdc7191ea804fb44703d86a6af83c734190c6da3348ad5143d5bed0ac1eaff4` |
| `exponent_boundaries` | 7,852 | 129,768 | `ff5c1eff13f6be33e131095dfa0b9c8e251107b77efb945273967d32f1738de4` |

Total: 697,852 values. `random_17digits` and `shortest_roundtrip` sample uniform
binary64 bit patterns; the latter prints each value with Python's shortest
round-trip spelling. `random_decimals` uses arbitrary decimal spellings and
exponents. `compact_halfway_neighbors` and `exact_halfway_neighbors` place
values one decimal unit either side of binary64 halfway ties. The `.bits`
sidecars for the two uniform corpora record the exact expected binary64 words.

## Bit verification

Every value in every corpus matched `parseutils.parseFloat`, `std/json`
`parseJson` and, where a `.bits` sidecar exists, the recorded bit pattern, for
both variants. The two probe runs exited zero with identical per-corpus
checksums. No input was found where the one-word product returns different
bits; its regression is coverage and throughput, not observed wrong results.

## Conversion-reason coverage

Counts from `-d:brianFloatStats` (columns are one-word then two-word):

| Corpus | `fcCached` | `fcHalfway` | `fcNonNormal` | Other |
| --- | ---: | ---: | ---: | --- |
| `random_17digits` | 198,425 / 198,425 | 0 / 0 | 87 / 87 | 1,488 `fcClinger` |
| `shortest_roundtrip` | 192,708 / 192,757 | 49 / 0 | 87 / 87 | 7,156 `fcClinger` |
| `random_decimals` | 172,044 / 172,167 | 132 / 6 | 10,615 / 10,618 | 11,271 `fcClinger`, 5,938 `fcExponent` |
| `compact_halfway_neighbors` | 38,000 / 40,000 | 22,000 / 20,000 | 0 / 0 | - |
| `exact_halfway_neighbors` | 104 / 108 | 58 / 54 | 0 / 0 | 29,838 `fcIncomplete` |
| `exponent_boundaries` | 7,114 / 7,124 | 16 / 6 | 426 / 426 | 270 `fcClinger`, 24 `fcExponent`, 2 `fcZero` |

The two-word product sends 2,189 fewer near-tie values to the exact stdlib
fallback overall, 2,000 of them in `compact_halfway_neighbors`. The extra
cached conversions are the intended effect of its tighter uncertainty interval.

## Instruction counts

Cachegrind `I refs` for the instrumented parse loop, one-word then two-word:

| Corpus | One-word | Two-word | Delta |
| --- | ---: | ---: | ---: |
| `random_17digits` | 107,568,758 | 109,556,442 | +1,987,684 |
| `shortest_roundtrip` | 105,798,359 | 107,604,218 | +1,805,859 |
| `random_decimals` | 106,556,087 | 108,019,259 | +1,463,172 |
| `compact_halfway_neighbors` | 68,852,359 | 65,606,359 | -3,246,000 |
| `exact_halfway_neighbors` | 642,807,027 | 642,640,609 | -166,418 |
| `exponent_boundaries` | 4,116,345 | 4,167,604 | +51,259 |

The two-word product costs roughly ten extra instructions per cached conversion
(the second wide multiply and its carry), but each avoided fallback saves the
much larger exact stdlib conversion. Ordinary decimal input pays the small
premium; tie-heavy input wins, and the wider `fcCached` coverage is the point.

## Decision

The two-word product is kept. Over 697,852 values neither form produced a wrong
result, so the regression is coverage and throughput rather than demonstrated
incorrect rounding. The two-word product sends 2,189 fewer near-tie values to
the exact fallback, and its tighter handling of the low product word is
what it spends an extra multiply on. On ordinary decimal input it pays roughly
ten instructions per cached conversion; on the tie-heavy
`compact_halfway_neighbors` corpus it saves about 3.25M instructions for 60,000
values by avoiding the exact fallback. Reverting to one word only saves about
5 KB of table; if that matters later, keep the two-word math and add a
strided/optional table behind a define in a separate, measured follow-up.

The classification regression is guarded by `tests/tfloatstats.nim`, which
asserts that `1e126`, `1e210` and `4611686018427388415e0` reach `fcCached`. The
one-word product sends those same inputs to `fcHalfway` and the test fails.
