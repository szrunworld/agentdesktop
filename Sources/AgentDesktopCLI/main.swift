import Foundation

// Ctrl-C while an ai/gui command waits is remembered so it can cancel
// the run it started (ContractCLI).
Interrupt.install()
exit(CLI().run(Array(CommandLine.arguments.dropFirst())))
