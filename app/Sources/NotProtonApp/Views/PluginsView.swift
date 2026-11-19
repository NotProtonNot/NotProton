import SwiftUI

struct PluginsView: View {

    @Environment(PluginsModel.self) private var model
    @State private var selection: PluginFile.ID?

    var body: some View {
        Group {
            if !model.hasLoaded {
                ProgressView("Looking for plugins")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.plugins.isEmpty {
                ContentUnavailableView {
                    Label("No Plugins", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Add a plugin by putting its .conf file in the plugins folder.")
                } actions: {
                    Button("Open Plugins Folder") { model.openFolder() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .navigationTitle("Plugins")
        .navigationSubtitle(summary)
        .safeAreaInset(edge: .bottom) {
            if let failure = model.failure {
                report(StatusRow(title: String(localized: "Failed"), value: failure, tone: .bad))
            } else if let outcome = model.outcome {
                report(StatusRow(title: String(localized: "Done"), value: outcome, tone: .ok))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) { strip }
        }
        .task { await model.load() }
        .onChange(of: model.plugins) { _, kept in
            if let id = selection, !kept.contains(where: { $0.id == id }) { selection = nil }
        }
        .confirmationDialog(
            String(localized: "Move “\(model.pendingRemoval?.title ?? "")” to the Trash?"),
            isPresented: asking,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                guard let target = model.pendingRemoval else { return }
                model.pendingRemoval = nil
                Task { await model.remove(target) }
            }
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Its .conf file goes to the Trash, with the files it requires from the plugins folder. Games stop loading it from their next launch.")
        }
    }

    private var summary: String {
        switch model.plugins.count {
        case 0: ""
        case 1: String(localized: "1 plugin")
        default: String(localized: "\(model.plugins.count) plugins")
        }
    }

    private var selected: PluginFile? {
        model.plugins.first { $0.id == selection }
    }

    private var asking: Binding<Bool> {
        Binding(
            get: { model.pendingRemoval != nil },
            set: { shown in if !shown { model.pendingRemoval = nil } }
        )
    }

    @ViewBuilder
    private var strip: some View {
        Button("Reveal in Finder", systemImage: "folder") {
            if let file = selected { model.reveal(file) }
        }
        .disabled(selected == nil)
        .help("Show the selected plugin in the Finder.")

        Button("Delete", systemImage: "trash") {
            if let file = selected { model.pendingRemoval = file }
        }
        .disabled(selected == nil || model.isLoading)
        .help("Move the selected plugin to the Trash.")

        Button("Open Plugins Folder", systemImage: "folder.badge.plus") {
            model.openFolder()
        }
        .help("Open the folder NotProton reads plugins from.")

        Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await model.load() }
        }
        .disabled(model.isLoading)
        .help("List the plugins again.")
    }

    private var table: some View {
        Table(model.plugins, selection: $selection) {
            TableColumn("Plugin") { file in
                Text(file.title).help(file.records.map(\.id).joined(separator: ", "))
            }
            .width(min: 80, ideal: 200)

            TableColumn("File") { file in
                Text(file.id).foregroundStyle(.secondary).help(file.url.path(percentEncoded: false))
            }
            .width(min: 60, ideal: 160)

            TableColumn("Games") { file in
                Text(file.apps.isEmpty ? String(localized: "All games") : file.apps.joined(separator: ", "))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 110)

            TableColumn("Status") { file in
                if let missing = model.missing(file) {
                    Text("Missing \(missing)").foregroundStyle(.red).help(missing)
                } else {
                    Text("Ready").foregroundStyle(.secondary)
                }
            }
            .width(min: 60, ideal: 160)
        }
        .contextMenu(forSelectionType: PluginFile.ID.self) { ids in
            if let id = ids.first, ids.count == 1, let file = model.plugins.first(where: { $0.id == id }) {
                Button("Reveal in Finder") { model.reveal(file) }
                Divider()
                Button("Delete", role: .destructive) { model.pendingRemoval = file }
                    .disabled(model.isLoading)
            }
        }
        .onDeleteCommand {
            if let file = selected { model.pendingRemoval = file }
        }
    }

    private func report(_ row: StatusRow) -> some View {
        row.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    }
}
