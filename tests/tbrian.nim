import std/[assertions, math, options, parseutils, strutils]
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

proc readJson*(dst: var Page; p: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  for name in p.jsonFields:
    case name
    of "number": readJson(dst.number, p, unknownFields)
    of "status": readJson(dst.status, p, unknownFields)
    else:
      if unknownFields == ufReject:
        p.raiseParseError("expected known field, got \"" & name & "\"")
      p.skipJson()

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
  doAssert toJson(page) == "{\"number\":4,\"status\":\"ok\"}"

block escaped_field_names:
  doAssert fromJson("{\"na\\u006de\":\"x\"}", Sample).name == "x"
  let page = fromJson("{\"num\\u0062er\":4,\"sta\\u0074us\":\"ok\"}", Page)
  doAssert page == Page(number: 4, status: "ok")

block raw_values:
  let raw = fromJson(" { \"x\" : [ 1, \"\\u03b1\" ] } ", RawJson)
  doAssert string(raw) == "{ \"x\" : [ 1, \"\\u03b1\" ] }"
  doAssert toJson(raw) == string(raw)
  doAssert toJson(RawJson("not validated here")) == "not validated here"
  let canonical = fromJson(" { \"x\" : [ 1, \"\\u03b1\" ] } ", CanonRawJson)
  doAssert string(canonical) == "{\"x\":[1,\"α\"]}"
  doAssert string(fromJson("{\"\":1}", CanonRawJson)) == "{\"\":1}"
  doAssert string(fromJson("1e", RawJson)) == "1e"
  doAssert string(fromJson("-", RawJson)) == "-"

block field_lifetime_and_unknown_policy:
  var destination = Sample()
  doAssertRaises JsonParsingError:
    fromJson("{\"name\":\"x\",\"extra\":1}", destination, ufReject)

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

block tuples_arrays_and_items:
  doAssert fromJson("[1,\"x\",true]", (int, string, bool)) == (1, "x", true)
  doAssert fromJson("[1,2,3]", array[3, int]) == [1, 2, 3]
  var collected: seq[int] = @[]
  for value in jsonItems("[1,2,3]", int): collected.add value
  doAssert collected == @[1, 2, 3]

block raw_string_compatibility:
  doAssert fromJson("\"\\x\"", string) == "\\x"
  doAssert fromJson("\"\\v\"", string) == "\v"
  doAssert fromJson("\"\\udc00\"", string) == "\xED\xB0\x80"
  doAssert string(fromJson("\"\\udc00\"", RawJson)) == "\"\\udc00\""

block string_serialization:
  doAssert toJson("line\nbreak") == "\"line\\nbreak\""
  doAssert toJson("\xff") == "\"\xff\""
  doAssert toJson("\v\x0e\x1f") == "\"\\u000b\\u000E\\u001F\""
