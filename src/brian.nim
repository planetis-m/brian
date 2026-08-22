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
    # An ephemeral object field name.  Ordinary unescaped names borrow the
    # input; escaped names borrow reader-owned scratch storage.
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
      # Storage capacity until `finish` truncates it to the written length.
    data: ptr UncheckedArray[char]
      # A write cursor into `output`; the minimum capacity keeps it heap-backed.
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

proc raiseParseError*(p: JsonParser; msg: string) {.noinline, noreturn.} =
  ## Raises a parse error suitable for custom `readJson` overloads.
  raise newException(JsonParsingError, "JSON at byte " & $p.pos & ": " & msg)

proc skip(p: var JsonParser) {.inline.} =
  while p.pos < p.len and p.data[p.pos] in {' ', '\t', '\n', '\r'}:
    inc p.pos

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

proc readHex(p: var JsonParser): int =
  if p.pos + 4 > p.len:
    p.raiseParseError("incomplete Unicode escape")
  for _ in 0..<4:
    let v = hexValue(p.data[p.pos])
    if v < 0: p.raiseParseError("invalid Unicode escape")
    result = (result shl 4) or v
    inc p.pos

proc addSpan(dst: var string; src: ptr UncheckedArray[char]; start, stop: int) {.inline.} =
  let length = stop - start
  if length > 0:
    let oldLength = dst.len
    {.cast(noSideEffect).}:
      copyMem(beginStore(dst, oldLength + length, oldLength), addr src[start], length)
      if oldLength < 8:
        endStore(dst)

proc parseString(p: var JsonParser; dst: var string; rawStart: var int;
                 rawLength: var int; hadEscape: var bool) =
  p.skip()
  if p.pos >= p.len or p.data[p.pos] != '"':
    p.raiseParseError("expected string")
  inc p.pos
  rawStart = p.pos
  var runStart = p.pos
  while p.pos < p.len:
    while p.pos < p.len and p.data[p.pos] notin {'"', '\\'}:
      inc p.pos
    if p.pos >= p.len:
      break
    case p.data[p.pos]
    of '"':
      rawLength = p.pos - rawStart
      let stringEnd = p.pos
      inc p.pos
      if hadEscape:
        dst.addSpan(p.data, runStart, stringEnd)
      return
    of '\\':
      if not hadEscape:
        hadEscape = true
        dst.setLen(0)
      dst.addSpan(p.data, runStart, p.pos)
      inc p.pos
      if p.pos >= p.len: p.raiseParseError("incomplete escape")
      let escaped = p.data[p.pos]
      inc p.pos
      case escaped
      of '"', '\\', '/', '\'': dst.add escaped
      of 'b': dst.add '\b'
      of 'f': dst.add '\f'
      of 'n': dst.add '\n'
      of 'r': dst.add '\r'
      of 't': dst.add '\t'
      of 'v': dst.add '\v'
      of 'u':
        var codePoint = p.readHex()
        if codePoint in 0xd800..0xdbff:
          if p.pos + 2 > p.len or p.data[p.pos] != '\\' or p.data[p.pos + 1] != 'u':
            p.raiseParseError("high surrogate without low surrogate")
          p.pos += 2
          let low = p.readHex()
          if low notin 0xdc00..0xdfff: p.raiseParseError("invalid low surrogate")
          codePoint = 0x10000 + ((codePoint - 0xd800) shl 10) + (low - 0xdc00)
        dst.addCodePoint(codePoint)
      else:
        dst.add '\\'
        dst.add escaped
      runStart = p.pos
    else:
      discard
  p.raiseParseError("unterminated string")

proc readString(p: var JsonParser; dst: var string) =
  var start = 0
  var length = 0
  var escaped = false
  var decoded = ""
  p.parseString(decoded, start, length, escaped)
  if escaped:
    dst = decoded
  else:
    dst.setLen(0)
    dst.addSpan(p.data, start, start + length)

proc consumeNull(p: var JsonParser): bool {.inline.} =
  p.skip()
  result = p.len - p.pos >= 4 and p.data[p.pos] == 'n' and
    p.data[p.pos + 1] == 'u' and p.data[p.pos + 2] == 'l' and
    p.data[p.pos + 3] == 'l'
  if result:
    p.pos += 4

proc readNull(p: var JsonParser) =
  if not p.consumeNull():
    p.raiseParseError("expected null")

proc readBool(p: var JsonParser; dst: var bool) =
  p.skip()
  if p.len - p.pos >= 4 and p.data[p.pos] == 't' and p.data[p.pos + 1] == 'r' and
      p.data[p.pos + 2] == 'u' and p.data[p.pos + 3] == 'e':
    dst = true
    p.pos += 4
  elif p.len - p.pos >= 5 and p.data[p.pos] == 'f' and p.data[p.pos + 1] == 'a' and
      p.data[p.pos + 2] == 'l' and p.data[p.pos + 3] == 's' and p.data[p.pos + 4] == 'e':
    dst = false
    p.pos += 5
  else:
    p.raiseParseError("expected boolean")

proc scanNumber(p: var JsonParser): int =
  ## Matches the permissive token shape used by `std/parsejson.parseNumber`.
  ## Typed readers validate the scanned token during conversion.
  p.skip()
  result = p.pos
  if p.pos < p.len and p.data[p.pos] == '-': inc p.pos
  while p.pos < p.len and p.data[p.pos] in {'0'..'9'}: inc p.pos
  if p.pos < p.len and p.data[p.pos] == '.':
    inc p.pos
    while p.pos < p.len and p.data[p.pos] in {'0'..'9'}: inc p.pos
  if p.pos < p.len and p.data[p.pos] in {'e', 'E'}:
    inc p.pos
    if p.pos < p.len and p.data[p.pos] in {'+', '-'}: inc p.pos
    while p.pos < p.len and p.data[p.pos] in {'0'..'9'}: inc p.pos

proc readInt[T: SomeInteger](p: var JsonParser; dst: var T) =
  p.skip()
  var negative = false
  if p.pos < p.len and p.data[p.pos] == '-':
    negative = true
    inc p.pos
  if p.pos >= p.len: p.raiseParseError("incomplete integer")
  let limit =
    when T is SomeUnsignedInt:
      uint64(high(T))
    else:
      uint64(high(T)) + uint64(ord(negative))
  var value = 0'u64
  if p.data[p.pos] notin {'0'..'9'}:
    p.raiseParseError("expected digit")
  while p.pos < p.len and p.data[p.pos] in {'0'..'9'}:
    let digit = uint64(ord(p.data[p.pos]) - ord('0'))
    if value > (limit - digit) div 10'u64:
      p.raiseParseError("integer overflow")
    value = value * 10'u64 + digit
    inc p.pos
  if p.pos < p.len and p.data[p.pos] in {'.', 'e', 'E'}:
    p.raiseParseError("expected integer")
  when T is SomeUnsignedInt:
    if negative and value != 0:
      p.raiseParseError("negative value for unsigned integer")
    dst = T(value)
  else:
    if negative:
      if value == limit:
        dst = low(T)
      else:
        dst = T(-int64(value))
    else:
      dst = T(value)

proc readFloat[T: SomeFloat](p: var JsonParser; dst: var T) =
  ## Uses a small exact fast path and the stdlib converter for difficult values.
  p.skip()
  let start = p.pos
  if p.pos < p.len and p.data[p.pos] == '-': inc p.pos
  if p.pos >= p.len: p.raiseParseError("incomplete number")
  var significand = 0'u64
  var storedDigits = 0
  var fractionDigits = 0
  template addDigit() =
    let digit = uint64(ord(p.data[p.pos]) - ord('0'))
    if significand != 0 or digit != 0:
      if storedDigits < 19:
        significand = significand * 10'u64 + digit
        inc storedDigits
    inc p.pos
  while p.pos < p.len and p.data[p.pos] in {'0'..'9'}: addDigit()
  if p.pos < p.len and p.data[p.pos] == '.':
    inc p.pos
    while p.pos < p.len and p.data[p.pos] in {'0'..'9'}:
      addDigit()
      if fractionDigits < 100000: inc fractionDigits
  var exponent = 0
  if p.pos < p.len and p.data[p.pos] in {'e', 'E'}:
    inc p.pos
    var exponentNegative = false
    if p.pos < p.len and p.data[p.pos] in {'+', '-'}:
      exponentNegative = p.data[p.pos] == '-'
      inc p.pos
    let exponentStart = p.pos
    while p.pos < p.len and p.data[p.pos] in {'0'..'9'}:
      if exponent < 100000:
        exponent = exponent * 10 + ord(p.data[p.pos]) - ord('0')
        if exponent > 100000: exponent = 100000
      inc p.pos
    if p.pos == exponentStart: p.raiseParseError("missing exponent digits")
    if exponentNegative: exponent = -exponent
  let decimalExponent = exponent - fractionDigits
  var value = 0.0
  if significand == 0:
    value = if p.data[start] == '-': -0.0 else: 0.0
  # Every stored 19-digit significand exceeds the exact-integer threshold and
  # therefore takes the stdlib fallback below.
  elif significand < (1'u64 shl 53) and decimalExponent in -22..22:
    value = float64(significand)
    if decimalExponent < 0:
      value /= DecimalPowers[-decimalExponent]
    else:
      value *= DecimalPowers[decimalExponent]
    if p.data[start] == '-': value = -value
  else:
    var token = ""
    token.addSpan(p.data, start, p.pos)
    let consumed = parseutils.parseFloat(token, value)
    if consumed != token.len: p.raiseParseError("invalid number")
  dst = T(value)

proc beginObject(p: var JsonParser) =
  p.skip()
  if p.pos >= p.len or p.data[p.pos] != '{': p.raiseParseError("expected object")
  if p.depth > DepthLimit:
    p.raiseParseError("maximum nesting depth exceeded")
  inc p.pos
  inc p.depth

proc nextField(p: var JsonParser; first: var bool; f: var FieldName): bool =
  p.skip()
  result = true
  if first:
    first = false
    if p.pos < p.len and p.data[p.pos] == '}':
      inc p.pos
      dec p.depth
      result = false
  else:
    if p.pos >= p.len: p.raiseParseError("unterminated object")
    if p.data[p.pos] == '}':
      inc p.pos
      dec p.depth
      result = false
    else:
      if p.data[p.pos] != ',': p.raiseParseError("expected comma or end of object")
      inc p.pos
      p.skip()
      if p.pos < p.len and p.data[p.pos] == '}': p.raiseParseError("trailing comma in object")
  if result:
    if p.pos >= p.len or p.data[p.pos] != '"':
      p.raiseParseError("expected string")
    inc p.pos
    let start = p.pos
    while p.pos < p.len and p.data[p.pos] notin {'"', '\\'}:
      inc p.pos
    if p.pos >= p.len:
      p.raiseParseError("unterminated string")
    if p.data[p.pos] == '"':
      f = FieldName(data: cast[ptr UncheckedArray[char]](addr p.data[start]),
                    len: p.pos - start)
      inc p.pos
    else:
      p.pos = start - 1
      var rawStart = 0
      var rawLength = 0
      var escaped = false
      p.parseString(p.scratch, rawStart, rawLength, escaped)
      f = FieldName(
        data: cast[ptr UncheckedArray[char]](cstring(p.scratch)),
        len: p.scratch.len
      )
    p.skip()
    if p.pos >= p.len or p.data[p.pos] != ':': p.raiseParseError("expected colon")
    inc p.pos

proc beginArray(p: var JsonParser) =
  p.skip()
  if p.pos >= p.len or p.data[p.pos] != '[': p.raiseParseError("expected array")
  if p.depth > DepthLimit:
    p.raiseParseError("maximum nesting depth exceeded")
  inc p.pos
  inc p.depth

proc nextElement(p: var JsonParser; first: var bool): bool =
  p.skip()
  result = true
  if first:
    first = false
    if p.pos < p.len and p.data[p.pos] == ']':
      inc p.pos
      dec p.depth
      result = false
  else:
    if p.pos >= p.len: p.raiseParseError("unterminated array")
    if p.data[p.pos] == ']':
      inc p.pos
      dec p.depth
      result = false
    else:
      if p.data[p.pos] != ',': p.raiseParseError("expected comma or end of array")
      inc p.pos
      p.skip()
      if p.pos < p.len and p.data[p.pos] == ']': p.raiseParseError("trailing comma in array")

proc toString(f: FieldName): string =
  ## Materializes an owned copy of this ephemeral field name.
  if f.len > 0:
    copyMem(beginStore(result, f.len), f.data, f.len)
    endStore(result)

proc `==`(f: FieldName; value: string): bool {.inline.} =
  result = f.len == value.len and cmpMem(f.data, cstring(value), f.len) == 0

proc skipUnicodeEscape(p: var JsonParser) {.noinline.} =
  let high = p.readHex()
  if high in 0xd800..0xdbff:
    if p.pos + 2 > p.len or p.data[p.pos] != '\\' or p.data[p.pos + 1] != 'u':
      p.raiseParseError("high surrogate without low surrogate")
    p.pos += 2
    let low = p.readHex()
    if low notin 0xdc00..0xdfff: p.raiseParseError("invalid low surrogate")

proc skipString(p: var JsonParser) =
  p.skip()
  if p.pos >= p.len or p.data[p.pos] != '"': p.raiseParseError("expected string")
  inc p.pos
  while p.pos < p.len:
    while p.pos < p.len and p.data[p.pos] notin {'"', '\\'}:
      inc p.pos
    if p.pos >= p.len:
      break
    case p.data[p.pos]
    of '"':
      inc p.pos
      return
    of '\\':
      inc p.pos
      if p.pos >= p.len: p.raiseParseError("incomplete escape")
      let escaped = p.data[p.pos]
      inc p.pos
      case escaped
      of '"', '\\', '/', 'b', 'f', 'n', 'r', 't': discard
      of 'u': p.skipUnicodeEscape()
      else:
        discard
    else:
      discard
  p.raiseParseError("unterminated string")

proc skipValue(p: var JsonParser) =
  ## Validates and discards exactly one value without materializing a DOM.
  p.skip()
  if p.pos >= p.len:
    p.raiseParseError("expected value")
  case p.data[p.pos]
  of 'n': p.readNull()
  of 't', 'f':
    var value = false
    p.readBool(value)
  of '"': p.skipString()
  of '-', '.', '0'..'9':
    discard p.scanNumber()
  of '[':
    p.beginArray()
    var first = true
    while p.nextElement(first): p.skipValue()
  of '{':
    p.beginObject()
    var first = true
    var f: FieldName
    while p.nextField(first, f): p.skipValue()
  else:
    p.raiseParseError("expected value")

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
  var f: FieldName
  while p.nextField(first, f):
    yield f.toString()

proc skipJson*(p: var JsonParser) =
  ## Discards one JSON value, validating it without materializing it.
  p.skipValue()

proc finish(p: var JsonParser) =
  if p.depth != 0: p.raiseParseError("unterminated container")
  p.skip()
  if p.pos != p.len: p.raiseParseError("trailing data")

proc readJson*(dst: var string; p: var JsonParser; unknownFields: UnknownFieldPolicy) =
  p.readString(dst)

proc readJson*(dst: var bool; p: var JsonParser; unknownFields: UnknownFieldPolicy) =
  p.readBool(dst)

proc readJson*[T: SomeInteger](dst: var T; p: var JsonParser;
                                unknownFields: UnknownFieldPolicy) =
  p.readInt(dst)

proc readJson*[T: SomeFloat](dst: var T; p: var JsonParser;
                              unknownFields: UnknownFieldPolicy) =
  p.readFloat(dst)

proc readJson*[T: enum](dst: var T; p: var JsonParser; unknownFields: UnknownFieldPolicy) =
  var value: string
  p.readString(value)
  try:
    dst = parseEnum[T](value)
  except ValueError:
    p.raiseParseError("expected a valid " & $T)

proc readJson*[T](dst: var Option[T]; p: var JsonParser; unknownFields: UnknownFieldPolicy) =
  if p.consumeNull():
    dst = none(T)
  else:
    var value = default(T)
    mixin readJson
    readJson(value, p, unknownFields)
    dst = some(value)

proc readJson*[T](dst: var seq[T]; p: var JsonParser; unknownFields: UnknownFieldPolicy) =
  p.beginArray()
  var first = true
  mixin readJson
  while p.nextElement(first):
    dst.add default(T)
    readJson(dst[^1], p, unknownFields)

proc readJson*[T](dst: var (SomeSet[T]|set[T]); p: var JsonParser;
                  unknownFields: UnknownFieldPolicy) =
  p.beginArray()
  var first = true
  mixin readJson
  while p.nextElement(first):
    var item = default(T)
    readJson(item, p, unknownFields)
    dst.incl item

proc readJson*[T](dst: var (Table[string, T]|OrderedTable[string, T]);
                  p: var JsonParser; unknownFields: UnknownFieldPolicy) =
  p.beginObject()
  var first = true
  var f: FieldName
  mixin readJson
  while p.nextField(first, f):
    let key = f.toString()
    var value = default(T)
    readJson(value, p, unknownFields)
    dst[key] = value

proc readJson*[I, T](dst: var array[I, T]; p: var JsonParser;
                     unknownFields: UnknownFieldPolicy) =
  p.beginArray()
  var first = true
  mixin readJson
  for item in mitems(dst):
    if not p.nextElement(first):
      p.raiseParseError("expected array with " & $dst.len & " elements")
    readJson(item, p, unknownFields)
  if p.nextElement(first):
    p.raiseParseError("expected array with " & $dst.len & " elements")

proc readObjectFields[T](dst: var T; p: var JsonParser;
                         unknownFields: UnknownFieldPolicy) {.inline.} =
  p.beginObject()
  mixin readJson
  var first = true
  var f: FieldName
  while p.nextField(first, f):
    var known = false
    for name, field in fieldPairs(dst):
      if f == name:
        readJson(field, p, unknownFields)
        known = true
        break
    if not known:
      if unknownFields == ufReject:
        p.raiseParseError("expected known field, got \"" & f.toString() & "\"")
      p.skipValue()

proc readJson*[T: tuple](dst: var T; p: var JsonParser; unknownFields: UnknownFieldPolicy) =
  when isNamedTuple(T):
    readObjectFields(dst, p, unknownFields)
  else:
    p.beginArray()
    var first = true
    mixin readJson
    for field in fields(dst):
      if not p.nextElement(first):
        p.raiseParseError("expected tuple with the expected number of elements")
      readJson(field, p, unknownFields)
    if p.nextElement(first):
      p.raiseParseError("expected tuple with the expected number of elements")

proc readJson*[T: object](dst: var T; p: var JsonParser; unknownFields: UnknownFieldPolicy) =
  readObjectFields(dst, p, unknownFields)

proc readJson*[T: ref object](dst: var T; p: var JsonParser;
                               unknownFields: UnknownFieldPolicy) =
  if p.consumeNull():
    dst = nil
  else:
    new dst
    mixin readJson
    readJson(dst[], p, unknownFields)

proc readJson*(dst: var RawJson; p: var JsonParser; unknownFields: UnknownFieldPolicy) =
  p.skip()
  let start = p.pos
  p.skipValue()
  let raw = FieldName(
    data: cast[ptr UncheckedArray[char]](addr p.data[start]),
    len: p.pos - start
  )
  dst = RawJson(raw.toString())

proc reserve(w: var JsonWriter; extra: int) {.inline.} =
  let required = w.pos + extra
  if required > w.output.len:
    if w.data != nil:
      w.output.endStore()
    let newLen = max(required, max(MinWriteCapacity, w.output.len * 2))
    w.data = w.output.beginStore(newLen)

proc append(w: var JsonWriter; src: ptr UncheckedArray[char]; start, len: int) {.inline.} =
  if len > 0:
    w.reserve(len)
    copyMem(addr w.data[w.pos], addr src[start], len)
    w.pos += len

proc write*(w: var JsonWriter; value: string) {.inline.} =
  ## Appends raw JSON syntax from a custom serializer.
  if value.len > 0:
    w.append(cast[ptr UncheckedArray[char]](cstring(value)), 0, value.len)

template put(w: var JsonWriter; c: char) =
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

template writeObject() =
  w.put '{'
  var comma = false
  mixin writeJson
  for name, field in fieldPairs(value):
    if comma: w.put ','
    else: comma = true
    w.write "\"" & name & "\":"
    writeJson(w, field)
  w.put '}'

proc writeJson*[T: tuple](w: var JsonWriter; value: T) =
  when isNamedTuple(T):
    writeObject()
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
  writeObject()

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
  result = move(w.output)

proc canonicalizeValue(p: var JsonParser; w: var JsonWriter) =
  case p.kind
  of jkNull:
    p.readNull()
    w.write "null"
  of jkBool:
    var value = false
    p.readBool(value)
    w.writeJson(value)
  of jkString:
    var value = ""
    p.readString(value)
    w.writeJson(value)
  of jkNumber:
    let start = p.scanNumber()
    w.append(p.data, start, p.pos - start)
  of jkArray:
    p.beginArray()
    w.put '['
    var comma = false
    var first = true
    while p.nextElement(first):
      if comma: w.put ','
      else: comma = true
      p.canonicalizeValue(w)
    w.put ']'
  of jkObject:
    p.beginObject()
    w.put '{'
    var comma = false
    var first = true
    var f: FieldName
    while p.nextField(first, f):
      if comma: w.put ','
      else: comma = true
      w.escapeJson(f.toString())
      w.put ':'
      p.canonicalizeValue(w)
    w.put '}'

proc readJson*(dst: var CanonRawJson; p: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  var writer = JsonWriter()
  p.canonicalizeValue(writer)
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
