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
  escapes, integer overflow, type mismatches, and trailing data.
- **No exceptions.** `fromJson` and `toJson` return a `Result` holding either
  the value or the first error and the byte where it was found.

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
import std/[result, syncio]
import brian

type
  Person = object
    name: string
    age: int
    active: bool

case fromJson("""{"name":"Ada","age":37,"active":true}""", Person)
of Ok(person):
  echo person.name
  echo toJson(person).get("")
of Err(e):
  echo $e
# Ada
# {"name":"Ada","age":37,"active":true}
```

A failed decode reports the first error: `e.kind` says what went wrong,
`e.pos` is the byte offset into the input, and `$e` spells it out as
`JSON at byte 12: expected colon`. `toJson` fails the same way for values
JSON cannot represent, such as NaN, reporting the output byte instead.

Object fields are matched by name. Unknown fields are skipped by default, which
makes readers tolerant of additive API changes. Ask for an exact shape when you
need one:

```nim
let compatible = fromJson(payload, Person)
let exact = fromJson(payload, Person, unknownFields = ufReject)
```

Both modes still validate known values and malformed JSON.

## Read JSON Lines

`jsonLines` decodes one value per line. Every line gets its own result, so a
malformed line does not stop the rest; empty lines are skipped:

```nim
import std/[result, syncio]
import brian

type
  Event = object
    id: int
    name: string

for line in jsonLines[Event]("{\"id\":1,\"name\":\"opened\"}\n{\"id\":2,\"name\":\"closed\"}\n"):
  case line
  of Ok(event): echo event.id, ": ", event.name
  of Err(e): echo $e
```

Error positions count from the start of the whole input, not the line.

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
  """{"name":"search","schema": { "type": "object" }}""", Tool).get(Tool())

echo $tool.schema        # { "type": "object" }
echo toJson(tool).get("") # {"name":"search","schema":{ "type": "object" }}
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

proc readJson(dst: var Content; p: var JsonParser; unknownFields: UnknownFieldPolicy) =
  case p.kind
  of jkString:
    dst = Content(kind: text)
    readJson(dst.body, p, unknownFields)
  of jkArray:
    dst = Content(kind: parts)
    readJson(dst.items, p, unknownFields)
  else:
    p.parseError("expected string or array")

proc writeJson(w: var JsonWriter; value: Content) =
  case value.kind
  of text:
    writeJson(w, value.body)
  of parts:
    writeJson(w, value.items)

let content = fromJson("[\"first\",\"second\"]", Content).get(Content())
echo toJson(content).get("") # ["first","second"]
```

Custom object readers use one iterator over borrowed `openArray[char]` keys.
Compare keys directly without allocating, and handle unknown values according
to the supplied policy. `parseError` records a failure; the parser keeps the
first one and turns every later read into a no-op, so readers need no early
returns:

```nim
type
  Page = object
    number: int
    status: string

proc readJson(dst: var Page; p: var JsonParser; unknownFields: UnknownFieldPolicy) =
  for field in p.jsonFields:
    if field == "number":
      readJson(dst.number, p, unknownFields)
    elif field == "status":
      readJson(dst.status, p, unknownFields)
    elif unknownFields == ufReject:
      p.parseError("expected known field, got \"" & $field & "\"")
    else:
      p.skipJson()
```

A key is a non-owning view. Compare it during the current iteration, or use
`$field` to create an owned string before retaining it.

Enum strings are matched exactly and case-sensitively against their Nim
spellings, including custom spellings such as `inProgress = "in_progress"`.
A tolerant custom reader can select an explicit fallback without duplicating
the enum mapping:

```nim
type ResponseStatus = enum
  completed, inProgress = "in_progress", unknown

proc readJson(dst: var ResponseStatus; p: var JsonParser;
              unknownFields: UnknownFieldPolicy) =
  readJson(dst, p, unknownFields, unknown)
```

Custom writers can append JSON syntax with `w.write`, escape keys or strings
with `w.escapeJson`, delegate values back to `writeJson`, and reject a value
with `w.writeError(msg)`.

## Supported mappings

- JSON strings map to `string` and enums.
- JSON numbers map to Nim integer and floating-point types with checked integer
  conversion.
- JSON arrays map to `seq`, `array`, unnamed tuples, `set`, and `HashSet`.
- JSON objects map to objects, named tuples, and `Table[string, T]`.
- JSON `null` maps to `none(T)` and `nil` for `nil ref` types.

Import `std/options`, `std/sets`, or `std/tables` when using the corresponding
Nim container type.

## Performance

The programs in [`bench/`](bench/) isolate strings, numbers, objects,
containers, unknown-field skipping, raw JSON, and writing paths so changes can
be measured one dimension at a time with Cachegrind instruction counts.

## API at a glance

- `fromJson(input, T)` returns a `Result[T, JsonError]`.
- `jsonLines[T](input)` yields one `Result[T, JsonError]` per JSON Lines line.
- `JsonError` holds the error `kind` and byte `pos`; `$` formats it.
- `toJson(value)` returns a `Result[string, JsonError]`.
- `readJson(dst, parser, policy)` customizes decoding.
- `readJson(dst, parser, policy, fallback)` reads an enum with an unknown-value fallback.
- `parser.jsonFields` iterates borrowed `openArray[char]` object keys.
- `parser.parseError(msg)` records a custom decoding failure.
- `writer.writeError(msg)` records a custom encoding failure.
- `writeJson(writer, value)` customizes encoding.
- `RawJson` preserves a captured JSON representation.
- `CanonRawJson` produces a compact normalized representation.

## Run the tests and benchmarks

Run the full matrix, including debug, release, danger, and AddressSanitizer,
from the repository root:

```sh
nimony c -r tests/tester.nim
```

Run one focused release benchmark from the repository root:

```sh
nimony c -d:release --outdir:bench bench/objects_known.nim
valgrind --tool=cachegrind ./bench/objects_known
```

Brian is available under the MIT license.
