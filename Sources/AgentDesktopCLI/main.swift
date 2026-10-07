import Foundation

exit(CLI().run(Array(CommandLine.arguments.dropFirst())).rawValue)
