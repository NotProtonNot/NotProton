// Winetricks package picker for a prefix, the native stand-in for the zenity
// menus winetricks runs for ProtonTricks. Category, checklist, install. The
// verb list itself comes from WinetricksCatalog, the running from PrefixTools.

import SwiftUI

struct WinetricksView: View {

    let prefix: WinePrefix

    @Environment(PrefixesModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var verbs: [WinetricksVerb] = []
    @State private var loadFailed: String?
    @State private var downloadLabel: String?
    @State private var installing = false
    @State private var category = "dlls"
    @State private var search = ""
    @State private var checked = Set<String>()
    @State private var customExpanded = false
    @State private var customVerbs = ""
    @State private var installed = Set<String>()
    @State private var tail = ""
    @State private var watcher: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure = loadFailed {
                failureView(failure)
            } else if verbs.isEmpty {
                ProgressView {
                    Text(downloadLabel ?? String(localized: "Preparing"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                pickerView
                searchView
                table
                otherVerbs
                if installing { logView }
                footer
            }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 480)
        .task {
            // An earlier tool action's outcome would sit in the footer as if
            // this window produced it.
            model.forgetOutcome()
            await load()
        }
        .onDisappear { watcher?.cancel() }
    }

    private func load() async {
        loadFailed = nil
        downloadLabel = String(localized: "Preparing")
        do {
            let script = try await PrefixTools.winetricksScript { progress in
                Task { @MainActor in downloadLabel = progress.label }
            }
            let text = try await Task.detached {
                try String(contentsOf: script, encoding: .utf8)
            }.value
            let found = await Task.detached { WinetricksCatalog.verbs(in: text) }.value
            verbs = found
            await refreshInstalled()
        } catch {
            loadFailed = (error as? StepFailure)?.detail ?? error.localizedDescription
        }
    }

    private func refreshInstalled() async {
        let found = verbs
        let target = prefix
        installed = await Task.detached {
            WinetricksCatalog.installedVerbs(among: found, in: target)
        }.value
    }

    private func install() {
        let chosen = selectedVerbs
        guard !chosen.isEmpty, !installing else { return }
        installing = true
        tail = ""
        watcher = Task { await watchLog() }
        Task {
            await model.winetricks(chosen, in: prefix)
            watcher?.cancel()
            installing = false
            await refreshInstalled()
        }
    }

    // The launcher writes winetricks' combined output to the prefix root, so
    // tailing it gives the sheet its progress without plumbing pipes around.
    private func watchLog() async {
        let log = prefix.root.appending(path: PrefixTools.winetricksLogName)
        while !Task.isCancelled {
            tail = Self.tail(of: log)
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private static func tail(of log: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? handle.close() }
        let window: UInt64 = 4096
        let size = (try? handle.seekToEnd()) ?? 0
        if size > window { handle.seek(toFileOffset: size - window) }
        let data = (try? handle.read(upToCount: Int(window))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func failureView(_ failure: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(failure)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Retry") { Task { await load() } }
                Button("Close") { dismiss() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Winetricks")
                .font(.title3)
                .bold()
            Text("Which package(s) would you like to install in \(prefix.title)?")
                .foregroundStyle(.secondary)
        }
    }

    private var pickerView: some View {
        HStack(spacing: 12) {
            Picker("Category", selection: $category) {
                ForEach(WinetricksCatalog.categories, id: \.self) { name in
                    Text(categoryLabel(name)).tag(name)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .disabled(installing)
            Spacer()
        }
    }

    private var searchView: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .disabled(installing)
        }
        .padding(EdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 6))
        .background(.bar, in: RoundedRectangle(cornerRadius: 5))
    }

    private struct Row: Identifiable {
        let verb: WinetricksVerb
        let installed: Bool
        var id: String { verb.name }
    }

    private var rows: [Row] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return verbs
            .filter { $0.category == category }
            .filter { verb in
                query.isEmpty
                    || verb.name.lowercased().contains(query)
                    || verb.title.lowercased().contains(query)
                    || verb.publisher.lowercased().contains(query)
            }
            .map { Row(verb: $0, installed: installed.contains($0.name)) }
    }

    private var table: some View {
        Table(rows) {
            TableColumn("") { row in
                Toggle("", isOn: check(row.verb))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(row.verb.isManualDownload || installing)
                    .accessibilityLabel(row.verb.title.isEmpty ? row.verb.name : row.verb.title)
            }
            .width(22)

            TableColumn("Package") { row in
                Text(row.verb.name).help(row.verb.title.isEmpty ? row.verb.name : row.verb.title)
            }
            .width(min: 60, ideal: 110)

            TableColumn("Title") { row in
                Text(row.verb.title).lineLimit(1).help(row.verb.title)
            }
            .width(min: 80, ideal: 230)

            TableColumn("Publisher") { row in
                Text(row.verb.publisher)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(row.verb.publisher)
            }
            .width(min: 40, ideal: 110)

            TableColumn("Year") { row in
                Text(row.verb.year)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 36, ideal: 44)

            TableColumn("Media") { row in
                Text(mediaLabel(row.verb))
                    .foregroundStyle(.secondary)
                    .help(manualHelp(row.verb) ?? "")
            }
            .width(min: 40, ideal: 92)

            TableColumn("Status") { row in
                if row.installed {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .width(min: 40, ideal: 84)
        }
    }

    private var otherVerbs: some View {
        DisclosureGroup("Other verbs", isExpanded: $customExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("vcrun2022 corefonts", text: $customVerbs)
                    .onSubmit { install() }
                    .disabled(installing)
                Text("Enter the Winetricks verbs to install in \(prefix.title), separated by spaces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .font(.callout)
        .disabled(installing)
    }

    private var logView: some View {
        ScrollView {
            Text(verbatim: String(tail.split(separator: "\n").suffix(10).joined(separator: "\n")))
                .font(Font.system(size: 11).monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(height: 110)
        .padding(8)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            if installing {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
                Text("Installing…")
                    .foregroundStyle(.secondary)
            } else if let failed = model.failure {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                Text(failed)
                    .lineLimit(3)
            } else if let outcome = model.outcome {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                Text(outcome)
                    .lineLimit(3)
            } else if let clash = clash {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Text("\(clash.a) conflicts with \(clash.b).")
                    .foregroundStyle(.orange)
            } else {
                Text(summary ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            if !installing {
                if PrefixTools.hasWinetricksLog(for: prefix) {
                    Button("Show Log") { PrefixTools.openWinetricksLog(for: prefix) }
                        .disabled(selectedVerbs.isEmpty)
                }
                Button("Install") { install() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedVerbs.isEmpty)
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func check(_ verb: WinetricksVerb) -> Binding<Bool> {
        Binding(
            get: { checked.contains(verb.name) },
            set: { on in
                if on { checked.insert(verb.name) } else { checked.remove(verb.name) }
            }
        )
    }

    private var selectedVerbs: [String] {
        var names = verbs.filter { checked.contains($0.name) }.map(\.name)
        for name in PrefixTools.winetricksVerbs(customVerbs) where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    private var summary: String? {
        let names = selectedVerbs
        guard !names.isEmpty else { return nil }
        return String(localized: "\(names.count) selected: \(names.joined(separator: " "))")
    }

    private var clash: (a: String, b: String)? {
        for verb in verbs where checked.contains(verb.name) {
            for other in verb.conflicts
            where other != verb.name && (installed.contains(other) || checked.contains(other)) {
                return (verb.name, other)
            }
        }
        return nil
    }

    private func categoryLabel(_ category: String) -> String {
        switch category {
        case "dlls": String(localized: "DLLs")
        case "fonts": String(localized: "Fonts")
        default: String(localized: "Settings")
        }
    }

    private func mediaLabel(_ verb: WinetricksVerb) -> String {
        switch verb.media {
        case "download": String(localized: "Download")
        case "manual_download": String(localized: "Manual download")
        default: ""
        }
    }

    private func manualHelp(_ verb: WinetricksVerb) -> String? {
        verb.isManualDownload ? String(localized: "This package needs its files downloaded by hand, which NotProton cannot do.") : nil
    }
}
