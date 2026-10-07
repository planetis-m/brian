# brian performance probes

Each program isolates one parsing path. They intentionally print only a
checksum, never elapsed time. Profile one program at a time with Cachegrind:

```sh
nim c -d:release -g -r strings_plain.nim
valgrind --tool=cachegrind ./strings_plain
```

Use `-d:danger` only as an additional correctness/configuration check; compare
instruction profiles from the same release build and fixed payload.

For matched Brian/jsonx/jsony object comparisons, see
[`compare/README.md`](compare/README.md). Its dependencies and local compiler
paths are intentionally kept out of the repository.

- `strings_plain` — unescaped string fast path and destination allocation.
- `strings_escaped` — escape decoding and Unicode escape handling.
- `unicode_typed` — typed string decoding with BMP escapes and surrogate pairs.
- `unicode_raw` — raw string capture with BMP escapes and surrogate pairs.
- `objects_known` — compile-time `fieldPairs` mapping for known object fields.
- `custom_enums` — custom string matcher dispatch to a tolerant enum.
- `custom_fields` — borrowed-span custom field dispatch and unknown-field skipping.
- `open_fields` — arbitrary keys materialized into their final destination.
- `unknown_skip` — nested unknown object and array skipping.
- `integers` — checked integer accumulation.
- `arrays` — fixed-size array element traversal.
- `tuples` — positional tuple field traversal.
- `sets` — hashed set construction from an array.
- `tables` — string-keyed table construction from an object.
- `floats_fast` — exact scalar float fast path.
- `floats_fallback` — exact float fallback conversion.
- `raw_values` — `RawJson` capture through value skipping.
- `canonical_fields` — canonical re-emission of ordinary and escaped object fields.
- `write_strings` — direct escaping of plain and escaped strings.
- `write_small` — repeated serialization of tiny scalar values.
- `write_integers` — direct integer serialization into the writer buffer.
- `write_objects` — object field names, values, and writer composition.
- `write_raw` — trusted `RawJson` serialization.
- `write_sets` — ordered hashed-set serialization.
- `write_tables` — ordered string-keyed table serialization.

## Surrogate compatibility in 0.1.1

The escape-handling change accepts unpaired high surrogates consistently with
the existing low-surrogate behavior. Raw capture no longer checks surrogate
pairing; hexadecimal escapes remain checked. Valid pairs still combine during
typed decoding. No additional validation pass or parser option was introduced.

Cachegrind instruction counts on Linux amd64, Nim 2.3.1
(`bb85d2dda5441d4871e44ffe1ebab7c36dc02ecb`), Valgrind 3.27.1, default ORC
and strings. The baseline is `e15861d`; each program runs 100 iterations.
Release and danger configurations were built separately with `-g`.

| Workload | Release baseline Ir | Release candidate Ir | Release change | Danger change |
| --- | ---: | ---: | ---: | ---: |
| strings_plain | 26,521,929 | 26,521,966 | +0.00014% | -0.00006% |
| strings_escaped | 31,650,345 | 31,630,345 | -0.06319% | 0.00000% |
| raw_values | 33,275,446 | 33,275,446 | 0.00000% | +0.00005% |
| unknown_skip | 63,617,051 | 63,617,037 | -0.00002% | 0.00000% |
| canonical_fields | 68,038,069 | 68,018,055 | -0.02942% | 0.00000% |
| unicode_typed | 80,805,373 | 80,605,410 | -0.24746% | +0.21731% |
| unicode_raw | 44,842,343 | 44,442,343 | -0.89201% | -1.69052% |

Matched workloads retained identical checksums. The largest release increase
is 37 instructions in 26.5 million; the deliberately pair-heavy typed workload
increases by 0.21731% in danger. These measurements support no material
instruction-count regression on these workloads, without establishing elapsed
time, cache-miss counts or other architectures' performance.
