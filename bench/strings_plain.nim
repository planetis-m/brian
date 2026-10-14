import brian
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

proc makePayload(): string =
  result = "["
  for index in 0..<400:
    if index > 0: result.add ','
    result.add "\"ordinary ASCII text copied in one run\""
  result.add ']'

proc main() {.raises.} =
  let payload = makePayload()
  var checksum = 0
  for iteration in 0..<100:
    let values = fromJson(payload, seq[string])
    check values.len == 400
    checksum += values[iteration mod values.len].len
  echo checksum

try:
  main()
except:
  quit "bench failed"
