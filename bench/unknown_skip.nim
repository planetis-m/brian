import brian

type Envelope = object
  name: string
  enabled: bool

proc makePayload(): string =
  result = "["
  for index in 0..<200:
    if index > 0: result.add ','
    result.add "{\"name\":\"known\",\"enabled\":true,\"extension\":{"
    result.add "\"deep\":[{\"value\":[\"a\",\"b\",{\"c\":false}]},null],"
    result.add "\"opaque\":\"skip this escaped \\\" string\\\"\"}}"
  result.add ']'

let payload = makePayload()
var checksum = 0
for iteration in 0..<100:
  let values = fromJson(payload, seq[Envelope])
  doAssert values.len == 200
  checksum += values[iteration mod values.len].name.len
echo checksum
