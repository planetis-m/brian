## A direct, typed JSON reader and writer.
##
## `brian` decodes JSON directly into Nim values.  It does not build a DOM or
## tokenize scalar values before their destination type is known. Raw string
## bytes follow jsonx compatibility semantics; JSON `\\u` escapes are decoded.

import std/[math, options, strutils]

type
  JsonParsingError* = object of ValueError
    ## Raised for malformed JSON and JSON values that do not fit their target type.

  JsonKind* = enum
    jkNull, jkBool, jkNumber, jkString, jkArray, jkObject

  UnknownFieldPolicy* = enum
    ufSkip, ufReject

  JsonReadOptions* = object
    ## Settings shared by built-in and custom `readJson` overloads.
    unknownFields*: UnknownFieldPolicy
    maxDepth*: Positive

  JsonField* = object
    ## An ephemeral object field name.  Ordinary unescaped names borrow the
    ## input; escaped names borrow reader-owned scratch storage.
    source: ptr UncheckedArray[char]
    start, length: int
    decoded: ptr string

  ContainerKind = enum
    ckArray, ckObject

  ReadContainer = object
    kind: ContainerKind
    first: bool

  JsonReader* = object
    ## A value-type cursor over one contiguous JSON input buffer.
    input: string
    pos: int
    maxDepth: int
    containers: seq[ReadContainer]
    fieldScratch: string

  WriteContainerKind = enum
    wckArray, wckObject

  WriteContainer = object
    kind: WriteContainerKind
    first: bool
    expectsValue: bool

  JsonWriter* = object
    ## A value-type JSON writer whose output is its final string buffer.
    output: string
    containers: seq[WriteContainer]
    wroteRoot: bool

  RawJson* = distinct string
    ## The original representation of one validated JSON value.

  CanonRawJson* = distinct string
    ## A deterministic, whitespace-free re-emission of one JSON value.

const DefaultMaxDepth = 256

const DecimalPowers: array[-22..22, float64] = [
  1.0e-22, 1.0e-21, 1.0e-20, 1.0e-19, 1.0e-18, 1.0e-17, 1.0e-16,
  1.0e-15, 1.0e-14, 1.0e-13, 1.0e-12, 1.0e-11, 1.0e-10, 1.0e-9,
  1.0e-8, 1.0e-7, 1.0e-6, 1.0e-5, 1.0e-4, 1.0e-3, 1.0e-2, 1.0e-1,
  1.0,
  1.0e1, 1.0e2, 1.0e3, 1.0e4, 1.0e5, 1.0e6, 1.0e7, 1.0e8, 1.0e9,
  1.0e10, 1.0e11, 1.0e12, 1.0e13, 1.0e14, 1.0e15, 1.0e16, 1.0e17,
  1.0e18, 1.0e19, 1.0e20, 1.0e21, 1.0e22
]

proc defaultJsonReadOptions*(): JsonReadOptions {.inline.} =
  JsonReadOptions(unknownFields: ufSkip, maxDepth: DefaultMaxDepth)

proc initJsonReader*(input: string;
                     options = defaultJsonReadOptions()): JsonReader {.inline.} =
  ## Creates a reader that borrows `input` for the duration of parsing.
  JsonReader(input: input, maxDepth: int(options.maxDepth))

proc initJsonWriter*(): JsonWriter {.inline.} =
  ## Creates an in-memory writer.
  JsonWriter()

proc fail(pos: int; message: string) {.noinline, noreturn.} =
  raise newException(JsonParsingError, "JSON at byte " & $pos & ": " & message)

proc raiseExpected*(r: JsonReader; expected: string) {.noinline, noreturn.} =
  ## Raises a parsing error suitable for custom `readJson` overloads.
  fail(r.pos, "expected " & expected)

{.push boundChecks: off.}

proc skipSpace(r: var JsonReader) {.inline.} =
  while r.pos < r.input.len and r.input[r.pos] in {' ', '\t', '\n', '\r'}:
    inc r.pos

proc push(r: var JsonReader; kind: ContainerKind) {.inline.} =
  if r.containers.len >= r.maxDepth:
    fail(r.pos, "maximum nesting depth exceeded")
  r.containers.add ReadContainer(kind: kind, first: true)

proc pop(r: var JsonReader; kind: ContainerKind) {.inline.} =
  if r.containers.len == 0 or r.containers[^1].kind != kind:
    fail(r.pos, "mismatched JSON container")
  r.containers.setLen(r.containers.len - 1)

proc hexValue(c: char): int {.inline.} =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

proc validUtf8Span(s: string; start, stop: int): bool =
  var i = start
  while i < stop:
    let b0 = ord(s[i])
    if b0 < 0x20:
      return false
    elif b0 < 0x80:
      inc i
    elif b0 in 0xc2..0xdf and i + 1 < stop:
      if ord(s[i + 1]) notin 0x80..0xbf: return false
      i += 2
    elif b0 == 0xe0 and i + 2 < stop:
      if ord(s[i + 1]) notin 0xa0..0xbf or ord(s[i + 2]) notin 0x80..0xbf:
        return false
      i += 3
    elif b0 in 0xe1..0xec or b0 in 0xee..0xef:
      if i + 2 >= stop or ord(s[i + 1]) notin 0x80..0xbf or
          ord(s[i + 2]) notin 0x80..0xbf:
        return false
      i += 3
    elif b0 == 0xed and i + 2 < stop:
      if ord(s[i + 1]) notin 0x80..0x9f or ord(s[i + 2]) notin 0x80..0xbf:
        return false
      i += 3
    elif b0 == 0xf0 and i + 3 < stop:
      if ord(s[i + 1]) notin 0x90..0xbf or ord(s[i + 2]) notin 0x80..0xbf or
          ord(s[i + 3]) notin 0x80..0xbf:
        return false
      i += 4
    elif b0 in 0xf1..0xf3 and i + 3 < stop:
      if ord(s[i + 1]) notin 0x80..0xbf or ord(s[i + 2]) notin 0x80..0xbf or
          ord(s[i + 3]) notin 0x80..0xbf:
        return false
      i += 4
    elif b0 == 0xf4 and i + 3 < stop:
      if ord(s[i + 1]) notin 0x80..0x8f or ord(s[i + 2]) notin 0x80..0xbf or
          ord(s[i + 3]) notin 0x80..0xbf:
        return false
      i += 4
    else:
      return false
  true

proc appendCodePoint(dst: var string; codePoint: int; pos: int) =
  if codePoint < 0 or codePoint > 0x10ffff or codePoint in 0xd800..0xdfff:
    fail(pos, "invalid Unicode code point")
  if codePoint < 0x80:
    dst.add char(codePoint)
  elif codePoint < 0x800:
    dst.add char(0xc0 or (codePoint shr 6))
    dst.add char(0x80 or (codePoint and 0x3f))
  elif codePoint < 0x10000:
    dst.add char(0xe0 or (codePoint shr 12))
    dst.add char(0x80 or ((codePoint shr 6) and 0x3f))
    dst.add char(0x80 or (codePoint and 0x3f))
  else:
    dst.add char(0xf0 or (codePoint shr 18))
    dst.add char(0x80 or ((codePoint shr 12) and 0x3f))
    dst.add char(0x80 or ((codePoint shr 6) and 0x3f))
    dst.add char(0x80 or (codePoint and 0x3f))

proc readHexEscape(r: var JsonReader): int =
  if r.pos + 4 > r.input.len:
    fail(r.pos, "incomplete Unicode escape")
  for _ in 0..<4:
    let v = hexValue(r.input[r.pos])
    if v < 0: fail(r.pos, "invalid Unicode escape")
    result = (result shl 4) or v
    inc r.pos

proc parseString(r: var JsonReader; dst: var string; rawStart: var int;
                 rawLength: var int; hadEscape: var bool) =
  r.skipSpace()
  if r.pos >= r.input.len or r.input[r.pos] != '"':
    fail(r.pos, "expected string")
  inc r.pos
  rawStart = r.pos
  var runStart = r.pos
  while r.pos < r.input.len:
    while r.pos < r.input.len and r.input[r.pos] notin {'"', '\\'}:
      inc r.pos
    if r.pos >= r.input.len:
      break
    case r.input[r.pos]
    of '"':
      rawLength = r.pos - rawStart
      let stringEnd = r.pos
      inc r.pos
      if hadEscape:
        dst.add r.input[runStart..<stringEnd]
      return
    of '\\':
      if not hadEscape:
        hadEscape = true
        dst.setLen(0)
      dst.add r.input[runStart..<r.pos]
      inc r.pos
      if r.pos >= r.input.len: fail(r.pos, "incomplete escape")
      let escaped = r.input[r.pos]
      inc r.pos
      case escaped
      of '"', '\\', '/': dst.add escaped
      of 'b': dst.add '\b'
      of 'f': dst.add '\f'
      of 'n': dst.add '\n'
      of 'r': dst.add '\r'
      of 't': dst.add '\t'
      of 'u':
        var codePoint = r.readHexEscape()
        if codePoint in 0xd800..0xdbff:
          if r.pos + 2 > r.input.len or r.input[r.pos] != '\\' or r.input[r.pos + 1] != 'u':
            fail(r.pos, "high surrogate without low surrogate")
          r.pos += 2
          let low = r.readHexEscape()
          if low notin 0xdc00..0xdfff: fail(r.pos, "invalid low surrogate")
          codePoint = 0x10000 + ((codePoint - 0xd800) shl 10) + (low - 0xdc00)
        elif codePoint in 0xdc00..0xdfff:
          fail(r.pos, "low surrogate without high surrogate")
        dst.appendCodePoint(codePoint, r.pos)
      else: dst.add escaped
      runStart = r.pos
    else:
      discard
  fail(r.pos, "unterminated string")

proc kind*(r: var JsonReader): JsonKind =
  r.skipSpace()
  if r.pos >= r.input.len: fail(r.pos, "expected value")
  case r.input[r.pos]
  of 'n': jkNull
  of 't', 'f': jkBool
  of '"': jkString
  of '[': jkArray
  of '{': jkObject
  of '-', '.', '0'..'9': jkNumber
  else: fail(r.pos, "expected value")

proc copyStringSpan(dst: var string; source: string; start, length: int) {.inline.} =
  dst.setLen(length)
  if length > 0:
    copyMem(addr dst[0], unsafeAddr source[start], length)

proc readString*(r: var JsonReader; dst: var string) =
  var start, length: int
  var escaped = false
  var decoded = ""
  r.parseString(decoded, start, length, escaped)
  if escaped:
    dst = decoded
  else:
    copyStringSpan(dst, r.input, start, length)

proc readNull*(r: var JsonReader) =
  r.skipSpace()
  if r.input.len - r.pos < 4 or r.input[r.pos..<r.pos + 4] != "null":
    fail(r.pos, "expected null")
  r.pos += 4

proc readBool*(r: var JsonReader; dst: var bool) =
  r.skipSpace()
  if r.input.len - r.pos >= 4 and r.input[r.pos..<r.pos + 4] == "true":
    dst = true
    r.pos += 4
  elif r.input.len - r.pos >= 5 and r.input[r.pos..<r.pos + 5] == "false":
    dst = false
    r.pos += 5
  else:
    fail(r.pos, "expected boolean")

proc scanNumber(r: var JsonReader; start: var int; integerOnly: bool) =
  r.skipSpace()
  start = r.pos
  if r.pos < r.input.len and r.input[r.pos] == '-': inc r.pos
  if r.pos >= r.input.len: fail(r.pos, "incomplete number")
  while r.pos < r.input.len and r.input[r.pos] in {'0'..'9'}: inc r.pos
  if r.pos < r.input.len and r.input[r.pos] == '.':
    if integerOnly: fail(r.pos, "expected integer")
    inc r.pos
    while r.pos < r.input.len and r.input[r.pos] in {'0'..'9'}: inc r.pos
  if r.pos < r.input.len and r.input[r.pos] in {'e', 'E'}:
    if integerOnly: fail(r.pos, "expected integer")
    inc r.pos
    if r.pos < r.input.len and r.input[r.pos] in {'+', '-'}: inc r.pos
    let exponentStart = r.pos
    while r.pos < r.input.len and r.input[r.pos] in {'0'..'9'}: inc r.pos
    if r.pos == exponentStart: fail(r.pos, "missing exponent digits")

proc readInt*[T: SomeInteger](r: var JsonReader; dst: var T) =
  r.skipSpace()
  var negative = false
  if r.pos < r.input.len and r.input[r.pos] == '-':
    negative = true
    inc r.pos
  if r.pos >= r.input.len: fail(r.pos, "incomplete integer")
  var limit: uint64
  when T is SomeUnsignedInt:
    if negative: fail(r.pos - 1, "negative value for unsigned integer")
    limit = uint64(high(T))
  else:
    if negative:
      limit = uint64(-(low(T) + T(1))) + 1'u64
    else:
      limit = uint64(high(T))
  var value = 0'u64
  template addDigit() =
    let digit = uint64(ord(r.input[r.pos]) - ord('0'))
    if value > (limit - digit) div 10'u64:
      fail(r.pos, "integer overflow")
    value = value * 10'u64 + digit
    inc r.pos
  if r.input[r.pos] notin {'0'..'9'}:
    fail(r.pos, "expected digit")
  while r.pos < r.input.len and r.input[r.pos] in {'0'..'9'}: addDigit()
  if r.pos < r.input.len and r.input[r.pos] in {'.', 'e', 'E'}:
    fail(r.pos, "expected integer")
  when T is SomeUnsignedInt:
    dst = T(value)
  else:
    if negative:
      if value == uint64(-(low(T) + T(1))) + 1'u64:
        dst = low(T)
      else:
        dst = T(-int64(value))
    else:
      dst = T(value)

proc readFloat*[T: SomeFloat](r: var JsonReader; dst: var T) =
  ## Parses JSON number grammar and accumulates its decimal value in one pass.
  r.skipSpace()
  let start = r.pos
  var negative = false
  if r.pos < r.input.len and r.input[r.pos] == '-':
    negative = true
    inc r.pos
  if r.pos >= r.input.len: fail(r.pos, "incomplete number")
  var mantissa = 0.0
  var fractionDigits = 0
  template addDigit() =
    mantissa = mantissa * 10.0 + float64(ord(r.input[r.pos]) - ord('0'))
    inc r.pos
  while r.pos < r.input.len and r.input[r.pos] in {'0'..'9'}: addDigit()
  if r.pos < r.input.len and r.input[r.pos] == '.':
    inc r.pos
    while r.pos < r.input.len and r.input[r.pos] in {'0'..'9'}:
      addDigit()
      if fractionDigits < 100000: inc fractionDigits
  var exponent = 0
  if r.pos < r.input.len and r.input[r.pos] in {'e', 'E'}:
    inc r.pos
    var exponentNegative = false
    if r.pos < r.input.len and r.input[r.pos] in {'+', '-'}:
      exponentNegative = r.input[r.pos] == '-'
      inc r.pos
    let exponentStart = r.pos
    while r.pos < r.input.len and r.input[r.pos] in {'0'..'9'}:
      if exponent < 100000:
        exponent = exponent * 10 + ord(r.input[r.pos]) - ord('0')
        if exponent > 100000: exponent = 100000
      inc r.pos
    if r.pos == exponentStart: fail(r.pos, "missing exponent digits")
    if exponentNegative: exponent = -exponent
  let decimalExponent = exponent - fractionDigits
  let scale = if decimalExponent in -22..22:
    DecimalPowers[decimalExponent]
  else:
    pow(10.0, float64(decimalExponent))
  let value = mantissa * scale
  if classify(value) in {fcInf, fcNegInf, fcNan}:
    fail(start, "floating-point value out of range")
  dst = T(if negative: -value else: value)
  if classify(float64(dst)) in {fcInf, fcNegInf, fcNan}:
    fail(start, "floating-point value out of range")

proc beginObject*(r: var JsonReader) =
  r.skipSpace()
  if r.pos >= r.input.len or r.input[r.pos] != '{': fail(r.pos, "expected object")
  inc r.pos
  r.push(ckObject)

proc nextField*(r: var JsonReader; field: var JsonField): bool =
  if r.containers.len == 0 or r.containers[^1].kind != ckObject:
    fail(r.pos, "not inside an object")
  r.skipSpace()
  if r.containers[^1].first:
    if r.pos < r.input.len and r.input[r.pos] == '}':
      inc r.pos
      r.pop(ckObject)
      return false
    r.containers[^1].first = false
  else:
    if r.pos >= r.input.len: fail(r.pos, "unterminated object")
    if r.input[r.pos] == '}':
      inc r.pos
      r.pop(ckObject)
      return false
    if r.input[r.pos] != ',': fail(r.pos, "expected comma or end of object")
    inc r.pos
    r.skipSpace()
    if r.pos < r.input.len and r.input[r.pos] == '}': fail(r.pos, "trailing comma in object")
  var start, length: int
  var escaped = false
  r.fieldScratch.setLen(0)
  r.parseString(r.fieldScratch, start, length, escaped)
  if escaped:
    field = JsonField(decoded: addr r.fieldScratch)
  else:
    field = JsonField(
      source: cast[ptr UncheckedArray[char]](unsafeAddr r.input[0]),
      start: start,
      length: length
    )
  r.skipSpace()
  if r.pos >= r.input.len or r.input[r.pos] != ':': fail(r.pos, "expected colon")
  inc r.pos
  true

proc beginArray*(r: var JsonReader) =
  r.skipSpace()
  if r.pos >= r.input.len or r.input[r.pos] != '[': fail(r.pos, "expected array")
  inc r.pos
  r.push(ckArray)

proc nextElement*(r: var JsonReader): bool =
  if r.containers.len == 0 or r.containers[^1].kind != ckArray:
    fail(r.pos, "not inside an array")
  r.skipSpace()
  if r.containers[^1].first:
    if r.pos < r.input.len and r.input[r.pos] == ']':
      inc r.pos
      r.pop(ckArray)
      return false
    r.containers[^1].first = false
  else:
    if r.pos >= r.input.len: fail(r.pos, "unterminated array")
    if r.input[r.pos] == ']':
      inc r.pos
      r.pop(ckArray)
      return false
    if r.input[r.pos] != ',': fail(r.pos, "expected comma or end of array")
    inc r.pos
    r.skipSpace()
    if r.pos < r.input.len and r.input[r.pos] == ']': fail(r.pos, "trailing comma in array")
  true

proc toString*(field: JsonField): string =
  ## Materializes an owned copy of this ephemeral field name.
  if field.decoded == nil:
    result = newString(field.length)
    if field.length > 0:
      copyMem(addr result[0], addr field.source[field.start], field.length)
  else:
    result = field.decoded[]

proc `==`*(field: JsonField; value: string): bool =
  if field.decoded != nil:
    field.decoded[] == value
  elif field.length != value.len:
    false
  else:
    for i in 0..<value.len:
      if field.source[field.start + i] != value[i]: return false
    true

proc `==`*(value: string; field: JsonField): bool {.inline.} = field == value

proc skipString(r: var JsonReader) =
  r.skipSpace()
  if r.pos >= r.input.len or r.input[r.pos] != '"': fail(r.pos, "expected string")
  inc r.pos
  while r.pos < r.input.len:
    while r.pos < r.input.len and r.input[r.pos] notin {'"', '\\'}:
      inc r.pos
    if r.pos >= r.input.len:
      break
    case r.input[r.pos]
    of '"':
      inc r.pos
      return
    of '\\':
      inc r.pos
      if r.pos >= r.input.len: fail(r.pos, "incomplete escape")
      let escaped = r.input[r.pos]
      inc r.pos
      case escaped
      of '"', '\\', '/', 'b', 'f', 'n', 'r', 't': discard
      of 'u':
        let high = r.readHexEscape()
        if high in 0xd800..0xdbff:
          if r.pos + 2 > r.input.len or r.input[r.pos] != '\\' or r.input[r.pos + 1] != 'u':
            fail(r.pos, "high surrogate without low surrogate")
          r.pos += 2
          let low = r.readHexEscape()
          if low notin 0xdc00..0xdfff: fail(r.pos, "invalid low surrogate")
        elif high in 0xdc00..0xdfff:
          fail(r.pos, "low surrogate without high surrogate")
      else: discard
    else:
      discard
  fail(r.pos, "unterminated string")

proc skipValue*(r: var JsonReader) =
  ## Validates and discards exactly one value without materializing a DOM.
  case r.kind
  of jkNull: r.readNull()
  of jkBool:
    var value: bool
    r.readBool(value)
  of jkString: r.skipString()
  of jkNumber:
    var start: int
    r.scanNumber(start, false)
  of jkArray:
    r.beginArray()
    while r.nextElement(): r.skipValue()
  of jkObject:
    r.beginObject()
    var field: JsonField
    while r.nextField(field): r.skipValue()

proc finish(r: var JsonReader) =
  if r.containers.len != 0: fail(r.pos, "unterminated container")
  r.skipSpace()
  if r.pos != r.input.len: fail(r.pos, "trailing data")

proc readJson*(dst: var string; r: var JsonReader; options: JsonReadOptions) =
  discard options
  r.readString(dst)

proc readJson*(dst: var bool; r: var JsonReader; options: JsonReadOptions) =
  discard options
  r.readBool(dst)

proc readJson*[T: SomeInteger](dst: var T; r: var JsonReader; options: JsonReadOptions) =
  discard options
  r.readInt(dst)

proc readJson*[T: SomeFloat](dst: var T; r: var JsonReader; options: JsonReadOptions) =
  discard options
  r.readFloat(dst)

proc readJson*[T: enum](dst: var T; r: var JsonReader; options: JsonReadOptions) =
  var value: string
  r.readString(value)
  try:
    dst = parseEnum[T](value)
  except ValueError:
    r.raiseExpected("a valid " & $T)

proc readJson*[T](dst: var Option[T]; r: var JsonReader; options: JsonReadOptions) =
  if r.kind == jkNull:
    r.readNull()
    dst = none(T)
  else:
    var value: T
    mixin readJson
    readJson(value, r, options)
    dst = some(value)

proc readJson*[T](dst: var seq[T]; r: var JsonReader; options: JsonReadOptions) =
  dst.setLen(0)
  r.beginArray()
  mixin readJson
  while r.nextElement():
    dst.add default(T)
    readJson(dst[^1], r, options)

proc readJson*[I, T](dst: var array[I, T]; r: var JsonReader; options: JsonReadOptions) =
  r.beginArray()
  var index = 0
  mixin readJson
  while r.nextElement():
    if index >= dst.len: r.raiseExpected("array with " & $dst.len & " elements")
    readJson(dst[I(index + ord(low(I)))], r, options)
    inc index
  if index != dst.len: r.raiseExpected("array with " & $dst.len & " elements")

proc readJson*[T: tuple](dst: var T; r: var JsonReader; options: JsonReadOptions) =
  r.beginArray()
  mixin readJson
  for _, field in fieldPairs(dst):
    if not r.nextElement(): r.raiseExpected("tuple with the expected number of elements")
    readJson(field, r, options)
  if r.nextElement(): r.raiseExpected("tuple with the expected number of elements")

proc readJson*[T: object](dst: var T; r: var JsonReader; options: JsonReadOptions) =
  r.beginObject()
  mixin readJson
  var jsonField: JsonField
  while r.nextField(jsonField):
    var known = false
    for name, field in fieldPairs(dst):
      if jsonField == name:
        readJson(field, r, options)
        known = true
    if not known:
      if options.unknownFields == ufReject:
        r.raiseExpected("known field, got \"" & jsonField.toString() & "\"")
      r.skipValue()

proc readJson*[T: ref object](dst: var T; r: var JsonReader; options: JsonReadOptions) =
  if r.kind == jkNull:
    r.readNull()
    dst = nil
  else:
    new dst
    mixin readJson
    readJson(dst[], r, options)

proc readJson*(dst: var RawJson; r: var JsonReader; options: JsonReadOptions) =
  discard options
  r.skipSpace()
  let start = r.pos
  r.skipValue()
  dst = RawJson(r.input[start..<r.pos])

{.pop.}

proc beforeValue(w: var JsonWriter) =
  if w.containers.len == 0:
    if w.wroteRoot: raise newException(ValueError, "JSON writer already has a root value")
    w.wroteRoot = true
  else:
    case w.containers[^1].kind
    of wckArray:
      if not w.containers[^1].first: w.output.add ','
      w.containers[^1].first = false
    of wckObject:
      if not w.containers[^1].expectsValue:
        raise newException(ValueError, "object value needs a field name")
      w.containers[^1].expectsValue = false

proc beginObject*(w: var JsonWriter) =
  w.beforeValue()
  w.output.add '{'
  w.containers.add WriteContainer(kind: wckObject, first: true)

proc endObject*(w: var JsonWriter) =
  if w.containers.len == 0 or w.containers[^1].kind != wckObject or w.containers[^1].expectsValue:
    raise newException(ValueError, "invalid object writer state")
  w.output.add '}'
  w.containers.setLen(w.containers.len - 1)

proc beginArray*(w: var JsonWriter) =
  w.beforeValue()
  w.output.add '['
  w.containers.add WriteContainer(kind: wckArray, first: true)

proc endArray*(w: var JsonWriter) =
  if w.containers.len == 0 or w.containers[^1].kind != wckArray:
    raise newException(ValueError, "invalid array writer state")
  w.output.add ']'
  w.containers.setLen(w.containers.len - 1)

proc writeEscapedString(w: var JsonWriter; value: string) =
  if not validUtf8Span(value, 0, value.len):
    raise newException(ValueError, "JSON strings must be valid UTF-8")
  w.output.add '"'
  var runStart = 0
  for i, c in value:
    let escaped = case c
      of '"': "\\\""
      of '\\': "\\\\"
      of '\b': "\\b"
      of '\f': "\\f"
      of '\n': "\\n"
      of '\r': "\\r"
      of '\t': "\\t"
      else: ""
    if escaped.len > 0 or ord(c) < 0x20:
      w.output.add value[runStart..<i]
      if escaped.len > 0:
        w.output.add escaped
      else:
        w.output.add "\\u00"
        const Hex = "0123456789abcdef"
        w.output.add Hex[(ord(c) shr 4) and 0xf]
        w.output.add Hex[ord(c) and 0xf]
      runStart = i + 1
  w.output.add value[runStart..^1]
  w.output.add '"'

proc writeField*(w: var JsonWriter; name: string) =
  ## Emits a field name in the current object; the next write supplies its value.
  if w.containers.len == 0 or w.containers[^1].kind != wckObject or w.containers[^1].expectsValue:
    raise newException(ValueError, "field name outside an object")
  if not w.containers[^1].first: w.output.add ','
  w.containers[^1].first = false
  w.writeEscapedString(name)
  w.output.add ':'
  w.containers[^1].expectsValue = true

proc writeJson*(w: var JsonWriter; value: string) =
  w.beforeValue()
  w.writeEscapedString(value)

proc writeJson*(w: var JsonWriter; value: bool) =
  w.beforeValue()
  w.output.add(if value: "true" else: "false")

proc writeJson*[T: SomeInteger](w: var JsonWriter; value: T) =
  w.beforeValue()
  w.output.addInt(value)

proc writeJson*[T: SomeFloat](w: var JsonWriter; value: T) =
  if classify(float64(value)) in {fcInf, fcNegInf, fcNan}:
    raise newException(ValueError, "JSON cannot represent NaN or infinity")
  w.beforeValue()
  w.output.add $value

proc writeJson*[T: enum](w: var JsonWriter; value: T) =
  w.writeJson($value)

proc writeJson*[T](w: var JsonWriter; value: Option[T]) =
  if value.isSome:
    mixin writeJson
    writeJson(w, value.get)
  else:
    w.beforeValue()
    w.output.add "null"

proc writeJson*[T](w: var JsonWriter; value: seq[T]) =
  w.beginArray()
  mixin writeJson
  for item in value: writeJson(w, item)
  w.endArray()

proc writeJson*[I, T](w: var JsonWriter; value: array[I, T]) =
  w.beginArray()
  mixin writeJson
  for item in value: writeJson(w, item)
  w.endArray()

proc writeJson*[T: tuple](w: var JsonWriter; value: T) =
  w.beginArray()
  mixin writeJson
  for _, field in fieldPairs(value): writeJson(w, field)
  w.endArray()

proc writeJson*[T: object](w: var JsonWriter; value: T) =
  w.beginObject()
  mixin writeJson
  for name, field in fieldPairs(value):
    w.writeField(name)
    writeJson(w, field)
  w.endObject()

proc writeJson*[T: ref object](w: var JsonWriter; value: T) =
  if value.isNil:
    w.beforeValue()
    w.output.add "null"
  else:
    mixin writeJson
    writeJson(w, value[])

proc validRaw(value: string) =
  var reader = initJsonReader(value)
  reader.skipValue()
  reader.finish()

proc writeJson*(w: var JsonWriter; value: RawJson) =
  let raw = string(value)
  validRaw(raw)
  w.beforeValue()
  w.output.add raw

proc canonicalizeValue(r: var JsonReader; w: var JsonWriter) =
  case r.kind
  of jkNull:
    r.readNull()
    w.beforeValue()
    w.output.add "null"
  of jkBool:
    var value: bool
    r.readBool(value)
    w.writeJson(value)
  of jkString:
    var value: string
    r.readString(value)
    w.writeJson(value)
  of jkNumber:
    var start: int
    r.scanNumber(start, false)
    w.beforeValue()
    w.output.add r.input[start..<r.pos]
  of jkArray:
    r.beginArray()
    w.beginArray()
    while r.nextElement(): r.canonicalizeValue(w)
    w.endArray()
  of jkObject:
    r.beginObject()
    w.beginObject()
    var field: JsonField
    while r.nextField(field):
      w.writeField(field.toString())
      r.canonicalizeValue(w)
    w.endObject()

proc readJson*(dst: var CanonRawJson; r: var JsonReader; options: JsonReadOptions) =
  discard options
  var writer = initJsonWriter()
  r.canonicalizeValue(writer)
  dst = CanonRawJson(writer.output)

proc writeJson*(w: var JsonWriter; value: CanonRawJson) =
  w.writeJson(RawJson(string(value)))

proc fromJson*[T](input: string; typ: typedesc[T];
                  options = defaultJsonReadOptions()): T =
  ## Decodes one complete JSON value from `input`.
  var reader = initJsonReader(input, options)
  mixin readJson
  readJson(result, reader, options)
  reader.finish()

proc fromJson*[T](input: string; dst: var T;
                  options = defaultJsonReadOptions()) =
  ## Decodes one complete JSON value directly into `dst`.
  var reader = initJsonReader(input, options)
  mixin readJson
  readJson(dst, reader, options)
  reader.finish()

proc finish*(w: JsonWriter): string =
  ## Returns the finished JSON string.
  if not w.wroteRoot or w.containers.len != 0:
    raise newException(ValueError, "unfinished JSON writer")
  w.output

proc toJson*[T](value: T): string =
  ## Serializes `value` directly into its final string buffer.
  var writer = initJsonWriter()
  mixin writeJson
  writeJson(writer, value)
  writer.finish()

iterator jsonItems*[T](input: string; typ: typedesc[T];
                       options = defaultJsonReadOptions()): T =
  ## Decodes the elements of one top-level JSON array lazily.
  var reader = initJsonReader(input, options)
  reader.beginArray()
  mixin readJson
  while reader.nextElement():
    var value: T
    readJson(value, reader, options)
    yield value
  reader.finish()
