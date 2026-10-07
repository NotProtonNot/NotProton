import Darwin
import Foundation

enum RunnerRuntime {
    static let selectionFile = ".notproton-runtime"

    static func usesBundledRosetta(in root: URL) -> Bool {
        let selected = try? String(contentsOf: root.appending(path: selectionFile), encoding: .utf8)
        return selected?.trimmingCharacters(in: .whitespacesAndNewlines) == "rosetta"
    }

    static let supportsFEX: Bool = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return false }
        defer { dlclose(handle) }
        // The shipped ARM loader calls this weak import without a null check.
        // On macOS 15 it jumps to address zero before Wine can report an error.
        return dlsym(handle, "posix_spawnattr_set_4k_page_size_np") != nil
    }()

    static func requireSupported(usesFEX: Bool, fexAvailable: Bool = supportsFEX) throws {
        guard !usesFEX || fexAvailable else {
            throw StepFailure(
                step: "Start compatibility tool",
                detail: "This CrossOver FEX build needs macOS 26's 4 KB page-size support. "
                    + "Use CrossOver Preview 20261006 and set up its bundled Rosetta runtime "
                    + "in NotProton. Rebuild existing FEX prefixes with a backup before launching games."
            )
        }
    }
}
