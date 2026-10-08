import SwiftUI
import AppKit

struct SetupGuideView: View {
    @Environment(SystemStatus.self) private var status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let initialSnapshot: StatusSnapshot
    @State private var step: SetupGuide.Step = .requirements
    @State private var sourceID: String?
    @State private var detailsExpanded = false
    @State private var writeAccess = SteamWriteAccess()

    private var snapshot: StatusSnapshot { status.snapshot ?? initialSnapshot }
    private var guide: SetupGuide { SetupGuide(snapshot) }
    private var source: CrossOverInstall? {
        if let sourceID { return status.usableCrossOvers.first { $0.id == sourceID } }
        return status.setupSource
    }
    private var sourceReady: Bool {
        if guide.runtimeReady { return true }
        guard let source else { return false }
        return snapshot.crossOverLicense[source.id]?.licensed != false
    }
    private var title: String {
        switch step {
        case .requirements: "Your Steam. More games."
        case .permissions: "Let NotProton set up Steam"
        case .integration: guide.integrationReady ? "Steam is ready" : "Bring them together"
        case .runtime: guide.runtimeReady ? "CrossOver is ready" : "Set up CrossOver"
        case .play: "You're ready to play"
        }
    }
    private var subtitle: String {
        switch step {
        case .requirements: "Windows games in the macOS Steam app, powered by CrossOver."
        case .permissions: "macOS may ask you to allow changes to the Steam app."
        case .integration: guide.integrationReady ? "Your integration has been checked. Continue to CrossOver."
            : "Quit your games. We'll install the integration and check its files."
        case .runtime: guide.runtimeReady ? "The runtime copy and components passed their checks."
            : "NotProton uses a separate copy of your activated CrossOver app."
        case .play: "Open a Windows game's Properties → Compatibility in Steam."
        }
    }
    private var canContinue: Bool {
        guard status.isIdle else { return false }
        switch step {
        case .requirements: return guide.requirementsReady && sourceReady
        case .permissions: return writeAccess.isReady
        case .integration: return guide.integrationReady
        case .runtime: return guide.runtimeReady
        case .play: return guide.isReady
        }
    }
    private var primaryLabel: String {
        if step == .integration, !guide.integrationReady { return "Install integration" }
        if step == .runtime, !guide.runtimeReady {
            if !snapshot.payload.missing(origin: .valve).isEmpty { return "Download missing components" }
            return "Set up CrossOver"
        }
        return step == .play ? "Open Steam" : "Continue"
    }
    private var primaryEnabled: Bool {
        if step == .integration, !guide.integrationReady {
            return status.canInstall && guide.requirementsReady && snapshot.steam != .steamMissing
        }
        if step == .runtime, !guide.runtimeReady {
            return status.canInstall && guide.integrationReady
                && (source != nil || !snapshot.payload.missing(origin: .valve).isEmpty)
        }
        return canContinue
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("NotProton").font(.headline).foregroundStyle(.secondary)
                Spacer()
                Text("\(step.rawValue + 1) / \(SetupGuide.Step.allCases.count)")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }.padding(.horizontal, 28).padding(.top, 22)

            ScrollView {
                VStack(spacing: 20) {
                    SetupArtwork(step: step, steam: SupportPaths.Steam.app,
                                 crossOver: source?.bundle)
                        .frame(height: 126)
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text(GuideCopy.text(title))
                            .font(.system(size: 28, weight: .bold))
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(GuideCopy.text(subtitle))
                            .font(.body).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 470)
                    pageContent
                    if let activity = status.activity {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(activity).font(.callout)
                        }.foregroundStyle(.secondary)
                    }
                    if let failure = status.failure {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(GuideCopy.text("This step needs attention"), systemImage: "exclamationmark.triangle.fill")
                                .font(.headline).foregroundStyle(Color.orange)
                            Text(failure).font(.callout).textSelection(.enabled)
                            HStack {
                                if let pane = status.failureRemedy?.settingsPane {
                                    Button(GuideCopy.text("Open System Settings")) { Remedy.openSettings(pane) }
                                        .buttonStyle(.borderedProminent)
                                }
                                Button(GuideCopy.text("Check again")) { Task { await status.refresh() } }
                                    .disabled(!status.isIdle)
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    DisclosureGroup(GuideCopy.text("Details"), isExpanded: $detailsExpanded) {
                        details.font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                    .disclosureGroupStyle(WholeRowDisclosureStyle())
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: 470)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 34).padding(.top, 16).padding(.bottom, 18)
                .id(step)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 8)))
            }

            VStack(spacing: 14) {
                HStack(spacing: 7) {
                    ForEach(SetupGuide.Step.allCases) { item in
                        Capsule().fill(item == step ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: item == step ? 22 : 6, height: 6)
                    }
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel(GuideCopy.text(step.title))
                    .accessibilityValue("\(step.rawValue + 1) / \(SetupGuide.Step.allCases.count)")
                Button(action: primaryAction) {
                    Text(GuideCopy.text(primaryLabel)).frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(width: 250)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!primaryEnabled)
                HStack {
                    Button(GuideCopy.text("Continue later")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(status.isBusy)
                    Spacer()
                    if step != .requirements {
                        Button(GuideCopy.text("Back")) { move(-1) }.disabled(!status.isIdle)
                    }
                    if step == .play {
                        Button(GuideCopy.text("Done")) { dismiss() }.disabled(status.isBusy)
                    }
                }.font(.callout).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 22)
        }
        .frame(width: 650, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(status.isBusy)
        .modifier(StatusConfirmations())
        .task(id: step) {
            if step == .permissions { writeAccess.check() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, step == .permissions { writeAccess.check() }
        }
        .onChange(of: status.usableCrossOvers.map(\.id)) { _, ids in
            if let sourceID, !ids.contains(sourceID) { self.sourceID = nil }
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch step {
        case .requirements:
            VStack(spacing: 10) {
                readinessBox("macOS Steam", detail: snapshot.steam == .steamMissing ? "Install and sign in once" : "Found on your Mac",
                             ready: snapshot.steam != .steamMissing, icon: SupportPaths.Steam.app) {
                    if snapshot.steam == .steamMissing {
                        Link(GuideCopy.text("Get Steam"), destination: URL(string: "https://store.steampowered.com/about/")!)
                    }
                }
                readinessBox("CrossOver", detail: sourceReady ? "Supported runtime available" : "Choose a supported, activated build",
                             ready: sourceReady, icon: source?.bundle) {
                    if let source, snapshot.crossOverLicense[source.id]?.licensed == false {
                        Button(GuideCopy.text("Activate…")) {
                            NSWorkspace.shared.openApplication(at: source.bundle, configuration: .init())
                        }.disabled(!status.isIdle)
                    }
                    Button(GuideCopy.text("Choose…")) { Task { await status.addCrossOver() } }.disabled(!status.isIdle)
                }
                if status.usableCrossOvers.count > 1 {
                    Picker(GuideCopy.text("CrossOver source"), selection: Binding(
                        get: { source?.id ?? "" }, set: { sourceID = $0 }
                    )) {
                        ForEach(status.usableCrossOvers) { install in
                            Text("\(install.name) · \(install.releaseVersion ?? "")").tag(install.id)
                        }
                    }.disabled(!status.isIdle)
                }
            }.frame(maxWidth: 470)
        case .permissions:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: writeAccess.isReady ? "checkmark.circle.fill" : "lock.shield.fill")
                        .font(.title2).foregroundStyle(writeAccess.isReady ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(writeAccess.isReady ? "Steam access is ready" : "App Management").font(.headline)
                        Text(writeAccess.isReady ? "You can continue." : "Allow NotProton to update Steam.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if !writeAccess.isReady {
                    if let pane = Remedy.appManagement.settingsPane {
                        Button("Open System Settings") {
                            writeAccess.check()
                            Remedy.openSettings(pane)
                        }.buttonStyle(.bordered).tint(.accentColor).disabled(!status.isIdle)
                    }
                    Button("Check again") { writeAccess.check() }.disabled(!status.isIdle)
                    if case .blocked(let reason) = writeAccess.state {
                        Text(reason).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.padding(16).frame(maxWidth: 470, alignment: .leading)
                .background((writeAccess.isReady ? Color.green : Color.orange).opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke((writeAccess.isReady ? Color.green : Color.orange).opacity(0.2)))
            if !writeAccess.isReady {
                Text("Not listed? Click + and add NotProton from Applications. Return here after enabling it.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        case .integration:
            readinessBox("Steam integration", detail: guide.integrationReady ? "Checked and ready" : "Games and saves are kept",
                         ready: guide.integrationReady, icon: nil) { EmptyView() }.frame(maxWidth: 470)
            if snapshot.installContent.blocksInstallation {
                Text(GuideCopy.text(guide.integrationDetail)).font(.callout).foregroundStyle(.secondary)
            }
        case .runtime:
            readinessBox("CrossOver", detail: guide.runtimeReady ? "Checked and ready" : "Your original app stays the source",
                         ready: guide.runtimeReady, icon: source?.bundle) { EmptyView() }.frame(maxWidth: 470)
        case .play:
            VStack(alignment: .leading, spacing: 12) {
                instruction(1, "Enable Force the use of a specific Steam Play compatibility tool.")
                instruction(2, "Choose CrossOver in the dropdown, then start the game.")
                instruction(3, "Check picture, controls and saves.")
            }.padding(16).frame(maxWidth: 470, alignment: .leading)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            Text(GuideCopy.text("The first game launch may take longer."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func readinessBox<Actions: View>(_ name: String, detail: String, ready: Bool, icon: URL?,
                                             @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 12) {
            if let icon { InstalledAppIcon(url: icon, fallback: "app.fill").frame(width: 36, height: 36) }
            else { Image(systemName: "puzzlepiece.extension.fill").font(.title2).foregroundStyle(Color.accentColor).frame(width: 36) }
            VStack(alignment: .leading, spacing: 3) {
                Text(GuideCopy.text(name)).font(.headline)
                Text(GuideCopy.text(detail)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            actions()
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? Color.green : Color.secondary)
                .accessibilityLabel(GuideCopy.text(ready ? "Ready" : "Needs setup"))
        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.12)))
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24).background(Color.accentColor.opacity(0.1), in: Circle())
            Text(GuideCopy.text(text)).padding(.top, 2)
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch step {
            case .requirements:
                Text(GuideCopy.text("NotProton is free; CrossOver needs activation. This app requires macOS 26 or later. Exact supported builds are listed in Status."))
                if let source {
                    Text(source.bundle.path(percentEncoded: false)).textSelection(.enabled)
                    if case .supported(let build) = source.support { Text("\(build.displayVersion) · build \(build.bundleVersion)") }
                }
                Button(GuideCopy.text("Check again")) { Task { await status.refresh() } }.disabled(!status.isIdle)
            case .permissions:
                Text("Open System Settings → Privacy & Security → App Management. If NotProton is missing, click +, select /Applications/NotProton.app and click Open. Enable NotProton and return to this app. If macOS asks you to restart NotProton, do so and reopen setup from Settings.")
                Text("The check creates and removes a unique temporary file in Steam's app bundle. It does not install or replace anything. The green check means Steam write access was verified, not that a particular macOS permission switch was read. macOS may allow access without adding a new entry.")
                Text(GuideCopy.text("Steam may later request Input Monitoring for controllers. Full Disk Access is not a general setup requirement."))
            case .integration:
                Text(GuideCopy.text(guide.integrationDetail))
                Text(GuideCopy.text("Installation may close Steam and also prepare an activated CrossOver runtime. A failed step stays open so you can correct it and retry."))
            case .runtime:
                Text(GuideCopy.text("Keep Rosetta as your starting point. Graphics options depend on the runtime; FEX is experimental."))
                Text(GuideCopy.text("Use Status to inspect or repair individual runtime copies and components."))
            case .play:
                Text(GuideCopy.text("Restart Steam if it was open during setup. A ready installation does not guarantee every game works. Find game-specific guidance in Help and back up your game environment before experimenting."))
            }
        }
    }

    private func primaryAction() {
        guard primaryEnabled else { return }
        if step == .integration, !guide.integrationReady {
            Task { await status.requestInstall(from: source) }; return
        }
        if step == .runtime, !guide.runtimeReady {
            if !snapshot.payload.missing(origin: .valve).isEmpty {
                Task { await status.fetchValveBinaries() }
            } else { Task { await status.requestCompatibilityTool(from: source) } }
            return
        }
        if step == .play {
            NSWorkspace.shared.openApplication(at: SupportPaths.Steam.app, configuration: .init()) { _, error in
                Task { @MainActor in
                    if let error { status.setFailure(error.localizedDescription) }
                    else { dismiss() }
                }
            }
            return
        }
        if step == .permissions {
            writeAccess.check()
            guard writeAccess.isReady else { return }
        }
        move(1)
    }

    private func move(_ delta: Int) {
        guard let destination = SetupGuide.Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: GuideMotion.duration)) {
            detailsExpanded = false
            step = destination
        }
    }
}

// Use the user's installed app icons. No third-party logo files are redistributed.
struct InstalledAppIcon: View {
    let url: URL
    let fallback: String
    var body: some View {
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: fallback).resizable().scaledToFit().foregroundStyle(Color.accentColor)
        }
    }
}

private struct SetupArtwork: View {
    let step: SetupGuide.Step
    let steam: URL
    let crossOver: URL?
    @Environment(\.colorScheme) private var colorScheme

    private var hue: Color { step == .permissions ? .orange : step == .play ? .green : .accentColor }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30)
                .fill(LinearGradient(colors: [hue.opacity(0.18), Color.purple.opacity(0.08), .clear],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 360, height: 126)
            HStack(spacing: 20) {
                iconTile(steam, fallback: "desktopcomputer")
                Image(systemName: step == .permissions ? "lock.shield.fill" : step == .play ? "checkmark.circle.fill" : "arrow.left.arrow.right")
                    .font(.system(size: 28, weight: .medium)).foregroundStyle(hue)
                if step == .play {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 56)).foregroundStyle(hue)
                        .frame(width: 80, height: 80)
                } else if let crossOver {
                    iconTile(crossOver, fallback: "app.fill")
                } else {
                    Image(systemName: "app.fill").font(.system(size: 56)).foregroundStyle(Color.purple)
                        .frame(width: 80, height: 80)
                }
            }
        }
    }
    private func iconTile(_ url: URL, fallback: String) -> some View {
        InstalledAppIcon(url: url, fallback: fallback)
            .frame(width: 72, height: 72)
            .padding(9)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.85), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.6)))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}
