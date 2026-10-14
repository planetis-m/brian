import brian
import std/result
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

proc main() {.raises.} =
  var values = newSeq[RawJson](200)
  for index in 0..<values.len:
    values[index] = RawJson("{\"name\":\"raw\",\"items\":[1,true,null]}")

  var checksum = 0
  for iteration in 0..<1000:
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
