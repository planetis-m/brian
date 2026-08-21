import brian

proc makePayload(): string =
  result = "["
  for index in 0..<1_000:
    if index > 0: result.add ','
    result.add "12.5"
  result.add ']'

let payload = makePayload()
var checksum = 0.0
for iteration in 0..<100:
  let values = fromJson(payload, seq[float64])
  doAssert values.len == 1_000
  checksum += values[iteration mod values.len]
echo checksum
