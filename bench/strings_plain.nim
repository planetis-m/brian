import brian

proc makePayload(): string =
  result = "["
  for index in 0..<400:
    if index > 0: result.add ','
    result.add "\"ordinary ASCII text copied in one run\""
  result.add ']'

let payload = makePayload()
var checksum = 0
for iteration in 0..<100:
  let values = fromJson(payload, seq[string])
  doAssert values.len == 400
  checksum += values[iteration mod values.len].len
echo checksum
