import std/tables
import brian
import std/[assertions, syncio]

template check(cond: bool) =
  if not cond: raiseAssert("bench check failed")

proc main() {.raises.} =
  var values = initOrderedTable[string, int]()
  for index in 0..<200:
    values["key" & $index] = index

  var checksum = 0
  for _ in 0..<1_000:
    checksum += toJson(values).len
  echo checksum

try:
  main()
except:
  quit "bench failed"
