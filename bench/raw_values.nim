import brian

proc makePayload(): string =
  result = "["
  for index in 0..<200:
    if index > 0: result.add ','
    result.add "{\"payload\":[\"a\",{\"nested\":true},null],\"text\":\"raw value\"}"
  result.add ']'

let payload = makePayload()
var checksum = 0
for iteration in 0..<100:
  let values = fromJson(payload, seq[RawJson])
  doAssert values.len == 200
  checksum += string(values[iteration mod values.len]).len
echo checksum
