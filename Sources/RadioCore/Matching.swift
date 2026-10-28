import Foundation

/// Song matching between YT and Apple, ported from compare.py and loop.py.
public enum Matching {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static let artistSplit = regex(#"\s*(?:,|&|\band\b|\bfeat\.?|\bft\.?|\bx\b)\s*"#)
    private static let brackets = regex(#"[\(\[].*?[\)\]]"#)
    private static let titleSuffix = regex(#"\s+-\s+.*$"#)  // " - Remastered 2011", " - Live"
    private static let nonWord = regex(#"[^\w\s]"#)
    private static let duration = regex(#"^(\d+:)*\d+:\d+$"#)

    private static func replace(_ re: NSRegularExpression, in text: String, with template: String) -> String {
        re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    public static func norm(_ text: String) -> String {
        replace(nonWord, in: text.lowercased(), with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func normTitle(_ title: String) -> String {
        norm(replace(titleSuffix, in: replace(brackets, in: title, with: ""), with: ""))
    }

    /// "A, B & C feat. D" -> {"a", "b", "c", "d"}
    public static func normArtists(_ artists: String) -> Set<String> {
        let lower = artists.lowercased()
        var parts: [String] = []
        var start = lower.startIndex
        for m in artistSplit.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)) {
            let r = Range(m.range, in: lower)!
            parts.append(String(lower[start..<r.lowerBound]))
            start = r.upperBound
        }
        parts.append(String(lower[start...]))
        return Set(parts.map(norm).filter { !$0.isEmpty })
    }

    public static func isDuration(_ text: String) -> Bool {
        duration.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// "3:45" -> 225; nil when unknown.
    public static func seconds(_ length: String?) -> Int? {
        guard let length, isDuration(length) else { return nil }
        return length.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }

    /// Does an Apple result look like the YT song? Title, artist and length.
    public static func isSameSong(_ song: Song, _ cand: AppleTrack) -> Bool {
        let ytTitle = normTitle(song.title), amTitle = normTitle(cand.trackName)
        guard ytTitle == amTitle || amTitle.contains(ytTitle) || ytTitle.contains(amTitle) else { return false }
        let ytArtists = song.artists.reduce(into: Set<String>()) { $0.formUnion(normArtists($1)) }
        if !ytArtists.isEmpty && ytArtists.isDisjoint(with: normArtists(cand.artistName)) { return false }
        guard let length = song.length, let ms = cand.trackTimeMillis else { return true }
        return abs(Double(ms) / 1000 - Double(length)) <= 10
    }

    /// Store searches to try for a song, most specific first.
    public static func queries(for song: Song) -> [String] {
        let title = song.title, artists = song.artists
        let candidates = [
            artists.first.map { "\(title) \($0)" } ?? title,
            ([title] + artists).joined(separator: " "),
            artists.first.map { "\(normTitle(title)) \($0)" } ?? normTitle(title),
            title,
        ]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// The song in Apple's catalog: any release of it (soundtrack, compilation, single),
    /// an exact title first. Nil if it is not on Apple Music.
    ///
    /// The shortcut queues the result by its link, so the store's ranking doesn't matter:
    /// the song only has to be somewhere in a search's results.
    public static func findTrack(
        for song: Song,
        search: (_ term: String) async throws -> [AppleTrack]
    ) async throws -> AppleTrack? {
        // An exact title beats a partial one: "White" is in "Pink + White" but isn't that song.
        var partial: AppleTrack?
        for q in queries(for: song) {
            let matches = try await search(q).filter { $0.trackViewUrl != nil && isSameSong(song, $0) }
            if let exact = matches.first(where: { normTitle($0.trackName) == normTitle(song.title) }) { return exact }
            partial = partial ?? matches.first
        }
        return partial
    }
}
