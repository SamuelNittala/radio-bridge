import Foundation
import Observation

/// A liked song and its mood, as kept on disk.
public struct LikedSong: Codable, Equatable, Sendable {
    // Song's fields, stored flat so this record is self-contained.
    public var videoId: String
    public var title: String
    public var artists: [String]
    public var length: Int?
    public var thumbnail: URL?
    /// nil means "No mood yet".
    public var mood: Mood?
    /// Set by the user; a hand-picked mood is never overwritten by a guess.
    public var moodByHand: Bool
    /// Already sent to the guesser, so an "unknown" song isn't re-sent every launch.
    public var guessed: Bool
    /// When the app itself liked it, if it did; used to keep it through a merge YT hasn't caught up to.
    var addedAt: Date?

    public var song: Song {
        Song(videoId: videoId, title: title, artists: artists, length: length, thumbnail: thumbnail)
    }

    init(_ song: Song, mood: Mood? = nil, moodByHand: Bool = false, guessed: Bool = false, addedAt: Date? = nil) {
        videoId = song.videoId
        title = song.title
        artists = song.artists
        length = song.length
        thumbnail = song.thumbnail
        self.mood = mood
        self.moodByHand = moodByHand
        self.guessed = guessed
        self.addedAt = addedAt
    }

    enum CodingKeys: String, CodingKey {
        case videoId, title, artists, length, thumbnail, mood, moodByHand, guessed, addedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try c.decode(String.self, forKey: .videoId)
        title = try c.decode(String.self, forKey: .title)
        artists = try c.decode([String].self, forKey: .artists)
        length = try c.decodeIfPresent(Int.self, forKey: .length)
        thumbnail = try c.decodeIfPresent(URL.self, forKey: .thumbnail)
        // A mood case removed or renamed in a later version decodes as nil, not a whole-file failure.
        mood = (try? c.decodeIfPresent(Mood.self, forKey: .mood)) ?? nil
        moodByHand = try c.decodeIfPresent(Bool.self, forKey: .moodByHand) ?? false
        guessed = try c.decodeIfPresent(Bool.self, forKey: .guessed) ?? false
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
    }
}

/// The user's liked songs grouped into moods, kept as JSON in Application Support,
/// like `AppleCatalog`'s cache. Songs come from YT's "Liked music" and from the app's
/// own likes; moods are guessed by Claude or set by hand.
@MainActor
@Observable
public final class MoodLibrary {
    /// At most this many are kept; the oldest are dropped.
    static let limit = 300
    /// A full first page: when YT returns this many, there may be more it didn't return,
    /// so known songs missing from the page are kept rather than treated as un-liked.
    static let pageSize = 100
    /// A just-liked song is kept through a merge for this long, in case YT hasn't shown it yet.
    static let graceAfterLike: TimeInterval = 10 * 60

    public private(set) var songs: [LikedSong] = []

    private let file: URL?
    private let clock: @Sendable () -> Date
    /// Ids currently out with a guesser, so two overlapping guesses don't send the same song.
    private var guessing = Set<String>()

    public init(file: URL? = MoodLibrary.defaultFile, clock: @escaping @Sendable () -> Date = Date.init) {
        self.file = file
        self.clock = clock
        guard let file, let data = try? Data(contentsOf: file) else { return }
        do {
            songs = try JSONDecoder().decode([LikedSong].self, from: data)
        } catch {
            // The file holds hand-picked moods that can't be rebuilt; keep the unreadable copy
            // instead of overwriting it on the next change.
            let aside = file.deletingLastPathComponent().appendingPathComponent("liked-moods.bad.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
        }
    }

    public nonisolated static var defaultFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Radio Bridge/liked-moods.json")
    }

    // MARK: - Changes

    /// A song the app just liked: moves or inserts it at the front.
    public func addLiked(_ song: Song) {
        var record = songs.first { $0.videoId == song.videoId } ?? LikedSong(song)
        record.addedAt = clock()
        songs.removeAll { $0.videoId == song.videoId }
        songs.insert(record, at: 0)
        trim()
        save()
    }

    /// YT's "Liked music", newest first. New songs are added ahead of older ones in YT's order;
    /// known songs keep their mood. An empty list is ignored (a signed-out or broken response
    /// must not wipe the library).
    ///
    /// Only the first page (100 songs) is fetched. When the page is full there may be more likes
    /// YT didn't return, so known songs missing from it are kept, after YT's songs. When the page
    /// is short it is the whole list, so songs missing from it are no longer liked and are removed.
    /// Either way, songs the app liked in the last ten minutes stay ahead (YT may not list them yet).
    public func mergeYT(_ liked: [Song]) {
        guard !liked.isEmpty else { return }
        let known = Dictionary(songs.map { ($0.videoId, $0) }, uniquingKeysWith: { a, _ in a })
        let onYT = Set(liked.map(\.videoId))
        // YT's songs, newest first, keeping any mood we already have.
        let merged = liked.map { song -> LikedSong in
            guard var record = known[song.videoId] else { return LikedSong(song) }
            record.title = song.title
            record.artists = song.artists
            record.length = song.length
            record.thumbnail = song.thumbnail
            return record
        }
        // Songs we know that YT didn't return, in their old order: recent app likes always;
        // older ones only when the page was full, so a short (complete) page prunes them.
        let now = clock()
        let pageFull = liked.count >= Self.pageSize
        let kept = songs.filter { record in
            guard !onYT.contains(record.videoId) else { return false }
            let recentLike = record.addedAt.map { now.timeIntervalSince($0) < Self.graceAfterLike } ?? false
            return recentLike || pageFull
        }
        // Recent app likes go ahead of YT's songs; older kept songs go after.
        let (ahead, behind) = kept.reduce(into: ([LikedSong](), [LikedSong]())) { out, record in
            let recentLike = record.addedAt.map { now.timeIntervalSince($0) < Self.graceAfterLike } ?? false
            if recentLike { out.0.append(record) } else { out.1.append(record) }
        }
        songs = ahead + merged + behind
        trim()
        save()
    }

    /// Sets a song's mood by hand; a hand-picked mood is never overwritten by a guess.
    public func setMood(_ mood: Mood?, for videoId: String) {
        guard let i = songs.firstIndex(where: { $0.videoId == videoId }) else { return }
        songs[i].mood = mood
        songs[i].moodByHand = true
        save()
    }

    /// Marks every song not set by hand to be guessed again, "unknown" ones included. Current moods
    /// stay until the new answer; a song that now comes back "unknown" keeps its mood.
    public func resortMoods() {
        for i in songs.indices where !songs[i].moodByHand { songs[i].guessed = false }
        save()
    }

    /// Whether a song is liked: the same id, or the same title with an artist in common, since the
    /// radio may play another release of a liked song.
    public func contains(_ song: Song) -> Bool {
        let title = Matching.normTitle(song.title)
        let artists = Matching.normArtists(song.artistLine)
        return songs.contains {
            $0.videoId == song.videoId
                || (Matching.normTitle($0.title) == title && !Matching.normArtists($0.song.artistLine).isDisjoint(with: artists))
        }
    }

    public func songs(in mood: Mood?) -> [LikedSong] {
        songs.filter { $0.mood == mood }
    }

    /// At most this many songs per guesser call, so one failed batch loses only itself.
    static let guessBatchSize = 50

    /// How many songs `guessMoods` would send now, so callers can skip it (and reading the
    /// token) when there is nothing to do.
    public var songsToGuess: Int { unsent().count }

    private func unsent() -> [LikedSong] {
        songs.filter { !$0.moodByHand && !$0.guessed && !guessing.contains($0.videoId) }
    }

    /// Asks the guesser about every song not set by hand that hasn't been sent (or was re-sorted), in
    /// batches of 50; stores and saves after each batch, so a later failure keeps the earlier
    /// results. Every sent song is marked guessed (so an "unknown" song isn't re-sent). A
    /// hand-picked mood is never touched, even one set while the guess is in flight. Overlapping
    /// calls never send the same song twice.
    public func guessMoods(using guesser: MoodGuesser) async throws {
        let toSend = unsent()
        guard !toSend.isEmpty else { return }
        let allIds = Set(toSend.map(\.videoId))
        guessing.formUnion(allIds)
        defer { guessing.subtract(allIds) }

        for start in stride(from: 0, to: toSend.count, by: Self.guessBatchSize) {
            let batch = Array(toSend[start..<min(start + Self.guessBatchSize, toSend.count)])
            let ids = Set(batch.map(\.videoId))
            let guessed = try await guesser.moods(for: batch.map(\.song))
            for i in songs.indices where ids.contains(songs[i].videoId) {
                songs[i].guessed = true
                // Re-check moodByHand here: it may have been set while this batch was in flight.
                if !songs[i].moodByHand, let mood = guessed[songs[i].videoId] {
                    songs[i].mood = mood
                }
            }
            save()
        }
    }

    // MARK: - Storage

    private func trim() {
        if songs.count > Self.limit { songs.removeLast(songs.count - Self.limit) }
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(songs) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
