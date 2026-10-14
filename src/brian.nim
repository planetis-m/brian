## Typed JSON decoding and encoding for Nimony values.
##
## Use `fromJson` and `toJson` for ordinary values. Custom types can provide
## `readJson` and `writeJson` overloads.
##
## Errors do not unwind through readers. A parser that hits malformed input
## records the first error, moves to the end of the input and turns every later
## read into a no-op, so custom readers stay straight-line code. `fromJson` and
## `toJson` check once at the end and raise `ValueError`; `tryFromJson` returns
## the message instead.

{.feature: "staticContracts".}

import std/[options, paths, sets, syncio, tables]
from std/parseutils import parseFloat

type
  JsonKind* = enum
    jkNull, jkBool, jkNumber, jkString, jkArray, jkObject

  UnknownFieldPolicy* = enum
    ufSkip, ufReject

  JsonError = enum
    ## Parse failures; `ErrorMessages` holds their text.
    errNone
    errCustom  ## a custom reader's message, kept in `message`
    errEscape
    errUnicodeIncomplete
    errUnicodeInvalid
    errStringUnterminated
    errStringExpected
    errNullExpected
    errBoolExpected
    errIntIncomplete
    errDigitExpected
    errIntOverflow
    errIntExpected
    errUnsignedNegative
    errNumberExpected
    errObjectExpected
    errArrayExpected
    errDepthExceeded
    errObjectUnterminated
    errArrayUnterminated
    errObjectCommaExpected
    errArrayCommaExpected
    errObjectTrailingComma
    errArrayTrailingComma
    errColonExpected
    errValueExpected
    errContainerUnterminated
    errTrailingData
    errEnumExpected

  JsonParser* = object
    ## Parses JSON for custom `readJson` overloads. A cursor over a borrowed
    ## view of the input.
    data: openArray[char]
    pos: Natural
    depth: int
    err: JsonError    ## the first error; later ones are ignored
    errorPos: int     ## where `err` was found
    message: string   ## the text of an `errCustom` error

  JsonWriter* = object
    ## Writes JSON for custom `writeJson` overloads.
    data: string
    failed: bool

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
  ErrorMessages: array[JsonError, string] = [
    "no error",
    "", # errCustom: the text is in `JsonParser.message`
    "incomplete escape",
    "incomplete Unicode escape",
    "invalid Unicode escape",
    "unterminated string",
    "expected string",
    "expected null",
    "expected boolean",
    "incomplete integer",
    "expected digit",
    "integer overflow",
    "expected integer",
    "negative value for unsigned integer",
    "expected number",
    "expected object",
    "expected array",
    "maximum nesting depth exceeded",
    "unterminated object",
    "unterminated array",
    "expected comma or end of object",
    "expected comma or end of array",
    "trailing comma in object",
    "trailing comma in array",
    "expected colon",
    "expected value",
    "unterminated container",
    "trailing data",
    "expected a known enum value"
  ]

# ── errors ────────────────────────────────────────────────────────────────

proc setError(p: var JsonParser; err: JsonError) {.noinline.} =
  # The first error wins; the parser then stands at the end of the input, so
  # every later read fails without doing work and every loop ends.
  if p.err == errNone:
    p.err = err
    p.errorPos = p.pos
  p.pos = p.data.len

proc parseError*(p: var JsonParser; msg: string) {.noinline.} =
  ## Records a parse error for custom `readJson` overloads. As with built-in
  ## errors, only the first one is kept and every later read does nothing.
  if p.err == errNone:
    p.message = msg
  p.setError(errCustom)

func hasError*(p: JsonParser): bool {.inline.} =
  ## Whether a parse error has been recorded.
  p.err != errNone

proc errorMsg(p: JsonParser): string =
  ## Formats the recorded error; only called once a caller wants the text.
  result = "JSON at byte " & $p.errorPos & ": "
  if p.err == errCustom:
    result.add p.message
  elif ord(p.err) >= 0 and ord(p.err) <= ord(high(JsonError)):
    # An enum conversion is not range checked; this lets the index be proven.
    result.add ErrorMessages[p.err]

proc writeError*(w: var JsonWriter) {.inline.} =
  ## Marks the output as failed for custom `writeJson` overloads; `toJson`
  ## raises `ValueError` once writing ends.
  w.failed = true

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
    p.setError(errUnicodeIncomplete)
    result = 0
  else:
    let a = hexValue(p.data[i])
    let b = hexValue(p.data[i + 1])
    let c = hexValue(p.data[i + 2])
    let d = hexValue(p.data[i + 3])
    if (a or b or c or d) < 0:
      p.setError(errUnicodeInvalid)
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
          p.setError(errEscape)
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
    p.setError(errStringUnterminated)

proc openString(p: var JsonParser): bool {.inline.} =
  ## Consumes the opening quote of the next value.
  p.skip()
  result = p.pos < p.data.len and p.data[p.pos] == '"'
  if result:
    inc p.pos
  else:
    p.setError(errStringExpected)

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
    p.setError(errNullExpected)

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
    p.setError(errBoolExpected)

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
    p.setError(errIntIncomplete)
  elif not isDigit(p.data[pos]):
    p.pos = pos
    p.setError(errDigitExpected)
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
      p.setError(errIntOverflow)
    elif pos < p.data.len and (p.data[pos] == '.' or p.data[pos] == 'e' or p.data[pos] == 'E'):
      p.setError(errIntExpected)
    else:
      when T is SomeUnsignedInt:
        if negative and value != 0'u64:
          p.setError(errUnsignedNegative)
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
    p.setError(errNumberExpected)

# ── containers ────────────────────────────────────────────────────────────

proc containerError(p: var JsonParser; objectErr: JsonError; bracket: char) {.noinline.} =
  # Kept out of line so `nextItem` stays small enough to inline. Every object
  # error is followed by its array twin in `JsonError`.
  p.setError(if bracket == '{' or bracket == '}': objectErr else: succ(objectErr))

proc beginContainer(p: var JsonParser; open: char) {.inline.} =
  ## Consumes `open`, which is `{` or `[`.
  p.skip()
  if p.pos >= p.data.len or p.data[p.pos] != open:
    p.containerError(errObjectExpected, open)
  elif p.depth > DepthLimit:
    p.setError(errDepthExceeded)
  else:
    inc p.pos
    inc p.depth

proc nextItem(p: var JsonParser; first: var bool; close: char): bool {.inline.} =
  ## Moves to the next item of an open container, or consumes `close`, which
  ## is `}` or `]`, and returns false.
  p.skip()
  result = false
  if p.pos >= p.data.len:
    p.containerError(errObjectUnterminated, close)
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
    p.containerError(errObjectCommaExpected, close)
  else:
    inc p.pos
    p.skip()
    if p.pos < p.data.len and p.data[p.pos] == close:
      p.containerError(errObjectTrailingComma, close)
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
      p.setError(errStringExpected)
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
        p.setError(errColonExpected)
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
            p.setError(errEscape)
          else:
            let escaped = p.data[p.pos]
            inc p.pos
            if escaped == 'u': discard p.readHex()
    if not closed:
      p.setError(errStringUnterminated)

proc skipJson*(p: var JsonParser) =
  ## Consumes and validates one JSON value without materializing it.
  p.skip()
  if p.pos >= p.data.len:
    p.setError(errValueExpected)
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
      p.setError(errValueExpected)

proc kind*(p: var JsonParser): JsonKind =
  ## Returns the kind of the next JSON value without consuming it. After an
  ## error it reports `jkNull`.
  p.skip()
  result = jkNull
  if p.pos >= p.data.len:
    p.setError(errValueExpected)
  else:
    case p.data[p.pos]
    of 'n': result = jkNull
    of 't', 'f': result = jkBool
    of '"': result = jkString
    of '[': result = jkArray
    of '{': result = jkObject
    of '-', '.', '0'..'9': result = jkNumber
    else: p.setError(errValueExpected)

proc finish(p: var JsonParser) =
  if p.depth != 0:
    p.setError(errContainerUnterminated)
  p.skip()
  if p.pos != p.data.len:
    p.setError(errTrailingData)

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
    p.setError(errEnumExpected)

proc readJson*[T: HoleyEnum](dst: var T; p: var JsonParser;
                             unknownFields: UnknownFieldPolicy) =
  if not p.readEnum(dst) and not p.hasError:
    p.setError(errEnumExpected)

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
    w.writeError()
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
  var writer = JsonWriter(data: "", failed: false)
  p.canonicalizeValue(writer)
  if not p.hasError:
    dst = CanonRawJson(move writer.data)

proc writeJson*(w: var JsonWriter; value: CanonRawJson) =
  w.write string(value)

# ── entry points ──────────────────────────────────────────────────────────

proc tryFromJson*[T: JsonReadable](input: string; dst: var T; errorMsg: var string;
                     unknownFields = ufSkip): bool =
  ## Decodes one complete JSON value into `dst`. On malformed input returns
  ## false and stores a message (`JSON at byte N: ...`) in `errorMsg`; `dst`
  ## may then be partially written.
  var reader = JsonParser(data: input)
  readJson(dst, reader, unknownFields)
  reader.finish()
  result = not reader.hasError
  if not result:
    errorMsg = reader.errorMsg

proc fromJson*[T: JsonReadable](input: string; dst: var T;
                  unknownFields = ufSkip) {.raises.} =
  ## Decodes one complete JSON value into `dst`. Raises `ValueError` when the
  ## input is malformed or does not match `T`.
  # Going through `tryFromJson` costs one message on failure, but keeps the
  # decode out of the caller: inlined there, gcc stops expanding the
  # field-name compares and calls `memcmp` (objects_known +4%).
  var errorMsg = ""
  if not tryFromJson(input, dst, errorMsg, unknownFields):
    raise ValueError

proc fromJson*[T: JsonReadable](input: string; typ: typedesc[T];
                  unknownFields = ufSkip): T {.raises.} =
  ## Decodes one complete JSON value from `input`.
  result = default(T)
  fromJson(input, result, unknownFields)

proc fromFile*[T: JsonReadable](path: Path; dst: var T;
                  unknownFields = ufSkip) {.raises.} =
  ## Decodes one complete JSON file directly into `dst`.
  fromJson(readFile($path), dst, unknownFields)

proc fromFile*[T: JsonReadable](path: Path; typ: typedesc[T];
                  unknownFields = ufSkip): T {.raises.} =
  ## Decodes one complete JSON file into `T`.
  result = default(T)
  fromFile(path, result, unknownFields)

proc toJson*[T: JsonWritable](value: T): string {.raises.} =
  ## Serializes `value` as JSON. Raises `ValueError` for values JSON cannot
  ## represent (NaN, infinity) or when a custom writer called `writeError`.
  var writer = JsonWriter(data: "", failed: false)
  writeJson(writer, value)
  if writer.failed:
    raise ValueError
  result = move writer.data

iterator jsonItems*[T: JsonReadable](input: string;
                       unknownFields = ufSkip): T {.raises, sideEffect.} =
  ## Iterates the values in one top-level JSON array: `for x in jsonItems[T](s)`.
  ## Raises `ValueError` after the last good item when the input is malformed.
  var reader = JsonParser(data: input)
  reader.beginContainer('[')
  var first = true
  while reader.nextItem(first, ']'):
    var value = default(T)
    readJson(value, reader, unknownFields)
    if not reader.hasError:
      yield value
  reader.finish()
  if reader.hasError:
    raise ValueError

