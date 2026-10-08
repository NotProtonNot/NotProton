import Foundation
import Observation

/// Checks the access installation needs; it does not inspect or modify the TCC database.
@MainActor
@Observable
final class SteamWriteAccess {
    enum State: Equatable {
        case unchecked
        case ready
        case blocked(String)
    }

    private(set) var state: State = .unchecked
    var isReady: Bool { state == .ready }

    func check(app: URL = SupportPaths.Steam.app,
               probe: (URL) throws -> Void = SteamInstaller.assertBundleIsWritable) {
        do {
            try probe(app)
            state = .ready
        } catch let refusal as WriteRefused {
            state = .blocked(refusal.remedy.advice)
        } catch {
            state = .blocked(error.localizedDescription)
        }
    }
}
