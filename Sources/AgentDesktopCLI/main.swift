import Foundation

Interrupt.install()
exit(CLI().run(Array(CommandLine.arguments.dropFirst())).rawValue)
