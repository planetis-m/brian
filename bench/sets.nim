import std/sets
import brian
import std/result
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

proc makePayload(): string =
  result = "["
  for index in 0..<1_000:
    if index > 0: result.add ','
    result.add $(index mod 400)
  result.add ']'

proc main() {.raises.} =
  let payload = makePayload()
  var checksum = 0
  for iteration in 0..<100:
    case fromJson(payload, HashSet[int])
    of Ok(values):
      check values.len == 400
      checksum += ord((iteration mod 400) in values)
    of Err(_):
      check false
  echo checksum

try:
  main()
except:
  quit "bench failed"
