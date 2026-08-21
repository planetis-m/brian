## A direct, typed JSON reader and writer.
##
## `brian` decodes JSON directly into Nim values.  It does not build a DOM or
## tokenize scalar values before their destination type is known. Raw string
## bytes follow `std/parsejson` compatibility semantics; JSON `\\u` escapes
## are decoded.

import std/[formatfloat, math, options, parseutils, sets, strutils, tables]
from std/typetraits import isNamedTuple

type
  JsonParsingError* = object of ValueError
    ## Raised for malformed JSON and JSON values that do not fit their target type.

  JsonKind* = enum
    jkNull, jkBool, jkNumber, jkString, jkArray, jkObject

  UnknownFieldPolicy* = enum
    ufSkip, ufReject

  FieldName = object
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
      ## Storage capacity until `finish` truncates it to the written length.
    data: ptr UncheckedArray[char]
      ## A write cursor into `output`; the minimum capacity keeps it heap-backed.
    pos: int

  RawJson* = distinct string
    ## Trusted bytes representing one JSON value.

  CanonRawJson* = distinct string
    ## A deterministic, whitespace-free re-emission of one JSON value.

proc `=copy`(dest: var JsonWriter; src: JsonWriter) {.error.}

const
  DepthLimit = 1_000
  MinWriteCapacity = 64
    ## Keeps writer storage heap-backed so `data` remains valid across moves.
  Digits100 =
    "000102030405060708091011121314151617181920212223242526272829" &
    "303132333435363738394041424344454647484950515253545556575859" &
    "606162636465666768697071727374757677787980818283848586878889" &
    "90919293949596979899"
  DecimalPowers: array[-22..22, float64] = [
    1.0e-22, 1.0e-21, 1.0e-20, 1.0e-19, 1.0e-18, 1.0e-17, 1.0e-16,
    1.0e-15, 1.0e-14, 1.0e-13, 1.0e-12, 1.0e-11, 1.0e-10, 1.0e-9,
    1.0e-8, 1.0e-7, 1.0e-6, 1.0e-5, 1.0e-4, 1.0e-3, 1.0e-2, 1.0e-1,
    1.0,
    1.0e1, 1.0e2, 1.0e3, 1.0e4, 1.0e5, 1.0e6, 1.0e7, 1.0e8, 1.0e9,
    1.0e10, 1.0e11, 1.0e12, 1.0e13, 1.0e14, 1.0e15, 1.0e16, 1.0e17,
    1.0e18, 1.0e19, 1.0e20, 1.0e21, 1.0e22
  ]

proc raiseParseError*(p: JsonParser; message: string) {.noinline, noreturn.} =
  ## Raises a parse error suitable for custom `readJson` overloads.
  raise newException(JsonParsingError, "JSON at byte " & $p.pos & ": " & message)

proc skip(r: var JsonParser) {.inline.} =
  while r.pos < r.len and r.data[r.pos] in {' ', '\t', '\n', '\r'}:
    inc r.pos

proc hexValue(c: char): int {.inline.} =
  case c
  of '0'..'9': result = ord(c) - ord('0')
  of 'a'..'f': result = ord(c) - ord('a') + 10
  of 'A'..'F': result = ord(c) - ord('A') + 10
  else: result = -1

proc addCodePoint(dst: var string; codePoint: int) =
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
    r.raiseParseError("incomplete Unicode escape")
  for _ in 0..<4:
    let v = hexValue(r.data[r.pos])
    if v < 0: r.raiseParseError("invalid Unicode escape")
    result = (result shl 4) or v
    inc r.pos

proc addSpan(dst: var string; source: ptr UncheckedArray[char]; start, stop: int) {.inline.} =
  let length = stop - start
  if length > 0:
    let oldLength = dst.len
    {.cast(noSideEffect).}:
      copyMem(beginStore(dst, oldLength + length, oldLength), addr source[start], length)
      if oldLength < 8:
        endStore(dst)

proc parseString(r: var JsonParser; dst: var string; rawStart: var int;
                 rawLength: var int; hadEscape: var bool) =
  r.skip()
  if r.pos >= r.len or r.data[r.pos] != '"':
    r.raiseParseError("expected string")
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
      if r.pos >= r.len: r.raiseParseError("incomplete escape")
      let escaped = r.data[r.pos]
      inc r.pos
      case escaped
      of '"', '\\', '/', '\'': dst.add escaped
      of 'b': dst.add '\b'
      of 'f': dst.add '\f'
      of 'n': dst.add '\n'
      of 'r': dst.add '\r'
      of 't': dst.add '\t'
      of 'v': dst.add '\v'
      of 'u':
        var codePoint = r.readHex()
        if codePoint in 0xd800..0xdbff:
          if r.pos + 2 > r.len or r.data[r.pos] != '\\' or r.data[r.pos + 1] != 'u':
            r.raiseParseError("high surrogate without low surrogate")
          r.pos += 2
          let low = r.readHex()
          if low notin 0xdc00..0xdfff: r.raiseParseError("invalid low surrogate")
          codePoint = 0x10000 + ((codePoint - 0xd800) shl 10) + (low - 0xdc00)
        dst.addCodePoint(codePoint)
      else:
        dst.add '\\'
        dst.add escaped
      runStart = r.pos
    else:
      discard
  r.raiseParseError("unterminated string")

proc readString(r: var JsonParser; dst: var string) =
  var start = 0
  var length = 0
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
  result = r.len - r.pos >= 4 and r.data[r.pos] == 'n' and
    r.data[r.pos + 1] == 'u' and r.data[r.pos + 2] == 'l' and
    r.data[r.pos + 3] == 'l'
  if result:
    r.pos += 4

proc readNull(r: var JsonParser) =
  if not r.consumeNull():
    r.raiseParseError("expected null")

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
    r.raiseParseError("expected boolean")

proc scanNumber(r: var JsonParser): int =
  ## Matches the permissive token shape used by `std/parsejson.parseNumber`.
  ## Typed readers validate the scanned token during conversion.
  r.skip()
  result = r.pos
  if r.pos < r.len and r.data[r.pos] == '-': inc r.pos
  while r.pos < r.len and r.data[r.pos] in {'0'..'9'}: inc r.pos
  if r.pos < r.len and r.data[r.pos] == '.':
    inc r.pos
    while r.pos < r.len and r.data[r.pos] in {'0'..'9'}: inc r.pos
  if r.pos < r.len and r.data[r.pos] in {'e', 'E'}:
    inc r.pos
    if r.pos < r.len and r.data[r.pos] in {'+', '-'}: inc r.pos
    while r.pos < r.len and r.data[r.pos] in {'0'..'9'}: inc r.pos

proc readInt[T: SomeInteger](r: var JsonParser; dst: var T) =
  r.skip()
  var negative = false
  if r.pos < r.len and r.data[r.pos] == '-':
    negative = true
    inc r.pos
  if r.pos >= r.len: r.raiseParseError("incomplete integer")
  let limit =
    when T is SomeUnsignedInt:
      uint64(high(T))
    else:
      uint64(high(T)) + uint64(ord(negative))
  var value = 0'u64
  if r.data[r.pos] notin {'0'..'9'}:
    r.raiseParseError("expected digit")
  while r.pos < r.len and r.data[r.pos] in {'0'..'9'}:
    let digit = uint64(ord(r.data[r.pos]) - ord('0'))
    if value > (limit - digit) div 10'u64:
      r.raiseParseError("integer overflow")
    value = value * 10'u64 + digit
    inc r.pos
  if r.pos < r.len and r.data[r.pos] in {'.', 'e', 'E'}:
    r.raiseParseError("expected integer")
  when T is SomeUnsignedInt:
    if negative and value != 0:
      r.raiseParseError("negative value for unsigned integer")
    dst = T(value)
  else:
    if negative:
      if value == limit:
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
  if r.pos >= r.len: r.raiseParseError("incomplete number")
  var significand = 0'u64
  var storedDigits = 0
  var fractionDigits = 0
  template addDigit() =
    let digit = uint64(ord(r.data[r.pos]) - ord('0'))
    if significand != 0 or digit != 0:
      if storedDigits < 19:
        significand = significand * 10'u64 + digit
        inc storedDigits
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
    if r.pos == exponentStart: r.raiseParseError("missing exponent digits")
    if exponentNegative: exponent = -exponent
  let decimalExponent = exponent - fractionDigits
  var value = 0.0
  if significand == 0:
    value = if r.data[start] == '-': -0.0 else: 0.0
  # Every stored 19-digit significand exceeds the exact-integer threshold and
  # therefore takes the stdlib fallback below.
  elif significand < (1'u64 shl 53) and decimalExponent in -22..22:
    value = float64(significand)
    if decimalExponent < 0:
      value /= DecimalPowers[-decimalExponent]
    else:
      value *= DecimalPowers[decimalExponent]
    if r.data[start] == '-': value = -value
  else:
    var token = ""
    token.addSpan(r.data, start, r.pos)
    let consumed = parseutils.parseFloat(token, value)
    if consumed != token.len: r.raiseParseError("invalid number")
  dst = T(value)

proc beginObject(r: var JsonParser) =
  r.skip()
  if r.pos >= r.len or r.data[r.pos] != '{': r.raiseParseError("expected object")
  if r.depth > DepthLimit:
    r.raiseParseError("maximum nesting depth exceeded")
  inc r.pos
  inc r.depth

proc nextField(r: var JsonParser; first: var bool; field: var FieldName): bool =
  r.skip()
  result = true
  if first:
    first = false
    if r.pos < r.len and r.data[r.pos] == '}':
      inc r.pos
      dec r.depth
      result = false
  else:
    if r.pos >= r.len: r.raiseParseError("unterminated object")
    if r.data[r.pos] == '}':
      inc r.pos
      dec r.depth
      result = false
    else:
      if r.data[r.pos] != ',': r.raiseParseError("expected comma or end of object")
      inc r.pos
      r.skip()
      if r.pos < r.len and r.data[r.pos] == '}': r.raiseParseError("trailing comma in object")
  if result:
    if r.pos >= r.len or r.data[r.pos] != '"':
      r.raiseParseError("expected string")
    inc r.pos
    let start = r.pos
    while r.pos < r.len and r.data[r.pos] notin {'"', '\\'}:
      inc r.pos
    if r.pos >= r.len:
      r.raiseParseError("unterminated string")
    if r.data[r.pos] == '"':
      field = FieldName(data: cast[ptr UncheckedArray[char]](addr r.data[start]),
                        len: r.pos - start)
      inc r.pos
    else:
      r.pos = start - 1
      var rawStart = 0
      var rawLength = 0
      var escaped = false
      r.parseString(r.scratch, rawStart, rawLength, escaped)
      field = FieldName(
        data: cast[ptr UncheckedArray[char]](cstring(r.scratch)),
        len: r.scratch.len
      )
    r.skip()
    if r.pos >= r.len or r.data[r.pos] != ':': r.raiseParseError("expected colon")
    inc r.pos

proc beginArray(r: var JsonParser) =
  r.skip()
  if r.pos >= r.len or r.data[r.pos] != '[': r.raiseParseError("expected array")
  if r.depth > DepthLimit:
    r.raiseParseError("maximum nesting depth exceeded")
  inc r.pos
  inc r.depth

proc nextElement(r: var JsonParser; first: var bool): bool =
  r.skip()
  result = true
  if first:
    first = false
    if r.pos < r.len and r.data[r.pos] == ']':
      inc r.pos
      dec r.depth
      result = false
  else:
    if r.pos >= r.len: r.raiseParseError("unterminated array")
    if r.data[r.pos] == ']':
      inc r.pos
      dec r.depth
      result = false
    else:
      if r.data[r.pos] != ',': r.raiseParseError("expected comma or end of array")
      inc r.pos
      r.skip()
      if r.pos < r.len and r.data[r.pos] == ']': r.raiseParseError("trailing comma in array")

proc toString(field: FieldName): string =
  ## Materializes an owned copy of this ephemeral field name.
  if field.len > 0:
    copyMem(beginStore(result, field.len), field.data, field.len)
    endStore(result)

{.push boundChecks: off.}

proc `==`(field: FieldName; value: string): bool {.inline.} =
  result = field.len == value.len
  if result:
    for i in 0..<value.len:
      if field.data[i] != value[i]:
        result = false
        break

{.pop.}

proc `==`(value: string; field: FieldName): bool {.inline.} =
  result = field == value

proc skipUnicodeEscape(r: var JsonParser) {.noinline.} =
  let high = r.readHex()
  if high in 0xd800..0xdbff:
    if r.pos + 2 > r.len or r.data[r.pos] != '\\' or r.data[r.pos + 1] != 'u':
      r.raiseParseError("high surrogate without low surrogate")
    r.pos += 2
    let low = r.readHex()
    if low notin 0xdc00..0xdfff: r.raiseParseError("invalid low surrogate")

proc skipString(r: var JsonParser) =
  r.skip()
  if r.pos >= r.len or r.data[r.pos] != '"': r.raiseParseError("expected string")
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
      if r.pos >= r.len: r.raiseParseError("incomplete escape")
      let escaped = r.data[r.pos]
      inc r.pos
      case escaped
      of '"', '\\', '/', 'b', 'f', 'n', 'r', 't': discard
      of 'u': r.skipUnicodeEscape()
      else:
        discard
    else:
      discard
  r.raiseParseError("unterminated string")

proc skipValue(r: var JsonParser) =
  ## Validates and discards exactly one value without materializing a DOM.
  r.skip()
  if r.pos >= r.len:
    r.raiseParseError("expected value")
  case r.data[r.pos]
  of 'n': r.readNull()
  of 't', 'f':
    var value = false
    r.readBool(value)
  of '"': r.skipString()
  of '-', '.', '0'..'9':
    discard r.scanNumber()
  of '[':
    r.beginArray()
    var first = true
    while r.nextElement(first): r.skipValue()
  of '{':
    r.beginObject()
    var first = true
    var field: FieldName
    while r.nextField(first, field): r.skipValue()
  else:
    r.raiseParseError("expected value")

proc kind*(p: var JsonParser): JsonKind =
  p.skip()
  if p.pos >= p.len: p.raiseParseError("expected value")
  case p.data[p.pos]
  of 'n': result = jkNull
  of 't', 'f': result = jkBool
  of '"': result = jkString
  of '[': result = jkArray
  of '{': result = jkObject
  of '-', '.', '0'..'9': result = jkNumber
  else: p.raiseParseError("expected value")

iterator jsonFields*(p: var JsonParser): string =
  ## Iterates an object and leaves `p` positioned at each field value.
  p.beginObject()
  var first = true
  var field: FieldName
  while p.nextField(first, field):
    yield field.toString()

proc skipJson*(p: var JsonParser) =
  ## Discards one JSON value, validating it without materializing it.
  p.skipValue()

proc finish(r: var JsonParser) =
  if r.depth != 0: r.raiseParseError("unterminated container")
  r.skip()
  if r.pos != r.len: r.raiseParseError("trailing data")

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
    r.raiseParseError("expected a valid " & $T)

proc readJson*[T](dst: var Option[T]; r: var JsonParser; unknownFields: UnknownFieldPolicy) =
  if r.consumeNull():
    dst = none(T)
  else:
    var value = default(T)
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

proc readJson*[T](dst: var (SomeSet[T]|set[T]); r: var JsonParser;
                  unknownFields: UnknownFieldPolicy) =
  r.beginArray()
  var first = true
  mixin readJson
  while r.nextElement(first):
    var item = default(T)
    readJson(item, r, unknownFields)
    dst.incl item

proc readJson*[T](dst: var (Table[string, T]|OrderedTable[string, T]);
                  r: var JsonParser; unknownFields: UnknownFieldPolicy) =
  r.beginObject()
  var first = true
  var fieldName: FieldName
  mixin readJson
  while r.nextField(first, fieldName):
    let key = fieldName.toString()
    var value = default(T)
    readJson(value, r, unknownFields)
    dst[key] = value

proc readJson*[I, T](dst: var array[I, T]; r: var JsonParser;
                      unknownFields: UnknownFieldPolicy) =
  r.beginArray()
  var first = true
  mixin readJson
  for item in mitems(dst):
    if not r.nextElement(first):
      r.raiseParseError("expected array with " & $dst.len & " elements")
    readJson(item, r, unknownFields)
  if r.nextElement(first):
    r.raiseParseError("expected array with " & $dst.len & " elements")

proc readObjectFields[T](dst: var T; r: var JsonParser;
                         unknownFields: UnknownFieldPolicy) {.inline.} =
  r.beginObject()
  mixin readJson
  var first = true
  var jsonField: FieldName
  while r.nextField(first, jsonField):
    var known = false
    for name, field in fieldPairs(dst):
      if jsonField == name:
        readJson(field, r, unknownFields)
        known = true
        break
    if not known:
      if unknownFields == ufReject:
        r.raiseParseError("expected known field, got \"" & jsonField.toString() & "\"")
      r.skipValue()

proc readJson*[T: tuple](dst: var T; r: var JsonParser; unknownFields: UnknownFieldPolicy) =
  when isNamedTuple(T):
    readObjectFields(dst, r, unknownFields)
  else:
    r.beginArray()
    var first = true
    mixin readJson
    for field in fields(dst):
      if not r.nextElement(first):
        r.raiseParseError("expected tuple with the expected number of elements")
      readJson(field, r, unknownFields)
    if r.nextElement(first):
      r.raiseParseError("expected tuple with the expected number of elements")

proc readJson*[T: object](dst: var T; r: var JsonParser; unknownFields: UnknownFieldPolicy) =
  readObjectFields(dst, r, unknownFields)

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
  let raw = FieldName(
    data: cast[ptr UncheckedArray[char]](addr r.data[start]),
    len: r.pos - start
  )
  dst = RawJson(raw.toString())

proc reserve(w: var JsonWriter; extra: int) {.inline.} =
  let required = w.pos + extra
  if required > w.output.len:
    if w.data != nil:
      w.output.endStore()
    let newLen = max(required, max(MinWriteCapacity, w.output.len * 2))
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
        const HexChars = "0123456789ABCDEF"
        w.put HexChars[(ord(c) shr 4) and 0xf]
        if c == '\v':
          w.put 'b'
        else:
          w.put HexChars[ord(c) and 0xf]
      runStart = i + 1
  w.append(data, runStart, value.len - runStart)
  w.put '"'

proc writeJson*(w: var JsonWriter; value: string) =
  w.escapeJson(value)

proc writeJson*(w: var JsonWriter; value: bool) =
  w.write(if value: "true" else: "false")

proc writeUint(w: var JsonWriter; value: uint64) {.inline.} =
  # Every byte in digits[pos..<digits.len] is assigned before it is appended.
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
  # `writeFloatToBufferRoundtrip` initializes buffer[0..<len].
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

template writeArray() =
  w.put '['
  var comma = false
  mixin writeJson
  for item in value:
    if comma: w.put ','
    else: comma = true
    writeJson(w, item)
  w.put ']'

proc writeJson*[T](w: var JsonWriter; value: seq[T]) =
  writeArray()

proc writeJson*[I, T](w: var JsonWriter; value: array[I, T]) =
  writeArray()

proc writeJson*[T](w: var JsonWriter; value: set[T]|SomeSet[T]) =
  writeArray()

proc writeJson*[T](w: var JsonWriter;
                   value: Table[string, T]|OrderedTable[string, T]) =
  w.put '{'
  var comma = false
  mixin writeJson
  for key, item in pairs(value):
    if comma: w.put ','
    else: comma = true
    w.escapeJson(key)
    w.put ':'
    writeJson(w, item)
  w.put '}'

proc writeObject[T](w: var JsonWriter; value: T) {.inline.} =
  w.put '{'
  var comma = false
  mixin writeJson
  for name, field in fieldPairs(value):
    if comma: w.put ','
    else: comma = true
    const prefix = "\"" & name & "\":"
    w.write prefix
    writeJson(w, field)
  w.put '}'

proc writeJson*[T: tuple](w: var JsonWriter; value: T) =
  when isNamedTuple(T):
    writeObject(w, value)
  else:
    w.put '['
    var comma = false
    mixin writeJson
    for field in fields(value):
      if comma: w.put ','
      else: comma = true
      writeJson(w, field)
    w.put ']'

proc writeJson*[T: object](w: var JsonWriter; value: T) =
  writeObject(w, value)

proc writeJson*[T: ref object](w: var JsonWriter; value: T) =
  if value.isNil:
    w.write "null"
  else:
    mixin writeJson
    writeJson(w, value[])

proc writeJson*(w: var JsonWriter; value: RawJson) =
  w.write string(value)

proc finish(w: var JsonWriter): string =
  w.output.setLen(w.pos)
  if w.data != nil:
    w.output.endStore()
    w.data = nil
  result = w.output

proc canonicalizeValue(r: var JsonParser; w: var JsonWriter) =
  case r.kind
  of jkNull:
    r.readNull()
    w.write "null"
  of jkBool:
    var value = false
    r.readBool(value)
    w.writeJson(value)
  of jkString:
    var value = ""
    r.readString(value)
    w.writeJson(value)
  of jkNumber:
    let start = r.scanNumber()
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
    var field: FieldName
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

proc fromJson*[T](input: string; dst: var T;
                  unknownFields = ufSkip) =
  ## Decodes one complete JSON value directly into `dst`.
  var reader = JsonParser(
    data: cast[ptr UncheckedArray[char]](cstring(input)), len: input.len
  )
  mixin readJson
  readJson(dst, reader, unknownFields)
  reader.finish()

proc fromJson*[T](input: string; typ: typedesc[T];
                  unknownFields = ufSkip): T =
  ## Decodes one complete JSON value from `input`.
  fromJson(input, result, unknownFields)

proc toJson*[T](value: T): string =
  ## Serializes `value` directly into its final string buffer.
  var writer = JsonWriter()
  mixin writeJson
  writeJson(writer, value)
  result = writer.finish()

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
    var value = default(T)
    readJson(value, reader, unknownFields)
    yield value
  reader.finish()
