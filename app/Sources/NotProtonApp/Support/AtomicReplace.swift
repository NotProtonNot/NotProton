// Simple logic

import Foundation

func atomicReplace(_ destination: URL, from source: URL, step: String) throws {
    let fm = FileManager.default
    let directory = destination.deletingLastPathComponent()
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)

    let staging = directory.appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString)")
    defer { try? fm.removeItem(at: staging) }
    try fm.copyItem(at: source, to: staging)

    if rename(
        staging.path(percentEncoded: false), destination.path(percentEncoded: false)
    ) != 0 {
        let code = errno
        if code == EACCES || code == EPERM {
            throw WriteRefused(path: destination.path(percentEncoded: false))
        }
        let reason = String(cString: strerror(code))
        throw StepFailure(
            step: step,
            detail: L10n.tr("Replacing \(destination.path(percentEncoded: false)) failed. \(reason)")
        )
    }
}

func atomicReplace(_ destination: URL, with data: Data, step: String) throws {
    let fm = FileManager.default
    let directory = destination.deletingLastPathComponent()
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)

    let staging = directory.appending(path: ".\(destination.lastPathComponent).new")
    try? fm.removeItem(at: staging)

    do {
        try data.write(to: staging)
    } catch {
        throw StepFailure(
            step: step,
            detail: L10n.tr("\(staging.path(percentEncoded: false)) could not be written. ")
                + error.localizedDescription
        )
    }

    if rename(
        staging.path(percentEncoded: false), destination.path(percentEncoded: false)
    ) != 0 {
        let reason = String(cString: strerror(errno))
        try? fm.removeItem(at: staging)
        throw StepFailure(
            step: step,
            detail: L10n.tr("Replacing \(destination.path(percentEncoded: false)) failed. \(reason)")
        )
    }
}
