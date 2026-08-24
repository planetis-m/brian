# brian

*Always look on the typed side of life.*

Brian decodes straight into your Nim types and encodes straight into a string,
without building a JSON DOM or scalar token objects.

## Why try it?

- **Direct typed mapping.** Objects, tuples, sequences, arrays, options, sets,
  tables, enums, and references map to their natural Nim types.
- **A deliberately small API.** Most code only needs `fromJson` and `toJson`;
  custom formats use ordinary `readJson` and `writeJson` overloads.
- **Low overhead.** The parser borrows ordinary object keys from the input and
  writes into the final output buffer.
- **Strict where it matters.** Brian rejects malformed structure, broken Unicode
  escapes and high-surrogate pairs, integer overflow, type mismatches, and
  trailing data.
- **Standalone.** Brian does not depend on jsonx, jsony, or their internals.

## Install

Add Brian to your `.nimble` file:

```nim
requires "https://github.com/planetis-m/brian"
```

Then resolve dependencies with Atlas:

```sh
atlas install
```

Or install it directly with Nimble:

```sh
nimble install https://github.com/planetis-m/brian
```

## Quick start

```nim
import brian

type
  Person = object
    name: string
    age: int
    active: bool

let person = fromJson(
  """{"name":"Ada","age":37,"active":true}""", Person)

echo person.name
echo toJson(person)
# Ada
# {"name":"Ada","age":37,"active":true}
```

Object fields are matched by name. Unknown fields are skipped by default, which
makes readers tolerant of additive API changes. Ask for an exact shape when you
need one:

```nim
let compatible = fromJson(payload, Person)
let exact = fromJson(payload, Person, unknownFields = ufReject)
```

Both modes still validate known values and malformed JSON. Parse failures raise
`JsonParsingError`.

## Read a large top-level array one item at a time

`jsonItems` decodes each item directly instead of first creating a `seq` for the
whole array:

```nim
import brian

type
  Event = object
    id: int
    name: string

for event in jsonItems(
    """[{"id":1,"name":"opened"},{"id":2,"name":"closed"}]""", Event):
  echo event.id, ": ", event.name
```

The input is still one contiguous string; iteration avoids materializing the
outer collection, not buffering the input itself.

## Keep JSON you do not want to model

Use `RawJson` for an embedded value whose schema belongs to another system.
Brian validates and captures the consumed representation without parsing and
reserializing it:

```nim
import brian

type
  Tool = object
    name: string
    schema: RawJson

let tool = fromJson(
  """{"name":"search","schema": { "type": "object" }}""", Tool)

echo string(tool.schema) # { "type": "object" }
echo toJson(tool)        # {"name":"search","schema":{ "type": "object" }}
```

`CanonRawJson` instead re-emits a whitespace-free representation and decodes
string escapes. It preserves object field order; it does not sort keys.

Values parsed into `RawJson` are validated. Manually constructing a `RawJson`
marks its bytes as trusted, so only do that with a complete valid JSON value.

## Custom JSON shapes

Customization is normal Nim overload resolution. This type accepts either a
JSON string or an array of strings and writes the same shape back:

```nim
import brian

type
  ContentKind = enum
    text, parts

  Content = object
    case kind: ContentKind
    of text:
      body: string
    of parts:
      items: seq[string]

proc readJson(dst: var Content; p: var JsonParser;
              unknownFields: UnknownFieldPolicy) =
  case p.kind
  of jkString:
    dst = Content(kind: text)
    readJson(dst.body, p, unknownFields)
  of jkArray:
    dst = Content(kind: parts)
    readJson(dst.items, p, unknownFields)
  else:
    p.raiseParseError("expected string or array")

proc writeJson(w: var JsonWriter; value: Content) =
  case value.kind
  of text:
    writeJson(w, value.body)
  of parts:
    writeJson(w, value.items)

let content = fromJson("[\"first\",\"second\"]", Content)
echo toJson(content) # ["first","second"]
```

For hand-written object readers, iterate `p.jsonFields` and call `p.skipJson()`
for fields you choose not to decode. Custom writers can append JSON syntax with
`w.write`, escape keys or strings with `w.escapeJson`, and delegate values back
to `writeJson`.

## Supported mappings

- JSON strings map to `string` and enums.
- JSON numbers map to Nim integer and floating-point types with checked integer
  conversion.
- JSON arrays map to `seq`, `array`, unnamed tuples, `set`, `HashSet`, and
  `OrderedSet`.
- JSON objects map to objects, named tuples, `Table[string, T]`, and
  `OrderedTable[string, T]`.
- JSON `null` maps to `none(T)` and `nil` for reference objects.

Import `std/options`, `std/sets`, or `std/tables` when using the corresponding
Nim container type.

## Performance

Cachegrind instructions (`-d:release -g`) and times
(`-d:danger`, default strings; median of 15 runs):

| Library | Read (CG) | Write (CG) | Read 2M | Write 10M |
| --- | ---: | ---: | ---: | ---: |
| Brian | 142.96M | 72.65M | 0.46 s | 0.56 s |
| jsonx | 165.60M | 242.39M | 0.70 s | 2.52 s |
| jsony | 166.26M | 98.69M | 0.70 s | 0.85 s |

Lower is better.

These are focused microbenchmarks, not a promise that every payload has the same
ratio. The programs in [`bench/`](bench/) isolate strings, numbers, objects,
containers, unknown-field skipping, raw JSON, and writing paths so changes can
be measured one dimension at a time.

## API at a glance

- `fromJson(input, T)` returns a decoded value.
- `fromJson(input, dst)` decodes into an existing value.
- `toJson(value)` returns the encoded string.
- `jsonItems(input, T)` iterates a top-level array.
- `readJson(dst, parser, policy)` customizes decoding.
- `writeJson(writer, value)` customizes encoding.
- `RawJson` preserves a captured JSON representation.
- `CanonRawJson` produces a compact normalized representation.

## Run the tests and benchmarks

Run the full matrix, including debug, release, danger, both Nim string modes,
and AddressSanitizer:

```sh
nim c -r -d:release tests/tester.nim
```

Run one focused release benchmark from the repository root:

```sh
nim c -d:release bench/objects_known.nim
valgrind --tool=cachegrind ./bench/objects_known
```

Brian is available under the MIT license.
