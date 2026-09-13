{.define: brianFloatStats.}
include brian
import std/[assertions, strutils]

block conversionReasons:
  for (text, expected) in [
    ("-0.0", fcZero),
    ("12.5", fcClinger),
    ("0.5175691602819188123", fcCached),
    ("123456789012345678901e-20", fcIncomplete),
    (repeat('0', 65) & "9007199254740993e0", fcLong),
    ("1e-343", fcExponent),
    ("9007199254740993e0", fcHalfway),
    ("1e-308", fcNonNormal),
    # Restoring the two-word cached product converts these near-tie values
    # directly; the previous one-word product sent them to fcHalfway.
    ("1e126", fcCached),
    ("1e210", fcCached),
    ("4611686018427388415e0", fcCached)]:
    floatCounts = default(typeof(floatCounts))
    discard fromJson(text, float64)
    for kind in FloatConversion:
      doAssert floatCounts[kind] == uint64(ord(kind == expected)), text
