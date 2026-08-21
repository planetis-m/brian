# Brian

`brian` is a standalone typed JSON library. It must not depend on `jsonx`,
`jsony`, or their internal code.

## Design

- Preserve the small public model: `fromJson`, `toJson`, overloaded
  `readJson`, overloaded `writeJson`, `RawJson`, `CanonRawJson`, and the
  minimal parser/writer surface needed by custom types.
- Customization is ordinary Nim overloads. Do not add hooks, visitors, source
  hierarchies, token streams, runtime polymorphism, or registration systems.
- Keep parsing direct and typed. Do not build a DOM or scalar token objects.
- `JsonParser` is a cursor over input bytes. Keep source ownership, refill,
  scratch buffers, and structural mechanics private unless custom readers need
  a specific operation.
- `fieldPairs` is compile-time expansion, not runtime reflection. Treat its
  generated comparisons as ordinary code and inspect the expansion/profile
  before changing dispatch.
- Prefer one clear fast path plus a rare fallback. Ordinary object keys borrow
  source bytes; escaped keys may use parser scratch. Ordinary string values
  copy directly to their destination.
- Do not add abstractions that merely wrap one call. Keep private helpers
  short and merge duplicate paths when their invariants are the same.

## Correctness

- Reject malformed structural JSON, malformed escapes, invalid surrogate
  pairs, integer overflow, and trailing data.
- Validate malformed external JSON, not Brian's own low-level API sequencing.
  Do not charge hot paths for redundant internal state checks.
- Keep validation no stricter than Nim's `std/parsejson` unless an intentional,
  documented compatibility decision requires it. In particular, do not add
  stricter number grammar checks casually; retain jsonx-compatible permissive
  number behavior while alignment with `std/parsejson` is evaluated.
- `RawJson` preserves the consumed JSON representation; do not parse and
  reserialize it merely to capture it.
- Add a focused regression test for each parser fast-path or fallback change.

## Performance work

- Use Cachegrind instruction counts, not wall-clock timings, for optimization
  decisions. Change one dimension at a time and retain a change only when the
  relevant focused benchmarks support it.
- Use the focused programs in `bench/`. Keep their workloads large enough that
  process startup is insignificant in Cachegrind.
- Build benchmark configurations separately with `-d:release` and
  `-d:danger`; never pass both defines to one compilation. `-d:danger` cannot
  answer questions about checks it disables, so use `-d:release` for those
  comparisons.
- Do not add broad unchecked pragmas. First inspect the release-generated code
  and profile the actual hot path; scope any unchecked region to the exact
  measured procedure.
- Prefer direct spans, `beginStore`/`endStore`, and `setLenUninit` where the
  length is proven. Avoid temporary strings and duplicate copies in hot paths.

## Verification

Run the complete test matrix after functional changes:

```sh
nim c -r -d:release tests/tester.nim
```

The tester covers debug, release, danger, both SSO variants, and AddressSanitizer.
Do not weaken ASan configuration or add ownership workarounds solely to hide a
known compiler cleanup-on-raise issue.
