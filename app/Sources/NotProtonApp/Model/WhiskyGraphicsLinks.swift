import Foundation

// GPTK's unix bridges must resolve through lib/external: their @loader_path
// rpath finds D3DMetal.framework there. cp -L isolates the runtime copy but
// flattens these aliases, so restore only the known, byte-identical bridges.
enum WhiskyGraphicsLinks {
    static let names = ["d3d10.so", "d3d11.so", "d3d12.so", "dxgi.so"]
    private static let optionalNames = ["nvapi.so", "nvapi64.so", "nvngx.so", "d3dmt.so", "dxgm.so"]
    static let destination = "../../external/libd3dshared.dylib"

    private static func payload(in root: URL) -> URL? {
        let library = root.appending(path: "lib/external/libd3dshared.dylib")
        let framework = root.appending(path: "lib/external/D3DMetal.framework/D3DMetal")
        guard FileManager.default.fileExists(atPath: library.path),
              FileManager.default.fileExists(atPath: framework.path) else { return nil }
        return library
    }

    private static func bridgeNames(in root: URL) -> [String] {
        names + optionalNames.filter { name in
            let file = root.appending(path: "lib/wine/x86_64-unix/\(name)")
            return FileManager.default.fileExists(atPath: file.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil
        }
    }

    private static func isInternal(_ file: URL, root: URL) -> Bool {
        file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    }

    private static func isCorrect(_ file: URL, root: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == destination
            && isInternal(file, root: root)
    }

    static func verify(in root: URL) -> [String] {
        guard let library = payload(in: root) else { return [] }
        guard isInternal(library, root: root) else {
            return [String(localized: "D3DMetal's shared library points outside the runtime copy.")]
        }
        return bridgeNames(in: root).compactMap { name in
            let file = root.appending(path: "lib/wine/x86_64-unix/\(name)")
            return isCorrect(file, root: root) ? nil
                : String(localized: "\(name) is not the D3DMetal runtime link.")
        }
    }

    static func repair(in root: URL) throws -> [String] {
        guard let library = payload(in: root) else { return [] }
        guard isInternal(library, root: root) else {
            throw StepFailure(step: RunnerPatcher.step,
                detail: String(localized: "D3DMetal's shared library points outside the runtime copy."))
        }
        let directory = root.appending(path: "lib/wine/x86_64-unix")
        guard isInternal(directory, root: root) else {
            throw StepFailure(step: RunnerPatcher.step,
                detail: String(localized: "The D3DMetal bridge directory points outside the runtime copy."))
        }
        let expected = try Digest.sha256(of: library)
        let files = bridgeNames(in: root).map { root.appending(path: "lib/wine/x86_64-unix/\($0)") }
            .filter { !isCorrect($0, root: root) }
        // Validate the whole set before changing any entry. Unexpected payloads
        // belong to the user/runtime and must not be silently replaced.
        for file in files {
            guard Digest.sha256IfPresent(file) == expected else {
                throw StepFailure(step: RunnerPatcher.step,
                    detail: String(localized: "\(file.lastPathComponent) does not match the D3DMetal runtime library."))
            }
        }
        for file in files {
            try RunnerPatcher.keepClean(file)
            let staging = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.createSymbolicLink(atPath: staging.path, withDestinationPath: destination)
            guard rename(staging.path, file.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
        }
        return files.map(\.lastPathComponent)
    }
}
