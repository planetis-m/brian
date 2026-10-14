import brian
import std/result
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

proc makePayload(): string =
  result = "["
  for index in 0..<200:
    if index > 0: result.add ','
    result.add "{\"ordinaryField\":1,\"escaped\\u0046ield\":2,\"nested\":{\"name\":\"value\"}}"
  result.add ']'

proc main() {.raises.} =
  let payload = makePayload()
  var checksum = 0
  for _ in 0..<100:
    case fromJson(payload, CanonRawJson)
    of Ok(value):
      checksum += string(value).len
    of Err(_):
      check false
  echo checksum

try:
  main()
except:
  quit "bench failed"
