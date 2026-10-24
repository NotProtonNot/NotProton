// Winetricks package picker for a prefix, the native stand-in for the zenity
// menus winetricks runs for ProtonTricks. Category, checklist, install. The
// verb list itself comes from WinetricksCatalog, the running from PrefixTools.

import AppKit
import SwiftUI

struct WinetricksView: View {

    let prefix: WinePrefix

    @Environment(PrefixesModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var verbs: [WinetricksVerb] = []
    @State private var loadFailed: String?
    @State private var downloadLabel: String?
    @State private var installing = false
    @State private var ranOnce = false
    @State private var category = "dlls"
    @State private var search = ""
    @State private var checked = Set<String>()
    @State private var selection = Set<String>()
    @State private var showingOther = false
    @State private var customVerbs = ""
    @State private var installed = Set<String>()
    @State private var tail = ""
    @State private var watcher: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure = loadFailed {
                failureView(failure)
            } else if verbs.isEmpty {
                ProgressView {
                    Text(downloadLabel ?? String(localized: "Preparing"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                Text(verbatim: "Winetricks")
                    .font(.headline)
                    .padding([.top, .horizontal], 20)
                controls
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                table
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                if installing {
                    logView
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                }
                footer
                    .padding(20)
            }
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 600)
        .interactiveDismissDisabled(installing)
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
            verbs = await Task.detached { WinetricksCatalog.verbs(in: text) }.value
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
        ranOnce = true
        tail = ""
        watcher = Task { await watchLog() }
        Task {
            await model.winetricks(chosen, in: prefix)
            watcher?.cancel()
            installing = false
            if model.failure == nil {
                checked.removeAll()
                customVerbs = ""
            }
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
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Retry") { Task { await load() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Category", selection: $category) {
                ForEach(WinetricksCatalog.categories, id: \.self) { name in
                    Text(categoryLabel(name)).tag(name)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 12)
            SearchField(text: $search, prompt: String(localized: "Search"))
                .frame(width: 220)
        }
        .disabled(installing)
    }

    private struct Row: Identifiable {
        let verb: WinetricksVerb
        let installed: Bool
        var id: String { verb.name }
        var name: String { verb.name }
        var title: String { verb.title }
        var publisher: String { verb.publisher }
        var year: String { verb.year }
    }

    @State private var sortOrder = [KeyPathComparator(\Row.name)]

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
            .sorted(using: sortOrder)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Package", value: \.name) { row in
                Toggle(isOn: check(row.verb)) {
                    CellText(text: row.verb.name)
                }
                .toggleStyle(.checkbox)
                .disabled(row.verb.isManualDownload || installing)
            }
            .width(min: 120, ideal: 160)

            TableColumn("Description", value: \.title) { row in
                CellText(text: row.verb.title)
            }
            .width(min: 160, ideal: 300)

            TableColumn("Publisher", value: \.publisher) { row in
                CellText(text: row.verb.publisher)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)

            TableColumn("Year", value: \.year) { row in
                CellText(text: row.verb.year)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 44, max: 56)

            TableColumn("Status") { row in
                if row.installed {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                } else if row.verb.isManualDownload {
                    Text("Manual download")
                        .foregroundStyle(.tertiary)
                        .help("This package needs its files downloaded by hand, which NotProton cannot do.")
                }
            }
            .width(min: 80, ideal: 110)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .onKeyPress(.space) {
            toggleSelected()
            return .handled
        }
    }

    // Space flips every selected row at once, the way a Finder-style
    // checklist does. Rows that cannot be installed are left alone.
    private func toggleSelected() {
        guard !installing else { return }
        let targets = verbs.filter { selection.contains($0.name) && !$0.isManualDownload }
        guard !targets.isEmpty else { return }
        let turnOn = targets.contains { !checked.contains($0.name) }
        for verb in targets {
            if turnOn { checked.insert(verb.name) } else { checked.remove(verb.name) }
        }
    }

    private var logView: some View {
        ScrollView {
            Text(verbatim: String(tail.split(separator: "\n").suffix(10).joined(separator: "\n")))
                .font(Font.system(size: 11).monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)
        }
        .frame(height: 110)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color(nsColor: .separatorColor)))
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            Button("Other Verbs…") { showingOther = true }
                .disabled(installing)
                .popover(isPresented: $showingOther, arrowEdge: .top) { otherVerbs }

            status
                .padding(.leading, 4)

            Spacer(minLength: 12)

            Button(ranOnce ? String(localized: "Done") : String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(installing)
            Button("Install") { install() }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedVerbs.isEmpty || installing)
        }
    }

    @ViewBuilder
    private var status: some View {
        if installing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing…").foregroundStyle(.secondary)
            }
        } else if let failed = model.failure {
            statusLine(failed, symbol: "xmark.circle.fill", color: .red, showLog: true)
        } else if let outcome = model.outcome {
            statusLine(outcome, symbol: "checkmark.circle.fill", color: .green, showLog: true)
        } else if let clash {
            statusLine(
                String(localized: "\(clash.a) conflicts with \(clash.b)."),
                symbol: "exclamationmark.triangle.fill", color: .orange, showLog: false)
        } else if let summary {
            Text(summary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(summary)
        }
    }

    private func statusLine(_ text: String, symbol: String, color: Color, showLog: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text)
                .lineLimit(2)
                .truncationMode(.tail)
                .help(text)
            if showLog, PrefixTools.hasWinetricksLog(for: prefix) {
                Button("Show Log") { PrefixTools.openWinetricksLog(for: prefix) }
                    .buttonStyle(.link)
            }
        }
    }

    private var otherVerbs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Other Verbs")
                .font(.headline)
            TextField("vcrun2022 corefonts", text: $customVerbs)
                .frame(width: 280)
                .onSubmit { showingOther = false }
            Text("Enter the Winetricks verbs to install in \(prefix.title), separated by spaces.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
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
}

// A tooltip only where the column cuts the text off. One on every cell would
// pop up over text that is already fully on screen.
private struct CellText: View {
    let text: String
    @State private var width: CGFloat = 0

    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .help(TextWidth.of(text) > width ? text : "")
    }
}

// SwiftUI's searchable needs a toolbar, which a sheet does not have.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
