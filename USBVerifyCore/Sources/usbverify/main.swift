import Foundation
import USBVerifyCLI

exit(await CLI.run(arguments: Array(CommandLine.arguments.dropFirst())))
