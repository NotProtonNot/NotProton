import SwiftUI

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case status
    case prefixes
    case backups
    case plugins

    var id: String { rawValue }

    var label: String {
        switch self {
        case .status: String(localized: "Status")
        case .prefixes: String(localized: "Prefixes")
        case .backups: String(localized: "Prefix Backups")
        case .plugins: String(localized: "Plugins")
        }
    }

    var symbol: String {
        switch self {
        case .status: "checklist"
        case .prefixes: "externaldrive"
        case .backups: "externaldrive.badge.timemachine"
        case .plugins: "puzzlepiece.extension"
        }
    }
}

struct RootView: View {

    @Binding var pane: Pane

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { item in
                    Label(item.label, systemImage: item.symbol)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch pane {
            case .status: StatusView()
            case .prefixes: PrefixesView()
            case .backups: BackupsView()
            case .plugins: PluginsView()
            }
        }
    }
}
