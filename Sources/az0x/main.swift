import AZ0XCore
import Foundation

// Thin on purpose: argument handling and an exit status, nothing else. Every decision lives in
// AZ0XCore, where it is reachable by a test without a process.
let status = await AZ0X.run(Array(CommandLine.arguments.dropFirst()))
exit(status)
