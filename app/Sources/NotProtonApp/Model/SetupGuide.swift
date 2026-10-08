import Foundation

// Completion comes from inspected files, not from a wizard's Next button.
struct SetupGuide: Sendable {
    enum Step: Int, CaseIterable, Identifiable {
        case requirements, permissions, integration, runtime, play
        var id: Self { self }
        var title: String {
            switch self {
            case .requirements: "Check requirements"
            case .permissions: "Prepare macOS permissions"
            case .integration: "Install Steam integration"
            case .runtime: "Set up a runtime"
            case .play: "Start your first game"
            }
        }
    }

    let requirementsReady: Bool
    let runtimeAvailable: Bool
    let integrationReady: Bool
    let runtimeReady: Bool
    let requirementsDetail: String
    let integrationDetail: String

    var isReady: Bool { requirementsReady && integrationReady && runtimeReady }
    var next: Step {
        if !requirementsReady { return .requirements }
        if !integrationReady { return .integration }
        if !runtimeReady { return .runtime }
        return .play
    }

    func isComplete(_ step: Step) -> Bool {
        switch step {
        case .requirements: requirementsReady
        case .permissions: false
        case .integration: integrationReady
        case .runtime: runtimeReady
        // A running process alone does not prove that a game works.
        case .play: false
        }
    }

    init(_ snapshot: StatusSnapshot) {
        let hasRuntime: Bool
        if case .ready(let builds) = snapshot.runner { hasRuntime = !builds.isEmpty }
        else { hasRuntime = false }
        let hasSource = snapshot.crossOver.contains { install in
            install.isUsable && snapshot.crossOverLicense[install.id]?.licensed != false
        }
        let hasSteam = snapshot.steam != .steamMissing
        runtimeAvailable = hasRuntime || hasSource
        requirementsReady = hasSteam && (hasRuntime || hasSource)
        requirementsDetail = !hasSteam ? "Install the macOS Steam app in Applications and sign in once."
            : !(hasRuntime || hasSource) ? "Choose a supported CrossOver build and activate it in CrossOver."
            : "Steam and a supported runtime are available."

        let installed: Bool
        if case .installed = snapshot.steam { installed = true } else { installed = false }
        integrationReady = installed && snapshot.payload.isSteamComplete && snapshot.installContent == .current
        integrationDetail = switch snapshot.installContent {
        case .newerInstalled: "A newer build is installed. Open the app that installed it."
        case .unavailable: "Installed files could not be checked. See the status details before continuing."
        case .update, .unrecorded: "This app includes updated integration files. Install them when no game is running."
        case .repair: "Some installed files need repair. See the status details below."
        case .unchecked: "Refresh to check the installed files."
        case .current: integrationReady ? "Steam integration is installed and its files have been checked."
            : "Install the integration. Steam may close; quit your games first."
        }
        runtimeReady = hasRuntime && snapshot.payload.isComplete
    }
}

enum GuideCopy {
    static func text(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: key, table: "Guidance")
    }
}

enum GuideMotion {
    // Native controls own press/focus feedback. Only the changing content moves.
    static let duration = 0.22
}
