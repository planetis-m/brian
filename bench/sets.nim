import std/sets
import brian
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
    let values = fromJson(payload, HashSet[int])
    check values.len == 400
    checksum += ord((iteration mod 400) in values)
  echo checksum

try:
  main()
except:
  quit "bench failed"
