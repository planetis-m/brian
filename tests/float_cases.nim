# Shared by the native and portable wide-multiply test programs.
import std/[assertions, json, parseutils, random, strutils]
import brian

proc checkNumber(text: string) =
  var expected: float64
  doAssert parseutils.parseFloat(text, expected) == text.len
  let actual = fromJson(text, float64)
  doAssert cast[uint64](actual) == cast[uint64](expected), text
  doAssert cast[uint64](actual) == cast[uint64](parseJson(text).getFloat), text
  doAssert cast[uint32](fromJson(text, float32)) == cast[uint32](float32(expected)), text

block exactBits:
  for (text, bits) in [
    ("4.1865435594163865e+30", 0x464a6bb9d53e1c6f'u64),
    ("-3.623417402822194e-30", 0xb9d25f76f68b30d6'u64),
    ("0.9734442705030664", 0x3fef267499494184'u64),
    ("0.5175691602819188123", 0x3fe08fed331a875c'u64),
    ("1e308", 0x7fe1ccf385ebc8a0'u64),
    ("1e-308", 0x000730d67819e8d2'u64),
    ("2.2250738585072014e-308", 0x0010000000000000'u64),
    ("5e-324", 0x0000000000000001'u64),
    ("1.7976931348623157e308", 0x7fefffffffffffff'u64),
    ("-0.0", 0x8000000000000000'u64),
    ("0e0", 0'u64),
    ("0e999999", 0'u64)]:
    doAssert cast[uint64](fromJson(text, float64)) == bits, text
    checkNumber(text)

block roundingAndFallback:
  for text in [
    "9007199254740993.0", "9007199254740995.0", # opposite halfway ties
    "9007199254740992.9", "9007199254740993.1",
    "1844674407370955161e1", "9999999999999999999e-19",
    "2.2250738585072011e-308", "2.2250738585072012e-308",
    "2.2250738585072013e-308", "2.2250738585072015e-308",
    "2.4703282292062327e-324", "2.4703282292062328e-324",
    "1.7976931348623158e308", "1.7976931348623159e308",
    "1.00000000000000011102230246251565404236316680908203125",
    "1.00000000000000011102230246251565404236316680908203126",
    "123456789012345678901234567890e-29",
    "0.000000000000000000000123456789012345678901",
    "10000000000000000000000000000000000000000e-38",
    "1e999999999999999999999", "-1e999999999999999999999",
    "1e-999999999999999999999", "-1e-999999999999999999999",
    "1e400"]:
    checkNumber(text)

block longSpellings:
  # Leading zeros count toward the stdlib converter's bounded scratch buffer,
  # even though Brian does not count them as significant digits. Very large
  # fraction/exponent counters can also cancel to a small combined exponent.
  for zeros in [45, 46, 47, 480, 490, 500, 99980, 99999, 100001]:
    for exponent in [zeros - 2, zeros, zeros + 2, 100000, 100001, 1000000]:
      for sign in ["", "-"]:
        checkNumber(sign & "0." & repeat('0', zeros) & "9734442705030664e" & $exponent)
  for zeros in [45, 46, 47, 480, 490, 500]:
    checkNumber(repeat('0', zeros) & "9734442705030664e-16")

block decimalExponentRange:
  # Exercise every cached exponent, including fallback at each end, with
  # different leading-bit positions, signs and significand lengths.
  for exponent in -343..309:
    for significand in ["1", "7", "123456789", "9007199254740993",
                        "1000000000000000000", "9999999999999999999"]:
      for sign in ["", "-"]:
        checkNumber(sign & significand & "e" & $exponent)

block deterministicDecimals:
  var rng = initRand(20260911)
  for iteration in 0..<20_000:
    var text = if rng.rand(1) == 0: "" else: "-"
    text.add char(ord('1') + rng.rand(8))
    text.add '.'
    for digit in 0..<rng.rand(30):
      text.add char(ord('0') + rng.rand(9))
    text.add 'e'
    text.add $(rng.rand(800) - 400)
    checkNumber(text)

block permissiveGrammar:
  doAssert cast[uint64](fromJson("-0e999999999999999999999", float64)) ==
    0x8000000000000000'u64
  # Keep Brian's existing zero-token behavior as well as permissive numbers.
  for text in [".", "-.", "e1", ".e1", "-.e1"]:
    doAssert fromJson(text, float64) == 0.0
  for text in [".9734442705030664", "-.9734442705030664",
               "009007199254740993.0", "9007199254740993."]:
    var expected: float64
    doAssert parseutils.parseFloat(text, expected) == text.len
    doAssert cast[uint64](fromJson(text, float64)) == cast[uint64](expected)
  for text in ["", "-", "1e", "1e+", "1e-", "1.2.3", "1e3junk"]:
    doAssertRaises brian.JsonParsingError:
      discard fromJson(text, float64)
