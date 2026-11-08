import Foundation

/// Guesses a mood for each song. videoId -> mood; songs it can't place are left out.
public protocol MoodGuesser: Sendable {
    func moods(for songs: [Song]) async throws -> [String: Mood]
}

public struct MoodGuessError: LocalizedError, Equatable {
    /// A message safe to show the user. Never contains the token.
    public var message: String
    public var errorDescription: String? { message }
}

/// Asks the Claude Code CLI (`claude -p`) which mood each song fits, using the user's
/// long-lived token from `claude setup-token`. There is no official Swift SDK, and the
/// token works with the CLI rather than the raw API.
///
/// The CLI is run through an injected runner, so tests never start a process; the app
/// supplies the real runner (finds the `claude` binary, runs it in a temp directory).
public struct ClaudeCodeMoodGuesser: MoodGuesser {
    /// Runs the CLI: arguments, extra environment, stdin -> exit status, stdout, stderr.
    public typealias Run = @Sendable (_ arguments: [String], _ environment: [String: String], _ input: Data)
        async throws -> (status: Int32, output: Data, error: Data)

    /// Larger inputs are split; one call per 50 songs.
    static let batchSize = 50

    private let token: String
    private let run: Run

    public init(token: String, run: @escaping Run) {
        self.token = token
        self.run = run
    }

    public func moods(for songs: [Song]) async throws -> [String: Mood] {
        var result: [String: Mood] = [:]
        for batch in stride(from: 0, to: songs.count, by: Self.batchSize).map({
            Array(songs[$0..<min($0 + Self.batchSize, songs.count)])
        }) {
            result.merge(try await guess(batch)) { _, new in new }
        }
        return result
    }

    private func guess(_ songs: [Song]) async throws -> [String: Mood] {
        let asked = Set(songs.map(\.videoId))
        let lines = songs.map { "\($0.videoId) | \($0.title) | \($0.artistLine)" }.joined(separator: "\n")
        let arguments = [
            "-p", "--output-format", "json", "--json-schema", Self.schemaJSON, "--tools", "",
            "--no-session-persistence", "--setting-sources", "", "--model", "opus",
            "--system-prompt", Self.instructions,
        ]
        // Only the token: the runner merges it in and removes ANTHROPIC_API_KEY /
        // ANTHROPIC_AUTH_TOKEN, which would otherwise take precedence over it.
        let (status, output, errorOut) = try await run(arguments, ["CLAUDE_CODE_OAUTH_TOKEN": token], Data(lines.utf8))

        guard let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              json["type"] as? String == "result" else {
            throw failed(status: status, stderr: errorOut)
        }
        if json["is_error"] as? Bool == true {
            if json["api_error_status"] as? Int == 401 {
                throw MoodGuessError(message: "Claude Code refused the token. Make a new one with `claude setup-token`.")
            }
            throw MoodGuessError(message: json["result"] as? String ?? "Claude Code returned an error.")
        }
        // is_error is false but no moods came back (the CLI gave up on the schema, hit a turn
        // limit, etc.). Throw rather than return [:], which would mark the batch guessed for good.
        guard let items = (json["structured_output"] as? [String: Any])?["moods"] as? [[String: Any]] else {
            throw MoodGuessError(message: json["result"] as? String ?? "Claude Code returned no moods.")
        }
        var moods: [String: Mood] = [:]
        for item in items {
            guard let id = item["id"] as? String, asked.contains(id),
                  let raw = item["mood"] as? String, let mood = Mood(rawValue: raw) else { continue }
            moods[id] = mood  // Mood(rawValue:) returns nil for "unknown", so it is dropped here.
        }
        return moods
    }

    /// When stdout isn't a result object (a crash, say): the last line of stderr, or the exit code.
    /// The token is never part of the message.
    private func failed(status: Int32, stderr: Data) -> MoodGuessError {
        let lastLine = String(decoding: stderr, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map(String.init)
        return MoodGuessError(message: lastLine ?? "Claude Code failed (exit \(status))")
    }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "moods": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "mood": ["type": "string",
                                 "enum": ["chill", "feelGood", "energetic", "party", "romantic", "sad", "unknown"]],
                    ],
                    "required": ["id", "mood"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["moods"],
        "additionalProperties": false,
    ]

    /// The schema as compact JSON, built once so the CLI always gets the same bytes.
    static let schemaJSON = String(
        decoding: (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data(),
        as: UTF8.self)

    static let instructions = """
        Group songs into moods. Each input line is: id | title | artists.
        Reply with one entry per id and its best-fitting mood:
        - chill: slow, calm, relaxed
        - feelGood: upbeat, happy, warm
        - energetic: fast, intense, workout, driving rap
        - party: dance, club, celebration
        - romantic: love songs, tender
        - sad: heartbreak, loss, melancholy
        The songs include Indian film music (Tamil, Telugu, Hindi) as well as Western music.
        If you do not recognise a song, answer "unknown" for it rather than guess.
        Reply only through the structured output.
        """
}
