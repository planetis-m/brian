import brian

var plain = newSeq[string](400)
var escaped = newSeq[string](400)
for index in 0..<plain.len:
  plain[index] = "ordinary string payload"
  escaped[index] = "quoted \" value\nwith \\ slash"

var checksum = 0
for iteration in 0..<200:
  checksum += toJson(plain).len
  checksum += toJson(escaped).len
echo checksum
