import brian

proc makePayload(): string =
  result = "["
  for index in 0..<200:
    if index > 0: result.add ','
    result.add "\"quote: \\\" newline: \\n greek: \\u03b1\""
  result.add ']'

let payload = makePayload()
var checksum = 0
for iteration in 0..<20:
  let values = fromJson(payload, seq[string])
  doAssert values.len == 200
  checksum += values[iteration mod values.len].len
echo checksum
