import Darwin
import Foundation
import Testing

@testable import NotProtonApp

@Suite("Bridge payload")
struct BridgePayloadTests {

    private func fakeResources(in work: URL) throws -> URL {
        let root = work.appending(path: "bridge")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for entry in BridgePayload.entries {
            let data = Data(repeating: UInt8(entry.resource.count % 256), count: entry.resource.count * 100)
            try data.write(to: root.appending(path: entry.resource))
        }
        return root
    }

    @Test("Locate finds all resources when present")
    func locateFindsAll() throws {
        let work = try scratchDirectory("bridge")
        defer { try? FileManager.default.removeItem(at: work) }

        let root = try fakeResources(in: work)
        let located = try BridgePayload.locate(root: root)
        #expect(located.sources.count == BridgePayload.entries.count)
    }

    @Test("Locate reports missing resources rather than silently staging nothing")
    func locateReportsMissing() throws {
        let work = try scratchDirectory("bridge")
        defer { try? FileManager.default.removeItem(at: work) }

        let root = work.appending(path: "empty-bridge")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        #expect(throws: StepFailure.self) { try BridgePayload.locate(root: root) }
    }

    @Test("Stage writes all bridge paths")
    func stageWritesAll() throws {
        let work = try scratchDirectory("bridge")
        defer { try? FileManager.default.removeItem(at: work) }

        let root = try fakeResources(in: work)
        let located = try BridgePayload.locate(root: root)
        let bridge = work.appending(path: "staged")
        let result = try BridgePayload.stage(located: located, bridge: bridge)

        let allPaths = BridgePayload.entries.flatMap(\.bridgePaths)
        #expect(result.staged.count == allPaths.count)
        #expect(result.unchanged.isEmpty)

        for path in allPaths {
            #expect(
                FileManager.default.fileExists(atPath: bridge.appending(path: path).path(percentEncoded: false)),
                "\(path) was not staged"
            )
        }
    }

    @Test("Matching contents are left untouched on a second run")
    func skipsMatchingContents() throws {
        let work = try scratchDirectory("bridge")
        defer { try? FileManager.default.removeItem(at: work) }

        let root = try fakeResources(in: work)
        let located = try BridgePayload.locate(root: root)
        let bridge = work.appending(path: "staged")

        let first = try BridgePayload.stage(located: located, bridge: bridge)
        let allPaths = BridgePayload.entries.flatMap(\.bridgePaths)
        let untouchedDate = Date(timeIntervalSince1970: 1_000_000)
        let before = try allPaths.map { path in
            let destination = bridge.appending(path: path).path(percentEncoded: false)
            try FileManager.default.setAttributes([.modificationDate: untouchedDate], ofItemAtPath: destination)
            return try FileManager.default.attributesOfItem(atPath: destination)
        }
        let second = try BridgePayload.stage(located: located, bridge: bridge)

        #expect(!first.staged.isEmpty)
        #expect(second.staged.isEmpty, "files were re-staged despite matching contents")
        #expect(second.unchanged.count == allPaths.count)
        for (path, original) in zip(allPaths, before) {
            let after = try FileManager.default.attributesOfItem(
                atPath: bridge.appending(path: path).path(percentEncoded: false)
            )
            #expect(after[.systemFileNumber] as? NSNumber == original[.systemFileNumber] as? NSNumber)
            #expect(after[.modificationDate] as? Date == original[.modificationDate] as? Date)
        }
    }

    @Test("Changed contents replace every copy even when byte counts match")
    func replacesSameSizeContents() throws {
        let work = try scratchDirectory("bridge")
        defer { try? FileManager.default.removeItem(at: work) }

        let root = try fakeResources(in: work)
        let located = try BridgePayload.locate(root: root)
        let bridge = work.appending(path: "staged")
        _ = try BridgePayload.stage(located: located, bridge: bridge)

        let entry = try #require(located.sources.first { $0.bridgePaths.count > 1 })
        let previous = try Data(contentsOf: entry.source)
        let changed = Data(repeating: 0xff, count: previous.count)
        try changed.write(to: entry.source)
        let result = try BridgePayload.stage(located: located, bridge: bridge)

        #expect(result.staged == entry.bridgePaths)
        #expect(Set(result.unchanged).isDisjoint(with: entry.bridgePaths))
        for path in entry.bridgePaths {
            #expect(try Data(contentsOf: bridge.appending(path: path)) == changed)
        }
    }

    @Test("An unavailable source fails without changing the previous destination", arguments: [false, true])
    func unavailableSourcePreservesDestination(missing: Bool) throws {
        let work = try scratchDirectory("bridge")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appending(path: "source")
        let destination = work.appending(path: "staged/steam.exe")
        try Data("old".utf8).write(to: source)
        let located = BridgePayload.Located(sources: [(source: source, bridgePaths: ["steam.exe"])])
        _ = try BridgePayload.stage(located: located, bridge: destination.deletingLastPathComponent())

        try Data("new".utf8).write(to: source)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: source.path(percentEncoded: false)
            )
        }
        if missing {
            try FileManager.default.removeItem(at: source)
        } else {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0], ofItemAtPath: source.path(percentEncoded: false)
            )
        }

        #expect(throws: (any Error).self) {
            try BridgePayload.stage(located: located, bridge: destination.deletingLastPathComponent())
        }
        #expect(try Data(contentsOf: destination) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: destination.deletingLastPathComponent().path(percentEncoded: false)
        ) == ["steam.exe"])
    }

    @Test("Flat and arch copies are byte-identical")
    func duplicatesMatch() throws {
        let work = try scratchDirectory("bridge")
        defer { try? FileManager.default.removeItem(at: work) }

        let root = try fakeResources(in: work)
        let located = try BridgePayload.locate(root: root)
        let bridge = work.appending(path: "staged")
        _ = try BridgePayload.stage(located: located, bridge: bridge)

        // The x86_64 lsteamclient.dll is staged to both lsteamclient.dll and
        // x86_64-windows/lsteamclient.dll, from the same source. Verify identity.
        for entry in BridgePayload.entries where entry.bridgePaths.count > 1 {
            let first = try Data(contentsOf: bridge.appending(path: entry.bridgePaths[0]))
            for duplicate in entry.bridgePaths.dropFirst() {
                let other = try Data(contentsOf: bridge.appending(path: duplicate))
                #expect(first == other, "\(entry.bridgePaths[0]) and \(duplicate) differ")
            }
        }
    }

    @Test("Replacement preserves source permissions and extended attributes")
    func replacementPreservesMetadata() throws {
        let work = try scratchDirectory("bridge")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appending(path: "source")
        let bridge = work.appending(path: "staged")
        let destination = bridge.appending(path: "steam.exe")
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination)
        try Data("new".utf8).write(to: source)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o751], ofItemAtPath: source.path(percentEncoded: false)
        )
        let attribute = Data("metadata".utf8)
        let setResult = attribute.withUnsafeBytes {
            setxattr(source.path(percentEncoded: false), "com.notproton.test", $0.baseAddress, $0.count, 0, 0)
        }
        #expect(setResult == 0)

        let located = BridgePayload.Located(sources: [(source: source, bridgePaths: ["steam.exe"])])
        let result = try BridgePayload.stage(located: located, bridge: bridge)

        #expect(result.staged == ["steam.exe"])
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path(percentEncoded: false))
        #expect(attributes[.posixPermissions] as? Int == 0o751)
        var copiedAttribute = Data(count: attribute.count)
        let readCount = copiedAttribute.withUnsafeMutableBytes {
            getxattr(destination.path(percentEncoded: false), "com.notproton.test", $0.baseAddress, $0.count, 0, 0)
        }
        #expect(readCount == attribute.count)
        #expect(copiedAttribute == attribute)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bridge.path(percentEncoded: false)) == ["steam.exe"])
    }

    @Test("An atomic copy failure preserves the destination and removes staging files", arguments: [false, true])
    func atomicCopyFailurePreservesDestination(missing: Bool) throws {
        let work = try scratchDirectory("bridge")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appending(path: "source")
        let bridge = work.appending(path: "staged")
        let destination = bridge.appending(path: "steam.exe")
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: source.path(percentEncoded: false)
            )
        }
        if !missing {
            try Data("new".utf8).write(to: source)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0], ofItemAtPath: source.path(percentEncoded: false)
            )
        }

        #expect(throws: (any Error).self) {
            try atomicReplace(destination, from: source, step: BridgePayload.step)
        }
        #expect(try Data(contentsOf: destination) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: bridge.path(percentEncoded: false)) == ["steam.exe"])
    }

    @Test("An atomic rename failure preserves the destination and removes staging files")
    func atomicRenameFailurePreservesDestination() throws {
        let work = try scratchDirectory("bridge")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appending(path: "source")
        let bridge = work.appending(path: "staged")
        let destination = bridge.appending(path: "steam.exe")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let previous = destination.appending(path: "previous")
        try Data("old".utf8).write(to: previous)
        try Data("new".utf8).write(to: source)

        #expect(throws: StepFailure.self) {
            try atomicReplace(destination, from: source, step: BridgePayload.step)
        }
        #expect(try Data(contentsOf: previous) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: bridge.path(percentEncoded: false)) == ["steam.exe"])
    }

    @Test("The entry manifest covers every built path in payload.manifest")
    func coversPayloadManifest() throws {
        let manifest = try PayloadManifest.bundled()
        let builtPaths = Set(manifest.paths(origin: .built))
        let bridgePaths = Set(BridgePayload.entries.flatMap(\.bridgePaths))
        #expect(builtPaths == bridgePaths, "BridgePayload entries do not match payload.manifest built paths")
    }
}
