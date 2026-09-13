## Fast decimal-to-binary64 conversion used by `readFloat`.
##
## The exact small-number path and the cached-power path live here, together
## with the wide multiply they share. `tryFastFloat` returns false when the
## value cannot be rounded without doubt, and the caller keeps the exact
## standard-library converter for that case.

import std/bitops

import brian_float_powers

const
  DecimalPowers: array[-22..22, float64] = [
    1.0e-22, 1.0e-21, 1.0e-20, 1.0e-19, 1.0e-18, 1.0e-17, 1.0e-16,
    1.0e-15, 1.0e-14, 1.0e-13, 1.0e-12, 1.0e-11, 1.0e-10, 1.0e-9,
    1.0e-8, 1.0e-7, 1.0e-6, 1.0e-5, 1.0e-4, 1.0e-3, 1.0e-2, 1.0e-1,
    1.0,
    1.0e1, 1.0e2, 1.0e3, 1.0e4, 1.0e5, 1.0e6, 1.0e7, 1.0e8, 1.0e9,
    1.0e10, 1.0e11, 1.0e12, 1.0e13, 1.0e14, 1.0e15, 1.0e16, 1.0e17,
    1.0e18, 1.0e19, 1.0e20, 1.0e21, 1.0e22
  ]

func portableMultiplyWide*(a, b: uint64): tuple[hi, lo: uint64] {.inline.} =
  ## 64x64->128 multiply from 32-bit limbs; the fallback for targets without a
  ## native wide product.
  const Mask = 0xffffffff'u64
  let aLow = a and Mask
  let bLow = b and Mask
  let aHigh = a shr 32
  let bHigh = b shr 32
  let low = aLow * bLow
  let middle = aHigh * bLow + (low shr 32)
  let carry = (middle and Mask) + aLow * bHigh
  result.lo = (carry shl 32) or (low and Mask)
  result.hi = aHigh * bHigh + (middle shr 32) + (carry shr 32)

func multiplyWide*(a, b: uint64): tuple[hi, lo: uint64] {.inline.} =
  ## Full 128-bit product. Compilers with a native `__int128` use one multiply,
  ## 64-bit MSVC uses `_umul128`, and everything else uses the portable path.
  when (defined(gcc) or defined(llvm_gcc) or defined(clang)) and
      sizeof(pointer) == 8:
    {.emit: """
    __uint128_t product = (__uint128_t)`a` * (__uint128_t)`b`;
    `result`.Field0 = (unsigned long long)(product >> 64);
    `result`.Field1 = (unsigned long long)product;
    """.}
  elif sizeof(pointer) == 8 and defined(windows) and not defined(tcc):
    proc umul128(a, b: uint64, c: ptr uint64): uint64 {.importc: "_umul128", header: "intrin.h".}
    var hi: uint64
    result.lo = umul128(a, b, addr hi)
    result.hi = hi
  else:
    result = portableMultiplyWide(a, b)

func clingerFloat(significand: uint64; exponent: int): float64 {.inline.} =
  ## Exact scaling for a significand below 2^53 and an exponent in -22..22.
  if exponent < 0:
    result = float64(significand) / DecimalPowers[-exponent]
  else:
    result = float64(significand) * DecimalPowers[exponent]

func cachedPowerFloat(significand: uint64; exponent: int; value: var float64): bool {.inline.} =
  ## Rounds `significand * 10^exponent` through the cached 128-bit power and
  ## fills `value` when the interval test can decide. Returns false at rounding
  ## boundaries, for subnormals and on overflow, so the caller keeps the exact
  ## converter for those.
  let power = FloatPowers[exponent]
  let shift = countLeadingZeroBits(significand)
  let normalized = significand shl shift
  var product = multiplyWide(normalized, power.hi)
  let tail = multiplyWide(normalized, power.lo)
  product.lo += tail.hi
  if product.lo < tail.hi: inc product.hi
  # The cached power is rounded down with error < 1. Discarding the low
  # product word adds error < 1, so the exact scaled product is in [P, P+2).
  let upper = int(product.hi shr 63)
  let discarded = 10 + upper
  let mask = (1'u64 shl discarded) - 1
  let halfway = 1'u64 shl (discarded - 1)
  let remainder = product.hi and mask
  if (remainder == halfway and product.lo == 0) or
      (remainder == halfway - 1 and product.lo >= high(uint64) - 1):
    result = false
  else:
    var mantissa = product.hi shr discarded
    if remainder >= halfway: inc mantissa
    # floor(log2(10^exponent)); the generator checks this for every entry.
    # ashr rounds negative exponents down, unlike integer division.
    let powerExponent = ashr(exponent * 217706, 16)
    var binaryExponent = powerExponent + 63 + upper - shift + 1023
    if mantissa == (1'u64 shl 53):
      mantissa = mantissa shr 1
      inc binaryExponent
    if binaryExponent > 0 and binaryExponent < 2047:
      value = cast[float64]((uint64(binaryExponent) shl 52) or
        (mantissa and ((1'u64 shl 52) - 1)))
      result = true

func tryFastFloat*(significand: uint64; exponent: int; tokenLen: uint; complete, negative: bool;
    value: var float64): bool {.inline.} =
  ## Fills `value` and returns true when the scanned token has a provable
  ## binary64 rounding. Long spellings and uncertain intervals return false.
  result = false
  if significand == 0:
    value = if negative: -0.0 else: 0.0
    result = true
  elif significand < (1'u64 shl 53) and exponent in -22..22:
    value = clingerFloat(significand, exponent)
    if negative: value = -value
    result = true
  elif complete and tokenLen <= 64 and exponent in low(FloatPowers)..high(FloatPowers):
    if cachedPowerFloat(significand, exponent, value):
      if negative: value = -value
      result = true
