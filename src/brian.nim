## A direct, typed JSON reader and writer.
##
## `brian` decodes JSON directly into Nim values.  It does not build a DOM or
## tokenize scalar values before their destination type is known. Raw string
## bytes follow jsonx compatibility semantics; JSON `\\u` escapes are decoded.

import std/[formatfloat, math, options, parseutils, strutils]

type
  JsonParsingError* = object of ValueError
    ## Raised for malformed JSON and JSON values that do not fit their target type.

  JsonKind* = enum
    jkNull, jkBool, jkNumber, jkString, jkArray, jkObject

  UnknownFieldPolicy* = enum
    ufSkip, ufReject

  Field = object
    ## An ephemeral object field name.  Ordinary unescaped names borrow the
    ## input; escaped names borrow reader-owned scratch storage.
    data: ptr UncheckedArray[char]
    len: int

  JsonParser* = object
    ## Cursor state supplied to custom `readJson` overloads.
    data: ptr UncheckedArray[char]
    len: int
    pos: int
    depth: int
    scratch: string

  JsonWriter* = object
    ## Output sink supplied to custom `writeJson` overloads.
    output: string
    data: ptr UncheckedArray[char]
    pos: int

  RawJson* = distinct string
    ## Trusted bytes representing one JSON value.

  CanonRawJson* = distinct string
    ## A deterministic, whitespace-free re-emission of one JSON value.

const DefaultMaxDepth = 256

const Digits100 =
  "000102030405060708091011121314151617181920212223242526272829" &
  "303132333435363738394041424344454647484950515253545556575859" &
  "606162636465666768697071727374757677787980818283848586878889" &
  "90919293949596979899"

const DecimalPowers: array[-22..22, float64] = [
  1.0e-22, 1.0e-21, 1.0e-20, 1.0e-19, 1.0e-18, 1.0e-17, 1.0e-16,
  1.0e-15, 1.0e-14, 1.0e-13, 1.0e-12, 1.0e-11, 1.0e-10, 1.0e-9,
  1.0e-8, 1.0e-7, 1.0e-6, 1.0e-5, 1.0e-4, 1.0e-3, 1.0e-2, 1.0e-1,
  1.0,
  1.0e1, 1.0e2, 1.0e3, 1.0e4, 1.0e5, 1.0e6, 1.0e7, 1.0e8, 1.0e9,
  1.0e10, 1.0e11, 1.0e12, 1.0e13, 1.0e14, 1.0e15, 1.0e16, 1.0e17,
  1.0e18, 1.0e19, 1.0e20, 1.0e21, 1.0e22
]

proc fail(pos: int; message: string) {.noinline, noreturn.} =
  raise newException(JsonParsingError, "JSON at byte " & $pos & ": " & message)

proc raiseExpected*(p: JsonParser; expected: string) {.noinline, noreturn.} =
  ## Raises a parse error suitable for custom `readJson` overloads.
  fail(p.pos, "expected " & expected)

{.push boundChecks: off.}

proc skip(r: var JsonParser) {.inline.} =
  while r.pos < r.len and r.data[r.pos] in {' ', '\t', '\n', '\r'}:
    inc r.pos

proc hexValue(c: char): int {.inline.} =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

proc addCodePoint(dst: var string; codePoint: int; pos: int) =
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

proc readHex(r: var JsonParser): int =
  if r.pos + 4 > r.len:
    fail(r.pos, "incomplete Unicode escape")
  for _ in 0..<4:
    let v = hexValue(r.data[r.pos])
    if v < 0: fail(r.pos, "invalid Unicode escape")
    result = (result shl 4) or v
    inc r.pos

proc addSpan(dst: var string; source: ptr UncheckedArray[char]; start, stop: int) {.inline.} =
  let length = stop - start
  if length > 0:
    let oldLength = dst.len
    {.cast(noSideEffect).}:
      copyMem(beginStore(dst, oldLength + length, oldLength), addr source[start], length)
      endStore(dst)

proc parseString(r: var JsonParser; dst: var string; rawStart: var int;
                 rawLength: var int; hadEscape: var bool) =
  r.skip()
  if r.pos >= r.len or r.data[r.pos] != '"':
    fail(r.pos, "expected string")
  inc r.pos
  rawStart = r.pos
  var runStart = r.pos
  while r.pos < r.len:
    while r.pos < r.len and r.data[r.pos] notin {'"', '\\'}:
      inc r.pos
    if r.pos >= r.len:
      break
    case r.data[r.pos]
    of '"':
      rawLength = r.pos - rawStart
      let stringEnd = r.pos
      inc r.pos
      if hadEscape:
        dst.addSpan(r.data, runStart, stringEnd)
      return
    of '\\':
      if not hadEscape:
        hadEscape = true
        dst.setLen(0)
      dst.addSpan(r.data, runStart, r.pos)
      inc r.pos
      if r.pos >= r.len: fail(r.pos, "incomplete escape")
      let escaped = r.data[r.pos]
      inc r.pos
      case escaped
      of '"', '\\', '/': dst.add escaped
      of 'b': dst.add '\b'
      of 'f': dst.add '\f'
      of 'n': dst.add '\n'
      of 'r': dst.add '\r'
      of 't': dst.add '\t'
      of 'u':
        var codePoint = r.readHex()
        if codePoint in 0xd800..0xdbff:
          if r.pos + 2 > r.len or r.data[r.pos] != '\\' or r.data[r.pos + 1] != 'u':
            fail(r.pos, "high surrogate without low surrogate")
          r.pos += 2
          let low = r.readHex()
          if low notin 0xdc00..0xdfff: fail(r.pos, "invalid low surrogate")
          codePoint = 0x10000 + ((codePoint - 0xd800) shl 10) + (low - 0xdc00)
        elif codePoint in 0xdc00..0xdfff:
          fail(r.pos, "low surrogate without high surrogate")
        dst.addCodePoint(codePoint, r.pos)
      else: dst.add escaped
      runStart = r.pos
    else:
      discard
  fail(r.pos, "unterminated string")

proc kind*(r: var JsonParser): JsonKind =
  r.skip()
  if r.pos >= r.len: fail(r.pos, "expected value")
  case r.data[r.pos]
  of 'n': jkNull
  of 't', 'f': jkBool
  of '"': jkString
  of '[': jkArray
  of '{': jkObject
  of '-', '.', '0'..'9': jkNumber
  else: fail(r.pos, "expected value")

proc readString(r: var JsonParser; dst: var string) =
  var start, length: int
  var escaped = false
  var decoded = ""
  r.parseString(decoded, start, length, escaped)
  if escaped:
    dst = decoded
  else:
    dst.setLen(0)
    dst.addSpan(r.data, start, start + length)

proc consumeNull(r: var JsonParser): bool {.inline.} =
  r.skip()
  if r.len - r.pos < 4 or r.data[r.pos] != 'n' or r.data[r.pos + 1] != 'u' or
      r.data[r.pos + 2] != 'l' or r.data[r.pos + 3] != 'l':
    return false
  r.pos += 4
  true

proc readNull(r: var JsonParser) =
  if not r.consumeNull():
    fail(r.pos, "expected null")

proc readBool(r: var JsonParser; dst: var bool) =
  r.skip()
  if r.len - r.pos >= 4 and r.data[r.pos] == 't' and r.data[r.pos + 1] == 'r' and
      r.data[r.pos + 2] == 'u' and r.data[r.pos + 3] == 'e':
    dst = true
    r.pos += 4
  elif r.len - r.pos >= 5 and r.data[r.pos] == 'f' and r.data[r.pos + 1] == 'a' and
      r.data[r.pos + 2] == 'l' and r.data[r.pos + 3] == 's' and r.data[r.pos + 4] == 'e':
    dst = false
    r.pos += 5
  else:
    fail(r.pos, "expected boolean")

proc scanNumber(r: var JsonParser; start: var int; integerOnly: bool) =
  r.skip()
  start = r.pos
  if r.pos < r.len and r.data[r.pos] == '-': inc r.pos
  if r.pos >= r.len: fail(r.pos, "incomplete number")
  while r.pos < r.len and r.data[r.pos] in {'0'..'9'}: inc r.pos
  if r.pos < r.len and r.data[r.pos] == '.':
    if integerOnly: fail(r.pos, "expected integer")
    inc r.pos
    while r.pos < r.len and r.data[r.pos] in {'0'..'9'}: inc r.pos
  if r.pos < r.len and r.data[r.pos] in {'e', 'E'}:
    if integerOnly: fail(r.pos, "expected integer")
    inc r.pos
    if r.pos < r.len and r.data[r.pos] in {'+', '-'}: inc r.pos
    let exponentStart = r.pos
    while r.pos < r.len and r.data[r.pos] in {'0'..'9'}: inc r.pos
    if r.pos == exponentStart: fail(r.pos, "missing exponent digits")

proc readInt[T: SomeInteger](r: var JsonParser; dst: var T) =
  r.skip()
  var negative = false
  if r.pos < r.len and r.data[r.pos] == '-':
    negative = true
    inc r.pos
  if r.pos >= r.len: fail(r.pos, "incomplete integer")
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
    let digit = uint64(ord(r.data[r.pos]) - ord('0'))
    if value > (limit - digit) div 10'u64:
      fail(r.pos, "integer overflow")
    value = value * 10'u64 + digit
    inc r.pos
  if r.data[r.pos] notin {'0'..'9'}:
    fail(r.pos, "expected digit")
  while r.pos < r.len and r.data[r.pos] in {'0'..'9'}: addDigit()
  if r.pos < r.len and r.data[r.pos] in {'.', 'e', 'E'}:
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

proc readFloat[T: SomeFloat](r: var JsonParser; dst: var T) =
  ## Uses a small exact fast path and the stdlib converter for difficult values.
  r.skip()
  let start = r.pos
  if r.pos < r.len and r.data[r.pos] == '-': inc r.pos
  if r.pos >= r.len: fail(r.pos, "incomplete number")
  var significand = 0'u64
  var significantDigits = 0
  var fast = true
  var fractionDigits = 0
  template addDigit() =
    let digit = uint64(ord(r.data[r.pos]) - ord('0'))
    if significand != 0 or digit != 0:
      if significantDigits < 19:
        significand = significand * 10'u64 + digit
        inc significantDigits
      else:
        fast = false
    inc r.pos
  while r.pos < r.len and r.data[r.pos] in {'0'..'9'}: addDigit()
  if r.pos < r.len and r.data[r.pos] == '.':
    inc r.pos
    while r.pos < r.len and r.data[r.pos] in {'0'..'9'}:
      addDigit()
      if fractionDigits < 100000: inc fractionDigits
  var exponent = 0
  if r.pos < r.len and r.data[r.pos] in {'e', 'E'}:
    inc r.pos
    var exponentNegative = false
    if r.pos < r.len and r.data[r.pos] in {'+', '-'}:
      exponentNegative = r.data[r.pos] == '-'
      inc r.pos
    let exponentStart = r.pos
    while r.pos < r.len and r.data[r.pos] in {'0'..'9'}:
      if exponent < 100000:
        exponent = exponent * 10 + ord(r.data[r.pos]) - ord('0')
        if exponent > 100000: exponent = 100000
      inc r.pos
    if r.pos == exponentStart: fail(r.pos, "missing exponent digits")
    if exponentNegative: exponent = -exponent
  let decimalExponent = exponent - fractionDigits
  var value: float64
  if significand == 0:
    value = if r.data[start] == '-': -0.0 else: 0.0
  elif fast and significand < (1'u64 shl 53) and decimalExponent in -22..22:
    value = float64(significand)
    if decimalExponent < 0:
      value /= DecimalPowers[-decimalExponent]
    else:
      value *= DecimalPowers[decimalExponent]
    if r.data[start] == '-': value = -value
  else:
    var token: string
    token.addSpan(r.data, start, r.pos)
    let consumed = parseutils.parseFloat(token, value)
    if consumed != token.len: fail(start, "invalid number")
  if classify(value) in {fcInf, fcNegInf, fcNan}:
    fail(start, "floating-point value out of range")
  dst = T(value)
  if classify(float64(dst)) in {fcInf, fcNegInf, fcNan}:
    fail(start, "floating-point value out of range")

proc beginObject(r: var JsonParser) =
  r.skip()
  if r.pos >= r.len or r.data[r.pos] != '{': fail(r.pos, "expected object")
  if r.depth >= DefaultMaxDepth:
    fail(r.pos, "maximum nesting depth exceeded")
  inc r.pos
  inc r.depth

proc nextField(r: var JsonParser; first: var bool; field: var Field): bool =
  r.skip()
  if first:
    if r.pos < r.len and r.data[r.pos] == '}':
      inc r.pos
      dec r.depth
      return false
    first = false
  else:
    if r.pos >= r.len: fail(r.pos, "unterminated object")
    if r.data[r.pos] == '}':
      inc r.pos
      dec r.depth
      return false
    if r.data[r.pos] != ',': fail(r.pos, "expected comma or end of object")
    inc r.pos
    r.skip()
    if r.pos < r.len and r.data[r.pos] == '}': fail(r.pos, "trailing comma in object")
  var start, length: int
  var escaped = false
  r.parseString(r.scratch, start, length, escaped)
  if escaped:
    field = Field(
      data: cast[ptr UncheckedArray[char]](cstring(r.scratch)),
      len: r.scratch.len
    )
  else:
    field = Field(
      data: cast[ptr UncheckedArray[char]](addr r.data[start]),
      len: length
    )
  r.skip()
  if r.pos >= r.len or r.data[r.pos] != ':': fail(r.pos, "expected colon")
  inc r.pos
  true

proc beginArray(r: var JsonParser) =
  r.skip()
  if r.pos >= r.len or r.data[r.pos] != '[': fail(r.pos, "expected array")
  if r.depth >= DefaultMaxDepth:
    fail(r.pos, "maximum nesting depth exceeded")
  inc r.pos
  inc r.depth

proc nextElement(r: var JsonParser; first: var bool): bool =
  r.skip()
  if first:
    if r.pos < r.len and r.data[r.pos] == ']':
      inc r.pos
      dec r.depth
      return false
    first = false
  else:
    if r.pos >= r.len: fail(r.pos, "unterminated array")
    if r.data[r.pos] == ']':
      inc r.pos
      dec r.depth
      return false
    if r.data[r.pos] != ',': fail(r.pos, "expected comma or end of array")
    inc r.pos
    r.skip()
    if r.pos < r.len and r.data[r.pos] == ']': fail(r.pos, "trailing comma in array")
  true

proc toString(field: Field): string =
  ## Materializes an owned copy of this ephemeral field name.
  result = newString(field.len)
  if field.len > 0:
    copyMem(addr result[0], addr field.data[0], field.len)

proc `==`(field: Field; value: string): bool {.inline.} =
  if field.len != value.len:
    false
  else:
    for i in 0..<value.len:
      if field.data[i] != value[i]: return false
    true

proc `==`(value: string; field: Field): bool {.inline.} = field == value

iterator jsonFields*(p: var JsonParser): string =
  ## Iterates an object and leaves `p` positioned at each field value.
  p.beginObject()
  var first = true
  var field: Field
  while p.nextField(first, field):
    yield field.toString()

proc skipString(r: var JsonParser) =
  r.skip()
  if r.pos >= r.len or r.data[r.pos] != '"': fail(r.pos, "expected string")
  inc r.pos
  while r.pos < r.len:
    while r.pos < r.len and r.data[r.pos] notin {'"', '\\'}:
      inc r.pos
    if r.pos >= r.len:
      break
    case r.data[r.pos]
    of '"':
      inc r.pos
      return
    of '\\':
      inc r.pos
      if r.pos >= r.len: fail(r.pos, "incomplete escape")
      let escaped = r.data[r.pos]
      inc r.pos
      case escaped
      of '"', '\\', '/', 'b', 'f', 'n', 'r', 't': discard
      of 'u':
        let high = r.readHex()
        if high in 0xd800..0xdbff:
          if r.pos + 2 > r.len or r.data[r.pos] != '\\' or r.data[r.pos + 1] != 'u':
            fail(r.pos, "high surrogate without low surrogate")
          r.pos += 2
          let low = r.readHex()
          if low notin 0xdc00..0xdfff: fail(r.pos, "invalid low surrogate")
        elif high in 0xdc00..0xdfff:
          fail(r.pos, "low surrogate without high surrogate")
      else: discard
    else:
      discard
  fail(r.pos, "unterminated string")

proc skipValue(r: var JsonParser) =
  ## Validates and discards exactly one value without materializing a DOM.
  r.skip()
  if r.pos >= r.len:
    fail(r.pos, "expected value")
  case r.data[r.pos]
  of 'n': r.readNull()
  of 't', 'f':
    var value: bool
    r.readBool(value)
  of '"': r.skipString()
  of '-', '.', '0'..'9':
    var start: int
    r.scanNumber(start, false)
  of '[':
    r.beginArray()
    var first = true
    while r.nextElement(first): r.skipValue()
  of '{':
    r.beginObject()
    var first = true
    var field: Field
    while r.nextField(first, field): r.skipValue()
  else:
    fail(r.pos, "expected value")

{.pop.}

proc skipJson*(p: var JsonParser) =
  ## Discards one JSON value, validating it without materializing it.
  p.skipValue()

proc finish(r: var JsonParser) =
  if r.depth != 0: fail(r.pos, "unterminated container")
  r.skip()
  if r.pos != r.len: fail(r.pos, "trailing data")

proc readJson*(dst: var string; r: var JsonParser; unknownFields: UnknownFieldPolicy) =
  r.readString(dst)

proc readJson*(dst: var bool; r: var JsonParser; unknownFields: UnknownFieldPolicy) =
  r.readBool(dst)

proc readJson*[T: SomeInteger](dst: var T; r: var JsonParser;
                                unknownFields: UnknownFieldPolicy) =
  r.readInt(dst)

proc readJson*[T: SomeFloat](dst: var T; r: var JsonParser;
                              unknownFields: UnknownFieldPolicy) =
  r.readFloat(dst)

proc readJson*[T: enum](dst: var T; r: var JsonParser; unknownFields: UnknownFieldPolicy) =
  var value: string
  r.readString(value)
  try:
    dst = parseEnum[T](value)
  except ValueError:
    r.raiseExpected("a valid " & $T)

proc readJson*[T](dst: var Option[T]; r: var JsonParser; unknownFields: UnknownFieldPolicy) =
  if r.consumeNull():
    dst = none(T)
  else:
    var value: T
    mixin readJson
    readJson(value, r, unknownFields)
    dst = some(value)

proc readJson*[T](dst: var seq[T]; r: var JsonParser; unknownFields: UnknownFieldPolicy) =
  dst.setLen(0)
  r.beginArray()
  var first = true
  mixin readJson
  while r.nextElement(first):
    dst.add default(T)
    readJson(dst[^1], r, unknownFields)

proc readJson*[I, T](dst: var array[I, T]; r: var JsonParser;
                      unknownFields: UnknownFieldPolicy) =
  r.beginArray()
  var index = 0
  var first = true
  mixin readJson
  while r.nextElement(first):
    if index >= dst.len: r.raiseExpected("array with " & $dst.len & " elements")
    readJson(dst[I(index + ord(low(I)))], r, unknownFields)
    inc index
  if index != dst.len: r.raiseExpected("array with " & $dst.len & " elements")

proc readJson*[T: tuple](dst: var T; r: var JsonParser; unknownFields: UnknownFieldPolicy) =
  r.beginArray()
  var first = true
  mixin readJson
  for _, field in fieldPairs(dst):
    if not r.nextElement(first):
      r.raiseExpected("tuple with the expected number of elements")
    readJson(field, r, unknownFields)
  if r.nextElement(first): r.raiseExpected("tuple with the expected number of elements")

proc readJson*[T: object](dst: var T; r: var JsonParser; unknownFields: UnknownFieldPolicy) =
  r.beginObject()
  mixin readJson
  var first = true
  var jsonField: Field
  while r.nextField(first, jsonField):
    var known = false
    for name, field in fieldPairs(dst):
      if jsonField == name:
        readJson(field, r, unknownFields)
        known = true
    if not known:
      if unknownFields == ufReject:
        r.raiseExpected("known field, got \"" & jsonField.toString() & "\"")
      r.skipValue()

proc readJson*[T: ref object](dst: var T; r: var JsonParser;
                               unknownFields: UnknownFieldPolicy) =
  if r.consumeNull():
    dst = nil
  else:
    new dst
    mixin readJson
    readJson(dst[], r, unknownFields)

proc readJson*(dst: var RawJson; r: var JsonParser; unknownFields: UnknownFieldPolicy) =
  r.skip()
  let start = r.pos
  r.skipValue()
  let len = r.pos - start
  var raw: string
  {.cast(noSideEffect).}:
    copyMem(beginStore(raw, len), addr r.data[start], len)
    endStore(raw)
  dst = RawJson(raw)

proc reserve(w: var JsonWriter; extra: int) {.inline.} =
  let required = w.pos + extra
  if required > w.output.len:
    if w.data != nil:
      w.output.endStore()
    let newLen = max(required, max(64, w.output.len * 2))
    w.data = w.output.beginStore(newLen)

proc append(w: var JsonWriter; source: ptr UncheckedArray[char]; start, len: int) {.inline.} =
  if len > 0:
    w.reserve(len)
    copyMem(addr w.data[w.pos], addr source[start], len)
    w.pos += len

proc write*(w: var JsonWriter; value: string) {.inline.} =
  ## Appends raw JSON syntax from a custom serializer.
  if value.len > 0:
    w.append(cast[ptr UncheckedArray[char]](cstring(value)), 0, value.len)

proc put(w: var JsonWriter; c: char) {.inline.} =
  w.reserve(1)
  w.data[w.pos] = c
  inc w.pos

proc escapeJson*(w: var JsonWriter; value: string) =
  ## Writes one JSON string, including quotes and required escapes.
  w.put '"'
  let data = cast[ptr UncheckedArray[char]](cstring(value))
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
      w.append(data, runStart, i - runStart)
      if escaped.len > 0:
        w.write escaped
      else:
        w.write "\\u00"
        const Hex = "0123456789abcdef"
        w.put Hex[(ord(c) shr 4) and 0xf]
        w.put Hex[ord(c) and 0xf]
      runStart = i + 1
  w.append(data, runStart, value.len - runStart)
  w.put '"'

template writeKnownField(w: var JsonWriter; comma: var bool; name: static[string];
                         value: untyped) =
  if comma: w.put ','
  else: comma = true
  const prefix = "\"" & name & "\":"
  w.write prefix
  writeJson(w, value)

proc writeJson*(w: var JsonWriter; value: string) =
  w.escapeJson(value)

proc writeJson*(w: var JsonWriter; value: bool) =
  w.write(if value: "true" else: "false")

proc writeUint(w: var JsonWriter; value: uint64) {.inline.} =
  var digits {.noinit.}: array[24, char]
  var number = value
  var pos = digits.len - 1
  while number >= 100:
    let original = number
    number = number div 100
    let index = int((original - number * 100) shl 1)
    digits[pos] = Digits100[index + 1]
    digits[pos - 1] = Digits100[index]
    pos -= 2
  if number < 10:
    digits[pos] = char(ord('0') + number)
  else:
    let index = int(number shl 1)
    digits[pos] = Digits100[index + 1]
    digits[pos - 1] = Digits100[index]
    dec pos
  w.append(cast[ptr UncheckedArray[char]](addr digits[0]), pos, digits.len - pos)

proc writeJson*[T: SomeInteger](w: var JsonWriter; value: T) =
  when T is SomeUnsignedInt:
    w.writeUint(uint64(value))
  else:
    let signed = int64(value)
    if signed < 0:
      w.put '-'
      w.writeUint(uint64(-(signed + 1)) + 1)
    else:
      w.writeUint(uint64(signed))

proc writeJson*[T: SomeFloat](w: var JsonWriter; value: T) =
  if classify(float64(value)) in {fcInf, fcNegInf, fcNan}:
    raise newException(ValueError, "JSON cannot represent NaN or infinity")
  var buffer {.noinit.}: array[65, char]
  let len = writeFloatToBufferRoundtrip(buffer, value)
  w.append(cast[ptr UncheckedArray[char]](addr buffer[0]), 0, len)

proc writeJson*[T: enum](w: var JsonWriter; value: T) =
  w.escapeJson($value)

proc writeJson*[T](w: var JsonWriter; value: Option[T]) =
  if value.isSome:
    mixin writeJson
    writeJson(w, value.get)
  else:
    w.write "null"

proc writeJson*[T](w: var JsonWriter; value: seq[T]) =
  w.put '['
  var comma = false
  mixin writeJson
  for item in value:
    if comma: w.put ','
    else: comma = true
    writeJson(w, item)
  w.put ']'

proc writeJson*[I, T](w: var JsonWriter; value: array[I, T]) =
  w.put '['
  var comma = false
  mixin writeJson
  for item in value:
    if comma: w.put ','
    else: comma = true
    writeJson(w, item)
  w.put ']'

proc writeJson*[T: tuple](w: var JsonWriter; value: T) =
  w.put '['
  var comma = false
  mixin writeJson
  for _, field in fieldPairs(value):
    if comma: w.put ','
    else: comma = true
    writeJson(w, field)
  w.put ']'

proc writeJson*[T: object](w: var JsonWriter; value: T) =
  w.put '{'
  var comma = false
  mixin writeJson
  for name, field in fieldPairs(value):
    writeKnownField(w, comma, name, field)
  w.put '}'

proc writeJson*[T: ref object](w: var JsonWriter; value: T) =
  if value.isNil:
    w.write "null"
  else:
    mixin writeJson
    writeJson(w, value[])

proc writeJson*(w: var JsonWriter; value: RawJson) =
  w.write string(value)

proc finish(w: var JsonWriter): string =
  if w.data != nil:
    w.output.endStore()
    w.data = nil
  w.output.setLen(w.pos)
  w.output

proc canonicalizeValue(r: var JsonParser; w: var JsonWriter) =
  case r.kind
  of jkNull:
    r.readNull()
    w.write "null"
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
    w.append(r.data, start, r.pos - start)
  of jkArray:
    r.beginArray()
    w.put '['
    var comma = false
    var first = true
    while r.nextElement(first):
      if comma: w.put ','
      else: comma = true
      r.canonicalizeValue(w)
    w.put ']'
  of jkObject:
    r.beginObject()
    w.put '{'
    var comma = false
    var first = true
    var field: Field
    while r.nextField(first, field):
      if comma: w.put ','
      else: comma = true
      w.escapeJson(field.toString())
      w.put ':'
      r.canonicalizeValue(w)
    w.put '}'

proc readJson*(dst: var CanonRawJson; r: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  var writer = JsonWriter()
  r.canonicalizeValue(writer)
  dst = CanonRawJson(writer.finish())

proc writeJson*(w: var JsonWriter; value: CanonRawJson) =
  w.write string(value)

proc fromJson*[T](input: string; typ: typedesc[T];
                  unknownFields = ufSkip): T =
  ## Decodes one complete JSON value from `input`.
  var reader = JsonParser(
    data: cast[ptr UncheckedArray[char]](cstring(input)), len: input.len
  )
  mixin readJson
  readJson(result, reader, unknownFields)
  reader.finish()

proc fromJson*[T](input: string; dst: var T;
                  unknownFields = ufSkip) =
  ## Decodes one complete JSON value directly into `dst`.
  var reader = JsonParser(
    data: cast[ptr UncheckedArray[char]](cstring(input)), len: input.len
  )
  mixin readJson
  readJson(dst, reader, unknownFields)
  reader.finish()

proc toJson*[T](value: T): string =
  ## Serializes `value` directly into its final string buffer.
  var writer = JsonWriter()
  mixin writeJson
  writeJson(writer, value)
  writer.finish()

iterator jsonItems*[T](input: string; typ: typedesc[T];
                       unknownFields = ufSkip): T =
  ## Decodes the elements of one top-level JSON array lazily.
  var reader = JsonParser(
    data: cast[ptr UncheckedArray[char]](cstring(input)), len: input.len
  )
  reader.beginArray()
  var first = true
  mixin readJson
  while reader.nextElement(first):
    var value: T
    readJson(value, reader, unknownFields)
    yield value
  reader.finish()
