import SwiftUI

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case status
    case prefixes
    case backups

    var id: String { rawValue }

    var label: String {
        switch self {
        case .status: L10n.tr("Status")
        case .prefixes: L10n.tr("Prefixes")
        case .backups: L10n.tr("Prefix Backups")
        }
    }

    var symbol: String {
        switch self {
        case .status: "checklist"
        case .prefixes: "externaldrive"
        case .backups: "externaldrive.badge.timemachine"
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
            }
        }
    }
}
