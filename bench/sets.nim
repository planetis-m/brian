import std/sets
import brian

proc makePayload(): string =
  result = "["
  for index in 0..<1_000:
    if index > 0: result.add ','
    result.add $(index mod 400)
  result.add ']'

let payload = makePayload()
var checksum = 0
for iteration in 0..<100:
  let values = fromJson(payload, HashSet[int])
  doAssert values.len == 400
  checksum += ord((iteration mod 400) in values)
echo checksum
