import std/[assertions, math, options, parseutils, sets, strutils, syncio, tables]
import brian

template check(cond: bool; msg = "") =
  # Unlike `assert`, never compiled out.
  if not cond: raiseAssert(msg)

proc rejects[T](input: string; typ: typedesc[T];
                unknownFields = ufSkip): bool {.untyped.} =
  var dst = default(T)
  var msg = ""
  result = not tryFromJson(input, dst, msg, unknownFields)

proc writeFails[T](value: T): bool {.untyped.} =
  result = false
  try:
    discard toJson(value)
  except:
    result = true

type
  Colour = enum
    red, blue
  Child = object
    value: int
  Sample = object
    name: string
    count: int64
    enabled: bool
    colour: Colour
    child: Option[Child]
    values: seq[int]
  ContentKind = enum
    text, parts
  Content = object
    case kind: ContentKind
    of text: body: string
    of parts: items: seq[string]
  Page = object
    number: int
    status: string
  OpenObject = object
    fields: seq[(string, int)]
  ResponseStatus = enum
    completed, inProgress = "in_progress", failed, cancelled, queued, incomplete, unknown
  WireStatus = enum
    ready = "wire_ready", stopped
  FailingWrite = object
  NamedTuple = tuple[name: string, count: int]
  Triple = (int, string, bool)
  Three = array[3, int]
  Empty = array[0, int]

proc readJson*(dst: var Page; p: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  for field in p.jsonFields:
    if field == "number":
      readJson(dst.number, p, unknownFields)
    elif "status" == field:
      readJson(dst.status, p, unknownFields)
    elif unknownFields == ufReject:
      p.parseError("expected known field, got \"" & $field & "\"")
    else:
      p.skipJson()

proc readJson*(dst: var OpenObject; p: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  for field in p.jsonFields:
    var value = 0
    readJson(value, p, unknownFields)
    dst.fields.add ($field, value)

proc readJson*(dst: var ResponseStatus; p: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  readJson(dst, p, unknownFields, unknown)

proc readJson*(dst: var Content; p: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  case p.kind
  of jkString:
    dst = Content(kind: text, body: "")
    readJson(dst.body, p, unknownFields)
  of jkArray:
    dst = Content(kind: parts, items: @[])
    readJson(dst.items, p, unknownFields)
  else:
    p.parseError("expected string or array")

proc writeJson*(w: var JsonWriter; value: Content) =
  case value.kind
  of text: writeJson(w, value.body)
  of parts: writeJson(w, value.items)

proc writeJson*(w: var JsonWriter; value: Page) =
  w.write "{\"number\":"
  writeJson(w, value.number)
  w.write ",\"status\":"
  writeJson(w, value.status)
  w.write "}"

proc writeJson*(w: var JsonWriter; value: FailingWrite) =
  w.write "allocated writer storage"
  w.writeError()

proc sameSample(a, b: Sample): bool =
  result = a.name == b.name and a.count == b.count and a.enabled == b.enabled and
    a.colour == b.colour and a.child.isSome == b.child.isSome and a.values == b.values
  if result and a.child.isSome:
    result = a.child.unsafeGet.value == b.child.unsafeGet.value

proc samePage(a: Page; number: int; status: string): bool =
  a.number == number and a.status == status

proc objectRoundTrip() {.raises.} =
  let source = """{
    "name":"\u0391\u03b8\u03ae\u03bd\u03b1",
    "count":-42,
    "enabled":true,
    "colour":"blue",
    "child":{"value":7},
    "values":[1,2,3],
    "unknown":{"deep":[false,null,"ignored"]}
  }"""
  let value = fromJson(source, Sample)
  check value.name == "Αθήνα"
  check value.count == -42
  check value.colour == blue
  check value.child.unsafeGet.value == 7
  check value.values == @[1, 2, 3]
  check sameSample(fromJson(toJson(value), Sample), value)

proc customUnion() {.raises.} =
  let textContent = fromJson("\"hello\"", Content)
  check textContent.kind == text
  check textContent.body == "hello"
  let partContent = fromJson("[\"a\",\"b\"]", Content)
  check partContent.kind == parts
  check partContent.items == @["a", "b"]
  check toJson(Content(kind: parts, items: @["a", "b"])) == "[\"a\",\"b\"]"

proc customObjectAndWriter() {.raises.} =
  let page = fromJson("{\"number\":4,\"status\":\"ok\"}", Page)
  check samePage(page, 4, "ok")
  check samePage(fromJson("{\"number\":4,\"extra\":[1],\"status\":\"ok\"}", Page), 4, "ok")
  check toJson(page) == "{\"number\":4,\"status\":\"ok\"}"
  check writeFails(FailingWrite())

proc customOpenObject() {.raises.} =
  var value = OpenObject(fields: @[("default", 0)])
  fromJson("{\"one\":1,\"t\\u0077o\":2,\"\":3}", value)
  check value.fields == @[("default", 0), ("one", 1), ("two", 2), ("", 3)]

proc customEnumFallback() {.raises.} =
  check fromJson("\"in_progress\"", ResponseStatus) == inProgress
  check fromJson("\"incompl\\u0065te\"", ResponseStatus) == incomplete
  check fromJson("\"delayed\"", ResponseStatus) == unknown
  check toJson(inProgress) == "\"in_progress\""

proc strictEnum() {.raises.} =
  check fromJson("\"wire_ready\"", WireStatus) == ready
  check fromJson("\"wire\\u005fready\"", WireStatus) == ready
  check rejects("\"Wire_Ready\"", WireStatus)

proc escapedFieldNames() {.raises.} =
  check fromJson("{\"na\\u006de\":\"x\"}", Sample).name == "x"
  let page = fromJson("{\"num\\u0062er\":4,\"sta\\u0074us\":\"ok\"}", Page)
  check samePage(page, 4, "ok")

proc rawValues() {.raises.} =
  let raw = fromJson(" { \"x\" : [ 1, \"\\u03b1\" ] } ", RawJson)
  check $raw == "{ \"x\" : [ 1, \"\\u03b1\" ] }"
  check string(raw) == "{ \"x\" : [ 1, \"\\u03b1\" ] }"
  check toJson(raw) == string(raw)
  check toJson(RawJson("not validated here")) == "not validated here"
  let canonical = fromJson(" { \"x\" : [ 1, \"\\u03b1\" ] } ", CanonRawJson)
  check $canonical == "{\"x\":[1,\"α\"]}"
  check string(fromJson("{\"\":1}", CanonRawJson)) == "{\"\":1}"
  let escapedKeys = fromJson(
    """{"a\u0022b":1,"c\\d":2,"\u0001":3}""", CanonRawJson)
  check string(escapedKeys) == """{"a\"b":1,"c\\d":2,"\u0001":3}"""
  check string(fromJson("1e", RawJson)) == "1e"
  check string(fromJson("-", RawJson)) == "-"

proc fieldLifetimeAndUnknownPolicy() {.raises.} =
  var destination = Sample()
  var msg = ""
  check not tryFromJson("{\"name\":\"x\",\"extra\":1}", destination, msg, ufReject)
  var page = Page()
  check not tryFromJson("{\"number\":4,\"ex\\u0074ra\":1}", page, msg, ufReject)
  check msg.endsWith("expected known field, got \"extra\""), msg

proc malformedInput() {.raises.} =
  for input in ["+1", "[1,]", "{\"x\":1,}", "true false", "\"\\u12xz\""]:
    check rejects(input, RawJson), input

proc parsejsonCompatibleDepth() {.raises.} =
  let accepted = repeat('[', 1_001) & repeat(']', 1_001)
  discard fromJson(accepted, RawJson)
  let rejected = repeat('[', 1_002) & repeat(']', 1_002)
  check rejects(rejected, RawJson)

proc integerLimits() {.raises.} =
  check fromJson("-128", int8) == -128'i8
  check fromJson("255", uint8) == 255'u8
  check fromJson("-32768", int16) == low(int16)
  check fromJson("32767", int16) == high(int16)
  check fromJson("65535", uint16) == high(uint16)
  check fromJson("-2147483648", int32) == low(int32)
  check fromJson("2147483647", int32) == high(int32)
  check fromJson("4294967295", uint32) == high(uint32)
  check fromJson("-9223372036854775808", int64) == low(int64)
  check fromJson("9223372036854775807", int64) == high(int64)
  check fromJson("18446744073709551615", uint64) == high(uint64)
  for input in ["128", "-129"]:
    check rejects(input, int8), input
  check rejects("32768", int16)
  check rejects("-32769", int16)
  check rejects("65536", uint16)
  check rejects("2147483648", int32)
  check rejects("-2147483649", int32)
  check rejects("4294967296", uint32)
  check rejects("9223372036854775808", int64)
  check rejects("-9223372036854775809", int64)
  check rejects("18446744073709551616", uint64)
  check rejects("-1", uint8)
  check fromJson("-0", uint8) == 0'u8

proc integerSerializationBoundaries() {.raises.} =
  for value in [0'i64, 9, 10, 99, 100, 101, 9_999, 10_000, -1, -99, -100]:
    check fromJson(toJson(value), int64) == value
  check fromJson(toJson(low(int64)), int64) == low(int64)
  check fromJson(toJson(high(int64)), int64) == high(int64)
  check fromJson(toJson(high(uint64)), uint64) == high(uint64)

proc floats() {.raises.} =
  check fromJson("-12.5e-1", float64) == -1.25
  check fromJson("1.25", float32) == 1.25'f32
  check fromJson(".1", float64) == 0.1
  check fromJson("01", float64) == 1.0
  check fromJson("1.", float64) == 1.0
  check rejects(".", float64)
  check rejects("-.", float64)
  for input in ["0.1", "2.2250738585072012e-308", "1.0000000000000001",
                "4.9406564584124654e-324", "1.7976931348623157e308"]:
    var expected = 0.0
    check parseFloat(input, expected) == input.len
    check cast[uint64](fromJson(input, float64)) == cast[uint64](expected), input
  check classify(fromJson("1e400", float64)) == fcInf
  for input in ["1e", "1e+", "-"]:
    check rejects(input, float64), input
  for value in [0.0, -0.0, 0.1, -12.5, 1.2345678901234567, 1.0e100, 1.0e-100]:
    check cast[uint64](fromJson(toJson(value), float64)) == cast[uint64](value)
  for value in [NaN, Inf, -Inf]:
    check writeFails(value)

proc tuplesArraysAndItems() {.raises.} =
  let anonymous = fromJson("[1,\"x\",true]", Triple)
  check anonymous[0] == 1 and anonymous[1] == "x" and anonymous[2]
  let named = fromJson("{\"name\":\"x\",\"count\":2}", NamedTuple)
  check named.name == "x" and named.count == 2
  check toJson(named) == "{\"name\":\"x\",\"count\":2}"
  check toJson((1, "x")) == "[1,\"x\"]"
  let withUnknown = "{\"name\":\"x\",\"extra\":true,\"count\":2}"
  let tolerant = fromJson(withUnknown, NamedTuple)
  check tolerant.name == "x" and tolerant.count == 2
  check rejects(withUnknown, NamedTuple, ufReject)
  check fromJson("[1,2,3]", Three) == [1, 2, 3]
  discard fromJson("[]", Empty)
  for input in ["[1,2]", "[1,2,3,4]"]:
    check rejects(input, Three), input
  var collected: seq[int] = @[]
  for value in jsonItems[int]("[1,2,3]"): collected.add value
  check collected == @[1, 2, 3]

proc setsAndTables() {.raises.} =
  var colours = {red}
  fromJson("[\"blue\"]", colours)
  check colours == {red, blue}
  check toJson({red, blue}) == "[\"red\",\"blue\"]"

  let hashed = fromJson("[1,2,2]", HashSet[int])
  check hashed.len == 2 and 1 in hashed and 2 in hashed
  let again = fromJson(toJson(hashed), HashSet[int])
  check again.len == 2 and 1 in again and 2 in again

  var numbers = initTable[string, int]()
  numbers["stale"] = 9
  fromJson("{\"one\":1,\"t\\u0077o\":2}", numbers)
  check numbers.len == 3
  check numbers.getOrDefault("stale") == 9 and numbers.getOrDefault("one") == 1 and
    numbers.getOrDefault("two") == 2

  var ordered = initTable[string, int]()
  ordered["one"] = 1
  ordered["two"] = 2
  check toJson(ordered) == "{\"one\":1,\"two\":2}"
  let reread = fromJson(toJson(ordered), Table[string, int])
  check toJson(reread) == "{\"one\":1,\"two\":2}"

  let duplicate = fromJson("{\"item\":{\"value\":1},\"item\":{}}", Table[string, Child])
  check duplicate.len == 1 and duplicate.getOrDefault("item").value == 0

proc rawStringCompatibility() {.raises.} =
  check fromJson("\"\\x\"", string) == "\\x"
  check fromJson("\"\\v\"", string) == "\v"
  check fromJson("\"\\udc00\"", string) == "\xED\xB0\x80"
  check string(fromJson("\"\\udc00\"", RawJson)) == "\"\\udc00\""

proc stringSerialization() {.raises.} =
  check toJson("line\nbreak") == "\"line\\nbreak\""
  check toJson("\xff") == "\"\xff\""
  check toJson("\v\x0e\x1f") == "\"\\u000b\\u000E\\u001F\""

proc surrogateCompatibility() {.raises.} =
  for (input, expected) in [
    ("\"\\ud83d\"", "\xED\xA0\xBD"),
    ("\"\\udc3e\"", "\xED\xB0\xBE"),
    ("\"\\ud83d\\udc3e\"", "🐾"),
    ("\"\\udbff\\udfff\"", "\xF4\x8F\xBF\xBF"),
    ("\"\\ud83d\\u0061\"", "\xED\xA0\xBDa"),
    ("\"\\ud83dtext\"", "\xED\xA0\xBDtext"),
    ("\"\\ud83d\\ud83d\\udc3e\"", "\xED\xA0\xBD🐾")
  ]:
    check fromJson(input, string) == expected, input
    check string(fromJson(input, RawJson)) == input, input
  for input in ["\"\\u12xz\"", "\"\\ud83d\\u12xz\"", "\"\\ud83d\\u12\""]:
    check rejects(input, string), input
    check rejects(input, RawJson), input

proc errorMessages() {.raises.} =
  # The first error wins and names the byte where it was found.
  var value: seq[int] = @[]
  var msg = ""
  check not tryFromJson("[1,2,x,y]", value, msg)
  check msg == "JSON at byte 5: expected digit", msg
  check not tryFromJson("[1,2", value, msg)
  check msg.endsWith("unterminated array"), msg

proc main() {.raises.} =
  objectRoundTrip()
  customUnion()
  customObjectAndWriter()
  customOpenObject()
  customEnumFallback()
  strictEnum()
  escapedFieldNames()
  rawValues()
  fieldLifetimeAndUnknownPolicy()
  malformedInput()
  parsejsonCompatibleDepth()
  integerLimits()
  integerSerializationBoundaries()
  floats()
  tuplesArraysAndItems()
  setsAndTables()
  rawStringCompatibility()
  stringSerialization()
  surrogateCompatibility()
  errorMessages()

try:
  main()
except:
  raiseAssert("unexpected ValueError")
