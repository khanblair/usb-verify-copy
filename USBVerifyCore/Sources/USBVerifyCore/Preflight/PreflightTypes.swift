/// One source file the user wants to copy onto the drive.
public struct PreflightFile: Equatable, Sendable {
    public var sourcePath: String
    public var size: Int64
    /// The name the file will have on the drive (full name with extension).
    public var destinationName: String

    public init(sourcePath: String, size: Int64, destinationName: String) {
        self.sourcePath = sourcePath
        self.size = size
        self.destinationName = destinationName
    }
}

/// One problem found before any write. `fileName` is nil for a whole-batch issue.
public struct PreflightIssue: Equatable, Sendable {
    public var fileName: String?
    public var error: VerifyError

    public init(fileName: String?, error: VerifyError) {
        self.fileName = fileName
        self.error = error
    }
}

/// The result of `Preflight.check`. The copy may start only when `isOK` is true.
public struct PreflightReport: Equatable, Sendable {
    public var issues: [PreflightIssue]

    public init(issues: [PreflightIssue]) {
        self.issues = issues
    }

    public var isOK: Bool { issues.isEmpty }
    public var firstError: VerifyError? { issues.first?.error }
}
