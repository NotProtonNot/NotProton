import SwiftUI
import AppKit

struct HelpView: View {
    @Environment(SystemStatus.self) private var status
    @Binding var pane: Pane
    @State private var query = ""
    @State private var copied = false
    @State private var showReport = false
    @State private var report = ""

    private var topics: [HelpTopic] { HelpTopic.all.filter { $0.matches(query) } }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(GuideCopy.text("A little guidance, when you need it"))
                        .font(.title2.weight(.semibold))
                    Text(GuideCopy.text("Start with the setup guide. For game issues, check one setting at a time and keep a backup."))
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(GuideCopy.text("Open Status")) { pane = .status }
                        Button(GuideCopy.text("Game environments")) { pane = .prefixes }
                        Button(GuideCopy.text("Backups")) { pane = .backups }
                    }.padding(.top, 4)
                }.padding(.vertical, 6)
            }
            Section(GuideCopy.text("Common questions")) {
                if topics.isEmpty {
                    Text(GuideCopy.text("No matching help. Try a shorter search, such as controller, Steam or saves."))
                        .foregroundStyle(.secondary)
                }
                ForEach(topics) { topic in
                    DisclosureGroup(GuideCopy.text(topic.title)) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(GuideCopy.text(topic.body)).textSelection(.enabled)
                            if let url = topic.url { Link(GuideCopy.text("More information"), destination: url) }
                        }.padding(.vertical, 6)
                    }.disclosureGroupStyle(WholeRowDisclosureStyle())
                }
            }
            Section("CrossOver") {
                runtime("CrossOver", state: "Supported profiles",
                        detail: "Paid runtime. Verified Stable and Preview profiles are listed in Status. CrossOver activation is required; NotProton itself is free.",
                        url: "https://www.codeweavers.com/crossover")
            }
            Section(GuideCopy.text("Share a useful support summary")) {
                Text(GuideCopy.text("Preview a short summary before copying it. It includes app/system versions and component status, without account data, paths, license data or raw logs. Nothing is uploaded."))
                    .foregroundStyle(.secondary)
                Button(GuideCopy.text("Preview support summary…")) {
                    report = SupportReport.make(snapshot: status.snapshot)
                    copied = false
                    showReport = true
                }
                Button(GuideCopy.text("Reveal local log…")) {
                    NSWorkspace.shared.activateFileViewerSelecting([AppLog.file])
                }
                Text(GuideCopy.text("The raw local log may contain private paths or error details. Review it before sharing."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(GuideCopy.text("Help"))
        .searchable(text: $query, prompt: GuideCopy.text("Search common questions"))
        .sheet(isPresented: $showReport) {
            VStack(alignment: .leading, spacing: 16) {
                Text(GuideCopy.text("Support summary")).font(.title2.weight(.semibold))
                ScrollView {
                    Text(report).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Text(GuideCopy.text(copied ? "Copied" : "Nothing is uploaded."))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(GuideCopy.text("Close")) { showReport = false }
                        .keyboardShortcut(.cancelAction)
                    Button(GuideCopy.text("Copy summary")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                        copied = true
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 600, height: 480)
        }
    }

    private func runtime(_ name: String, state: String, detail: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                Text(GuideCopy.text(state)).font(.callout).foregroundStyle(.secondary)
            }
            Text(GuideCopy.text(detail)).foregroundStyle(.secondary)
            Link(GuideCopy.text("Official project"), destination: URL(string: url)!)
        }.padding(.vertical, 4)
    }
}
