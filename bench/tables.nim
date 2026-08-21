import std/tables
import brian

proc makePayload(): string =
  result = "{"
  for index in 0..<200:
    if index > 0: result.add ','
    result.add "\"key"
    result.add $index
    result.add "\":"
    result.add $index
  result.add '}'

let payload = makePayload()
var checksum = 0
for iteration in 0..<100:
  let values = fromJson(payload, Table[string, int])
  doAssert values.len == 200
  checksum += values["key" & $(iteration mod 200)]
echo checksum
