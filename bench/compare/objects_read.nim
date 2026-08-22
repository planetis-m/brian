## Compare direct typed object decoding across brian, jsonx, and jsony.
##
## Compile normally for brian, with -d:compareJsonx for jsonx, or with
## -d:compareJsony for jsony. See README.md in this directory for setup.

import common

let payload = makePayload()
var checksum = 0

for iteration in 0..<100:
  let values = fromJson(payload, seq[Record])
  doAssert values.len == 200
  checksum += values[iteration mod values.len].labels.len

echo checksum
