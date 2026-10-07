import brian

proc makePayload(): string =
  result = "["
  for index in 0..<400:
    if index > 0: result.add ','
    result.add "\"text \\u03b1 \\ud83d\\udc3e \\ud834\\udd1e\""
  result.add ']'

let payload = makePayload()
var checksum = 0
for iteration in 0..<100:
  let values = fromJson(payload, seq[string])
  doAssert values.len == 400
  checksum += string(values[iteration mod values.len]).len
echo checksum
