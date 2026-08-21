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

Custom representation types use ordinary overloads:

```nim
proc readJson(dst: var Content; r: var JsonReader; options: JsonReadOptions) =
  case r.kind
  of jkString: readJson(dst.text, r, options)
  of jkArray: readJson(dst.parts, r, options)
  else: r.raiseExpected("string or array")
```

The initial package provides in-memory parsing/serialization, jsonx-compatible
raw-string handling with surrogate validation, typed scalars, sequences, arrays, tuples, objects,
`Option`, `RawJson`, unknown-field policies, and depth limits. Buffered input
and output are intentionally deferred to a subsequent layer so the contiguous
reader/writer hot path remains simple.
