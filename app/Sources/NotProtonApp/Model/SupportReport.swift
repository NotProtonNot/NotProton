import Foundation

// Deliberate allowlist: never read log files, account config, license values,
// game names, arbitrary failure messages, environment variables or user paths.
enum SupportReport {
    static func make(snapshot: StatusSnapshot?, version: String = AppVersion.bundled,
                     osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString) -> String {
        var lines = ["NotProton support summary", "App: \(version)", "System: \(osVersion)"]
        #if arch(arm64)
        lines.append("Architecture: Apple Silicon")
        #else
        lines.append("Architecture: Intel")
        #endif
        guard let snapshot else { return (lines + ["Status: not checked"]).joined(separator: "\n") }
        let deployment = switch snapshot.steam {
        case .steamMissing: "missing"
        case .notInstalled: "not installed"
        case .installed: "installed"
        case .outdated: "update available"
        case .foreign: "other injection detected"
        }
        let content = switch snapshot.installContent {
        case .unchecked: "not checked"
        case .current: "current"
        case .update, .unrecorded: "update available"
        case .repair: "repair needed"
        case .newerInstalled: "newer build installed"
        case .unavailable: "check failed"
        }
        let builds = snapshot.installedRunners.map(\.id).filter { SupportedRunners.build(id: $0) != nil }
        lines += ["Integration: \(deployment)", "File check: \(content)",
                  "Steam running: \(snapshot.steamRunning)", "Client updates blocked: \(snapshot.updateBlocked)",
                  "Steam components complete: \(snapshot.payload.isSteamComplete)",
                  "All components complete: \(snapshot.payload.isComplete)",
                  "Missing component count: \(snapshot.payload.missing.count)",
                  "Detected CrossOver copies: \(snapshot.crossOver.count)",
                  "Supported CrossOver copies: \(snapshot.crossOver.filter(\.isUsable).count)",
                  "Installed profiles: \(builds.isEmpty ? "none" : builds.joined(separator: ", "))",
                  "Next setup step: \(SetupGuide(snapshot).next.title)",
                  "No account data, paths, license data or raw logs included."]
        return lines.joined(separator: "\n")
    }
}
