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
- `objects_known` — compile-time `fieldPairs` mapping for known object fields.
- `custom_enums` — custom string matcher dispatch to a tolerant enum.
- `custom_fields` — indexed custom object-field dispatch and unknown-field skipping.
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
