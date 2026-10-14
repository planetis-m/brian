## Typed JSON decoding and encoding for Nimony values.
##
## Use `fromJson` and `toJson` for ordinary values. Custom types can provide
## `readJson` and `writeJson` overloads.
##
## Nothing raises. A parser that hits malformed input records the first
## error, moves to the end of the input and turns every later read into a no-op,
## so custom readers stay straight-line code. `fromJson` and `jsonLines` check
## once per value and return a `Result[T, JsonError]`; `toJson` likewise
## returns the output or the first error a writer recorded.

{.feature: "staticContracts".}

import std/[options, result, sets, tables]
from std/parseutils import parseFloat

type
  JsonKind* = enum
    jkNull, jkBool, jkNumber, jkString, jkArray, jkObject

  UnknownFieldPolicy* = enum
    ufSkip, ufReject

  JsonErrorKind* = enum
    ## What went wrong; `$` on a `JsonError` spells it out.
    jeNone
    jeCustom  ## a custom reader's `parseError` message
    jeEscape
    jeUnicodeIncomplete
    jeUnicodeInvalid
    jeStringUnterminated
    jeStringExpected
    jeNullExpected
    jeBoolExpected
    jeIntIncomplete
    jeDigitExpected
    jeIntOverflow
    jeIntExpected
    jeUnsignedNegative
    jeNumberExpected
    jeObjectExpected
    jeArrayExpected
    jeDepthExceeded
    jeObjectUnterminated
    jeArrayUnterminated
    jeObjectCommaExpected
    jeArrayCommaExpected
    jeObjectTrailingComma
    jeArrayTrailingComma
    jeColonExpected
    jeValueExpected
    jeContainerUnterminated
    jeTrailingData
    jeEnumExpected
    jeNonFinite

  JsonError* = object
    ## The first error a decode ran into.
    kind*: JsonErrorKind
    pos*: int          ## byte offset into the input, or the output when writing
    message: string    ## the text of a `jeCustom` error

  JsonParser* = object
    ## Parses JSON for custom `readJson` overloads. A cursor over a borrowed
    ## view of the input.
    data: openArray[char]
    pos: Natural
    depth: int
    error: JsonError  ## the first error; later ones are ignored

  JsonWriter* = object
    ## Writes JSON for custom `writeJson` overloads.
    data: string
    error: JsonError  ## the first error; later ones are ignored

  RawJson* = distinct string
    ## A JSON value emitted without parsing, quoting, or escaping.
    ##
    ## Values read into `RawJson` are validated. When constructing one manually,
    ## provide exactly one valid JSON value.

  CanonRawJson* = distinct string
    ## A JSON value rewritten without insignificant whitespace.
    ##
    ## Object field order and number spellings are preserved.

  JsonReadable = concept of HasDefault
    proc readJson(dst: var Self; p: var JsonParser; unknownFields: UnknownFieldPolicy)

  JsonWritable = concept
    proc writeJson(w: var JsonWriter; value: Self)

func `$`*(value: RawJson): string {.inline.} = string(value)
func `$`*(value: CanonRawJson): string {.inline.} = string(value)

const
  DepthLimit = 1_000
  ErrorMessages: array[JsonErrorKind, string] = [
    jeNone: "no error",
    jeCustom: "", # the text is in `JsonError.message`
    jeEscape: "incomplete escape",
    jeUnicodeIncomplete: "incomplete Unicode escape",
    jeUnicodeInvalid: "invalid Unicode escape",
    jeStringUnterminated: "unterminated string",
    jeStringExpected: "expected string",
    jeNullExpected: "expected null",
    jeBoolExpected: "expected boolean",
    jeIntIncomplete: "incomplete integer",
    jeDigitExpected: "expected digit",
    jeIntOverflow: "integer overflow",
    jeIntExpected: "expected integer",
    jeUnsignedNegative: "negative value for unsigned integer",
    jeNumberExpected: "expected number",
    jeObjectExpected: "expected object",
    jeArrayExpected: "expected array",
    jeDepthExceeded: "maximum nesting depth exceeded",
    jeObjectUnterminated: "unterminated object",
    jeArrayUnterminated: "unterminated array",
    jeObjectCommaExpected: "expected comma or end of object",
    jeArrayCommaExpected: "expected comma or end of array",
    jeObjectTrailingComma: "trailing comma in object",
    jeArrayTrailingComma: "trailing comma in array",
    jeColonExpected: "expected colon",
    jeValueExpected: "expected value",
    jeContainerUnterminated: "unterminated container",
    jeTrailingData: "trailing data",
    jeEnumExpected: "expected a known enum value",
    jeNonFinite: "NaN or infinity has no JSON form"
  ]

# ── errors ────────────────────────────────────────────────────────────────

proc setError(p: var JsonParser; kind: JsonErrorKind) {.noinline.} =
  # The first error wins; the parser then stands at the end of the input, so
  # every later read fails without doing work and every loop ends.
  if p.error.kind == jeNone:
    p.error.kind = kind
    p.error.pos = p.pos
  p.pos = p.data.len

proc parseError*(p: var JsonParser; msg: string) {.noinline.} =
  ## Records a parse error for custom `readJson` overloads. As with built-in
  ## errors, only the first one is kept and every later read does nothing.
  if p.error.kind == jeNone:
    p.error.message = msg
  p.setError(jeCustom)

func hasError*(p: JsonParser): bool {.inline.} =
  ## Whether a parse error has been recorded.
  p.error.kind != jeNone

proc `$`*(e: JsonError): string =
  ## `JSON at byte N: message`. Text is only ever built here.
  result = "JSON at byte " & $e.pos & ": "
  if e.kind == jeCustom:
    result.add e.message
  elif ord(e.kind) >= 0 and ord(e.kind) <= ord(high(JsonErrorKind)):
    # An enum conversion is not range checked; this lets the index be proven.
    result.add ErrorMessages[e.kind]

proc setError(w: var JsonWriter; kind: JsonErrorKind) {.noinline.} =
  # The first error wins. Writing carries on, but `toJson` discards the output.
  if w.error.kind == jeNone:
    w.error.kind = kind
    w.error.pos = w.data.len

proc writeError*(w: var JsonWriter; msg: string) {.noinline.} =
  ## Records a write error for custom `writeJson` overloads; `toJson` then
  ## returns it instead of the output.
  if w.error.kind == jeNone:
    w.error.message = msg
  w.setError(jeCustom)

# ── spans ─────────────────────────────────────────────────────────────────

proc addSpan(dst: var string; src: openArray[char]; start, stop: int) {.inline.} =
  ## Appends src[start ..< stop].
  if start >= 0 and start < stop and stop <= src.len:
    let length = stop - start
    let oldLength = dst.len
    copyMem(beginStore(dst, oldLength + length, oldLength), addr src[start], length)
    if oldLength < 8:
      endStore(dst)

proc toString(src: openArray[char]; start, stop: int): string {.inline.} =
  result = ""
  result.addSpan(src, start, stop)

func `==`*(a: openArray[char]; b: string): bool {.inline.} =
  ## Compares a borrowed field name with a string.
  result = a.len == b.len and (a.len == 0 or cmpMem(addr a[0], readRawData(b), a.len) == 0)

template `==`*(a: string; b: openArray[char]): bool =
  b == a

proc `$`*(s: openArray[char]): string {.inline.} =
  ## An owned copy of a borrowed field name.
  toString(s, 0, s.len)

# ── scanning ──────────────────────────────────────────────────────────────
#
# Character classes are spelled as comparisons: a `set[char]` test compiles to
# a load from a 32-byte bitset, which costs more than one or two compares.

template isDigit(c: char): bool = cast[uint](ord(c) - ord('0')) <= 9'u

template isSpace(c: char): bool =
  c <= ' ' and (c == ' ' or c == '\n' or c == '\t' or c == '\r')

proc skip(p: var JsonParser) {.inline.} =
  var pos = p.pos
  while pos < p.data.len and isSpace(p.data[pos]):
    inc pos
  p.pos = pos

func hexValue(c: char): int {.inline.} =
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
  ## Four hex digits; the cursor must stand on the first.
  let i = p.pos
  if i >= p.data.len - 3:
    p.setError(jeUnicodeIncomplete)
    result = 0
  else:
    let a = hexValue(p.data[i])
    let b = hexValue(p.data[i + 1])
    let c = hexValue(p.data[i + 2])
    let d = hexValue(p.data[i + 3])
    if (a or b or c or d) < 0:
      p.setError(jeUnicodeInvalid)
      result = 0
    else:
      result = (a shl 12) or (b shl 8) or (c shl 4) or d
      p.pos = i + 4

template scanStringRun(p: JsonParser) =
  # Advances `p` over the next run of bytes that are neither `"` nor `\`.
  # The cursor lives in a local so the code generator keeps it in a register.
  var pos = p.pos
  while pos < p.data.len and p.data[pos] != '"' and p.data[pos] != '\\':
    inc pos
  p.pos = pos

proc parseStringBody(p: var JsonParser; dst: var string): bool =
  ## The cursor stands just past the opening quote and ends just past the
  ## closing one. Returns whether the string had escapes: if so it is decoded
  ## into `dst`, which is cleared at the first one; otherwise `dst` is left
  ## alone and the caller takes the bytes between the quotes from the input.
  result = false
  var runStart = p.pos
  var closed = false
  while not closed and p.pos < p.data.len:
    scanStringRun(p)
    if p.pos < p.data.len:
      let c = p.data[p.pos]
      if c == '"':
        if result:
          dst.addSpan(p.data, runStart, p.pos)
        inc p.pos
        closed = true
      else: # a backslash
        if not result:
          result = true
          dst.setLen(0)
        dst.addSpan(p.data, runStart, p.pos)
        inc p.pos
        if p.pos >= p.data.len:
          p.setError(jeEscape)
        else:
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
            let mark = p.pos
            if codePoint in 0xd800..0xdbff and
                mark < p.data.len - 1 and p.data[mark] == '\\' and
                p.data[mark + 1] == 'u':
              p.pos = mark + 2
              let low = p.readHex()
              if low in 0xdc00..0xdfff:
                codePoint = 0x10000 + ((codePoint - 0xd800) shl 10) + (low - 0xdc00)
              elif not p.hasError:
                # Leave this six-byte escape for the next iteration.
                p.pos = mark
            dst.addCodePoint(codePoint)
          else:
            dst.add '\\'
            dst.add escaped
          runStart = p.pos
  if not closed:
    p.setError(jeStringUnterminated)

proc openString(p: var JsonParser): bool {.inline.} =
  ## Consumes the opening quote of the next value.
  p.skip()
  result = p.pos < p.data.len and p.data[p.pos] == '"'
  if result:
    inc p.pos
  else:
    p.setError(jeStringExpected)

proc readString(p: var JsonParser; dst: var string) =
  if p.openString():
    let start = p.pos
    if not p.parseStringBody(dst) and not p.hasError:
      dst.setLen(0)
      dst.addSpan(p.data, start, p.pos - 1)

proc consumeNull(p: var JsonParser): bool {.inline.} =
  p.skip()
  let i = p.pos
  result = false
  if i < p.data.len - 3 and p.data[i] == 'n' and p.data[i + 1] == 'u' and
      p.data[i + 2] == 'l' and p.data[i + 3] == 'l':
    p.pos = i + 4
    result = true

proc readNull(p: var JsonParser) =
  if not p.consumeNull():
    p.setError(jeNullExpected)

proc readBool(p: var JsonParser; dst: var bool) =
  p.skip()
  let i = p.pos
  if i < p.data.len - 3 and p.data[i] == 't' and p.data[i + 1] == 'r' and
      p.data[i + 2] == 'u' and p.data[i + 3] == 'e':
    dst = true
    p.pos = i + 4
  elif i < p.data.len - 4 and p.data[i] == 'f' and p.data[i + 1] == 'a' and
      p.data[i + 2] == 'l' and p.data[i + 3] == 's' and p.data[i + 4] == 'e':
    dst = false
    p.pos = i + 5
  else:
    p.setError(jeBoolExpected)

proc scanNumber(p: var JsonParser): int =
  # Matches the permissive token shape used by `std/parsejson.parseNumber`.
  # Typed readers validate the scanned token during conversion.
  p.skip()
  result = p.pos
  var pos = p.pos
  if pos < p.data.len and p.data[pos] == '-': inc pos
  while pos < p.data.len and isDigit(p.data[pos]): inc pos
  if pos < p.data.len and p.data[pos] == '.':
    inc pos
    while pos < p.data.len and isDigit(p.data[pos]): inc pos
  if pos < p.data.len and (p.data[pos] == 'e' or p.data[pos] == 'E'):
    inc pos
    if pos < p.data.len and (p.data[pos] == '+' or p.data[pos] == '-'): inc pos
    while pos < p.data.len and isDigit(p.data[pos]): inc pos
  p.pos = pos

proc readInt[T: SomeInteger](p: var JsonParser; dst: var T) =
  p.skip()
  var pos = p.pos
  var negative = false
  if pos < p.data.len and p.data[pos] == '-':
    negative = true
    inc pos
  if pos >= p.data.len:
    p.setError(jeIntIncomplete)
  elif not isDigit(p.data[pos]):
    p.pos = pos
    p.setError(jeDigitExpected)
  else:
    let limit =
      when T is SomeUnsignedInt:
        uint64(high(T))
      else:
        uint64(high(T)) + uint64(ord(negative))
    var value = 0'u64
    var overflow = false
    while pos < p.data.len and isDigit(p.data[pos]):
      let digit = uint64(ord(p.data[pos]) - ord('0'))
      if value > (limit - digit) div 10'u64:
        overflow = true
        break
      value = value * 10'u64 + digit
      inc pos
    p.pos = pos
    if overflow:
      p.setError(jeIntOverflow)
    elif pos < p.data.len and (p.data[pos] == '.' or p.data[pos] == 'e' or p.data[pos] == 'E'):
      p.setError(jeIntExpected)
    else:
      when T is SomeUnsignedInt:
        if negative and value != 0'u64:
          p.setError(jeUnsignedNegative)
        else:
          dst = T(value)
      else:
        if negative:
          if value == limit:
            dst = low(T)
          else:
            dst = T(-int64(value))
        else:
          dst = T(value)

template readFloat(p: var JsonParser; dst: untyped) =
  # The number is whatever `parseFloat` reads.
  p.skip()
  let start = p.pos
  let consumed = parseFloat(p.data.toOpenArray(start, p.data.len - 1), dst)
  if consumed > 0:
    p.pos = start + consumed
  else:
    p.setError(jeNumberExpected)

# ── containers ────────────────────────────────────────────────────────────

proc containerError(p: var JsonParser; objectErr: JsonErrorKind; bracket: char) {.noinline.} =
  # Kept out of line so `nextItem` stays small enough to inline. Every object
  # error is followed by its array twin in `JsonErrorKind`.
  p.setError(if bracket == '{' or bracket == '}': objectErr else: succ(objectErr))

proc beginContainer(p: var JsonParser; open: char) {.inline.} =
  ## Consumes `open`, which is `{` or `[`.
  p.skip()
  if p.pos >= p.data.len or p.data[p.pos] != open:
    p.containerError(jeObjectExpected, open)
  elif p.depth > DepthLimit:
    p.setError(jeDepthExceeded)
  else:
    inc p.pos
    inc p.depth

proc nextItem(p: var JsonParser; first: var bool; close: char): bool {.inline.} =
  ## Moves to the next item of an open container, or consumes `close`, which
  ## is `}` or `]`, and returns false.
  p.skip()
  result = false
  if p.pos >= p.data.len:
    p.containerError(jeObjectUnterminated, close)
  elif first:
    first = false
    if p.data[p.pos] == close:
      inc p.pos
      dec p.depth
    else:
      result = true
  elif p.data[p.pos] == close:
    inc p.pos
    dec p.depth
  elif p.data[p.pos] != ',':
    p.containerError(jeObjectCommaExpected, close)
  else:
    inc p.pos
    p.skip()
    if p.pos < p.data.len and p.data[p.pos] == close:
      p.containerError(jeObjectTrailingComma, close)
    else:
      result = true

proc nextField(p: var JsonParser; first: var bool; nameStart, nameStop: var int;
               escaped: var bool; name: var string): bool =
  ## Moves to the next field of an open object and leaves the cursor at its
  ## value. An unescaped name is `p.data[nameStart ..< nameStop]`; an escaped
  ## one is decoded into `name`.
  result = p.nextItem(first, '}')
  if result:
    if p.pos >= p.data.len or p.data[p.pos] != '"':
      p.setError(jeStringExpected)
      result = false
    else:
      inc p.pos
      let start = p.pos
      scanStringRun(p)
      if p.pos < p.data.len and p.data[p.pos] == '"':
        escaped = false
        nameStart = start
        nameStop = p.pos
        inc p.pos
      else:
        p.pos = start
        escaped = p.parseStringBody(name)
      p.skip()
      if p.pos >= p.data.len or p.data[p.pos] != ':':
        p.setError(jeColonExpected)
        result = false
      else:
        inc p.pos

iterator jsonFields*(p: var JsonParser): openArray[char] {.sideEffect.} =
  ## Iterates object-field names and leaves `p` at the corresponding value.
  ##
  ## Each name is borrowed and remains valid only during the current iteration.
  p.beginContainer('{')
  var first = true
  var start = 0
  var stop = 0
  var escaped = false
  var name = ""
  while p.nextField(first, start, stop, escaped, name):
    if escaped:
      yield name.toOpenArray(0, name.len - 1)
    else:
      yield p.data.toOpenArray(start, stop - 1)

iterator jsonStrings(p: var JsonParser): openArray[char] {.sideEffect.} =
  ## The next string value, borrowed (yielded once, or not at all on error).
  if p.openString():
    let start = p.pos
    var decoded = ""
    let escaped = p.parseStringBody(decoded)
    if not p.hasError:
      if escaped:
        yield decoded.toOpenArray(0, decoded.len - 1)
      else:
        yield p.data.toOpenArray(start, p.pos - 2)

proc skipString(p: var JsonParser) =
  if p.openString():
    var closed = false
    while not closed and p.pos < p.data.len:
      scanStringRun(p)
      if p.pos < p.data.len:
        if p.data[p.pos] == '"':
          inc p.pos
          closed = true
        else: # a backslash
          inc p.pos
          if p.pos >= p.data.len:
            p.setError(jeEscape)
          else:
            let escaped = p.data[p.pos]
            inc p.pos
            if escaped == 'u': discard p.readHex()
    if not closed:
      p.setError(jeStringUnterminated)

proc skipJson*(p: var JsonParser) =
  ## Consumes and validates one JSON value without materializing it.
  p.skip()
  if p.pos >= p.data.len:
    p.setError(jeValueExpected)
  else:
    case p.data[p.pos]
    of 'n': p.readNull()
    of 't', 'f':
      var value = false
      p.readBool(value)
    of '"': p.skipString()
    of '-', '.', '0'..'9':
      discard p.scanNumber()
    of '[':
      p.beginContainer('[')
      var first = true
      while p.nextItem(first, ']'): p.skipJson()
    of '{':
      for _ in p.jsonFields: p.skipJson()
    else:
      p.setError(jeValueExpected)

proc kind*(p: var JsonParser): JsonKind =
  ## Returns the kind of the next JSON value without consuming it. After an
  ## error it reports `jkNull`.
  p.skip()
  result = jkNull
  if p.pos >= p.data.len:
    p.setError(jeValueExpected)
  else:
    case p.data[p.pos]
    of 'n': result = jkNull
    of 't', 'f': result = jkBool
    of '"': result = jkString
    of '[': result = jkArray
    of '{': result = jkObject
    of '-', '.', '0'..'9': result = jkNumber
    else: p.setError(jeValueExpected)

proc finish(p: var JsonParser) =
  if p.depth != 0:
    p.setError(jeContainerUnterminated)
  p.skip()
  if p.pos != p.data.len:
    p.setError(jeTrailingData)

# ── readers ───────────────────────────────────────────────────────────────

proc readJson*(dst: var string; p: var JsonParser; unknownFields: UnknownFieldPolicy) =
  p.readString(dst)

proc readJson*(dst: var bool; p: var JsonParser; unknownFields: UnknownFieldPolicy) =
  p.readBool(dst)

proc readJson*[T: SomeInteger](dst: var T; p: var JsonParser;
                               unknownFields: UnknownFieldPolicy) =
  p.readInt(dst)

proc readJson*(dst: var float64; p: var JsonParser; unknownFields: UnknownFieldPolicy) {.inline.} =
  p.readFloat(dst)

proc readJson*(dst: var float32; p: var JsonParser; unknownFields: UnknownFieldPolicy) {.inline.} =
  p.readFloat(dst)

# Ordinal and holey enums need separate overloads: a checked generic over
# `enum` cannot dispatch to either, and only ordinal enums iterate with `..`.

proc readEnum[T: OrdinalEnum](p: var JsonParser; dst: var T): bool =
  ## Matches the next string against each value's exact spelling.
  result = false
  for name in p.jsonStrings:
    for e in low(T)..high(T):
      if not result and name == $e:
        dst = e
        result = true

proc readEnum[T: HoleyEnum](p: var JsonParser; dst: var T): bool =
  ## Walks the ordinal range; holes spell as "", so an empty name never matches.
  result = false
  for name in p.jsonStrings:
    if name.len > 0:
      for i in ord(low(T))..ord(high(T)):
        let e = T(i)
        if not result and name == $e:
          dst = e
          result = true

proc readJson*[T: OrdinalEnum](dst: var T; p: var JsonParser;
                               unknownFields: UnknownFieldPolicy) =
  if not p.readEnum(dst) and not p.hasError:
    p.setError(jeEnumExpected)

proc readJson*[T: HoleyEnum](dst: var T; p: var JsonParser;
                             unknownFields: UnknownFieldPolicy) =
  if not p.readEnum(dst) and not p.hasError:
    p.setError(jeEnumExpected)

proc readJson*[T: OrdinalEnum](dst: var T; p: var JsonParser;
                               unknownFields: UnknownFieldPolicy; fallback: T) =
  ## Reads an enum using its exact JSON spelling, or stores `fallback` when the
  ## input string is unknown.
  if not p.readEnum(dst) and not p.hasError:
    dst = fallback

proc readJson*[T: HoleyEnum](dst: var T; p: var JsonParser;
                             unknownFields: UnknownFieldPolicy; fallback: T) =
  if not p.readEnum(dst) and not p.hasError:
    dst = fallback

proc readJson*[T: JsonReadable](dst: var Option[T]; p: var JsonParser;
                  unknownFields: UnknownFieldPolicy) =
  if p.consumeNull():
    dst = none[T]()
  else:
    var value = default(T)
    readJson(value, p, unknownFields)
    dst = some(value)

proc readJson*[T: JsonReadable](dst: var seq[T]; p: var JsonParser;
                  unknownFields: UnknownFieldPolicy) =
  p.beginContainer('[')
  var first = true
  while p.nextItem(first, ']'):
    dst.add default(T)
    let last = dst.len - 1
    if last >= 0:
      readJson(dst[last], p, unknownFields)

proc readJson*[T: Ordinal and JsonReadable](dst: var set[T]; p: var JsonParser;
                  unknownFields: UnknownFieldPolicy) =
  p.beginContainer('[')
  var first = true
  while p.nextItem(first, ']'):
    var item = default(T)
    readJson(item, p, unknownFields)
    dst.incl item

proc readJson*[T: Keyable and JsonReadable](dst: var HashSet[T]; p: var JsonParser;
                  unknownFields: UnknownFieldPolicy) =
  p.beginContainer('[')
  var first = true
  while p.nextItem(first, ']'):
    var item = default(T)
    readJson(item, p, unknownFields)
    dst.incl item

proc readJson*[T: JsonReadable](dst: var Table[string, T]; p: var JsonParser;
                  unknownFields: UnknownFieldPolicy) =
  for name in p.jsonFields:
    let key = $name
    var value = default(T)
    readJson(value, p, unknownFields)
    dst[key] = value

proc lengthError(p: var JsonParser; length: int) {.noinline.} =
  p.parseError("expected array with " & $length & " elements")

proc readJson*[I; T: JsonReadable](dst: var array[I, T]; p: var JsonParser;
                     unknownFields: UnknownFieldPolicy) =
  p.beginContainer('[')
  var first = true
  for item in mitems(dst):
    if p.nextItem(first, ']'):
      readJson(item, p, unknownFields)
    elif not p.hasError:
      p.lengthError(dst.len)
  if p.nextItem(first, ']'):
    p.lengthError(dst.len)

proc readObjectFields[T: object|tuple](dst: var T; p: var JsonParser;
                         unknownFields: UnknownFieldPolicy) {.inline.} =
  for name in p.jsonFields:
    var known = false
    for fieldName, field in fieldPairs(dst):
      if not known and name == fieldName:
        readJson(field, p, unknownFields)
        known = true
    if not known:
      if unknownFields == ufReject:
        p.parseError("expected known field, got \"" & $name & "\"")
      else:
        p.skipJson()

proc isNamedTuple[T: tuple](value: T): bool {.inline.} =
  # Nimony names the fields of an anonymous tuple `Field1`, `Field2`, ...
  result = true
  for fieldName, field in fieldPairs(value):
    when fieldName == "Field1":
      result = false

proc readJson*[T: tuple](dst: var T; p: var JsonParser;
                         unknownFields: UnknownFieldPolicy) =
  ## A named tuple reads as an object, an anonymous one as an array.
  if isNamedTuple(dst):
    readObjectFields(dst, p, unknownFields)
  else:
    var length = 0
    for field in fields(dst): inc length
    p.beginContainer('[')
    var first = true
    for field in fields(dst):
      if p.nextItem(first, ']'):
        readJson(field, p, unknownFields)
      elif not p.hasError:
        p.lengthError(length)
    if p.nextItem(first, ']'):
      p.lengthError(length)

proc readJson*[T: object](dst: var T; p: var JsonParser;
                          unknownFields: UnknownFieldPolicy) =
  readObjectFields(dst, p, unknownFields)

proc readJson*[T: JsonReadable](dst: var (nil ref T); p: var JsonParser;
                             unknownFields: UnknownFieldPolicy) =
  if p.consumeNull():
    dst = nil
  else:
    if dst == nil:
      new dst
    if dst != nil:
      readJson(dst[], p, unknownFields)

# ── writer ────────────────────────────────────────────────────────────────

proc write*(w: var JsonWriter; value: string) {.inline.} =
  ## Appends raw JSON syntax without validation or escaping.
  ##
  ## `value` must contain valid JSON syntax in the current output context.
  w.data.add value

proc put(w: var JsonWriter; c: char) {.inline.} =
  w.data.add c

proc putComma(w: var JsonWriter; comma: var bool) {.inline.} =
  ## Separates every item from the previous one.
  if comma: w.put ','
  else: comma = true

proc escapeJson(w: var JsonWriter; data: openArray[char]) =
  const HexChars = "0123456789ABCDEF"
  w.put '"'
  var runStart = 0
  for i in 0 ..< data.len:
    let c = data[i]
    if c == '"' or c == '\\' or c < ' ':
      w.data.addSpan(data, runStart, i)
      case c
      of '"': w.write "\\\""
      of '\\': w.write "\\\\"
      of '\b': w.write "\\b"
      of '\f': w.write "\\f"
      of '\n': w.write "\\n"
      of '\r': w.write "\\r"
      of '\t': w.write "\\t"
      of '\v': w.write "\\u000b"
      else:
        w.write "\\u00"
        w.put HexChars[(ord(c) shr 4) and 0xf]
        w.put HexChars[ord(c) and 0xf]
      runStart = i + 1
  w.data.addSpan(data, runStart, data.len)
  w.put '"'

proc escapeJson*(w: var JsonWriter; value: string) =
  ## Writes one JSON string, including quotes and required escapes.
  w.escapeJson(value.toOpenArray(0, value.len - 1))

proc writeJson*(w: var JsonWriter; value: string) =
  w.escapeJson(value)

proc writeJson*(w: var JsonWriter; value: bool) =
  w.write(if value: "true" else: "false")

proc writeJson*[T: SomeInteger](w: var JsonWriter; value: T) =
  when T is SomeUnsignedInt:
    w.data.addInt(uint64(value))
  else:
    w.data.addInt(int64(value))

template writeFloat(w: var JsonWriter; value: untyped) =
  # NaN and infinity have no JSON spelling: they fail the writer.
  if value != value or value - value != value - value:
    w.setError(jeNonFinite)
  else:
    w.data.addFloat(value)

proc writeJson*(w: var JsonWriter; value: float64) {.inline.} =
  w.writeFloat(value)

proc writeJson*(w: var JsonWriter; value: float32) {.inline.} =
  w.writeFloat(value)

proc writeJson*[T: enum](w: var JsonWriter; value: T) =
  w.escapeJson($value)

proc writeJson*[T: JsonWritable](w: var JsonWriter; value: Option[T]) =
  if value.isSome:
    writeJson(w, value.unsafeGet)
  else:
    w.write "null"

template writeArray(w: var JsonWriter; value: untyped) =
  w.put '['
  var comma = false
  for item in value:
    w.putComma(comma)
    writeJson(w, item)
  w.put ']'

proc writeJson*[T: JsonWritable](w: var JsonWriter; value: seq[T]) =
  writeArray(w, value)

proc writeJson*[I; T: JsonWritable](w: var JsonWriter; value: array[I, T]) =
  writeArray(w, value)

proc writeJson*[T: Ordinal and JsonWritable](w: var JsonWriter; value: set[T]) =
  w.put '['
  var comma = false
  for item in low(T)..high(T):
    if item in value:
      w.putComma(comma)
      writeJson(w, item)
  w.put ']'

proc writeJson*[T: Keyable and JsonWritable](w: var JsonWriter; value: HashSet[T]) =
  writeArray(w, value)

proc writeJson*[T: JsonWritable](w: var JsonWriter; value: Table[string, T]) =
  w.put '{'
  var comma = false
  for key, item in pairs(value):
    w.putComma(comma)
    w.escapeJson(key)
    w.put ':'
    writeJson(w, item)
  w.put '}'

proc writeObject[T: object|tuple](w: var JsonWriter; value: T) {.inline.} =
  w.put '{'
  var comma = false
  for name, field in fieldPairs(value):
    w.putComma(comma)
    w.put '"'
    w.write name
    w.write "\":"
    writeJson(w, field)
  w.put '}'

proc writeJson*[T: tuple](w: var JsonWriter; value: T) =
  if isNamedTuple(value):
    writeObject(w, value)
  else:
    w.put '['
    var comma = false
    for field in fields(value):
      w.putComma(comma)
      writeJson(w, field)
    w.put ']'

proc writeJson*[T: object](w: var JsonWriter; value: T) =
  writeObject(w, value)

proc writeJson*[T: JsonWritable](w: var JsonWriter; value: (nil ref T)) =
  if value == nil:
    w.write "null"
  else:
    writeJson(w, value[])

# ── raw values ────────────────────────────────────────────────────────────

proc readJson*(dst: var RawJson; p: var JsonParser; unknownFields: UnknownFieldPolicy) =
  p.skip()
  let start = p.pos
  p.skipJson()
  if not p.hasError:
    dst = RawJson(toString(p.data, start, p.pos))

proc writeJson*(w: var JsonWriter; value: RawJson) =
  w.write string(value)

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
    w.data.addSpan(p.data, start, p.pos)
  of jkArray:
    p.beginContainer('[')
    w.put '['
    var comma = false
    var first = true
    while p.nextItem(first, ']'):
      w.putComma(comma)
      p.canonicalizeValue(w)
    w.put ']'
  of jkObject:
    w.put '{'
    var comma = false
    for name in p.jsonFields:
      w.putComma(comma)
      w.escapeJson(name)
      w.put ':'
      p.canonicalizeValue(w)
    w.put '}'

proc readJson*(dst: var CanonRawJson; p: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  var writer = JsonWriter(data: "")
  p.canonicalizeValue(writer)
  if not p.hasError:
    dst = CanonRawJson(move writer.data)

proc writeJson*(w: var JsonWriter; value: CanonRawJson) =
  w.write string(value)

# ── entry points ──────────────────────────────────────────────────────────

proc decode[T: JsonReadable](data: openArray[char]; offset: int;
                             unknownFields: UnknownFieldPolicy): Result[T, JsonError] =
  # One complete value. `offset` places error positions within a larger input.
  var value = default(T)
  var p = JsonParser(data: data)
  readJson(value, p, unknownFields)
  p.finish()
  if p.hasError:
    p.error.pos += offset
    result = err[T, JsonError](move p.error)
  else:
    result = ok[T, JsonError](move value)

proc fromJson*[T: JsonReadable](input: string; typ: typedesc[T];
                                unknownFields = ufSkip): Result[T, JsonError] =
  ## Decodes one complete JSON value, or reports the first error in it.
  decode[T](input, 0, unknownFields)

iterator jsonLines*[T: JsonReadable](input: string;
                                     unknownFields = ufSkip): Result[T, JsonError] {.sideEffect.} =
  ## Decodes JSON Lines: one value per line, each with its own result, so a
  ## malformed line does not stop the rest. Empty lines are skipped; error
  ## positions are byte offsets into `input`.
  var start = 0
  while start < input.len:
    var stop = start
    while stop < input.len and input[stop] != '\n':
      inc stop
    if stop > start:
      yield decode[T](input.toOpenArray(start, stop - 1), start, unknownFields)
    start = stop + 1

proc toJson*[T: JsonWritable](value: T): Result[string, JsonError] =
  ## Serializes `value` as JSON, or reports why it has no JSON form: NaN,
  ## infinity, or a custom writer's `writeError`.
  var writer = JsonWriter(data: "")
  writeJson(writer, value)
  if writer.error.kind != jeNone:
    result = err[string, JsonError](move writer.error)
  else:
    result = ok[string, JsonError](move writer.data)
