import Foundation

enum DeveloperCleaningSettings {
    static let enabledKey = "developerCleaning.enabled"
    static let rootsKey = "developerCleaning.projectRoots"
}

nonisolated struct DeepScanCacheFolder: Identifiable, Sendable {
    let url: URL
    let sizeBytes: Int64
    var id: String { url.path }
}

/// Collects incomplete paths from the background project walk.
nonisolated final class DeepScanIssues: @unchecked Sendable {
    private let lock = NSLock()
    private var paths = Set<String>()
    func add(_ path: String) { lock.withLock { _ = paths.insert(path) } }
    func snapshot() -> [String] { lock.withLock { paths.sorted() } }
}
