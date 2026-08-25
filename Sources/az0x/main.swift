import AZ0XCore
import Foundation

// Thin on purpose: argument handling and an exit status, nothing else. Every decision lives in
// AZ0XCore, where it is reachable by a test without a process.
// Line-buffered even when stdout is a pipe. Swift block-buffers there, so `az0x run | tee log`
// showed nothing at all for the first several minutes of a run — the operator could not tell a
// working run from a hung one, which is exactly what the progress lines exist to answer.
setvbuf(stdout, nil, _IOLBF, 0)

let status = await AZ0X.run(Array(CommandLine.arguments.dropFirst()))
exit(status)
