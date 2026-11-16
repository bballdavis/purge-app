import Foundation
import Testing
@testable import Purge

@MainActor
@Suite("Hidden files and developer deep scan")
struct HiddenAndDeepScanTests {
    @Test func hiddenSelectionStaysHiddenAcrossScansAndStores() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        fake.hasAccess = true
        let path = URL(fileURLWithPath: "/tmp/purge-hidden-\(UUID().uuidString).mov")
        let key = HiddenLargeFilesStore.key(path)
        defer { HiddenLargeFilesStore.remove([key]) }
        let file = LargeFile(path: path, sizeBytes: 2_000, lastUsed: .distantPast, category: .video)
        fake.largeFileEvents = [.file(file)]
        let store = fake.makeStore()
        await store.scanLargeFiles()
        store.setLargeFileSelected(id: file.id, isSelected: true)
        store.hideSelectedLargeFiles()
        #expect(store.largeFiles.isEmpty)
        #expect(store.selectedLargeFiles.isEmpty)
        #expect(fake.makeStore().hiddenLargeFiles.contains { $0.path == key })
        store.setLargeFileSelected(id: file.id, isSelected: true)
        #expect(store.selectedLargeFiles.isEmpty)
        await store.scanLargeFiles()
        #expect(store.largeFiles.isEmpty)
        #expect(HiddenLargeFilesStore.contains(file.path))
        HiddenLargeFilesStore.remove([key])
        await store.scanLargeFiles()
        #expect(store.largeFiles.map(\.id) == [file.id])
    }

    @Test func deepWalkReportsDepthLimitsAndDoesNotFollowLinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("purge-deep-\(UUID().uuidString)")
        let project = root.appendingPathComponent("one/two/project")
        let outside = fm.temporaryDirectory.appendingPathComponent("purge-outside-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        try Data("{}".utf8).write(to: outside.appendingPathComponent("package.json"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        let issues = DeepScanIssues()
        let shallow = DevScanner.findProjectRoots(in: [root], home: root, access: .full, maxDepth: 1, onIssue: { issues.add($0) })
        #expect(shallow.roots.isEmpty)
        #expect(!issues.snapshot().isEmpty)
        let deep = DevScanner.findProjectRoots(in: [root], home: root.deletingLastPathComponent(), access: .full, maxDepth: 12)
        #expect(deep.roots.map { $0.0.standardizedFileURL.path } == [project.standardizedFileURL.path])
    }

    @Test func hidingCancelsAStaleRemoveDownloadRequest() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let path = URL(fileURLWithPath: "/tmp/purge-hidden-cloud-\(UUID().uuidString).mov")
        let key = HiddenLargeFilesStore.key(path)
        defer { HiddenLargeFilesStore.remove([key]) }
        let file = LargeFile(path: path, sizeBytes: 2_000, lastUsed: .distantPast, category: .video,
                             syncsWithICloud: true, canMoveToTrash: true, canRemoveDownload: true)
        let store = fake.makeStore()
        store.largeFiles = [file]
        store.setLargeFileSelected(id: file.id, isSelected: true)
        store.requestRemoveDownloads(for: file)
        #expect(store.pendingRemoveDownload != nil)
        store.hideSelectedLargeFiles()
        await store.confirmRemoveDownloads()
        #expect(store.pendingRemoveDownload == nil)
        #expect(store.removeDownloadResult == nil)
        store.requestRemoveDownloads(for: file)
        #expect(store.pendingRemoveDownload == nil)
    }

    @Test func developerCleaningPreferenceAndRootsPersist() {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        store.setDeveloperCleaningEnabled(true)
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("purge-test-\(UUID().uuidString)")
        store.addDeveloperCleaningRoots([root])
        let next = fake.makeStore()
        #expect(next.developerCleaningEnabled)
        #expect(next.developerCleaningRoots == [root.resolvingSymlinksInPath().standardizedFileURL.path])
        next.setDeveloperCleaningEnabled(false)
        #expect(next.developerCleaningRoots.count == 1)
    }

    @Test func cancellingADeepScanWaitingForTheQueueDoesNotReleaseAnotherHolder() async {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let store = fake.makeStore()
        store.setDeveloperCleaningEnabled(true)
        store.isScanQueueHeld = true
        store.startDeepScan()
        #expect(store.isDeepScanning)
        await Task.yield()
        store.cancelDeepScan()
        #expect(!store.isDeepScanning)
        #expect(store.isScanQueueHeld)
        store.isScanQueueHeld = false
    }

    @Test func deepResultsAreManualOnlyAndUnknownCachesAreReadOnly() async throws {
        let fake = FakeScans()
        defer { fake.cleanUp() }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("purge-deep-test-\(UUID().uuidString)")
        let project = root.appendingPathComponent("projects/nested/app")
        let cache = root.appendingPathComponent("cache")
        let mystery = cache.appendingPathComponent("mystery")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: project.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mystery, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        try Data("{}".utf8).write(to: project.appendingPathComponent("package-lock.json"))
        try Data("cache".utf8).write(to: mystery.appendingPathComponent("data"))
        let store = fake.makeStore()
        store.deepScanCacheRoot = cache
        store.setDeveloperCleaningEnabled(true)
        store.addDeveloperCleaningRoots([root.appendingPathComponent("projects")])
        store.startDeepScan()
        #expect(await eventually { !store.isDeepScanning })
        let artifacts = store.projectGroups.flatMap(\.artifacts)
        #expect(artifacts.contains { $0.path.lastPathComponent == "node_modules" && $0.safetyInfo.level == .medium })
        #expect(store.scanSelection.artifactIDs.isEmpty)
        #expect(store.manualSafeCleanupCandidates().allSatisfy { $0.path.lastPathComponent != "node_modules" })
        #expect(store.deepScanUnknownCaches.map(\.url.lastPathComponent) == ["mystery"])
        store.setDeveloperCleaningEnabled(false)
        #expect(store.projectGroups.isEmpty)
        #expect(store.deepScanUnknownCaches.isEmpty)
    }
}
