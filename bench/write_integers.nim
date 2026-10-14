import brian
import std/result
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

proc main() {.raises.} =
  var values = newSeq[int64](1_000)
  for index in 0..<values.len:
    values[index] = int64(index * 7_919) - 3_000_000

  var checksum = 0
  for iteration in 0..<200:
    case toJson(values)
    of Ok(text):
      checksum += text.len
    of Err(_):
      check false
  echo checksum

try:
  main()
except:
  quit "bench failed"
