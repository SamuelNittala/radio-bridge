import Foundation
import RadioCore
import Security

enum ClaudeCodeError: LocalizedError {
    case notInstalled
    case tookTooLong
    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Claude Code isn't installed. Install it from claude.com/claude-code to sort songs by mood."
        case .tookTooLong:
            "Claude Code took too long."
        }
    }
}

/// Runs the Claude Code CLI for `ClaudeCodeMoodGuesser`. An app launched from Finder has no
/// shell PATH, so the binary is found at its known install locations. It runs in a fresh empty
/// directory, so no project files or CLAUDE.md are picked up, and with the API-key variables
/// stripped so the token wins.
enum ClaudeCode {
    /// Where `claude` ends up: user install, then Homebrew (Apple silicon, then Intel).
    static let searchPaths = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    /// One run sorts up to 50 songs; a run that takes longer than this is stuck.
    static let timeout: TimeInterval = 180

    static var binary: URL? {
        searchPaths.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A runner for `ClaudeCodeMoodGuesser`: arguments, extra environment, stdin ->
    /// status, stdout, stderr.
    static let run: ClaudeCodeMoodGuesser.Run = { arguments, environment, input in
        guard let binary else { throw ClaudeCodeError.notInstalled }

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // The app's environment plus the given variables, without the API-key vars, which
        // would otherwise take precedence over CLAUDE_CODE_OAUTH_TOKEN.
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        env["ANTHROPIC_API_KEY"] = nil
        env["ANTHROPIC_AUTH_TOKEN"] = nil

        do {
            return try await ProcessRunner.run(binary, arguments, environment: env, directory: workDir,
                                               input: input, timeout: timeout)
        } catch is ProcessRunner.TimedOut {
            throw ClaudeCodeError.tookTooLong
        }
    }
}

enum KeychainError: LocalizedError {
    case failed(String, OSStatus)
    var errorDescription: String? {
        if case .failed(let what, let status) = self { return "Couldn't \(what) the token in the Keychain (\(status))." }
        return nil
    }
}

/// The user's long-lived Claude Code token, from `claude setup-token`, in the login Keychain.
/// It never touches UserDefaults, files, logs or any user-facing text.
enum ClaudeCodeToken {
    static let service = "Radio Bridge"
    static let account = "claude-code-token"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Whether a token is saved. Asks for the item's attributes only, not the secret, so macOS
    /// doesn't ask the user to allow access just to find out.
    static var saved: Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The token itself; reading it can make macOS ask for permission, so only when it is needed.
    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        var status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery.merging([kSecValueData as String: data]) { $1 } as CFDictionary, nil)
        } else if status != errSecSuccess {
            // Can't update it (an old item this build may not change): replace it.
            SecItemDelete(baseQuery as CFDictionary)
            status = SecItemAdd(baseQuery.merging([kSecValueData as String: data]) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.failed("save", status) }
    }

    static func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.failed("remove", status)
        }
    }
}
