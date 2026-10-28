import AppKit
import RadioCore

/// Music.app through Apple events. Runs in-process, so a status check takes milliseconds.
final class MusicAppPlayer: MusicPlayer {
    static let bundleID = "com.apple.Music"

    private let statusScript: NSAppleScript = {
        let script = NSAppleScript(source: """
            tell application "Music"
              set s to player state as text
              if s is "stopped" then return {s}
              set t to current track
              return {s, persistent ID of t, name of t, duration of t, player position, favorited of t}
            end tell
            """)!
        script.compileAndReturnError(nil)
        return script
    }()

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    func status() -> PlayerStatus {
        // "tell application" would launch Music; don't.
        guard isRunning else { return .stopped }
        var error: NSDictionary?
        let result = statusScript.executeAndReturnError(&error)
        guard error == nil, result.numberOfItems >= 6 else { return .stopped }
        let state: PlayerState = switch result.atIndex(1)?.stringValue {
        case "playing": .playing
        case "paused": .paused
        default: .stopped
        }
        return PlayerStatus(
            state: state,
            pid: result.atIndex(2)?.stringValue ?? "",
            name: result.atIndex(3)?.stringValue ?? "",
            duration: result.atIndex(4)?.doubleValue ?? 0,
            position: result.atIndex(5)?.doubleValue ?? 0,
            favorited: result.atIndex(6)?.booleanValue ?? false)
    }

    func nextTrack() { run("next track") }
    func play() { run("play") }
    func pause() { run("pause") }

    private func run(_ command: String) {
        NSAppleScript(source: "tell application \"Music\" to \(command)")?.executeAndReturnError(nil)
    }
}

enum ShortcutError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Queues songs with the user's shortcut: Get URLs from Input -> Add to Playing Next.
/// Shortcuts can add catalog songs to Music's queue without bringing Music forward;
/// given a link, it adds exactly that song, at the end of Playing Next.
struct ShortcutQueuer: TrackQueuer {
    var name: String
    /// Shortcut with the single action "Clear Playing Next".
    var clearName: String

    func queue(_ link: URL) async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString).txt")
        try link.absoluteString.write(to: input, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: input) }
        let (status, _, err) = try await Self.run(["run", name, "-i", input.path])
        guard status == 0 else {
            throw ShortcutError.failed(err.isEmpty ? "The '\(name)' shortcut failed." : err)
        }
    }

    func clear() async throws {
        let (status, _, err) = try await Self.run(["run", clearName])
        guard status == 0 else {
            throw ShortcutError.failed(err.isEmpty ? "The '\(clearName)' shortcut failed." : err)
        }
    }

    /// Which of `names` are not among the user's shortcuts.
    static func missing(_ names: [String]) async -> [String] {
        guard let (status, out, _) = try? await run(["list"]), status == 0 else { return names }
        let existing = Set(out.split(separator: "\n").map(String.init))
        return names.filter { !existing.contains($0) }
    }

    private static func run(_ arguments: [String]) async throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read while it runs, so a long output can't fill the pipe and stall it.
        return await Task.detached {
            let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, o, e.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }
}
