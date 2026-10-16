import Foundation
import Testing

@testable import NotProtonApp

@Suite("Update block")
struct UpdateBlockTests {

    @Test("Writing the block writes the required copy and the best-effort one")
    func writesBothCopies() throws {
        let work = try scratchDirectory("cfg")
        defer { try? FileManager.default.removeItem(at: work) }

        let required = work.appending(path: "Steam/steam.cfg")
        let inner = work.appending(path: "Steam/Steam.AppBundle/Steam/Contents/MacOS/steam.cfg")
        try FileManager.default.createDirectory(
            at: inner.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let written = try UpdateBlock.write(to: [required, inner])

        #expect(written.count == 2)
        for url in [required, inner] {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text == "BootStrapperInhibitUpdateOnLaunch=enable\n")
        }
    }

    // The client owns that directory. Creating it would leave a config file somewhere the
    // client is not installed, which is worse than not writing the best-effort copy.
    @Test("The best-effort copy is skipped when the client directory is not there")
    func skipsBestEffortWhenDirectoryAbsent() throws {
        let work = try scratchDirectory("cfg")
        defer { try? FileManager.default.removeItem(at: work) }

        let required = work.appending(path: "Steam/steam.cfg")
        let inner = work.appending(path: "no-client-here/steam.cfg")

        let written = try UpdateBlock.write(to: [required, inner])

        #expect(written == [required.path(percentEncoded: false)])
        #expect(!FileManager.default.fileExists(atPath: inner.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(
            atPath: inner.deletingLastPathComponent().path(percentEncoded: false)
        ), "a directory was created where the client is not installed")
    }

    @Test("Presence is decided by the required copy only")
    func presenceFollowsRequiredCopy() throws {
        let work = try scratchDirectory("cfg")
        defer { try? FileManager.default.removeItem(at: work) }

        let required = work.appending(path: "steam.cfg")
        let inner = work.appending(path: "inner/steam.cfg")
        #expect(UpdateBlock.isPresent(at: [required, inner]) == false)

        try UpdateBlock.write(to: [required])
        #expect(UpdateBlock.isPresent(at: [required, inner]))

        // A file that exists but says something else is not the block.
        try Data("SomethingElse=1\n".utf8).write(to: required)
        #expect(UpdateBlock.isPresent(at: [required, inner]) == false)
    }

    @Test("Removing the block takes every copy it finds and ignores the rest")
    func removesEveryCopy() throws {
        let work = try scratchDirectory("cfg")
        defer { try? FileManager.default.removeItem(at: work) }

        let present = work.appending(path: "steam.cfg")
        let absent = work.appending(path: "inner/steam.cfg")
        try UpdateBlock.write(to: [present])

        let removed = try UpdateBlock.remove(from: [present, absent])

        #expect(removed == [present.path(percentEncoded: false)])
        #expect(!FileManager.default.fileExists(atPath: present.path(percentEncoded: false)))
        #expect(try UpdateBlock.remove(from: [present, absent]).isEmpty)
    }

    @Test("Writing over an existing block leaves one block, not two")
    func writeIsIdempotent() throws {
        let work = try scratchDirectory("cfg")
        defer { try? FileManager.default.removeItem(at: work) }

        let required = work.appending(path: "steam.cfg")
        try UpdateBlock.write(to: [required])
        try UpdateBlock.write(to: [required])

        let text = try String(contentsOf: required, encoding: .utf8)
        #expect(text == "BootStrapperInhibitUpdateOnLaunch=enable\n")
    }

    // The block being present used to mean the key appearing anywhere in the file, so a
    // config that turns it off read as one that turns it on.
    @Test("The key set to anything but enable is not a block")
    func disabledKeyIsNotABlock() throws {
        let work = try scratchDirectory("cfg")
        defer { try? FileManager.default.removeItem(at: work) }
        let cfg = work.appending(path: "steam.cfg")

        try Data("BootStrapperInhibitUpdateOnLaunch=disable\n".utf8).write(to: cfg)
        #expect(UpdateBlock.isPresent(at: [cfg]) == false)

        // A later line is the one that takes effect.
        try Data("BootStrapperInhibitUpdateOnLaunch=enable\nBootStrapperInhibitUpdateOnLaunch=disable\n".utf8)
            .write(to: cfg)
        #expect(UpdateBlock.isPresent(at: [cfg]) == false)

        try Data("BootStrapperInhibitUpdateOnLaunch=enable\n".utf8).write(to: cfg)
        #expect(UpdateBlock.isPresent(at: [cfg]))
    }

    // steam.cfg is the client's file. Writing the block replaced it outright and removing the
    // block deleted it, either of which threw away settings nothing to do with NotProton.
    @Test("Blocking and unblocking leave the rest of the file alone")
    func otherSettingsSurvive() throws {
        let work = try scratchDirectory("cfg")
        defer { try? FileManager.default.removeItem(at: work) }
        let cfg = work.appending(path: "steam.cfg")
        try Data("BootStrapperInhibitAll=enable\nSomethingElse=1\n".utf8).write(to: cfg)

        try UpdateBlock.write(to: [cfg])
        var text = try String(contentsOf: cfg, encoding: .utf8)
        #expect(text == "BootStrapperInhibitAll=enable\nSomethingElse=1\nBootStrapperInhibitUpdateOnLaunch=enable\n")
        #expect(UpdateBlock.isPresent(at: [cfg]))

        try UpdateBlock.remove(from: [cfg])
        text = try String(contentsOf: cfg, encoding: .utf8)
        #expect(text == "BootStrapperInhibitAll=enable\nSomethingElse=1\n")
        #expect(FileManager.default.fileExists(atPath: cfg.path(percentEncoded: false)))
    }

    // Turning the block on where it is turned off changes that line rather than adding a
    // second one under it, since the last line is the one that counts.
    @Test("Blocking replaces a line that turned the block off")
    func blockingReplacesADisabledLine() throws {
        let work = try scratchDirectory("cfg")
        defer { try? FileManager.default.removeItem(at: work) }
        let cfg = work.appending(path: "steam.cfg")
        try Data("BootStrapperInhibitUpdateOnLaunch=disable\nOther=2\n".utf8).write(to: cfg)

        try UpdateBlock.write(to: [cfg])

        #expect(try String(contentsOf: cfg, encoding: .utf8)
            == "BootStrapperInhibitUpdateOnLaunch=enable\nOther=2\n")
    }

    @Test("A file holding nothing but the block is removed with it")
    func aFileOfOnlyTheBlockGoes() throws {
        let work = try scratchDirectory("cfg")
        defer { try? FileManager.default.removeItem(at: work) }
        let cfg = work.appending(path: "steam.cfg")

        try UpdateBlock.write(to: [cfg])
        let removed = try UpdateBlock.remove(from: [cfg])

        #expect(removed == [cfg.path(percentEncoded: false)])
        #expect(!FileManager.default.fileExists(atPath: cfg.path(percentEncoded: false)))
    }

    // A file the block was never in is not a file this changed, so repair does not report it.
    @Test("A file without the block is left as it is")
    func aFileWithoutTheBlockIsUntouched() throws {
        let work = try scratchDirectory("cfg")
        defer { try? FileManager.default.removeItem(at: work) }
        let cfg = work.appending(path: "steam.cfg")
        try Data("Other=2\n".utf8).write(to: cfg)

        #expect(try UpdateBlock.remove(from: [cfg]).isEmpty)
        #expect(try String(contentsOf: cfg, encoding: .utf8) == "Other=2\n")
    }

    // Read as UTF-8, this file used to come back empty, so removing the block deleted it.
    @Test("Removing the block keeps the bytes of a file that is not UTF-8")
    func removalKeepsAFileThatIsNotUTF8() throws {
        let work = try scratchDirectory("cfg")
        defer { try? FileManager.default.removeItem(at: work) }
        let cfg = work.appending(path: "steam.cfg")
        let other = Data("Name=caf".utf8) + Data([0xE9, 0x0A])
        try (Data("BootStrapperInhibitUpdateOnLaunch=enable\n".utf8) + other).write(to: cfg)

        #expect(try UpdateBlock.remove(from: [cfg]) == [cfg.path(percentEncoded: false)])
        #expect(try Data(contentsOf: cfg) == other)
    }

    @Test("Writing the block keeps the bytes of a file that is not UTF-8")
    func writingKeepsAFileThatIsNotUTF8() throws {
        let work = try scratchDirectory("cfg")
        defer { try? FileManager.default.removeItem(at: work) }
        let cfg = work.appending(path: "steam.cfg")
        let other = Data("Name=caf".utf8) + Data([0xE9, 0x0A])
        try other.write(to: cfg)

        try UpdateBlock.write(to: [cfg])

        let block = Data("BootStrapperInhibitUpdateOnLaunch=enable\n".utf8)
        #expect(try Data(contentsOf: cfg) == other + block)
        #expect(UpdateBlock.isPresent(at: [cfg]))
    }

    // "\r\n" is one Character, so this file used to read as one line and removal deleted it.
    @Test("Removing the block from a CRLF file keeps the other lines")
    func removalKeepsTheRestOfACRLFFile() throws {
        let work = try scratchDirectory("cfg")
        defer { try? FileManager.default.removeItem(at: work) }
        let cfg = work.appending(path: "steam.cfg")
        try Data("BootStrapperInhibitUpdateOnLaunch=enable\r\nOther=2\r\n".utf8).write(to: cfg)

        #expect(UpdateBlock.isPresent(at: [cfg]))
        #expect(try UpdateBlock.remove(from: [cfg]) == [cfg.path(percentEncoded: false)])
        #expect(try String(contentsOf: cfg, encoding: .utf8) == "Other=2\r\n")
    }

    @Test("Writing the block into a CRLF file keeps its line endings")
    func writingKeepsCRLFLineEndings() throws {
        let work = try scratchDirectory("cfg")
        defer { try? FileManager.default.removeItem(at: work) }
        let cfg = work.appending(path: "steam.cfg")
        try Data("Other=2\r\n".utf8).write(to: cfg)

        try UpdateBlock.write(to: [cfg])

        let text = try String(contentsOf: cfg, encoding: .utf8)
        #expect(text == "Other=2\r\nBootStrapperInhibitUpdateOnLaunch=enable\r\n")
        #expect(UpdateBlock.isPresent(at: [cfg]))
    }

    @Test("A required copy that cannot be read is refused and left as it is")
    func anUnreadableRequiredCopyIsRefused() throws {
        let work = try scratchDirectory("cfg")
        defer { try? FileManager.default.removeItem(at: work) }
        let cfg = work.appending(path: "steam.cfg")
        let text = "BootStrapperInhibitUpdateOnLaunch=enable\nOther=2\n"
        try unreadable(cfg, holding: text)
        defer { try? readable(cfg) }

        #expect(throws: WriteRefused.self) { try UpdateBlock.remove(from: [cfg]) }
        #expect(throws: WriteRefused.self) { try UpdateBlock.write(to: [cfg]) }

        try readable(cfg)
        #expect(try String(contentsOf: cfg, encoding: .utf8) == text)
    }

    @Test("A best-effort copy that cannot be read is skipped and left as it is")
    func anUnreadableBestEffortCopyIsSkipped() throws {
        let work = try scratchDirectory("cfg")
        defer { try? FileManager.default.removeItem(at: work) }
        let required = work.appending(path: "steam.cfg")
        let inner = work.appending(path: "inner.cfg")
        let text = "Other=2\n"
        try unreadable(inner, holding: text)
        defer { try? readable(inner) }

        #expect(try UpdateBlock.write(to: [required, inner]) == [required.path(percentEncoded: false)])

        try readable(inner)
        #expect(try String(contentsOf: inner, encoding: .utf8) == text)
    }

    private func unreadable(_ url: URL, holding text: String) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    private func readable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    @Test("The shipped paths are the two the client actually reads")
    func shippedPathsAreTheClientPaths() {
        let paths = UpdateBlock.paths.map { $0.path(percentEncoded: false) }

        #expect(paths.count == 2)
        #expect(paths[0].hasSuffix("/Application Support/Steam/steam.cfg"))
        // Next to the client executable, not beside its bundle: that is where the
        // bootstrapper looks, and it was checked against the live install.
        #expect(paths[1].hasSuffix("/Steam.AppBundle/Steam/Contents/MacOS/steam.cfg"))
    }
}
