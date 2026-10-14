import std/tables
import brian
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

proc makePayload(): string =
  result = "{"
  for index in 0..<200:
    if index > 0: result.add ','
    result.add "\"key"
    result.add $index
    result.add "\":"
    result.add $index
  result.add '}'

proc main() {.raises.} =
  let payload = makePayload()
  var checksum = 0
  for iteration in 0..<100:
    let values = fromJson(payload, Table[string, int])
    check values.len == 200
    checksum += values["key" & $(iteration mod 200)]
  echo checksum

try:
  main()
except:
  quit "bench failed"
