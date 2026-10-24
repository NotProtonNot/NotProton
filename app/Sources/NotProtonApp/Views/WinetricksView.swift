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
    @State private var installed = Set<String>()
    @State private var ran = Set<String>()
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
            let target = prefix
            verbs = await Task.detached {
                let is32Bit = PrefixStore.arch(of: target) == .i386
                return WinetricksCatalog.verbs(in: text)
                    .filter { WinetricksCatalog.isOffered($0, prefixIs32Bit: is32Bit) }
            }.value
            await refreshInstalled()
        } catch {
            loadFailed = (error as? StepFailure)?.detail ?? error.localizedDescription
        }
    }

    private func refreshInstalled() async {
        let found = verbs
        let target = prefix
        (installed, ran) = await Task.detached {
            (WinetricksCatalog.installedVerbs(among: found, in: target),
             WinetricksCatalog.ranVerbs(in: target))
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
            if model.failure == nil { checked.removeAll() }
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
            Picker("Sort By", selection: $sort) {
                ForEach(SortKey.allCases, id: \.self) { key in
                    Text(key.label).tag(key)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            SearchField(text: $search, prompt: String(localized: "Search"))
                .frame(width: 200)
        }
        .disabled(installing)
    }

    private enum SortKey: CaseIterable {
        case name, publisher, year

        var label: String {
            switch self {
            case .name: String(localized: "Name")
            case .publisher: String(localized: "Publisher")
            case .year: String(localized: "Year")
            }
        }
    }

    @State private var sort = SortKey.name

    private var rows: [WinetricksVerb] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = verbs
            .filter { $0.category == category }
            .filter { verb in
                query.isEmpty
                    || verb.name.lowercased().contains(query)
                    || verb.title.lowercased().contains(query)
                    || verb.publisher.lowercased().contains(query)
            }
        // Ties fall back to the name so the order never shuffles.
        func key(_ verb: WinetricksVerb) -> String {
            switch sort {
            case .name: ""
            case .publisher: verb.publisher.lowercased()
            case .year: verb.year
            }
        }
        return shown.sorted {
            let (a, b) = (key($0), key($1))
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a < b
        }
    }

    private var table: some View {
        List(rows, selection: $selection) { verb in
            row(verb)
                .padding(.vertical, 4)
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .onKeyPress(.space) {
            toggleSelected()
            return .handled
        }
    }

    // The whole row is the checkbox's label, so a click anywhere on it ticks
    // the package, as in any Mac checklist.
    private func row(_ verb: WinetricksVerb) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: check(verb)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: verb.title.isEmpty ? verb.name : readable(verb.title))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if !verb.title.isEmpty {
                            Text(verbatim: verb.name).foregroundStyle(.secondary)
                        }
                        status(verb)
                    }
                    .font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.checkbox)
            .disabled(verb.isManualDownload || installing)

            VStack(alignment: .trailing, spacing: 2) {
                if !verb.publisher.isEmpty {
                    Text(verbatim: publisher(verb))
                }
                if !verb.year.isEmpty {
                    Text(verbatim: verb.year).monospacedDigit()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
        }
    }

    // allcodecs and a few others credit "various".
    private func publisher(_ verb: WinetricksVerb) -> String {
        verb.publisher.prefix(1).uppercased() + verb.publisher.dropFirst()
    }

    // Descriptions like vcrun2022's list their DLLs as one comma-run with no
    // spaces, which can only wrap mid-word.
    private func readable(_ title: String) -> String {
        title.replacingOccurrences(of: #",(?=\S)"#, with: ", ", options: .regularExpression)
    }

    @ViewBuilder
    private func status(_ verb: WinetricksVerb) -> some View {
        if installed.contains(verb.name) {
            Label {
                Text("Installed").foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else if verb.isManualDownload {
            Text("Manual download")
                .foregroundStyle(.tertiary)
                .help("This package needs its files downloaded by hand, which NotProton cannot do.")
        } else if verb.wined3dOnly {
            Text("wined3d only")
                .foregroundStyle(.secondary)
                .help("Only games that run on wined3d use this setting. Games on D3DMetal, DXMT or DXVK ignore it.")
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

    private var dismissLabel: String {
        if installing { return String(localized: "Close") }
        return ranOnce ? String(localized: "Done") : String(localized: "Cancel")
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            status

            Spacer(minLength: 12)

            // Closing mid-install leaves it running. The install's Task is not
            // the sheet's, and the Prefixes window shows its spinner and outcome.
            Button(dismissLabel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .help(installing ? String(localized: "Winetricks keeps running. The Prefixes window shows when it is done.") : "")
            Button("Install") { install() }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedVerbs.isEmpty || installing || clash != nil)
        }
    }

    @ViewBuilder
    private var status: some View {
        if installing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing…").foregroundStyle(.secondary)
            }
        } else if let clash {
            statusLine(
                String(localized: "\(clash.verb) conflicts with \(clash.with)."),
                symbol: "exclamationmark.triangle.fill", color: .orange, showLog: false)
        } else if checked.isEmpty, let failed = model.failure {
            statusLine(failed, symbol: "xmark.circle.fill", color: .red, showLog: true)
        } else if checked.isEmpty, let outcome = model.outcome {
            statusLine(outcome, symbol: "checkmark.circle.fill", color: .green, showLog: true)
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

    private func check(_ verb: WinetricksVerb) -> Binding<Bool> {
        Binding(
            get: { checked.contains(verb.name) },
            set: { on in
                if on { checked.insert(verb.name) } else { checked.remove(verb.name) }
            }
        )
    }

    private var selectedVerbs: [String] {
        verbs.filter { checked.contains($0.name) }.map(\.name)
    }

    private var summary: String? {
        let names = selectedVerbs
        guard !names.isEmpty else { return nil }
        return String(localized: "\(names.count) selected: \(names.joined(separator: " "))")
    }

    // winetricks stops on a conflict, so Install stays off while there is one.
    private var clash: (verb: String, with: String)? {
        WinetricksCatalog.clash(among: verbs, checked: checked, ran: ran)
    }

    private func categoryLabel(_ category: String) -> String {
        switch category {
        case "dlls": String(localized: "DLLs")
        case "fonts": String(localized: "Fonts")
        default: String(localized: "Settings")
        }
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
