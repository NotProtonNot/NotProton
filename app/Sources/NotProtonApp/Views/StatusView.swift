// 'Status' view, see SystemStatus for actual logic

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
                    Label(L10n.tr("More"), systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L10n.tr("More actions"))
                .accessibilityLabel(L10n.tr("More actions, \(title)"))
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

    private static let updateBlockPrompt =
        L10n.tr("Steam client updates may break NotProton. If you don't want to wait for NotProton to be updated to be compatible with future Steam versions at the cost of not getting updates to the Steam client, you can stop the Steam client from updating itself.")

    var body: some View {
        Group {
            if let snapshot = status.snapshot {
                statusForm(snapshot)
            } else {
                ProgressView(L10n.tr("Checking"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(L10n.tr("Status"))
        .toolbar {
            if #available(macOS 26.1, *) {
                ToolbarItem(placement: .primaryAction) { refreshButton }
                    .visibilityPriority(.high)
            } else {
                ToolbarItem(placement: .primaryAction) { refreshButton }
            }
        }
        .confirmationDialog(
            L10n.tr("Block Steam client updates?"),
            isPresented: asking(.blockUpdates),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Block Updates"), role: .destructive) {
                Task { await status.setUpdateBlock(true) }
            }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: {
            Text(Self.updateBlockPrompt)
        }
        .confirmationDialog(
            L10n.tr("Replace Steam with Valve's bundle?"),
            isPresented: asking(.replaceSteam),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Replace Steam"), role: .destructive) {
                Task { await status.repairSteam() }
            }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.tr("This will restore Steam itself to its original state but does not remove the support components used by NotProton.")
            )
        }
        .confirmationDialog(
            status.pendingRemoval.map {
                L10n.tr("Remove the \(SupportedRunners.displayVersion(forID: $0)) copy?")
            } ?? "",
            isPresented: asking(.removeBuild),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Remove Copy"), role: .destructive) {
                Task { await status.removePendingBuild() }
            }
            Button(L10n.tr("Cancel"), role: .cancel) { status.cancelBuildRemoval() }
        } message: {
            Text(L10n.tr("CrossOver itself is not removed."))
        }
        .confirmationDialog(
            L10n.tr("Remove everything NotProton has created?"),
            isPresented: asking(.removeEverything),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Remove Everything"), role: .destructive) {
                Task { await status.removeEverything() }
            }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: {
            Text(
                L10n.tr("Steam is restored to its unmodified state and NotProton is removed, including the compatibility tool that lives inside the Steam folder. Windows games and Steam Play prefixes are not removed.")
            )
        }
        .confirmationDialog(
            CrossOverLicense.notActivatedTitle,
            isPresented: asking(.installUnlicensed),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("Continue Anyway")) {
                Task { await status.installIntoSteam() }
            }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        } message: {
            Text(
                CrossOverLicense.notActivatedAdvice
                    + L10n.tr(" NotProton can be deployed, but the CrossOver compatibility tool cannot be installed without a valid license.")
            )
        }
        .task { if status.snapshot == nil { await status.refresh() } }
        .confirmationDialog(
            CrossOverLicense.notActivatedTitle,
            isPresented: asking(.toolUnlicensed),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("OK"), role: .cancel) {}
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
                    title: L10n.tr("Failed"),
                    value: failure,
                    tone: .bad,
                    action: status.failureRemedy?.settingsPane.map { pane in
                        StatusAction(label: Remedy.settingsButton) {
                            Remedy.openSettings(pane)
                        }
                    }
                )
            } else if let outcome = status.outcome {
                StatusRow(title: L10n.tr("Done"), value: outcome, tone: .ok)
            }

            if let failure = status.templateCleanupFailure {
                StatusRow(title: L10n.tr("Template cleanup incomplete"), value: failure, tone: .warning)
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
                steamRow(snapshot.steam, payload: snapshot.payload)
                if snapshot.steamRunning {
                    StatusRow(
                        title: L10n.tr("Steam is running"),
                        value: L10n.tr("Close Steam before continuing."),
                        tone: .info
                    )
                }
                updateBlockRow(snapshot.updateBlocked)
                StatusRow(
                    title: L10n.tr("Controller permission"),
                    value: L10n.tr("Clear Steam's controller permission so macOS asks for it again."),
                    action: StatusAction(
                        label: L10n.tr("Reset"),
                        isEnabled: status.isIdle
                    ) { Task { await status.resetControllerPermission() } }
                )
            }

            Section {
                crossOverSection(snapshot)
            } header: {
                Text("CrossOver")
            } footer: {
                HStack {
                    Spacer()
                    Button(L10n.tr("Add CrossOver\u{2026}")) { Task { await status.addCrossOver() } }
                        .disabled(!status.isIdle)
                        .help(L10n.tr("Add a copy of CrossOver from another folder."))
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
                title: L10n.tr("Repair Steam"),
                value: L10n.tr("Restore Steam to its original state."),
                action: StatusAction(
                    label: L10n.tr("Repair"),
                    role: .destructive,
                    isEnabled: status.isIdle
                ) { status.pendingConfirmation = .replaceSteam }
            )
            StatusRow(
                title: L10n.tr("Remove Everything"),
                value: L10n.tr("Remove NotProton and restore Steam to its original state."),
                action: StatusAction(
                    label: L10n.tr("Remove"),
                    role: .destructive,
                    isEnabled: status.isIdle
                ) { status.pendingConfirmation = .removeEverything }
            )
        }
    }

    private var refreshButton: some View {
        Button(L10n.tr("Refresh"), systemImage: "arrow.clockwise") {
            Task { await status.refresh() }
        }
        .disabled(!status.isIdle)
    }

    private func installAction(prominent: Bool, label: String = L10n.tr("Install")) -> StatusAction {
        StatusAction(
            label: label,
            isProminent: prominent,
            help: L10n.tr("Install NotProton into Steam."),
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
            StatusRow(title: "NotProton", value: L10n.tr("A newer build is installed."), tone: .neutral,
                      detail: L10n.tr("Use the newer NotProton app to update or repair the installed files."))
        case .unavailable(let reason):
            StatusRow(title: "NotProton", value: L10n.tr("Could not check installed files."), tone: .warning, detail: reason)
        case .update(let files):
            StatusRow(title: "NotProton", value: L10n.tr("Update available."), tone: .warning,
                      detail: L10n.tr("This app includes newer files than those installed for Steam."),
                      action: installAction(prominent: true, label: L10n.tr("Update")))
                .help(files.joined(separator: "\n"))
        case .repair(let files):
            StatusRow(title: "NotProton", value: L10n.tr("Installed files differ from this build."), tone: .warning,
                      detail: L10n.tr("Restore the files included with this app."),
                      action: installAction(prominent: true, label: L10n.tr("Repair")))
                .help(files.joined(separator: "\n"))
        case .unrecorded(let files):
            StatusRow(title: "NotProton", value: L10n.tr("Update available."), tone: .warning,
                      detail: L10n.tr("This app includes updated files for Steam."),
                      action: installAction(prominent: true, label: L10n.tr("Update")))
                .help(files.joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private func deploymentRow(_ deployment: SteamDeployment, payload: PayloadState) -> some View {
        switch deployment {
        case .steamMissing:
            StatusRow(title: "NotProton", value: L10n.tr("Steam not found."), tone: .bad)
        case .notInstalled:
            StatusRow(
                title: "NotProton",
                value: L10n.tr("Not installed."),
                tone: .neutral,
                action: installAction(prominent: true)
            )
        case .installed(let version):
            if payload.isComplete {
                StatusRow(
                    title: "NotProton",
                    value: L10n.tr("Installed") + (version.map { " (\($0))" } ?? ""),
                    tone: .ok
                )
            } else {
                StatusRow(
                    title: "NotProton",
                    value: L10n.tr("Installed, but not for this account."),
                    tone: .warning,
                    detail: L10n.tr("Steam is set up for NotProton, but this account is missing its components. Install to add them."),
                    action: installAction(prominent: true)
                )
            }
        case .outdated(_, let bundled):
            StatusRow(
                title: "NotProton",
                value: L10n.tr("Update available (\(bundled))."),
                tone: .warning,
                action: installAction(prominent: true)
            )
        case .foreign:
            StatusRow(
                title: "NotProton",
                value: L10n.tr("Another dylib is present."),
                tone: .warning,
                detail: L10n.tr("Repair your Steam install before installing NotProton.")
            )
        }
    }

    private func updateBlockRow(_ blocked: Bool) -> some View {
        StatusRow(
            title: L10n.tr("Block Steam client updates"),
            value: blocked
                ? L10n.tr("The Steam client will not update itself.")
                : L10n.tr("A Steam client update may break NotProton."),
            toggle: blockUpdates
        )
        .disabled(!status.isIdle)
        .help(L10n.tr("Steam client updates may break NotProton."))
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
                value: L10n.tr("Not found. Supported: \(SupportedRunners.versionList)."),
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
                title: L10n.tr("Compatibility Tool"),
                value: L10n.tr("Patched components are missing."),
                tone: .warning,
                action: StatusAction(
                    label: L10n.tr("Repair"),
                    isProminent: true,
                    help: L10n.tr("Set up the compatibility tool again."),
                    isEnabled: status.isIdle && status.setupSource != nil
                ) { Task { await status.requestCompatibilityTool() } }
            )
        }
    }

    private func crossOverValue(_ row: CrossOverRow) -> String {
        if let version = row.unsupportedVersion {
            return L10n.tr("Version \(version) not supported (supported: \(SupportedRunners.versionList))")
        }
        let build = L10n.tr("Build \(SupportedRunners.displayVersion(forID: row.buildID))")
        switch row.copy {
        case .ready: return build
        case .none: return build + (row.licensed == false ? L10n.tr(", not set up or activated") : L10n.tr(", not set up"))
        case .unpatched: return build + L10n.tr(", not patched")
        case .damaged: return build + L10n.tr(", copy damaged")
        case .unsupported: return build + L10n.tr(", not supported")
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
        if row.copy == .none, row.licensed == false { lines.append(L10n.tr("Open CrossOver to activate it.")) }
        if let install = row.install {
            var path = install.bundle.path(percentEncoded: false)
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            lines.append(path)
        } else if row.copy != .unsupported {
            lines.append(L10n.tr("CrossOver app not found."))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func crossOverAction(_ row: CrossOverRow, prominent: Bool) -> StatusAction? {
        let install = row.install
        switch row.copy {
        case .none where row.canSetUp:
            return StatusAction(
                label: L10n.tr("Set Up"),
                isProminent: prominent,
                help: L10n.tr("Copy \(row.title) and set up its compatibility tool."),
                isEnabled: status.canInstall
            ) { Task { await status.requestCompatibilityTool(from: install) } }
        case .unpatched where row.canSetUp, .damaged where row.canSetUp:
            return StatusAction(
                label: L10n.tr("Repair"),
                isProminent: true,
                help: L10n.tr("Copy \(row.title) again."),
                isEnabled: status.canInstall
            ) { Task { await status.requestCompatibilityTool(from: install) } }
        case .unsupported:
            return removeCopyAction(row.buildID, label: L10n.tr("Remove\u{2026}"))
        default:
            return nil
        }
    }

    private func crossOverMenu(_ row: CrossOverRow) -> [StatusAction] {
        var items: [StatusAction] = []
        let install = row.install
        if row.copy == .ready {
            items.append(StatusAction(
                label: L10n.tr("Reinstall"),
                help: L10n.tr("Copy \(row.title) again."),
                isEnabled: status.canInstall && row.canSetUp
            ) { Task { await status.requestCompatibilityTool(from: install, replacingExisting: true) } })
        }
        let shown = install?.bundle
            ?? (row.copy == .none ? nil : SupportPaths.runnerRoot(forBuild: row.buildID))
        if let shown {
            items.append(StatusAction(label: L10n.tr("Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([shown])
            })
        }
        if [.ready, .unpatched, .damaged].contains(row.copy) {
            var remove = removeCopyAction(row.buildID, label: L10n.tr("Remove Copy\u{2026}"))
            remove.startsGroup = true
            items.append(remove)
        }
        if let install, row.isManual {
            items.append(StatusAction(
                label: L10n.tr("Remove from List"),
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
                return L10n.tr("\(flavor.name) templates \(bytes.formatted(.byteCount(style: .file)))")
            }
        } else {
            let bytes = templates.values.reduce(0, +)
            lines = bytes > 0 ? [L10n.tr("Templates \(bytes.formatted(.byteCount(style: .file)))")] : []
        }
        return ([L10n.tr("Runner \(runner.formatted(.byteCount(style: .file)))")] + lines).joined(separator: "\n")
    }

    private func removeCopyAction(_ build: String, label: String) -> StatusAction {
        StatusAction(
            label: label,
            role: .destructive,
            help: L10n.tr("Delete NotProton's copy of this build."),
            isEnabled: status.canInstall
        ) {
            status.requestBuildRemoval(build)
        }
    }

    private func fetchAction() -> StatusAction {
        StatusAction(
            label: L10n.tr("Fetch Valve Binaries"),
            isProminent: true,
            help: L10n.tr("Download missing Valve binaries."),
            isEnabled: status.canInstall
        ) { Task { await status.fetchValveBinaries() } }
    }

    @ViewBuilder
    private func componentsSection(_ payload: PayloadState) -> some View {
        if let problem = payload.manifestProblem {
            Section(L10n.tr("NotProton Components")) {
                StatusRow(title: L10n.tr("Components"), value: L10n.tr("Component list unreadable."), tone: .bad, detail: problem)
            }
        } else if payload.isComplete {
            Section(L10n.tr("NotProton Components")) {
                StatusRow(
                    title: L10n.tr("Components"), value: L10n.tr("Ready."), tone: .ok,
                    trailing: status.bridgeCopyBytes > 0
                        ? L10n.tr("Copies on other drives \(status.bridgeCopyBytes.formatted(.byteCount(style: .file)))") : nil
                )
            }
        } else if payload.isEmpty {
            Section(L10n.tr("NotProton Components")) {
                StatusRow(title: L10n.tr("Components"), value: L10n.tr("Not yet deployed."), tone: .neutral)
            }
        } else {
            Section(L10n.tr("NotProton Components")) {
                if !payload.missing.isEmpty {
                    let names = payload.missing.map {
                        URL(filePath: $0.path).lastPathComponent
                    }.joined(separator: ", ")
                    StatusRow(
                        title: L10n.tr("Missing."),
                        value: names,
                        tone: .bad,
                        action: payload.missing.contains(where: { $0.origin.isFetchable })
                            ? fetchAction() : nil
                    )
                }
                if !payload.overlayShimPresent {
                    StatusRow(title: L10n.tr("Overlay shim"), value: L10n.tr("Missing."), tone: .bad)
                }
                if payload.signatureDatabase == nil {
                    StatusRow(title: L10n.tr("Signature database"), value: L10n.tr("Missing."), tone: .bad)
                }
            }
        }
    }
}
