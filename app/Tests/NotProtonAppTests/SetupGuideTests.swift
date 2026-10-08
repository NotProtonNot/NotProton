import Foundation
import Testing
@testable import NotProtonApp

@Suite("Guided setup and support privacy")
struct SetupGuideTests {
    private func snapshot() -> StatusSnapshot {
        let build = SupportedRunners.all.first!
        let source = CrossOverInstall(bundle: URL(filePath: "/Users/private-user/Secret/CrossOver.app"),
                                       releaseVersion: build.releaseVersion, support: .supported(build))
        return StatusSnapshot(steam: .installed(version: "test"), steamRunning: false,
                              updateBlocked: false, crossOver: [source], runner: .ready(builds: [build.id]),
                              payload: PayloadState(expected: 0, present: 0, missing: [], overlayShimPresent: true,
                                                    iconmakerPresent: true, appinfoPresent: true, signatureDatabase: "secret/path",
                                                    legacyCompatPresent: 0, legacyCompatExpected: 0),
                              installedRunners: [build], installContent: .current)
    }

    @Test("File checks and runtime checks determine readiness; play is never inferred")
    func readiness() {
        var s = snapshot()
        #expect(SetupGuide(s).isReady)
        #expect(SetupGuide(s).next == .play)
        #expect(!SetupGuide(s).isComplete(.play))
        s.steamRunning = true
        #expect(!SetupGuide(s).isComplete(.play))
        s.runner = .none
        #expect(SetupGuide(s).next == .runtime)
        #expect(!SetupGuide(s).isReady)
        s.steam = .notInstalled
        #expect(SetupGuide(s).next == .integration)
        s.steam = .steamMissing
        #expect(SetupGuide(s).next == .requirements)
    }

    @Test("Unreadable, unchecked, newer and changed installations cannot look ready")
    func contentGuards() {
        for content in [DeploymentContent.Status.unchecked, .newerInstalled, .unavailable("private path"),
                        .update(["x"]), .repair(["x"]), .unrecorded(["x"])] {
            var s = snapshot()
            s.installContent = content
            #expect(!SetupGuide(s).integrationReady)
            #expect(!SetupGuide(s).isReady)
        }
        var s = snapshot()
        s.payload.iconmakerPresent = false
        #expect(!SetupGuide(s).isReady)
        s = snapshot()
        s.runner = .ready(builds: [])
        #expect(!SetupGuide(s).runtimeReady)
    }

    @Test("Existing runtime works without source app; inactive sources cannot start fresh setup")
    func sourceAndLicense() {
        var s = snapshot()
        s.crossOver = []
        #expect(SetupGuide(s).requirementsReady)
        s = snapshot()
        s.runner = .none
        let source = s.crossOver[0]
        s.crossOverLicense[source.id] = .init(licensed: false, detail: "private license detail", diagnostic: "private")
        #expect(!SetupGuide(s).requirementsReady)
        let build = SupportedRunners.all.last!
        let other = CrossOverInstall(bundle: URL(filePath: "/Applications/Other.app"), releaseVersion: build.releaseVersion,
                                      support: .supported(build))
        s.crossOver.append(other)
        #expect(SetupGuide(s).requirementsReady)
    }

    @Test("Allowlisted summary does not leak paths, account details or arbitrary errors")
    func summaryPrivacy() {
        var s = snapshot()
        s.steam = .foreign(insert: "/Users/private-user/private-injection")
        s.installContent = .unavailable("private-account private-error")
        s.payload.missing = [.init(origin: .built, path: "private-missing-path")]
        s.crossOverLicense[s.crossOver[0].id] = .init(licensed: false, detail: "private-license", diagnostic: "private-diagnostic")
        let report = SupportReport.make(snapshot: s, version: "test", osVersion: "test OS")
        #expect(!report.contains("private"))
        #expect(!report.contains("secret/path"))
        #expect(report.contains("other injection detected"))
        #expect(report.contains("Missing component count: 1"))
        #expect(SupportReport.make(snapshot: nil).contains("not checked"))
    }

    @Test("Help is searchable by symptom with all query words")
    func helpSearch() {
        #expect(HelpTopic.all.filter { $0.matches("black screen") }.map(\.id).contains("black-screen"))
        #expect(HelpTopic.all.filter { $0.matches("controller keyboard") }.map(\.id).contains("controller"))
        #expect(HelpTopic.all.allSatisfy { $0.matches(" \n ") })
        #expect(HelpTopic.all.filter { $0.matches("not-a-real-symptom") }.isEmpty)
    }

    @Test("English guidance resources contain nonempty help and step text")
    func localizationCoverage() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/NotProtonApp/Resources")
        func table(_ language: String) throws -> [String: String] {
            let data = try Data(contentsOf: sources.appending(path: "\(language).lproj/Guidance.strings"))
            return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let en = try table("en")
        #expect(en.values.allSatisfy { !$0.isEmpty })
        for step in SetupGuide.Step.allCases { #expect(en[step.title] != nil) }
        for topic in HelpTopic.all { #expect(en[topic.title] != nil); #expect(en[topic.body] != nil) }
    }
}
