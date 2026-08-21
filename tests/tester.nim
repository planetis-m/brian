import std/os

proc run(command: string) =
  if execShellCmd(command) != 0:
    quit "FAILURE " & command

let testDir = getCurrentDir() / "tests"
for path in walkFiles(testDir / "t*.nim"):
  if path.extractFilename != "tester.nim":
    run "nim c -r " & quoteShell(path)

echo "All brian tests completed."
