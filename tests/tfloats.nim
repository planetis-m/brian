# Brian reads numbers with `std/parseutils.parseFloat`, which rounds correctly
# to each width; these cases check that every token reaches it intact.
import std/[assertions, parseutils, random, result, strutils]
import brian

template check(cond: bool; msg = "") =
  # Unlike `assert`, never compiled out.
  if not cond: raiseAssert(msg)

proc decoded[T](input: string; typ: typedesc[T]): T {.untyped, raises.} =
  # `case` on a Result does not compile in an untyped generic yet.
  let decoded = fromJson(input, T)
  if decoded.isErr: raiseAssert($decoded.error(JsonError()))
  result = decoded.unsafeGet

proc rejects[T](input: string; typ: typedesc[T]): bool {.untyped.} =
  fromJson(input, T).isErr

proc checkNumber(text: string) {.raises.} =
  var expected = 0.0
  check parseFloat(text, expected) == text.len, text
  check cast[uint64](decoded(text, float64)) == cast[uint64](expected), text
  # float32 is rounded once, directly from the decimal text.
  var expected32 = 0.0'f32
  check parseFloat(text, expected32) == text.len, text
  check cast[uint32](decoded(text, float32)) == cast[uint32](expected32), text

proc exactBits() {.raises.} =
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
    check cast[uint64](decoded(text, float64)) == bits, text
    checkNumber(text)

proc roundingAndFallback() {.raises.} =
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

proc longSpellings() {.raises.} =
  # Leading zeros count toward the stdlib converter's bounded scratch buffer,
  # even though Brian does not count them as significant digits. Very large
  # fraction/exponent counters can also cancel to a small combined exponent.
  for zeros in [45, 46, 47, 480, 490, 500, 99980, 99999, 100001]:
    for exponent in [zeros - 2, zeros, zeros + 2, 100000, 100001, 1000000]:
      for sign in ["", "-"]:
        checkNumber(sign & "0." & repeat('0', zeros) & "9734442705030664e" & $exponent)
  for zeros in [45, 46, 47, 480, 490, 500]:
    checkNumber(repeat('0', zeros) & "9734442705030664e-16")

proc decimalExponentRange() {.raises.} =
  # Exercise every cached exponent, including fallback at each end, with
  # different leading-bit positions, signs and significand lengths.
  for exponent in -343..309:
    for significand in ["1", "7", "123456789", "9007199254740993",
                        "1000000000000000000", "9999999999999999999"]:
      for sign in ["", "-"]:
        checkNumber(sign & significand & "e" & $exponent)

proc deterministicDecimals() {.raises.} =
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

proc permissiveGrammar() {.raises.} =
  check cast[uint64](decoded("-0e999999999999999999999", float64)) ==
    0x8000000000000000'u64
  # A number is whatever `parseFloat` reads: a token without digits is none.
  for text in [".", "-.", "e1", ".e1", "-.e1"]:
    check rejects(text, float64), text
  for text in [".9734442705030664", "-.9734442705030664",
               "009007199254740993.0", "9007199254740993."]:
    var expected = 0.0
    check parseFloat(text, expected) == text.len
    check cast[uint64](decoded(text, float64)) == cast[uint64](expected)
  for text in ["", "-", "1e", "1e+", "1e-", "1.2.3", "1e3junk"]:
    check rejects(text, float64), text

proc significandCompleteness() {.raises.} =
  # The accumulation threshold must retain exactly 19 significant digits;
  # any further digit, including zero, makes the stored value incomplete.
  for text in ["999999999999999999", "1000000000000000000",
               "9999999999999999999", "10000000000000000000",
               "10000000000000000001", "99999999999999999999",
               "0000000000000000000010000000000000000000e-19"]:
    # Force std/json to use its float reader; its integer reader can overflow.
    let number = if 'e' in text: text else: text & "e0"
    checkNumber(number)
    checkNumber("-" & number)

proc cachedRoundingBoundaries() {.raises.} =
  # Neighbors of binary64 halfway ties exercise both sides of the wider
  # one-multiply uncertainty interval, with different decimal scales.
  for base in [9007199254740992'u64, 18014398509481984'u64,
               36028797018963968'u64, 72057594037927936'u64]:
    for offset in 0'u64..16'u64:
      for exponent in [-23, -22, -1, 0, 1, 22, 23]:
        for sign in ["", "-"]:
          checkNumber(sign & $(base + offset) & "e" & $exponent)
  for sign in ["", "-"]:
    for exponent in ["0", "22", "-22", "23", "-23"]:
      checkNumber(sign & "0e" & exponent)
  # Brian intentionally preserves the zero sign even when stdlib's huge
  # exponent handling loses it. This behavior predates cached conversion.
  for exponent in ["999999", "-999999"]:
    check cast[uint64](decoded("-0e" & exponent, float64)) ==
      0x8000000000000000'u64

proc main() {.raises.} =
  exactBits()
  roundingAndFallback()
  longSpellings()
  decimalExponentRange()
  deterministicDecimals()
  permissiveGrammar()
  significandCompleteness()
  cachedRoundingBoundaries()

try:
  main()
except:
  raiseAssert("unexpected ValueError")
