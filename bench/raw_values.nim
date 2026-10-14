import brian
import std/result
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
    case fromJson(payload, seq[RawJson])
    of Ok(values):
      check values.len == 200
      checksum += string(values[iteration mod values.len]).len
    of Err(_):
      check false
  echo checksum

try:
  main()
except:
  quit "bench failed"
