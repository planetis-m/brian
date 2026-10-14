import brian
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

proc makePayload(): string =
  result = "["
  for index in 0..<1_000:
    if index > 0: result.add ','
    result.add $((index * 7_919) mod 1_000_000_007)
  result.add ']'

proc main() {.raises.} =
  let payload = makePayload()
  var checksum = 0'i64
  for iteration in 0..<100:
    let values = fromJson(payload, seq[int64])
    check values.len == 1_000
    checksum += values[iteration mod values.len]
  echo checksum

try:
  main()
except:
  quit "bench failed"
