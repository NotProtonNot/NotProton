// Prefix management UI inside NotProton, also see PrefixesModel

import SwiftUI
import CachedAsyncImage

struct PrefixesView: View {
    
    @Environment(PrefixesModel.self) private var model
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var sortOrder = [KeyPathComparator(\PrefixRow.lastUsed, order: .reverse)]
    // persisted to userdefaults
    @AppStorage("PrefixViewMode") private var viewMode: ViewMode = .list
    @State private var winetricksPrefix: WinePrefix?
    @State private var winetricksVerbs = ""
    
    var body: some View {
        Group {
            if !model.hasLoaded {
                ProgressView("Looking for prefixes")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.prefixes.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Prefixes"),
                    systemImage: "externaldrive",
                    description: Text(
                        String(localized: "A prefix appears here once a Windows game has been launched through NotProton.")
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if viewMode == .list {
                    table
                } else {
                    grid
                }
            }
        }
        .navigationTitle("Prefixes")
        .safeAreaInset(edge: .bottom) {
            if let failed = model.report {
                report(
                    StatusRow(
                        title: String(localized: "Failed"),
                        value: failed.message,
                        tone: .bad,
                        action: failed.settingsPane.map { pane in
                            StatusAction(label: Remedy.settingsButton) { Remedy.openSettings(pane) }
                        }
                    )
                )
            } else if let outcome = model.outcome {
                report(
                    StatusRow(
                        title: String(localized: "Done"),
                        value: outcome,
                        tone: .ok
                    )
                )
            }
        }
        .toolbar {
            if #available(macOS 26.1, *) {
                ToolbarItemGroup(placement: .primaryAction) { strip }
                    .visibilityPriority(.high)
            } else {
                ToolbarItemGroup(placement: .primaryAction) { strip }
            }
        }
        .task { if model.prefixes.isEmpty { await model.load() } }
        .confirmationDialog(
            PrefixPrompt.deleteTitle(deleting),
            isPresented: asking(.delete),
            titleVisibility: .visible
        ) {
            Button(PrefixPrompt.deleteButton(deleting), role: .destructive) {
                let targets = deleting
                model.pendingConfirmation = nil
                Task { await model.delete(targets) }
            }
            Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(PrefixPrompt.deleteMessage(deleting))
        }
        .confirmationDialog(
            PrefixPrompt.rebuildTitle(rebuilding, for: rebuildTool),
            isPresented: asking(.rebuild),
            titleVisibility: .visible
        ) {
            Button(PrefixPrompt.rebuildWithBackupButton(rebuilding)) {
                model.confirmRebuild()
            }
            .keyboardShortcut(.defaultAction)
            Button(PrefixPrompt.rebuildWithoutBackupButton(rebuilding)) {
                model.confirmRebuild(keepBackup: false)
            }
            Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
        } message: {
            Text(PrefixPrompt.rebuildMessage())
        }
        .confirmationDialog(
            PrefixPrompt.backUpTitle(backingUp),
            isPresented: asking(.backUp),
            titleVisibility: .visible
        ) {
            Button(PrefixPrompt.backUpButton(backingUp)) {
                let targets = backingUp
                model.pendingConfirmation = nil
                Task { await model.backUp(targets) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
        } message: {
            Text(PrefixPrompt.backUpMessage(backingUp))
        }
        .alert(
            "Winetricks",
            isPresented: Binding(
                get: { winetricksPrefix != nil },
                set: { if !$0 { winetricksPrefix = nil } }
            ),
            presenting: winetricksPrefix
        ) { prefix in
            TextField("vcrun2022 corefonts", text: $winetricksVerbs)
            Button("Install") {
                let verbs = winetricksVerbs
                Task { await model.winetricks(verbs, in: prefix) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(PrefixTools.winetricksVerbs(winetricksVerbs).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { prefix in
            Text("Enter the Winetricks verbs to install in \(prefix.title), separated by spaces.")
        }
    }
    
    private enum ViewMode: String, CaseIterable, Identifiable {
        case grid
        case list
        
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .grid: return "square.grid.2x2"
            case .list: return "list.bullet"
            }
        }
    }
    
    private enum Question {
        case delete, rebuild, backUp
    }
    
    private var deleting: [WinePrefix] {
        if case .delete(let targets) = model.pendingConfirmation { return targets }
        return []
    }
    
    private var rebuilding: [WinePrefix] {
        if case .rebuild(let targets, _) = model.pendingConfirmation { return targets }
        return []
    }
    
    private var rebuildTool: InstalledTool? {
        if case .rebuild(_, let tool) = model.pendingConfirmation { return tool }
        return nil
    }
    
    private var backingUp: [WinePrefix] {
        if case .backUp(let targets) = model.pendingConfirmation { return targets }
        return []
    }
    
    private func isAsking(_ question: Question) -> Bool {
        switch (question, model.pendingConfirmation) {
        case (.delete, .delete): true
        case (.rebuild, .rebuild(_, _)): true
        case (.backUp, .backUp): true
        default: false
        }
    }
    
    private func asking(_ question: Question) -> Binding<Bool> {
        Binding(
            get: { isAsking(question) },
            set: { shown in
                if !shown, isAsking(question) { model.pendingConfirmation = nil }
            }
        )
    }
    
    @ViewBuilder
    private var strip: some View {
        Picker("View Mode", selection: $viewMode) {
            ForEach(ViewMode.allCases) { mode in
                Label(mode.rawValue.capitalized, systemImage: mode.systemImage)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        
        Menu {
            toolButtons(for: model.selectedPrefix)
        } label: {
            Label("Tools", systemImage: "wrench.and.screwdriver")
        }
        .disabled(model.selectedPrefix == nil || model.isBusy)
        .help("Run a program or open a Wine tool in the selected prefix.")
        
        Button("Reveal in Finder", systemImage: "folder") {
            if let prefix = model.selectedPrefix { model.reveal(prefix) }
        }
        .disabled(model.selectedPrefix == nil)
        .help("Show the selected prefix in the Finder.")
        
        Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await model.load() }
        }
        .disabled(model.isLoading)
        .help("List the prefixes again and update their sizes.")
    }
    
    private func lastUsed(_ prefix: WinePrefix) -> String {
        prefix.lastUsed?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "Never")
    }
    
    private var libraryWidth: CGFloat {
        TextWidth.widest(model.prefixes.map(\.library.displayName)) ?? 120
    }
    
    private var toolWidth: CGFloat {
        TextWidth.widest(model.prefixes.compactMap(model.lastTool)) ?? 60
    }
    
    private var lastUsedWidth: CGFloat {
        TextWidth.widest(model.prefixes.map(lastUsed)) ?? 110
    }
    
    private var gameWidth: CGFloat {
        let widths = model.prefixes.map { prefix -> CGFloat in
            var width = TextWidth.of(prefix.title)
            if model.isStale(prefix) { width += 22 }
            if prefix.name == nil {
                width += TextWidth.of(String(localized: "No longer installed"), size: NSFont.smallSystemFontSize) + 6
            }
            return width
        }
        guard let widest = widths.max() else { return 240 }
        return widest + TextWidth.cellPadding
    }
    
    struct PrefixRow: Identifiable {
        let prefix: WinePrefix
        let tool: String
        let appID: Int
        let size: Int64
        let title: String
        let library: String
        let lastUsed: Date
        
        var id: WinePrefix.ID { prefix.id }
    }
    
    private var rows: [PrefixRow] {
        model.prefixes.map { prefix in
            PrefixRow(
                prefix: prefix,
                tool: model.lastTool(prefix) ?? "",
                appID: Int(prefix.appID) ?? 0,
                size: model.usage[prefix.id]?.bytes ?? -1,
                title: prefix.title,
                library: prefix.library.displayName,
                lastUsed: prefix.lastUsed ?? .distantPast
            )
        }
        .sorted(using: sortOrder)
    }
    
    private var table: some View {
        @Bindable var model = model
        return Table(rows, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Game", value: \.title) { row in
                let prefix = row.prefix
                HStack(spacing: 6) {
                    if model.isStale(prefix) {
                        Menu {
                            rebuildChoices([prefix])
                        } label: {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(model.isBusy || model.tools.isEmpty)
                        .accessibilityLabel("Needs rebuilding")
                    }
                    Text(prefix.title).help(prefix.title)
                    if prefix.name == nil {
                        Text("No longer installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if model.busy.contains(prefix.id) {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .width(min: 60, ideal: gameWidth)
            
            TableColumn("Tool", value: \.tool) { row in
                let prefix = row.prefix
                if let tool = model.lastTool(prefix) {
                    Text(tool).foregroundStyle(.secondary).help(tool)
                } else {
                    Text("None")
                        .foregroundStyle(contrast == .increased ? .secondary : .tertiary)
                }
            }
            .width(min: 60, ideal: toolWidth)
            
            TableColumn("App ID", value: \.appID) { row in
                Text(row.prefix.appID).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 80)
            
            TableColumn("Library", value: \.library) { row in
                Text(row.library)
                    .foregroundStyle(.secondary)
                    .help(row.library)
            }
            .width(min: 44, ideal: libraryWidth)
            
            TableColumn("Private Size", value: \.size) { row in
                if let usage = model.usage[row.id] {
                    Text(usage.bytes.formatted(.byteCount(style: .file)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("Calculating…")
                        .foregroundStyle(contrast == .increased ? .secondary : .tertiary)
                }
            }
            .width(min: 56, ideal: 90)
            
            TableColumn("Last used", value: \.lastUsed) { row in
                Text(lastUsed(row.prefix))
                    .foregroundStyle(.secondary)
                    .help(lastUsed(row.prefix))
            }
            .width(min: 60, ideal: lastUsedWidth)
            
        }
        .contextMenu(forSelectionType: WinePrefix.ID.self) { ids in
            actions(for: ids)
        }
        .onDeleteCommand {
            let targets = model.selectedPrefixes
            if !model.isBusy, !targets.isEmpty {
                model.pendingConfirmation = .delete(targets)
            }
        }
    }
    
    @ViewBuilder
    private var grid: some View {
        @Bindable var model = model
        ScrollView {
            LazyVGrid(columns: [.init(.adaptive(minimum: 105))]) {
                ForEach(rows) {row in
                    GridCell(app: row, allRows: rows, model: model)
                        .contextMenu {
                            toolButtons(for: row.prefix )
                        }
                }
            }
            .padding()
        }
    }
    
    @ViewBuilder
    private func actions(for ids: Set<WinePrefix.ID>) -> some View {
        let targets = model.prefixes.filter { ids.contains($0.id) }
        Group {
            if let prefix = single(ids) {
                toolButtons(for: prefix)
                Divider()
                Button("Reveal in Finder") { model.reveal(prefix) }
                Menu("Open Log") {
                    ForEach(PrefixLog.allCases, id: \.self) { log in
                        Button(log.label) { model.open(log, for: prefix) }
                            .disabled(!model.hasLog(log, for: prefix))
                    }
                }
            }
            if !targets.isEmpty {
                Divider()
                Button(PrefixPrompt.backUpButton(targets)) {
                    model.pendingConfirmation = .backUp(targets)
                }
                if model.tools.count > 1 {
                    Menu(PrefixPrompt.rebuildButton(targets)) { rebuildChoices(targets) }
                } else {
                    rebuildChoices(targets, label: PrefixPrompt.rebuildButton(targets))
                }
                Button(PrefixPrompt.deleteButton(targets), role: .destructive) {
                    model.pendingConfirmation = .delete(targets)
                }
            }
        }
        .disabled(model.isBusy)
    }
    
    @ViewBuilder
    private func rebuildChoices(_ targets: [WinePrefix], label: String? = nil) -> some View {
        ForEach(model.tools) { tool in
            Button(label ?? tool.display) {
                model.pendingConfirmation = .rebuild(targets, tool)
            }
        }
    }
    
    @ViewBuilder
    private func toolButtons(for prefix: WinePrefix?) -> some View {
        Button("Run Program…") {
            if let prefix { model.chooseExecutable(for: prefix) }
        }
        Button("Winetricks…") {
            winetricksPrefix = prefix
        }
        Divider()
        ForEach(WineTool.allCases, id: \.self) { tool in
            Button(tool.label) {
                if let prefix { model.open(tool, for: prefix) }
            }
        }
    }
    
    private func single(_ ids: Set<WinePrefix.ID>) -> WinePrefix? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return model.prefixes.first { $0.id == id }
    }
    
    private func report(_ row: StatusRow) -> some View {
        row.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    }
    
    struct GridCell: View {
        var app: PrefixRow
        var allRows: [PrefixRow]
        @State private var artURL: URL?
        
        @Bindable var model: PrefixesModel
        var body: some View {
            let prefix = app.prefix
            VStack {
                Group {
                    if let artURL {
                        CachedAsyncImage(url: artURL) {phase in
                            if let image = phase.image {
                                image
                                    .resizable()
                            } else if let err = phase.error {
                                // surface error to the user kinda
                                VStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.largeTitle)
                                    Text(err.localizedDescription)
                                        .lineLimit(3)
                                        .multilineTextAlignment(.center)
                                        .font(.caption)
                                }
                                .padding()
                                .foregroundStyle(.secondary)
                            } else {
                                ProgressView() // while image is downloading
                            }
                        }
                    } else {
                        ProgressView() // while fetching art
                    }
                }
                .frame(minWidth: 120, maxWidth: 120, minHeight: 180, maxHeight: 180)
                .background(Color(NSColor.secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    // selection outline
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: model.selectedPrefixes.contains(prefix) ? 4 : 0)
                }
                .onTapGesture {
                    let mod = NSEvent.modifierFlags
                    if mod.contains(.command) {
                        // append to selected prefixes
                        model.selection.insert(prefix.id)
                    } else if mod.contains(.shift) {
                        // im like a swift god kinda
                        if let idx1 = allRows.firstIndex(where: {$0.prefix == model.selectedPrefixes.last}),
                           let idx2 = allRows.firstIndex(where: {$0.prefix == app.prefix}) {
                            let startIdx = min(idx1, idx2)
                            let endIdx = max(idx1, idx2)
                            let slice = Array(allRows[startIdx...endIdx]).map {$0.id}
                            model.selection.formUnion(slice) //merge with current selection
                            
                        }
                    } else {
                        // only select this prefix
                        model.selection = [prefix.id]
                    }
                }
                Text(app.title)
                    .foregroundStyle(prefix.name == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
            .task(priority: .high) {
                // async art fetch
                artURL = await getArt(app.appID)
            }
        }
        
        // get art from steam cdn.
        // TODO: cache the url to better take advantage of that cachedasyncimage?
        private func getArt(_ appId: Int) async -> URL? {
            let body: [String: Any] = [
                "ids": [["appid": appId]],
                "context": ["language": "english", "country_code": "US"],
                "data_request": ["include_assets": true],
            ]
            
            guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {return nil}
            
            var components = URLComponents(string: "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/")!
            components.queryItems = [URLQueryItem(name: "input_json", value: String(decoding: bodyData, as: UTF8.self))]
            
            guard let (data, _) = try? await URLSession.shared.data(from: components.url!) else {return nil}
            
            print(String(decoding: data, as: UTF8.self))
            
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let items = (json["response"] as? [String: Any])?["store_items"] as? [[String: Any]],
                let assets = items.first?["assets"] as? [String: Any],
                let format = assets["asset_url_format"] as? String,
                let file = (assets["library_capsule"] as? String)
                    else { return nil }
            
            print(file)
            
            return URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/"
                       + format.replacingOccurrences(of: "${FILENAME}", with: file))
        }
    }
}
