# brian

`brian` is a standalone typed JSON library for Nim. It reads directly from a
contiguous input string into the requested Nim type and writes directly to the
final output string—there is no JSON DOM or scalar token layer.

```nim
import brian

type Person = object
  name: string
  age: int

let person = fromJson("{\"name\":\"Ada\",\"age\":37}", Person)
let encoded = toJson(person)
```

Custom readers use ordinary overloads. `jsonFields` is only needed for a
hand-written object shape; generated object decoding remains allocation-free.

```nim
proc readJson(dst: var Content; p: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  case p.kind
  of jkString: readJson(dst.text, p, unknownFields)
  of jkArray: readJson(dst.parts, p, unknownFields)
  else: p.raiseParseError("expected string or array")
```

Custom writers use the writer as a direct output sink:

```nim
proc writeJson(w: var JsonWriter; value: Page) =
  w.write "{\"page\":"
  writeJson(w, value.page)
  w.write ",\"status\":"
  writeJson(w, value.status)
  w.write "}"
```

The primary API is `fromJson`, `toJson`, `readJson`, `writeJson`, `RawJson`,
`CanonRawJson`, `UnknownFieldPolicy`, and `jsonItems`.

## Testing

Run the complete matrix, including AddressSanitizer and both Nim string modes:

```sh
nim c -r -d:release tests/tester.nim
```

## String bytes

`toJson` follows jsonx-compatible raw-byte behavior for Nim strings: it escapes
JSON control bytes, `"`, and `\\`, and otherwise preserves the input bytes. It
does not perform a separate UTF-8 validation pass during serialization.

## Raw JSON

`RawJson` is trusted during serialization, matching jsonx. Values obtained via
`fromJson(..., RawJson)` are validated while captured; manually constructed
`RawJson` values must already contain one valid JSON value.
