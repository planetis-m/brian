import std/sets
import brian
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

proc main() {.raises.} =
  var values = initHashSet[int]()
  for value in 0..<400:
    values.incl value

  var checksum = 0
  for _ in 0..<1_000:
    checksum += toJson(values).len
  echo checksum

try:
  main()
except:
  quit "bench failed"
