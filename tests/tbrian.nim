import std/[assertions, math, options, parseutils, sets, strutils, tables]
import brian

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
    completed, inProgress, failed, cancelled, queued, incomplete, unknown
  FailingWrite = object

proc readJson*(dst: var Page; p: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  for field in p.jsonFields(["number", "status"], unknownFields):
    case field
    of 0: readJson(dst.number, p, unknownFields)
    of 1: readJson(dst.status, p, unknownFields)
    else: discard

proc readJson*(dst: var OpenObject; p: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  for field in p.jsonFields:
    var value: int
    readJson(value, p, unknownFields)
    dst.fields.add (field, value)

proc readJson*(dst: var ResponseStatus; p: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  case p.matchString([
    "completed", "in_progress", "failed", "cancelled", "queued", "incomplete"
  ])
  of 0: dst = completed
  of 1: dst = inProgress
  of 2: dst = failed
  of 3: dst = cancelled
  of 4: dst = queued
  of 5: dst = incomplete
  else: dst = unknown

proc readJson*(dst: var Content; p: var JsonParser;
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
  raise newException(ValueError, "intentional writer failure")

block object_round_trip:
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
  doAssert value.name == "Αθήνα"
  doAssert value.count == -42
  doAssert value.colour == blue
  doAssert value.child.get.value == 7
  doAssert value.values == @[1, 2, 3]
  doAssert fromJson(toJson(value), Sample) == value

block custom_union:
  let textContent = fromJson("\"hello\"", Content)
  doAssert textContent.kind == text
  doAssert textContent.body == "hello"
  let partContent = fromJson("[\"a\",\"b\"]", Content)
  doAssert partContent.kind == parts
  doAssert partContent.items == @["a", "b"]
  doAssert toJson(Content(kind: parts, items: @["a", "b"])) == "[\"a\",\"b\"]"

block custom_object_and_writer:
  let page = fromJson("{\"number\":4,\"status\":\"ok\"}", Page)
  doAssert page == Page(number: 4, status: "ok")
  doAssert fromJson("{\"number\":4,\"extra\":[1],\"status\":\"ok\"}", Page) == page
  doAssert toJson(page) == "{\"number\":4,\"status\":\"ok\"}"
  doAssertRaises ValueError:
    discard toJson(FailingWrite())

block custom_open_object:
  var value = OpenObject(fields: @[("default", 0)])
  fromJson("{\"one\":1,\"two\":2}", value)
  doAssert value.fields == @[("default", 0), ("one", 1), ("two", 2)]

block custom_string_matcher:
  doAssert fromJson("\"in_progress\"", ResponseStatus) == inProgress
  doAssert fromJson("\"incompl\\u0065te\"", ResponseStatus) == incomplete
  doAssert fromJson("\"delayed\"", ResponseStatus) == unknown

block escaped_field_names:
  doAssert fromJson("{\"na\\u006de\":\"x\"}", Sample).name == "x"
  let page = fromJson("{\"num\\u0062er\":4,\"sta\\u0074us\":\"ok\"}", Page)
  doAssert page == Page(number: 4, status: "ok")

block raw_values:
  let raw = fromJson(" { \"x\" : [ 1, \"\\u03b1\" ] } ", RawJson)
  doAssert $raw == "{ \"x\" : [ 1, \"\\u03b1\" ] }"
  doAssert string(raw) == "{ \"x\" : [ 1, \"\\u03b1\" ] }"
  doAssert toJson(raw) == string(raw)
  doAssert toJson(RawJson("not validated here")) == "not validated here"
  let canonical = fromJson(" { \"x\" : [ 1, \"\\u03b1\" ] } ", CanonRawJson)
  doAssert $canonical == "{\"x\":[1,\"α\"]}"
  doAssert string(fromJson("{\"\":1}", CanonRawJson)) == "{\"\":1}"
  let escapedKeys = fromJson(
    """{"a\u0022b":1,"c\\d":2,"\u0001":3}""", CanonRawJson)
  doAssert string(escapedKeys) ==
    """{"a\"b":1,"c\\d":2,"\u0001":3}"""
  doAssert string(fromJson("1e", RawJson)) == "1e"
  doAssert string(fromJson("-", RawJson)) == "-"

block field_lifetime_and_unknown_policy:
  var destination = Sample()
  doAssertRaises JsonParsingError:
    fromJson("{\"name\":\"x\",\"extra\":1}", destination, ufReject)
  try:
    discard fromJson("{\"number\":4,\"ex\\u0074ra\":1}", Page, ufReject)
    doAssert false, "unknown custom fields should be rejected"
  except JsonParsingError as error:
    doAssert error.msg.endsWith("expected known field, got \"extra\"")

block malformed_input:
  for input in ["+1", "[1,]", "{\"x\":1,}",
                "true false", "\"\\ud800\"", "\"\\u12xz\""]:
    doAssertRaises JsonParsingError:
      discard fromJson(input, RawJson)

block parsejson_compatible_depth:
  let accepted = repeat('[', 1_001) & repeat(']', 1_001)
  discard fromJson(accepted, RawJson)
  let rejected = repeat('[', 1_002) & repeat(']', 1_002)
  doAssertRaises JsonParsingError:
    discard fromJson(rejected, RawJson)

block integer_limits:
  doAssert fromJson("-128", int8) == -128'i8
  doAssert fromJson("255", uint8) == 255'u8
  doAssert fromJson("-32768", int16) == low(int16)
  doAssert fromJson("32767", int16) == high(int16)
  doAssert fromJson("65535", uint16) == high(uint16)
  doAssert fromJson("-2147483648", int32) == low(int32)
  doAssert fromJson("2147483647", int32) == high(int32)
  doAssert fromJson("4294967295", uint32) == high(uint32)
  doAssert fromJson("-9223372036854775808", int64) == low(int64)
  doAssert fromJson("9223372036854775807", int64) == high(int64)
  doAssert fromJson("18446744073709551615", uint64) == high(uint64)
  for input in ["128", "-129"]:
    doAssertRaises JsonParsingError:
      discard fromJson(input, int8)
  doAssertRaises JsonParsingError:
    discard fromJson("32768", int16)
  doAssertRaises JsonParsingError:
    discard fromJson("-32769", int16)
  doAssertRaises JsonParsingError:
    discard fromJson("65536", uint16)
  doAssertRaises JsonParsingError:
    discard fromJson("2147483648", int32)
  doAssertRaises JsonParsingError:
    discard fromJson("-2147483649", int32)
  doAssertRaises JsonParsingError:
    discard fromJson("4294967296", uint32)
  doAssertRaises JsonParsingError:
    discard fromJson("9223372036854775808", int64)
  doAssertRaises JsonParsingError:
    discard fromJson("-9223372036854775809", int64)
  doAssertRaises JsonParsingError:
    discard fromJson("18446744073709551616", uint64)
  doAssertRaises JsonParsingError:
    discard fromJson("-1", uint8)
  doAssert fromJson("-0", uint8) == 0'u8

block integer_serialization_boundaries:
  for value in [0'i64, 9, 10, 99, 100, 101, 9_999, 10_000, -1, -99, -100]:
    doAssert fromJson(toJson(value), int64) == value
  doAssert fromJson(toJson(low(int64)), int64) == low(int64)
  doAssert fromJson(toJson(high(int64)), int64) == high(int64)
  doAssert fromJson(toJson(high(uint64)), uint64) == high(uint64)

block floats:
  doAssert fromJson("-12.5e-1", float64) == -1.25
  doAssert fromJson("1.25", float32) == 1.25'f32
  doAssert fromJson(".1", float64) == 0.1
  doAssert fromJson("01", float64) == 1.0
  doAssert fromJson("1.", float64) == 1.0
  doAssert fromJson(".", float64) == 0.0
  doAssert fromJson("-.", float64) == -0.0
  for input in ["0.1", "2.2250738585072012e-308", "1.0000000000000001",
                "4.9406564584124654e-324", "1.7976931348623157e308"]:
    var expected = 0.0
    doAssert parseutils.parseFloat(input, expected) == input.len
    doAssert cast[uint64](fromJson(input, float64)) == cast[uint64](expected)
  doAssert classify(fromJson("1e400", float64)) == fcInf
  for input in ["1e", "1e+", "-"]:
    doAssertRaises JsonParsingError:
      discard fromJson(input, float64)
  for value in [0.0, -0.0, 0.1, -12.5, 1.2345678901234567, 1.0e100, 1.0e-100]:
    doAssert cast[uint64](fromJson(toJson(value), float64)) == cast[uint64](value)
  for value in [NaN, Inf, -Inf]:
    doAssertRaises ValueError:
      discard toJson(value)

block tuples_arrays_and_items:
  doAssert fromJson("[1,\"x\",true]", (int, string, bool)) == (1, "x", true)
  type NamedTuple = tuple[name: string, count: int]
  let named = fromJson("{\"name\":\"x\",\"count\":2}", NamedTuple)
  doAssert named == (name: "x", count: 2)
  doAssert toJson(named) == "{\"name\":\"x\",\"count\":2}"
  let withUnknown = "{\"name\":\"x\",\"extra\":true,\"count\":2}"
  doAssert fromJson(withUnknown, NamedTuple) == named
  var rejected = default(NamedTuple)
  doAssertRaises JsonParsingError:
    fromJson(withUnknown, rejected, ufReject)
  doAssert fromJson("[1,2,3]", array[3, int]) == [1, 2, 3]
  doAssert fromJson("[]", array[0, int]) == default(array[0, int])
  for input in ["[1,2]", "[1,2,3,4]"]:
    doAssertRaises JsonParsingError:
      discard fromJson(input, array[3, int])
  var collected: seq[int] = @[]
  for value in jsonItems("[1,2,3]", int): collected.add value
  doAssert collected == @[1, 2, 3]

block sets_and_tables:
  var colours = {red}
  fromJson("[\"blue\"]", colours)
  doAssert colours == {red, blue}
  doAssert toJson({red, blue}) == "[\"red\",\"blue\"]"

  let hashed = fromJson("[1,2,2]", HashSet[int])
  doAssert hashed == [1, 2].toHashSet()
  doAssert fromJson(toJson(hashed), HashSet[int]) == hashed

  let ordered = ["first", "second"].toOrderedSet()
  doAssert toJson(ordered) == "[\"first\",\"second\"]"
  doAssert fromJson(toJson(ordered), OrderedSet[string]) == ordered

  var numbers = {"stale": 9}.toTable()
  fromJson("{\"one\":1,\"t\\u0077o\":2}", numbers)
  doAssert numbers == {"stale": 9, "one": 1, "two": 2}.toTable()

  let orderedTable = [("one", 1), ("two", 2)].toOrderedTable()
  doAssert toJson(orderedTable) == "{\"one\":1,\"two\":2}"
  doAssert fromJson(toJson(orderedTable), OrderedTable[string, int]) == orderedTable

  let duplicate = fromJson("{\"item\":{\"value\":1},\"item\":{}}",
                           Table[string, Child])
  doAssert duplicate["item"] == Child()

block raw_string_compatibility:
  doAssert fromJson("\"\\x\"", string) == "\\x"
  doAssert fromJson("\"\\v\"", string) == "\v"
  doAssert fromJson("\"\\udc00\"", string) == "\xED\xB0\x80"
  doAssert string(fromJson("\"\\udc00\"", RawJson)) == "\"\\udc00\""

block string_serialization:
  doAssert toJson("line\nbreak") == "\"line\\nbreak\""
  doAssert toJson("\xff") == "\"\xff\""
  doAssert toJson("\v\x0e\x1f") == "\"\\u000b\\u000E\\u001F\""
