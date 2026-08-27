import brian

type Response = object
  id: int
  active: bool
  retry: int

proc readJson*(dst: var Response; p: var JsonParser;
               unknownFields: UnknownFieldPolicy) =
  for field in p.jsonFields(["id", "active", "retry"], unknownFields):
    case field
    of 0: readJson(dst.id, p, unknownFields)
    of 1: readJson(dst.active, p, unknownFields)
    of 2: readJson(dst.retry, p, unknownFields)
    else: discard

proc makePayload(): string =
  result = "["
  for index in 0..<2_000:
    if index > 0: result.add ','
    result.add "{\"id\":" & $index & ",\"active\":true,\"retry\":3}"
  result.add ']'

let payload = makePayload()
var checksum = 0
for iteration in 0..<20:
  let values = fromJson(payload, seq[Response])
  doAssert values.len == 2_000
  checksum += values[iteration].retry
echo checksum
