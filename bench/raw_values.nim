import brian
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

proc makePayload(): string =
  result = "["
  for index in 0..<200:
    if index > 0: result.add ','
    result.add "{\"payload\":[\"a\",{\"nested\":true},null],\"text\":\"raw value\"}"
  result.add ']'

proc main() {.raises.} =
  let payload = makePayload()
  var checksum = 0
  for iteration in 0..<100:
    let values = fromJson(payload, seq[RawJson])
    check values.len == 200
    checksum += string(values[iteration mod values.len]).len
  echo checksum

try:
  main()
except:
  quit "bench failed"
