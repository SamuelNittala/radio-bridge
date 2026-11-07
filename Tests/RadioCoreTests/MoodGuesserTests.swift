import Foundation
import Testing
@testable import RadioCore

/// Stands in for the `claude` CLI: records each run's arguments, environment and stdin,
/// and answers from a queue of (status, stdout, stderr) results (the last one repeats).
final class FakeClaudeCode: @unchecked Sendable {
    struct Call { var arguments: [String]; var environment: [String: String]; var input: Data }
    var calls: [Call] = []
    var results: [(status: Int32, output: Data, error: Data)] = []

    func run(_ arguments: [String], _ environment: [String: String], _ input: Data)
        -> (status: Int32, output: Data, error: Data) {
        calls.append(Call(arguments: arguments, environment: environment, input: input))
        return results[min(calls.count - 1, results.count - 1)]
    }

    /// Successful CLI output: the structured output maps each id to a mood (or "unknown").
    static func success(_ pairs: [(String, String)]) -> (status: Int32, output: Data, error: Data) {
        let moods = pairs.map { ["id": $0.0, "mood": $0.1] }
        let inner = String(data: try! JSONSerialization.data(withJSONObject: ["moods": moods]), encoding: .utf8)!
        let json: [String: Any] = [
            "type": "result", "subtype": "success", "is_error": false,
            "result": inner, "structured_output": ["moods": moods],
        ]
        return (0, try! JSONSerialization.data(withJSONObject: json), Data())
    }

    /// A result object with is_error true (e.g. a bad token), exit status 1.
    static func apiError(_ status: Int, result: String) -> (status: Int32, output: Data, error: Data) {
        let json: [String: Any] = [
            "type": "result", "subtype": "success", "is_error": true,
            "api_error_status": status, "result": result,
        ]
        return (1, try! JSONSerialization.data(withJSONObject: json), Data())
    }
}

@Suite struct ClaudeCodeMoods {
    func song(_ id: String, _ title: String = "Song", _ artists: [String] = ["A"]) -> Song {
        Song(videoId: id, title: title, artists: artists)
    }

    func guesser(_ fake: FakeClaudeCode) -> ClaudeCodeMoodGuesser {
        ClaudeCodeMoodGuesser(token: "oauth-secret-123", run: { fake.run($0, $1, $2) })
    }

    @Test func runArgumentsAndEnvironmentAndStdin() async throws {
        let fake = FakeClaudeCode()
        fake.results = [FakeClaudeCode.success([("v1", "party")])]
        _ = try await guesser(fake).moods(for: [song("v1", "Naatu Naatu", ["Rahul", "Kaala"])])

        let call = try #require(fake.calls.first)
        // The fixed arguments; the schema and instructions are checked in their own tests.
        #expect(call.arguments.prefix(11) == [
            "-p", "--output-format", "json", "--json-schema", ClaudeCodeMoodGuesser.schemaJSON, "--tools", "",
            "--no-session-persistence", "--setting-sources", "", "--model",
        ])
        #expect(Array(call.arguments.suffix(3)) == ["opus", "--system-prompt", ClaudeCodeMoodGuesser.instructions])
        // Only the token key is set; the runner merges it and strips the API-key vars.
        #expect(call.environment == ["CLAUDE_CODE_OAUTH_TOKEN": "oauth-secret-123"])
        // One line per song: id | title | artists (artists joined with ", ").
        #expect(String(data: call.input, encoding: .utf8) == "v1 | Naatu Naatu | Rahul, Kaala")
    }

    // The schema given to the CLI is the brief's, not just whatever the code holds.
    @Test func schemaMatchesTheBrief() throws {
        let moodEnum = ["chill", "feelGood", "energetic", "party", "romantic", "sad", "unknown"]
        let expected: [String: Any] = [
            "type": "object",
            "properties": ["moods": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "mood": ["type": "string", "enum": moodEnum],
                    ],
                    "required": ["id", "mood"],
                    "additionalProperties": false,
                ],
            ]],
            "required": ["moods"],
            "additionalProperties": false,
        ]
        let decoded = try JSONSerialization.jsonObject(with: Data(ClaudeCodeMoodGuesser.schemaJSON.utf8))
        #expect(NSDictionary(dictionary: decoded as! [String: Any]) == NSDictionary(dictionary: expected))
    }

    @Test func instructionsCoverTheBrief() {
        let text = ClaudeCodeMoodGuesser.instructions
        for line in ["chill:", "feelGood:", "energetic:", "party:", "romantic:", "sad:"] {
            #expect(text.contains(line))
        }
        #expect(text.contains("Indian film music"))
        #expect(text.localizedCaseInsensitiveContains("unknown"))
        #expect(text.contains("Reply only through the structured output."))
    }

    @Test func parsesMoodsAndDropsUnknownAndUnasked() async throws {
        let fake = FakeClaudeCode()
        fake.results = [FakeClaudeCode.success([
            ("v1", "party"), ("v2", "unknown"), ("v3", "sad"), ("vx", "chill"),
        ])]
        let moods = try await guesser(fake).moods(for: [song("v1"), song("v2"), song("v3")])
        #expect(moods == ["v1": .party, "v3": .sad])  // "unknown" dropped, "vx" wasn't asked for
    }

    @Test func splitsIntoBatchesOfFifty() async throws {
        let fake = FakeClaudeCode()
        fake.results = [FakeClaudeCode.success([])]  // reused for every run
        let songs = (0..<120).map { song("v\($0)") }
        _ = try await guesser(fake).moods(for: songs)
        #expect(fake.calls.count == 3)
        func lines(_ i: Int) -> Int {
            String(data: fake.calls[i].input, encoding: .utf8)!.split(separator: "\n").count
        }
        #expect(lines(0) == 50)
        #expect(lines(1) == 50)
        #expect(lines(2) == 20)
    }

    @Test func badTokenGivesAFriendlyMessage() async throws {
        let fake = FakeClaudeCode()
        fake.results = [FakeClaudeCode.apiError(401, result: "Failed to authenticate. API Error: 401 Invalid bearer token")]
        do {
            _ = try await guesser(fake).moods(for: [song("v1")])
            Issue.record("expected a throw")
        } catch let error as MoodGuessError {
            #expect(error.localizedDescription == "Claude Code refused the token. Make a new one with `claude setup-token`.")
            // The token must never leak into an error.
            #expect(!error.localizedDescription.contains("oauth-secret-123"))
        }
    }

    @Test func otherApiErrorsCarryTheResultText() async throws {
        let fake = FakeClaudeCode()
        fake.results = [FakeClaudeCode.apiError(529, result: "API Error: 529 overloaded")]
        do {
            _ = try await guesser(fake).moods(for: [song("v1")])
            Issue.record("expected a throw")
        } catch let error as MoodGuessError {
            #expect(error.localizedDescription == "API Error: 529 overloaded")
        }
    }

    // is_error is false but no structured output came back: must throw, not silently return [:],
    // which would mark the batch guessed and never re-send it.
    @Test func successShapeWithoutMoodsThrows() async throws {
        let fake = FakeClaudeCode()
        let json: [String: Any] = ["type": "result", "subtype": "error_max_turns", "is_error": false,
                                   "result": "I couldn't finish."]
        fake.results = [(0, try! JSONSerialization.data(withJSONObject: json), Data())]
        do {
            _ = try await guesser(fake).moods(for: [song("v1")])
            Issue.record("expected a throw")
        } catch let error as MoodGuessError {
            #expect(error.localizedDescription == "I couldn't finish.")
        }
    }

    @Test func garbageOutputThrowsWithTheLastStderrLine() async throws {
        let fake = FakeClaudeCode()
        fake.results = [(1, Data("not json".utf8), Data("first line\nclaude: command crashed".utf8))]
        do {
            _ = try await guesser(fake).moods(for: [song("v1")])
            Issue.record("expected a throw")
        } catch let error as MoodGuessError {
            #expect(error.localizedDescription == "claude: command crashed")
        }
    }

    @Test func garbageOutputWithoutStderrFallsBackToExitCode() async throws {
        let fake = FakeClaudeCode()
        fake.results = [(2, Data("".utf8), Data())]
        do {
            _ = try await guesser(fake).moods(for: [song("v1")])
            Issue.record("expected a throw")
        } catch let error as MoodGuessError {
            #expect(error.localizedDescription == "Claude Code failed (exit 2)")
        }
    }
}
