import Foundation
import USBVerifyCore

public enum CLICommand: Equatable, Sendable {
    case list(includeDiskImages: Bool)
    case copy(CopyOptions)
    case verify(VerifyOptions)
    case resume(String)
    case jobs
    case eject(DriveSelector)
    case help
}

public struct DriveSelector: Equatable, Sendable {
    public var value: String
    public init(value: String) { self.value = value }
}

public struct CopyOptions: Equatable, Sendable {
    public var drive: DriveSelector
    public var folder: String
    public var mode: VerifyMode
    public var conflict: ConflictPolicy?
    public var dotClean: Bool
    public var dryRun: Bool
    public var yes: Bool
    public var files: [String]
    public init(
        drive: DriveSelector, folder: String, mode: VerifyMode = .strict, conflict: ConflictPolicy? = nil,
        dotClean: Bool = false, dryRun: Bool = false, yes: Bool = false, files: [String]
    ) {
        self.drive = drive
        self.folder = folder
        self.mode = mode
        self.conflict = conflict
        self.dotClean = dotClean
        self.dryRun = dryRun
        self.yes = yes
        self.files = files
    }
}

public struct VerifyOptions: Equatable, Sendable {
    public var drive: DriveSelector
    public var folder: String
    public var files: [String]
    public init(drive: DriveSelector, folder: String, files: [String]) {
        self.drive = drive
        self.folder = folder
        self.files = files
    }
}

public enum ConflictPolicy: String, Sendable {
    case ask
    case replace
    case skip
    case keepBoth = "keep-both"
}

public enum ArgumentParser {
    public static let helpText = """
        usbverify list [--include-disk-images]
        usbverify copy --drive <name|uuid|number> --to <folder> [--mode strict|quick] [--on-conflict ask|replace|skip|keep-both] [--dot-clean] [--dry-run] [--yes] <file>...
        usbverify verify --drive <name|uuid|number> --folder <folder> <source file>...
        usbverify resume <job-id>
        usbverify jobs
        usbverify eject --drive <name|uuid|number>
        usbverify help
        """

    public static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let command = arguments.first else { return .help }
        switch command {
        case "help": return .help
        case "jobs":
            try requireNoExtra(arguments)
            return .jobs
        case "resume":
            guard arguments.count == 2, !arguments[1].isEmpty else { throw CLIError.usage("resume needs a job id") }
            return .resume(arguments[1])
        case "list": return try parseList(Array(arguments.dropFirst()))
        case "eject": return .eject(try parseDriveOnly(Array(arguments.dropFirst())))
        case "copy": return .copy(try parseCopy(Array(arguments.dropFirst())))
        case "verify": return try parseVerify(Array(arguments.dropFirst()))
        default: throw CLIError.usage("unknown command: \(command)")
        }
    }

    private static func parseList(_ args: [String]) throws -> CLICommand {
        guard args.allSatisfy({ $0 == "--include-disk-images" }) else { throw CLIError.usage("unknown list flag") }
        return .list(includeDiskImages: args.contains("--include-disk-images"))
    }

    private static func parseDriveOnly(_ args: [String]) throws -> DriveSelector {
        guard args.count == 2, args[0] == "--drive" else { throw CLIError.usage("eject needs --drive") }
        return DriveSelector(value: args[1])
    }

    private static func parseCopy(_ args: [String]) throws -> CopyOptions {
        var drive: String?
        var folder: String?
        var mode = VerifyMode.strict
        var conflict: ConflictPolicy?
        var dotClean = false
        var dryRun = false
        var yes = false
        var files: [String] = []
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--drive": drive = try value(args, &index, "--drive")
            case "--to": folder = try value(args, &index, "--to")
            case "--mode":
                let value = try value(args, &index, "--mode")
                guard let parsed = VerifyMode(rawValue: value) else {
                    throw CLIError.usage("mode must be strict or quick")
                }
                mode = parsed
            case "--on-conflict":
                let value = try value(args, &index, "--on-conflict")
                guard let parsed = ConflictPolicy(rawValue: value) else {
                    throw CLIError.usage("invalid conflict policy")
                }
                conflict = parsed
            case "--dot-clean": dotClean = true
            case "--dry-run": dryRun = true
            case "--yes": yes = true
            case let flag where flag.hasPrefix("--"): throw CLIError.usage("unknown flag: \(flag)")
            default: files.append(args[index])
            }
            index += 1
        }
        guard let drive, !drive.isEmpty else { throw CLIError.usage("copy needs --drive") }
        guard let folder, !folder.hasPrefix("/"), !folder.split(separator: "/").contains("..") else {
            throw CLIError.usage("--to must be a folder below the drive root")
        }
        guard !files.isEmpty else { throw CLIError.usage("copy needs at least one file") }
        guard Set(files.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }).count == files.count else {
            throw CLIError.usage("two files have the same name")
        }
        return CopyOptions(
            drive: DriveSelector(value: drive), folder: folder, mode: mode, conflict: conflict,
            dotClean: dotClean, dryRun: dryRun, yes: yes, files: files)
    }

    private static func parseVerify(_ args: [String]) throws -> CLICommand {
        var drive: String?
        var folder: String?
        var files: [String] = []
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--drive": drive = try value(args, &index, "--drive")
            case "--folder": folder = try value(args, &index, "--folder")
            case let flag where flag.hasPrefix("--"): throw CLIError.usage("unknown flag: \(flag)")
            default: files.append(args[index])
            }
            index += 1
        }
        guard let drive, let folder, !folder.hasPrefix("/"), !folder.split(separator: "/").contains(".."),
            !files.isEmpty
        else {
            throw CLIError.usage("verify needs --drive, --folder, and source files")
        }
        guard Set(files.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }).count == files.count else {
            throw CLIError.usage("two files have the same name")
        }
        return .verify(VerifyOptions(drive: DriveSelector(value: drive), folder: folder, files: files))
    }

    private static func value(_ args: [String], _ index: inout Int, _ flag: String) throws -> String {
        let next = index + 1
        guard next < args.count, !args[next].hasPrefix("--") else { throw CLIError.usage("\(flag) needs a value") }
        index = next
        return args[next]
    }

    private static func requireNoExtra(_ args: [String]) throws {
        guard args.count == 1 else { throw CLIError.usage("unexpected arguments") }
    }
}

public enum CLIError: Error, Equatable, Sendable {
    case usage(String)
    case operational(String)
}
