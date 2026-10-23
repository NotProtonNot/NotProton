// 'Status' view, see SystemStatus for actual logic

import AppKit
import SwiftUI

enum StatusTone: Sendable {
    case ok, info, warning, bad, neutral

    var symbol: String {
        switch self {
        case .ok: "circle.fill"
        case .info: "circle"
        case .warning: "circle.fill"
        case .bad: "circle.fill"
        case .neutral: "circle"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .info: .secondary
        case .warning: .orange
        case .bad: .red
        case .neutral: .secondary
        }
    }
}

struct StatusAction {
    let label: String
    var isProminent = false
    var role: ButtonRole?
    var help: String?
    var isEnabled = true
    var startsGroup = false
    let perform: () -> Void
}

enum StatusMetrics {
    static let symbolWidth: CGFloat = 10
    static let symbolSpacing: CGFloat = 8
    static var textInset: CGFloat { symbolWidth + symbolSpacing }
}

struct StatusRow: View {

    let title: String
    var value: String?

    var tone: StatusTone?
    var detail: String?
    var trailing: String?
    var secondaryAction: StatusAction?
    var action: StatusAction?
    var menu: [StatusAction] = []
    var toggle: Binding<Bool>?

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: StatusMetrics.symbolSpacing) {
                if let tone {
                    Image(systemName: tone.symbol)
                        .font(.system(size: 8))
                        .foregroundStyle(tone.color)
                        .frame(width: StatusMetrics.symbolWidth)
                        .accessibilityHidden(true)
                } else {
                    Color.clear.frame(width: StatusMetrics.symbolWidth, height: 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let value {
                        Text(value)
                            .foregroundStyle(.secondary)
                    }
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            if secondaryAction != nil || action != nil || !menu.isEmpty || toggle != nil || trailing != nil {
                Spacer(minLength: 12)
            }
            if let trailing {
                Text(trailing)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .padding(.trailing, action == nil && menu.isEmpty ? 0 : 8)
            }
            if let toggle {
                Toggle(title, isOn: toggle)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if let secondaryAction {
                button(secondaryAction)
                    .disabled(!secondaryAction.isEnabled)
                    .help(secondaryAction.help ?? "")
                    .accessibilityLabel("\(secondaryAction.label), \(title)")
                    .padding(.trailing, 8)
            }
            if let action {
                button(action)
                    .disabled(!action.isEnabled)
                    .help(action.help ?? "")
                    .accessibilityLabel("\(action.label), \(title)")
            }
            if !menu.isEmpty {
                Menu {
                    menuItems(menu, hidingUnavailable: false)
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions, \(title)")
                .padding(.leading, action == nil ? 0 : 8)
            }
        }
        .accessibilityElement(children: .combine)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            menuItems([action, secondaryAction].compactMap { $0 } + menu, hidingUnavailable: true)
        }
    }

    @ViewBuilder
    private func menuItems(_ items: [StatusAction], hidingUnavailable: Bool) -> some View {
        let shown = hidingUnavailable ? items.filter(\.isEnabled) : items
        ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
            if item.startsGroup && index > 0 { Divider() }
            Button(item.label, role: item.role, action: item.perform)
                .disabled(!item.isEnabled)
        }
    }

    @ViewBuilder
    private func button(_ action: StatusAction) -> some View {
        if action.isProminent {
            Button(action.label, role: action.role, action: action.perform)
                .buttonStyle(.borderedProminent)
        } else {
            Button(action.label, role: action.role, action: action.perform)
                .buttonStyle(.bordered)
        }
    }
}

struct StatusView: View {
    @Environment(SystemStatus.self) private var status
    @State private var libraryMovePresented = false

    private static let updateBlockPrompt =
        String(localized: "Steam client updates may break NotProton. If you don't want to wait for NotProton to be updated to be compatible with future Steam versions at the cost of not getting updates to the Steam client, you can stop the Steam client from updating itself.")

    var body: some View {
        Group {
            if let snapshot = status.snapshot {
                statusForm(snapshot)
            } else {
                ProgressView("Checking")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Status")
        .sheet(isPresented: $libraryMovePresented) {
            LibraryMoveSheet(isPresented: $libraryMovePresented)
        }
        .toolbar {
            if #available(macOS 26.1, *) {
                ToolbarItem(placement: .primaryAction) { refreshButton }
                    .visibilityPriority(.high)
            } else {
                ToolbarItem(placement: .primaryAction) { refreshButton }
            }
        }
        .confirmationDialog(
            String(localized: "Block Steam client updates?"),
            isPresented: asking(.blockUpdates),
            titleVisibility: .visible
        ) {
            Button("Block Updates", role: .destructive) {
                Task { await status.setUpdateBlock(true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.updateBlockPrompt)
        }
        .confirmationDialog(
            String(localized: "Replace Steam with Valve's bundle?"),
            isPresented: asking(.replaceSteam),
            titleVisibility: .visible
        ) {
            Button("Replace Steam", role: .destructive) {
                Task { await status.repairSteam() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(localized: "This will restore Steam itself to its original state but does not remove the support components used by NotProton.")
            )
        }
        .confirmationDialog(
            status.pendingRemoval.map {
                String(localized: "Remove the \(SupportedRunners.displayVersion(forID: $0)) copy?")
            } ?? "",
            isPresented: asking(.removeBuild),
            titleVisibility: .visible
        ) {
            Button("Remove Copy", role: .destructive) {
                Task { await status.removePendingBuild() }
            }
            Button("Cancel", role: .cancel) { status.cancelBuildRemoval() }
        } message: {
            Text("CrossOver itself is not removed.")
        }
        .confirmationDialog(
            String(localized: "Remove everything NotProton has created?"),
            isPresented: asking(.removeEverything),
            titleVisibility: .visible
        ) {
            Button("Remove Everything", role: .destructive) {
                Task { await status.removeEverything() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Uninstall.confirmation())
        }
        .confirmationDialog(
            CrossOverLicense.notActivatedTitle,
            isPresented: asking(.installUnlicensed),
            titleVisibility: .visible
        ) {
            Button("Continue Anyway") {
                Task { await status.installIntoSteam() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                CrossOverLicense.notActivatedAdvice
                    + String(localized: " NotProton can be deployed, but the CrossOver compatibility tool cannot be installed without a valid license.")
            )
        }
        .task { if status.snapshot == nil { await status.refresh() } }
        .confirmationDialog(
            CrossOverLicense.notActivatedTitle,
            isPresented: asking(.toolUnlicensed),
            titleVisibility: .visible
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(CrossOverLicense.notActivatedAdvice)
        }
    }

    private func asking(_ confirmation: SystemStatus.Confirmation) -> Binding<Bool> {
        Binding(
            get: { status.pendingConfirmation == confirmation },
            set: { shown in
                if !shown, status.pendingConfirmation == confirmation {
                    status.pendingConfirmation = nil
                }
            }
        )
    }

    private func statusForm(_ snapshot: StatusSnapshot) -> some View {
        ScrollViewReader { proxy in
            form(snapshot)
                .onChange(of: status.highlightedRow) { _, row in
                    guard let row else { return }
                    withAnimation { proxy.scrollTo(row, anchor: .center) }
                }
        }
    }

    private func form(_ snapshot: StatusSnapshot) -> some View {
        Form {
            if let failure = status.failure {
                StatusRow(
                    title: String(localized: "Failed"),
                    value: failure,
                    tone: .bad,
                    action: status.failureRemedy?.settingsPane.map { pane in
                        StatusAction(label: Remedy.settingsButton) {
                            Remedy.openSettings(pane)
                        }
                    }
                )
            } else if let outcome = status.outcome {
                StatusRow(title: String(localized: "Done"), value: outcome, tone: .ok)
            }

            if let failure = status.templateCleanupFailure {
                StatusRow(title: String(localized: "Template cleanup incomplete"), value: failure, tone: .warning)
            }

            if let activity = status.activity {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(activity)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Steam") {
                StatusRow(
                    title: String(localized: "Location"),
                    value: SupportPaths.Steam.app.path(percentEncoded: false),
                    action: StatusAction(
                        label: String(localized: "Choose\u{2026}"),
                        help: String(localized: "Use a copy of Steam from another folder or drive."),
                        isEnabled: status.isIdle
                    ) { Task { await status.chooseSteam() } }
                )
                steamRow(snapshot.steam, payload: snapshot.payload)
                if snapshot.steamRunning {
                    StatusRow(
                        title: String(localized: "Steam is running"),
                        value: String(localized: "Close Steam before continuing."),
                        tone: .info
                    )
                }
                updateBlockRow(snapshot.updateBlocked)
                StatusRow(
                    title: String(localized: "Controller permission"),
                    value: String(localized: "Clear Steam's controller permission so macOS asks for it again."),
                    action: StatusAction(
                        label: String(localized: "Reset"),
                        isEnabled: status.isIdle
                    ) { Task { await status.resetControllerPermission() } }
                )
                StatusRow(
                    title: String(localized: "Steam library"),
                    value: String(localized: "Move games between CrossOver bottles and native Steam."),
                    action: StatusAction(
                        label: String(localized: "Move\u{2026}"),
                        help: String(localized: "Transfer selected games into Steam or back into a bottle."),
                        isEnabled: status.isIdle
                    ) { libraryMovePresented = true }
                )
            }

            Section {
                crossOverSection(snapshot)
            } header: {
                Text("CrossOver")
            } footer: {
                HStack {
                    Spacer()
                    Button("Add CrossOver\u{2026}") { Task { await status.addCrossOver() } }
                        .disabled(!status.isIdle)
                        .help("Add a copy of CrossOver from another folder.")
                }
            }

            componentsSection(snapshot.payload)

            dangerSection
        }
        .formStyle(.grouped)
    }

    private var dangerSection: some View {
        Section {
            StatusRow(
                title: String(localized: "Repair Steam"),
                value: String(localized: "Restore Steam to its original state."),
                action: StatusAction(
                    label: String(localized: "Repair"),
                    role: .destructive,
                    isEnabled: status.isIdle
                ) { status.pendingConfirmation = .replaceSteam }
            )
            StatusRow(
                title: String(localized: "Remove Everything"),
                value: String(localized: "Remove NotProton and restore Steam to its original state."),
                action: StatusAction(
                    label: String(localized: "Remove"),
                    role: .destructive,
                    isEnabled: status.isIdle
                ) { status.pendingConfirmation = .removeEverything }
            )
        }
    }

    private var refreshButton: some View {
        Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await status.refresh() }
        }
        .disabled(!status.isIdle)
    }

    private func installAction(prominent: Bool, label: String = String(localized: "Install")) -> StatusAction {
        StatusAction(
            label: label,
            isProminent: prominent,
            help: String(localized: "Install NotProton into Steam."),
            isEnabled: status.canInstall
        ) {
            Task { await status.requestInstall() }
        }
    }

    @ViewBuilder
    private func steamRow(_ deployment: SteamDeployment, payload: PayloadState) -> some View {
        switch deployment {
        case .notInstalled:
            if let content = status.snapshot?.installContent, content.blocksInstallation {
                installedContentRow(content, deployment: deployment, payload: payload)
            } else {
                deploymentRow(deployment, payload: payload)
            }
        case .installed, .outdated:
            if let content = status.snapshot?.installContent, content != .unchecked {
                installedContentRow(content, deployment: deployment, payload: payload)
            } else {
                deploymentRow(deployment, payload: payload)
            }
        default:
            deploymentRow(deployment, payload: payload)
        }
    }

    @ViewBuilder
    private func installedContentRow(_ content: DeploymentContent.Status, deployment: SteamDeployment, payload: PayloadState) -> some View {
        switch content {
        case .unchecked, .current:
            let version: String? = switch deployment {
            case .installed(let version): version
            case .outdated(let deployed, _): deployed
            default: nil
            }
            deploymentRow(.installed(version: version), payload: payload)
        case .newerInstalled:
            StatusRow(title: "NotProton", value: String(localized: "A newer build is installed."), tone: .neutral,
                      detail: String(localized: "Use the newer NotProton app to update or repair the installed files."))
        case .unavailable(let reason):
            StatusRow(title: "NotProton", value: String(localized: "Could not check installed files."), tone: .warning, detail: reason)
        case .update(let files):
            StatusRow(title: "NotProton", value: String(localized: "Update available."), tone: .warning,
                      detail: String(localized: "This app includes newer files than those installed for Steam."),
                      action: installAction(prominent: true, label: String(localized: "Update")))
                .help(files.joined(separator: "\n"))
        case .repair(let files):
            StatusRow(title: "NotProton", value: String(localized: "Installed files differ from this build."), tone: .warning,
                      detail: String(localized: "Restore the files included with this app."),
                      action: installAction(prominent: true, label: String(localized: "Repair")))
                .help(files.joined(separator: "\n"))
        case .unrecorded(let files):
            StatusRow(title: "NotProton", value: String(localized: "Update available."), tone: .warning,
                      detail: String(localized: "This app includes updated files for Steam."),
                      action: installAction(prominent: true, label: String(localized: "Update")))
                .help(files.joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private func deploymentRow(_ deployment: SteamDeployment, payload: PayloadState) -> some View {
        switch deployment {
        case .steamMissing:
            StatusRow(title: "NotProton", value: String(localized: "Steam not found."), tone: .bad)
        case .notInstalled:
            StatusRow(
                title: "NotProton",
                value: String(localized: "Not installed."),
                tone: .neutral,
                action: installAction(prominent: true)
            )
        case .installed(let version):
            if payload.isSteamComplete {
                StatusRow(
                    title: "NotProton",
                    value: String(localized: "Installed") + (version.map { " (\($0))" } ?? ""),
                    tone: .ok
                )
            } else {
                StatusRow(
                    title: "NotProton",
                    value: String(localized: "Steam integration needs repair."),
                    tone: .warning,
                    detail: steamRepairDetail(payload),
                    action: installAction(prominent: true)
                )
            }
        case .outdated(_, let bundled):
            StatusRow(
                title: "NotProton",
                value: String(localized: "Update available (\(bundled))."),
                tone: .warning,
                action: installAction(prominent: true)
            )
        case .foreign:
            StatusRow(
                title: "NotProton",
                value: String(localized: "Another dylib is present."),
                tone: .warning,
                detail: String(localized: "Repair your Steam install before installing NotProton.")
            )
        }
    }

    private func updateBlockRow(_ blocked: Bool) -> some View {
        StatusRow(
            title: String(localized: "Block Steam client updates"),
            value: blocked
                ? String(localized: "The Steam client will not update itself.")
                : String(localized: "A Steam client update may break NotProton."),
            toggle: blockUpdates
        )
        .disabled(!status.isIdle)
        .help("Steam client updates may break NotProton.")
    }

    private var blockUpdates: Binding<Bool> {
        Binding(
            get: { status.snapshot?.updateBlocked ?? false },
            set: { wanted in
                if wanted {
                    status.pendingConfirmation = .blockUpdates
                } else {
                    Task { await status.setUpdateBlock(false) }
                }
            }
        )
    }

    @ViewBuilder
    private func crossOverSection(_ snapshot: StatusSnapshot) -> some View {
        let rows = status.crossOverRows
        if rows.isEmpty {
            StatusRow(
                title: "CrossOver",
                value: String(localized: "Not found. Supported: \(SupportedRunners.versionList)."),
                tone: .bad
            )
        }
        let tools = SupportedRunners.tools(for: snapshot.installedRunners)
        ForEach(rows) { row in
            StatusRow(
                title: row.title,
                value: crossOverValue(row),
                tone: crossOverTone(row),
                detail: crossOverDetail(row, tools: tools),
                trailing: row.copy == .ready ? buildSize(row.buildID) : nil,
                action: crossOverAction(row, prominent: snapshot.runner == .none),
                menu: crossOverMenu(row)
            )
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.2))
                    .padding(-6)
                    .opacity(status.highlightedRow == row.id ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.3), value: status.highlightedRow == row.id)
            .id(row.id)
        }
        if case .ready = snapshot.runner, !snapshot.payload.missing(origin: .patched).isEmpty {
            StatusRow(
                title: String(localized: "Compatibility Tool"),
                value: String(localized: "Patched components are missing."),
                tone: .warning,
                action: StatusAction(
                    label: String(localized: "Repair"),
                    isProminent: true,
                    help: String(localized: "Set up the compatibility tool again."),
                    isEnabled: status.isIdle && status.setupSource != nil
                ) { Task { await status.requestCompatibilityTool() } }
            )
        }
    }

    private func crossOverValue(_ row: CrossOverRow) -> String {
        if let version = row.unsupportedVersion {
            return String(localized: "Version \(version) not supported (supported: \(SupportedRunners.versionList))")
        }
        let build = String(localized: "Build \(SupportedRunners.displayVersion(forID: row.buildID))")
        switch row.copy {
        case .ready: return build
        case .none: return build + (row.licensed == false ? String(localized: ", not set up or activated") : String(localized: ", not set up"))
        case .unpatched: return build + String(localized: ", not patched")
        case .damaged: return build + String(localized: ", copy damaged")
        case .unsupported: return build + String(localized: ", not supported")
        }
    }

    private func crossOverTone(_ row: CrossOverRow) -> StatusTone {
        if row.unsupportedVersion != nil { return .neutral }
        switch row.copy {
        case .none: return row.licensed == false ? .warning : .neutral
        case .ready: return .ok
        case .unpatched, .damaged, .unsupported: return .warning
        }
    }

    private func crossOverDetail(_ row: CrossOverRow, tools: [InstalledTool]) -> String? {
        var lines: [String] = []
        if row.copy == .ready || row.copy == .unpatched {
            let names = tools.filter { $0.build == row.buildID }.map(\.display)
            lines.append(contentsOf: names)
        }
        if row.copy == .none, row.licensed == false { lines.append("\(String(localized: "Open CrossOver to activate it.")) \(CrossOverLicense.trialUnsupported)") }
        if let install = row.install {
            var path = install.bundle.path(percentEncoded: false)
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            lines.append(path)
        } else if row.copy != .unsupported {
            lines.append(String(localized: "CrossOver app not found."))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func crossOverAction(_ row: CrossOverRow, prominent: Bool) -> StatusAction? {
        let install = row.install
        switch row.copy {
        case .none where row.canSetUp:
            return StatusAction(
                label: String(localized: "Set Up"),
                isProminent: prominent,
                help: String(localized: "Copy \(row.title) and set up its compatibility tool."),
                isEnabled: status.canInstall
            ) { Task { await status.requestCompatibilityTool(from: install) } }
        case .unpatched where row.canSetUp, .damaged where row.canSetUp:
            return StatusAction(
                label: String(localized: "Repair"),
                isProminent: true,
                help: String(localized: "Copy \(row.title) again."),
                isEnabled: status.canInstall
            ) { Task { await status.requestCompatibilityTool(from: install) } }
        case .unsupported:
            return removeCopyAction(row.buildID, label: String(localized: "Remove\u{2026}"))
        default:
            return nil
        }
    }

    private func crossOverMenu(_ row: CrossOverRow) -> [StatusAction] {
        var items: [StatusAction] = []
        let install = row.install
        if row.copy == .ready {
            items.append(StatusAction(
                label: String(localized: "Reinstall"),
                help: String(localized: "Copy \(row.title) again."),
                isEnabled: status.canInstall && row.canSetUp
            ) { Task { await status.requestCompatibilityTool(from: install, replacingExisting: true) } })
        }
        let shown = install?.bundle
            ?? (row.copy == .none ? nil : SupportPaths.runnerRoot(forBuild: row.buildID))
        if let shown {
            items.append(StatusAction(label: String(localized: "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([shown])
            })
        }
        if [.ready, .unpatched, .damaged].contains(row.copy) {
            var remove = removeCopyAction(row.buildID, label: String(localized: "Remove Copy\u{2026}"))
            remove.startsGroup = true
            items.append(remove)
        }
        if let install, row.isManual {
            items.append(StatusAction(
                label: String(localized: "Remove from List"),
                isEnabled: status.isIdle,
                startsGroup: !items.contains(where: \.startsGroup)
            ) { Task { await status.removeFromList(install) } })
        }
        return items
    }

    private func buildSize(_ build: String) -> String? {
        guard let runner = status.runnerSizes[build] else { return nil }
        let flavors = SupportedRunners.build(id: build)?.tools.map(\.flavor) ?? []
        return Self.sizeText(runner: runner, templates: status.templateSizes[build] ?? [:], flavors: flavors)
    }

    nonisolated static func sizeText(runner: Int64, templates: [CompatTool.Flavor: Int64], flavors: [CompatTool.Flavor]) -> String {
        let lines: [String]
        if flavors.count > 1 {
            lines = flavors.compactMap { flavor in
                guard let bytes = templates[flavor], bytes > 0 else { return nil }
                return String(localized: "\(flavor.name) templates \(bytes.formatted(.byteCount(style: .file)))")
            }
        } else {
            let bytes = templates.values.reduce(0, +)
            lines = bytes > 0 ? [String(localized: "Templates \(bytes.formatted(.byteCount(style: .file)))")] : []
        }
        return ([String(localized: "Runner \(runner.formatted(.byteCount(style: .file)))")] + lines).joined(separator: "\n")
    }

    private func removeCopyAction(_ build: String, label: String) -> StatusAction {
        StatusAction(
            label: label,
            role: .destructive,
            help: String(localized: "Delete NotProton's copy of this build."),
            isEnabled: status.canInstall
        ) {
            status.requestBuildRemoval(build)
        }
    }

    private func steamRepairDetail(_ payload: PayloadState) -> String {
        if let problem = payload.manifestProblem { return problem }
        var names = payload.missingSteamFiles
        if payload.signatureDatabase == nil { names.append(String(localized: "Signature database")) }
        return String(localized: "Missing: \(names.joined(separator: ", ")). Install to restore these files for your macOS user.")
    }

    private func fetchAction() -> StatusAction {
        StatusAction(
            label: String(localized: "Fetch Valve Binaries"),
            isProminent: true,
            help: String(localized: "Download missing Valve binaries."),
            isEnabled: status.canInstall
        ) { Task { await status.fetchValveBinaries() } }
    }

    @ViewBuilder
    private func componentsSection(_ payload: PayloadState) -> some View {
        Section("NotProton Components") {
            if let problem = payload.manifestProblem {
                StatusRow(title: String(localized: "Components"), value: String(localized: "Component list unreadable."), tone: .bad, detail: problem)
            } else if payload.isComplete {
                StatusRow(
                    title: String(localized: "Components"), value: String(localized: "Ready."), tone: .ok,
                    trailing: status.bridgeCopyBytes > 0
                        ? String(localized: "Copies on other drives \(status.bridgeCopyBytes.formatted(.byteCount(style: .file)))") : nil
                )
            } else if payload.isEmpty {
                StatusRow(title: String(localized: "Components"), value: String(localized: "Not yet deployed."), tone: .neutral)
            } else {
                if !payload.missing.isEmpty {
                    let names = payload.missing.map(\.path).joined(separator: ", ")
                    StatusRow(
                        title: String(localized: "Missing."),
                        value: names,
                        tone: .bad,
                        action: payload.missing.contains(where: { $0.origin.isFetchable })
                            ? fetchAction() : nil
                    )
                }
                if !payload.overlayShimPresent {
                    StatusRow(title: String(localized: "Overlay shim"), value: String(localized: "Missing."), tone: .bad)
                }
                if payload.signatureDatabase == nil {
                    StatusRow(title: String(localized: "Signature database"), value: String(localized: "Missing."), tone: .bad)
                }
            }
        }
    }
}

private struct LibraryMoveSheet: View {
    private enum Direction: String, CaseIterable, Identifiable {
        case intoSteam
        case intoBottle

        var id: String { rawValue }

        var title: String {
            switch self {
            case .intoSteam: String(localized: "Into Steam")
            case .intoBottle: String(localized: "Into bottle")
            }
        }
    }

    @Environment(SystemStatus.self) private var status
    @Binding var isPresented: Bool

    @State private var direction: Direction = .intoSteam
    @State private var bottles: [BottleSteamLibrary] = []
    @State private var bottleID: String?
    @State private var games: [BottleGame] = []
    @State private var selection: Set<String> = []
    @State private var thumbs: [String: NSImage] = [:]
    @State private var alertMessage: String?
    @State private var confirmCrossVolume = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "Move Library"))
                    .font(.headline)
                Spacer()
                Button(String(localized: "Select Custom Folder")) { pickFolder() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.top)
            Picker(String(localized: "Destination"), selection: $direction) {
                ForEach(Direction.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)
            .onChange(of: direction) { _, _ in reloadSources() }

            if direction == .intoBottle, bottles.isEmpty {
                ContentUnavailableView(
                    String(localized: "No bottle with Steam"),
                    systemImage: "shippingbox",
                    description: Text(String(localized: "Install Steam in a CrossOver bottle first."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if direction == .intoBottle, bottles.count > 1 {
                    Picker(String(localized: "Bottle"), selection: $bottleID) {
                        ForEach(bottles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                gameList
            }

            Divider()
            HStack {
                Button(String(localized: "Cancel"), role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "Move")) { attemptMove() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(direction == .intoBottle && bottles.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 420, minHeight: 360)
        .onAppear { reloadSources() }
        .alert(
            String(localized: "Can't move"),
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .confirmationDialog(
            String(localized: "Move across volumes?"),
            isPresented: $confirmCrossVolume,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Move Anyway")) { startTransfer() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Some games are on a different volume than the destination. macOS will copy them instead of renaming, which is slower and uses more disk while it runs."))
        }
    }

    @ViewBuilder
    private var gameList: some View {
        if games.isEmpty {
            ContentUnavailableView(
                String(localized: "No games found"),
                systemImage: "shippingbox",
                description: Text(
                    direction == .intoBottle
                        ? String(localized: "No games in the native Steam library. Select a custom folder if they live elsewhere.")
                        : String(localized: "Select a custom folder, or install Steam games in a CrossOver bottle.")
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(games) { game in
                    Toggle(isOn: Binding(
                        get: { selection.contains(game.id) },
                        set: { on in
                            if on { selection.insert(game.id) } else { selection.remove(game.id) }
                        }
                    )) {
                        HStack(spacing: 8) {
                            libraryThumb(game.id)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(game.title)
                                Text(game.sourceLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var selectedGames: [BottleGame] {
        games.filter { selection.contains($0.id) }
    }

    private var destinationSteamapps: URL? {
        switch direction {
        case .intoSteam:
            status.libraryMoveDestination()
        case .intoBottle:
            bottles.first { $0.id == bottleID }?.steamapps
        }
    }

    private func reloadSources() {
        bottles = PrefixStore.bottleSteamLibraries()
        if bottleID == nil || !bottles.contains(where: { $0.id == bottleID }) {
            bottleID = bottles.first?.id
        }
        let scanned = status.scanLibraryMoveGames(intoBottle: direction == .intoBottle)
        games = scanned
        selection = direction == .intoBottle ? [] : Set(scanned.map(\.id))
        thumbs = Self.loadThumbs(for: scanned)
    }

    private func pickFolder() {
        switch status.pickLibraryFolder(mergingInto: games) {
        case .cancelled:
            break
        case .empty:
            alertMessage = String(localized: "No games found in that folder.")
        case .merged(_, let added) where added.isEmpty:
            alertMessage = String(localized: "Those games are already in the list.")
        case .merged(let next, let added):
            games = next
            if direction == .intoSteam {
                for game in added {
                    selection.insert(game.id)
                }
            }
            for (id, image) in Self.loadThumbs(for: added) {
                thumbs[id] = image
            }
        }
    }

    private func attemptMove() {
        if selection.isEmpty {
            alertMessage = String(localized: "Select at least one game to move.")
        } else if direction == .intoBottle, destinationSteamapps == nil {
            alertMessage = String(localized: "Pick a CrossOver bottle that already has Steam.")
        } else if let reason = status.libraryMoveBlockReason {
            alertMessage = reason
        } else if let dest = destinationSteamapps,
            PrefixStore.crossesVolumes(selectedGames, destSteamapps: dest)
        {
            confirmCrossVolume = true
        } else {
            startTransfer()
        }
    }

    private func startTransfer() {
        guard let dest = destinationSteamapps else { return }
        let moving = selectedGames
        isPresented = false
        Task { await status.transferLibraryGames(moving, into: dest) }
    }

    private static func loadThumbs(for games: [BottleGame]) -> [String: NSImage] {
        var loaded: [String: NSImage] = [:]
        for game in games {
            guard let url = PrefixStore.libraryArtwork(for: game),
                let image = NSImage(contentsOf: url)
            else { continue }
            loaded[game.id] = image
        }
        return loaded
    }

    @ViewBuilder
    private func libraryThumb(_ id: String) -> some View {
        let height: CGFloat = 40
        let width = height * 2 / 3
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
            if let image = thumbs[id] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "shippingbox")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
