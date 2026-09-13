# Typed coordinate averaging workload from kostya/benchmarks/json.
import std/[assertions, syncio]
import brian

type
  Coordinate = tuple[x, y, z: float64]
  CoordinateObject = object
    coordinates: seq[Coordinate]

{.emit: "#include <valgrind/cachegrind.h>".}

proc calc(text: string): Coordinate =
  let obj = fromJson(text, CoordinateObject)
  var x, y, z: float64
  for coord in obj.coordinates:
    x += coord.x
    y += coord.y
    z += coord.z
  let count = float64(obj.coordinates.len)
  result = (x / count, y / count, z / count)

proc main() =
  for text in ["""{"coordinates":[{"x":2.0,"y":0.5,"z":0.25}]}""",
               """{"coordinates":[{"y":0.5,"x":2.0,"z":0.25}]}"""]:
    doAssert calc(text) == (2.0, 0.5, 0.25)
  let text = readFile("/tmp/1.json")
  {.emit: "CACHEGRIND_START_INSTRUMENTATION;".}
  let average = calc(text)
  {.emit: "CACHEGRIND_STOP_INSTRUMENTATION;".}
  echo average

main()
