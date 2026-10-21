import AppKit

// A rebuild started from Play runs while Steam shows the game as running, with nothing
// else on screen saying why it has not started. The Compatibility page shows its own
// progress, so only the run script asks for this.
enum RebuildProgressCommand {
    static let environmentKey = "NOTPROTON_REBUILD_WINDOW"

    static var requested: Bool { ProcessInfo.processInfo.environment[environmentKey] == "1" }

    // Never returns. The rebuild runs off the main thread, which AppKit needs for the window.
    static func run(_ arguments: [String]) -> Never {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let window = RebuildProgressWindow()
            DispatchQueue.main.async { MainActor.assumeIsolated { window.present() } }
            Thread.detachNewThread {
                var code: Int32 = 0
                do {
                    try RebuildPrefixCommand.run(arguments, observe: { name, phase in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { window.show(game: name, phase: phase) }
                        }
                    })
                } catch {
                    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                    code = 1
                }
                DispatchQueue.main.async { exit(code) }
            }
            app.run()
        }
        exit(1)
    }
}

// Laid out like the alert that asked for the rebuild, so the one reads as following the other.
@MainActor
final class RebuildProgressWindow {
    private static let width: CGFloat = 440
    private static let textWidth: CGFloat = width - 20 - 64 - 16 - 20

    private let panel: NSPanel
    private let message = NSTextField(wrappingLabelWithString: "")
    private let phase = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                        styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = String(localized: "Rebuilding the prefix")
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        // macOS may refuse to activate a background helper while Steam is in front, and a
        // panel that hides on deactivate then never shows.
        panel.hidesOnDeactivate = false

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        message.font = .systemFont(ofSize: NSFont.systemFontSize)
        message.preferredMaxLayoutWidth = Self.textWidth
        message.maximumNumberOfLines = 3
        message.lineBreakMode = .byWordWrapping
        message.cell?.truncatesLastVisibleLine = true
        phase.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        phase.textColor = .secondaryLabelColor
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)

        let text = NSStackView(views: [message, bar, phase])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 8
        text.setCustomSpacing(12, after: message)
        let content = NSView()
        for view in [icon, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.width),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            text.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            bar.widthAnchor.constraint(equalTo: text.widthAnchor),
            message.widthAnchor.constraint(equalTo: text.widthAnchor),
            content.bottomAnchor.constraint(greaterThanOrEqualTo: icon.bottomAnchor, constant: 20),
            content.bottomAnchor.constraint(greaterThanOrEqualTo: text.bottomAnchor, constant: 20),
        ])
        panel.contentView = content
        show(game: nil, phase: .settingUp)
        panel.center()
    }

    // Ordering the panel front before the application has finished launching leaves it
    // off screen, so this waits for the run loop.
    func present() {
        panel.orderFrontRegardless()
        NSApp.activate()
    }

    func show(game name: String?, phase current: RebuildPhase) {
        message.stringValue = name.map {
            String(localized: "NotProton is rebuilding the prefix for \($0).")
        } ?? String(localized: "NotProton is rebuilding this game's prefix.")
        phase.stringValue = switch current {
        case .settingUp: String(localized: "Rebuilding…")
        case .copying: String(localized: "Copying your files…")
        case .finishing: String(localized: "Finishing…")
        }
        bar.setAccessibilityLabel(phase.stringValue)
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
    }
}
