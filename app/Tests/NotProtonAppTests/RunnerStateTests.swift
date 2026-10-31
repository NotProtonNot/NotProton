import Foundation
import Testing

@testable import NotProtonApp

@Suite("Runner state detection")
struct RunnerStateTests {

    struct Fixture: ~Copyable {
        let runners: URL

        init() throws {
            runners = FileManager.default.temporaryDirectory
                .appending(path: "np-runners-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: runners, withIntermediateDirectories: true)
        }

        func makeClone(build: String, withWine: Bool = true) throws {
            let root = runners.appending(path: "crossover-\(build)/CrossOver")
            let leaf = withWine ? root.appending(path: "lib/wine") : root
            try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: runners) }
    }

    @Test("No clone means nothing is set up")
    func reportsNone() throws {
        let fixture = try Fixture()
        #expect(RunnerStore.state(runners: fixture.runners) == .none)
    }

    @Test("Every patched clone is reported ready")
    func reportsReadyClones() throws {
        let fixture = try Fixture()
        let ids = SupportedRunners.all.prefix(2).map(\.id)
        for id in ids { try fixture.makeClone(build: id) }

        #expect(RunnerStore.state(runners: fixture.runners, verify: { _, _ in [] })
            == .ready(builds: ids.sorted()))
    }

    // The launch path only reads the runner, so a clone the app never finished patching
    // has to be caught here rather than by a game failing its ownership check.
    @Test("A clone missing a file the app installs is reported as unpatched")
    func reportsUnpatchedClone() throws {
        let fixture = try Fixture()
        let version = SupportedRunners.all[0].id
        try fixture.makeClone(build: version)

        #expect(RunnerStore.state(runners: fixture.runners, verify: { _, _ in ["ntdll is stock"] })
            == .unpatched(builds: [version], problems: ["\(version): ntdll is stock"]))
    }

    @Test("Every unpatched clone is reported, not just the first")
    func reportsEveryUnpatchedClone() throws {
        let fixture = try Fixture()
        let ids = SupportedRunners.all.prefix(3).map(\.id).sorted()
        for id in ids { try fixture.makeClone(build: id) }
        let stock = Set(ids.dropFirst())

        #expect(RunnerStore.state(runners: fixture.runners, verify: { build, _ in
            stock.contains(build.id) ? ["ntdll is stock"] : []
        }) == .unpatched(builds: Array(ids.dropFirst()), problems: ids.dropFirst().map { "\($0): ntdll is stock" }))
    }

    @Test("A clone outside the allow list is orphaned, not ready")
    func reportsUnsupportedClone() throws {
        let fixture = try Fixture()
        try fixture.makeClone(build: "1.0.0.1")

        #expect(RunnerStore.state(runners: fixture.runners) == .none)
        #expect(RunnerStore.orphanedClones(in: fixture.runners) == ["1.0.0.1"])
    }

    @Test("A supported clone with no lib/wine is damaged, not ready")
    func detectsIncompleteTree() throws {
        let fixture = try Fixture()
        let version = SupportedRunners.all[0].id
        try fixture.makeClone(build: version, withWine: false)

        #expect(RunnerStore.state(runners: fixture.runners) == .none)
        #expect(RunnerStore.damagedClones(in: fixture.runners) == [version])
    }

    @Test("Clones are listed by version")
    func listsClones() throws {
        let fixture = try Fixture()
        try fixture.makeClone(build: "27.0.0.40921")
        try fixture.makeClone(build: "26.0.0.1")

        #expect(RunnerStore.clonedBuilds(in: fixture.runners) == ["26.0.0.1", "27.0.0.40921"])
    }

    @Test("Assembled variant runners are not listed as CrossOver builds or orphans")
    func ignoresVariantClones() throws {
        let fixture = try Fixture()
        let base = SupportedRunners.all[0].id
        try fixture.makeClone(build: base)
        try fixture.makeClone(build: "\(base)+dxmt-mine")
        try FileManager.default.createDirectory(
            at: fixture.runners.appending(path: ".crossover-\(base)+dxmt-mine.new"),
            withIntermediateDirectories: true
        )

        #expect(RunnerStore.clonedBuilds(in: fixture.runners) == [base])
        #expect(RunnerStore.orphanedClones(in: fixture.runners).isEmpty)
    }
}
