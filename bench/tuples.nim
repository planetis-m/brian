import brian
import std/result
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

type Row = (int, int, int, int, int, int, int, int)

proc makePayload(): string =
  result = "["
  for row in 0..<200:
    if row > 0: result.add ','
    result.add "[1,2,3,4,5,6,7,8]"
  result.add ']'

proc main() {.raises.} =
  let payload = makePayload()
  var checksum = 0
  for iteration in 0..<100:
    case fromJson(payload, seq[Row])
    of Ok(rows):
      check rows.len == 200
      checksum += rows[iteration mod rows.len][0]
    of Err(_):
      check false
  echo checksum

try:
  main()
except:
  quit "bench failed"
