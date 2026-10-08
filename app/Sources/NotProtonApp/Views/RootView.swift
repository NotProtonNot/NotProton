import SwiftUI

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case status
    case prefixes
    case backups
    case help
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .status: GuideCopy.text("Status")
        case .prefixes: GuideCopy.text("Game environments")
        case .backups: GuideCopy.text("Backups")
        case .help: GuideCopy.text("Help")
        case .settings: GuideCopy.text("Settings")
        }
    }

    var symbol: String {
        switch self {
        case .status: "checklist"
        case .prefixes: "externaldrive"
        case .backups: "externaldrive.badge.timemachine"
        case .help: "questionmark.circle"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {

    @Binding var pane: Pane
    @Environment(SystemStatus.self) private var status
    @State private var showSetup = false
    @AppStorage("hasSeenSetupGuide") private var hasSeenSetup = false

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases.filter { $0 != .settings }) { item in
                    Label(item.label, systemImage: item.symbol)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                Button { pane = .settings } label: {
                    Label(GuideCopy.text("Settings"), systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .buttonStyle(.plain)
                .background(pane == .settings ? Color.accentColor.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .padding(8)
            }
        } detail: {
            switch pane {
            case .status: StatusView(showGuide: $showSetup)
            case .prefixes: PrefixesView()
            case .backups: BackupsView()
            case .help: HelpView(pane: $pane)
            case .settings: SettingsView(showGuide: $showSetup)
            }
        }
        .sheet(isPresented: $showSetup) {
            if let snapshot = status.snapshot { SetupGuideView(initialSnapshot: snapshot) }
        }
        .task {
            if status.snapshot == nil { await status.refresh() }
            if status.snapshot != nil, !hasSeenSetup {
                hasSeenSetup = true
                showSetup = true
            }
        }
    }
}
