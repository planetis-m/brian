import brian

type Row = array[8, int]

proc makePayload(): string =
  result = "["
  for row in 0..<200:
    if row > 0: result.add ','
    result.add "[1,2,3,4,5,6,7,8]"
  result.add ']'

let payload = makePayload()
var checksum = 0
for iteration in 0..<100:
  let rows = fromJson(payload, seq[Row])
  doAssert rows.len == 200
  checksum += rows[iteration mod rows.len][iteration mod 8]
echo checksum
