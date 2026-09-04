import ValidationCore
import Foundation

// Thin on purpose: argument handling and an exit status, nothing else. Every decision lives in
// ValidationCore, where it is reachable by a test without a process.
// Line-buffered even when stdout is a pipe. Swift block-buffers there, so `rkval run | tee log`
// showed nothing at all for the first several minutes of a run — the operator could not tell a
// working run from a hung one, which is exactly what the progress lines exist to answer.
setvbuf(stdout, nil, _IOLBF, 0)

let status = await CLI.run(Array(CommandLine.arguments.dropFirst()))
exit(status)
