import SwiftUI

struct SettingsView: View {
    @Environment(SystemStatus.self) private var status
    @Binding var showGuide: Bool

    var body: some View {
        Form {
            Section(GuideCopy.text("Getting started")) {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.title2).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(GuideCopy.text("Setup guide")).font(.headline)
                        Text(GuideCopy.text("Walk through setup again. Your installation is checked, not reset."))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(GuideCopy.text("Open guide")) { showGuide = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(status.snapshot == nil || !status.isIdle)
                }.padding(.vertical, 8)
            }
            Section(GuideCopy.text("About")) {
                LabeledContent("NotProton", value: AppVersion.bundled)
                Text(GuideCopy.text("The guide follows macOS Reduce Motion. All guidance is in English."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(GuideCopy.text("Settings"))
    }
}
