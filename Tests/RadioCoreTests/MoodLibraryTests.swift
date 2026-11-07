import Foundation
import Testing
@testable import RadioCore

/// A mood guesser that answers from a fixed table and records the ids it was asked about.
final class FakeGuesser: MoodGuesser, @unchecked Sendable {
    struct Boom: Error {}
    var answers: [String: Mood]
    var askedBatches: [[String]] = []
    /// Sleeps before answering, so concurrent calls overlap.
    var delay: Duration = .zero
    /// Throws on the Nth call (1-based), to test partial-batch handling.
    var failOnCall: Int?
    init(_ answers: [String: Mood]) { self.answers = answers }

    func moods(for songs: [Song]) async throws -> [String: Mood] {
        askedBatches.append(songs.map(\.videoId))
        if delay != .zero { try? await Task.sleep(for: delay) }
        if failOnCall == askedBatches.count { throw Boom() }
        return songs.reduce(into: [:]) { out, song in
            if let mood = answers[song.videoId] { out[song.videoId] = mood }
        }
    }
}

@MainActor
@Suite struct MoodLibraryTests {
    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }
    let clock = Clock()

    func library(file: URL? = nil) -> MoodLibrary {
        let clock = self.clock
        return MoodLibrary(file: file, clock: { clock.now })
    }

    func song(_ id: String, _ title: String = "Song") -> Song {
        Song(videoId: id, title: title, artists: ["A"], length: 100)
    }

    // The radio may play another release of a liked song (another id): title and an artist match too.
    @Test func containsMatchesByIdOrByTitleAndArtist() {
        let lib = library()
        lib.mergeYT([Song(videoId: "a1", title: "Naatu Naatu", artists: ["Rahul Sipligunj", "Kaala Bhairava"])])
        #expect(lib.contains(Song(videoId: "a1", title: "Other title", artists: [])))
        #expect(lib.contains(Song(videoId: "b2", title: "Naatu Naatu (From \"RRR\")", artists: ["Kaala Bhairava"])))
        #expect(!lib.contains(Song(videoId: "b3", title: "Naatu Naatu", artists: ["Someone Else"])))
        #expect(!lib.contains(Song(videoId: "b4", title: "Dosti", artists: ["Kaala Bhairava"])))
    }

    @Test func addLikedPutsSongAtTheFront() {
        let lib = library()
        lib.addLiked(song("v1"))
        lib.addLiked(song("v2"))
        #expect(lib.songs.map(\.videoId) == ["v2", "v1"])
        // Adding it again moves it to the front, not a duplicate.
        lib.addLiked(song("v1"))
        #expect(lib.songs.map(\.videoId) == ["v1", "v2"])
    }

    @Test func mergeYTAddsNewSongsAheadAndKeepsMoods() {
        let lib = library()
        lib.mergeYT([song("v2"), song("v1")])  // newest first
        lib.setMood(.party, for: "v1")
        // YT now shows a newer song; the old ones keep their place and mood.
        lib.mergeYT([song("v3"), song("v2"), song("v1")])
        #expect(lib.songs.map(\.videoId) == ["v3", "v2", "v1"])
        #expect(lib.songs.first { $0.videoId == "v1" }?.mood == .party)
    }

    @Test func mergeYTRemovesSongsNoLongerLiked() {
        let lib = library()
        lib.mergeYT([song("v3"), song("v2"), song("v1")])
        lib.mergeYT([song("v3"), song("v1")])  // v2 un-liked on YT
        #expect(lib.songs.map(\.videoId) == ["v3", "v1"])
    }

    @Test func mergeYTKeepsRecentlyAddedSongsYTHasNotShownYet() {
        let lib = library()
        lib.addLiked(song("v1"))  // just liked in the app
        // YT's list doesn't have it yet; it is kept because it was added moments ago.
        lib.mergeYT([song("v2")])
        #expect(lib.songs.map(\.videoId).contains("v1"))
        // Eleven minutes later YT still doesn't show it: now it is dropped.
        clock.now += 11 * 60
        lib.mergeYT([song("v2")])
        #expect(!lib.songs.map(\.videoId).contains("v1"))
    }

    @Test func setMoodByHandIsNeverOverwrittenByAGuess() async throws {
        let lib = library()
        lib.addLiked(song("v1"))
        lib.setMood(.sad, for: "v1")
        #expect(lib.songs.first?.moodByHand == true)
        try await lib.guessMoods(using: FakeGuesser(["v1": .party]))
        // The hand-picked mood stays; the song wasn't even sent.
        #expect(lib.songs.first?.mood == .sad)
        #expect(lib.songs.first?.moodByHand == true)
    }

    @Test func songsInMoodGroupsByMood() {
        let lib = library()
        lib.addLiked(song("v1"))
        lib.addLiked(song("v2"))
        lib.setMood(.party, for: "v1")
        #expect(lib.songs(in: .party).map(\.videoId) == ["v1"])
        #expect(lib.songs(in: nil).map(\.videoId) == ["v2"])  // "No mood yet"
    }

    @Test func guessMoodsStoresResultsAndMarksAllSentGuessed() async throws {
        let lib = library()
        lib.addLiked(song("v1"))
        lib.addLiked(song("v2"))  // the guesser won't place this one
        let guesser = FakeGuesser(["v1": .chill])
        try await lib.guessMoods(using: guesser)
        #expect(lib.songs.first { $0.videoId == "v1" }?.mood == .chill)
        #expect(lib.songs.first { $0.videoId == "v2" }?.mood == nil)
        // Both were sent and marked guessed, so an "unknown" song isn't re-sent next launch.
        #expect(lib.songs.allSatisfy { $0.guessed })
        guesser.askedBatches = []
        try await lib.guessMoods(using: guesser)
        #expect(guesser.askedBatches.isEmpty)  // nothing left to send
    }

    @Test func concurrentGuessesDoNotSendTheSameSongTwice() async throws {
        let lib = library()
        for i in 0..<10 { lib.addLiked(song("v\(i)")) }
        let guesser = FakeGuesser([:])
        guesser.delay = .milliseconds(20)
        async let a: Void = lib.guessMoods(using: guesser)
        async let b: Void = lib.guessMoods(using: guesser)
        _ = try await (a, b)
        let sent = guesser.askedBatches.flatMap { $0 }
        #expect(Set(sent).count == sent.count)  // no id sent twice
    }

    @Test func atMost300SongsAreKept() {
        let lib = library()
        for i in 0..<305 { lib.addLiked(song("v\(i)")) }
        #expect(lib.songs.count == 300)
        // The newest are kept; the oldest dropped.
        #expect(lib.songs.first?.videoId == "v304")
        #expect(!lib.songs.contains { $0.videoId == "v0" })
    }

    @Test func savesAndReloadsFromDisk() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("moods-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let lib = library(file: file)
        lib.addLiked(song("v1"))
        lib.setMood(.romantic, for: "v1")
        let reloaded = library(file: file)
        #expect(reloaded.songs.first?.videoId == "v1")
        #expect(reloaded.songs.first?.mood == .romantic)
    }

    // An empty list (a signed-out or broken YT response) must not wipe the library.
    @Test func mergeYTIgnoresAnEmptyList() {
        let lib = library()
        lib.addLiked(song("v1"))
        lib.setMood(.sad, for: "v1")
        lib.mergeYT([])
        #expect(lib.songs.map(\.videoId) == ["v1"])
        #expect(lib.songs.first?.mood == .sad)
    }

    // A full page (100 songs) may not be the whole list, so known songs absent from it are kept.
    @Test func mergeYTKeepsKnownSongsWhenThePageIsFull() {
        let lib = library()
        // Seed a known song with a hand-picked mood.
        lib.mergeYT([song("old")])
        lib.setMood(.romantic, for: "old")
        // A full page of 100 brand-new songs that doesn't include "old".
        let page = (0..<100).map { song("new\($0)") }
        lib.mergeYT(page)
        #expect(lib.songs.contains { $0.videoId == "old" })
        #expect(lib.songs.first { $0.videoId == "old" }?.mood == .romantic)
        // YT's songs come first, the kept known song after them.
        #expect(lib.songs.last?.videoId == "old")
    }

    // A short page is the whole list, so an absent known song really is no longer liked.
    @Test func mergeYTDropsKnownSongsWhenThePageIsShort() {
        let lib = library()
        lib.mergeYT([song("old")])
        lib.mergeYT((0..<3).map { song("new\($0)") })
        #expect(!lib.songs.contains { $0.videoId == "old" })
    }

    // A recent app like sits ahead of YT's songs even when the page is full.
    @Test func mergeYTPutsRecentAppLikeAheadOfYTSongs() {
        let lib = library()
        lib.addLiked(song("just-liked"))
        let page = (0..<100).map { song("new\($0)") }
        lib.mergeYT(page)
        #expect(lib.songs.first?.videoId == "just-liked")
    }

    // One failed batch keeps the batches that already succeeded.
    @Test func resortSendsEverySongNotSetByHandAgain() async throws {
        let lib = library()
        lib.addLiked(song("v1"))
        lib.addLiked(song("v2"))
        lib.addLiked(song("v3"))
        lib.addLiked(song("v4"))
        lib.setMood(.sad, for: "v3")  // by hand
        let guesser = FakeGuesser(["v1": .chill, "v2": .party])  // v4: "unknown"
        try await lib.guessMoods(using: guesser)

        lib.resortMoods()
        #expect(lib.songsToGuess == 3)
        #expect(lib.songs.first { $0.videoId == "v1" }?.mood == .chill)  // kept until the new answer
        guesser.answers = ["v1": .romantic, "v4": .energetic]  // v2 now "unknown"
        guesser.askedBatches = []
        try await lib.guessMoods(using: guesser)
        #expect(Set(guesser.askedBatches.flatMap { $0 }) == ["v1", "v2", "v4"])
        let mood = { (id: String) in lib.songs.first { $0.videoId == id }?.mood }
        #expect(mood("v1") == .romantic)
        #expect(mood("v2") == .party)  // an "unknown" answer keeps the earlier mood
        #expect(mood("v3") == .sad)
        #expect(mood("v4") == .energetic)
        #expect(lib.songsToGuess == 0)
    }

    @Test func guessMoodsKeepsEarlierBatchesWhenALaterOneFails() async throws {
        let lib = library()
        for i in 0..<60 { lib.addLiked(song("v\(i)")) }  // addLiked prepends, so newest first
        // The first batch (50 songs) succeeds; the second throws.
        let guesser = FakeGuesser(Dictionary(uniqueKeysWithValues: (0..<60).map { ("v\($0)", Mood.chill) }))
        guesser.failOnCall = 2
        await #expect(throws: FakeGuesser.Boom.self) { try await lib.guessMoods(using: guesser) }
        // Exactly one batch's worth of songs got a mood and is marked guessed; the rest are untouched.
        #expect(lib.songs.filter { $0.mood == .chill }.count == 50)
        #expect(lib.songs.filter { $0.guessed }.count == 50)
        #expect(lib.songs.filter { !$0.guessed }.count == 10)
        // A second run re-sends only the untouched 10.
        guesser.failOnCall = nil
        guesser.askedBatches = []
        try await lib.guessMoods(using: guesser)
        #expect(guesser.askedBatches.flatMap { $0 }.count == 10)
    }

    // The UI asks this before reading the token, so it only does so when there is something to send.
    @Test func songsToGuessCountsOnlySongsThatWouldBeSent() async throws {
        let lib = library()
        #expect(lib.songsToGuess == 0)
        for id in ["v1", "v2", "v3", "v4"] { lib.addLiked(song(id)) }
        lib.setMood(.sad, for: "v1")    // by hand: never sent
        lib.setMood(nil, for: "v2")     // "No mood" by hand: never sent
        #expect(lib.songsToGuess == 2)  // v3, v4
        try await lib.guessMoods(using: FakeGuesser(["v3": .chill]))
        #expect(lib.songsToGuess == 0)  // both sent, so v4 ("unknown") isn't counted either
    }

    // guessMoods splits into batches of 50 itself.
    @Test func guessMoodsSplitsIntoBatchesOfFifty() async throws {
        let lib = library()
        for i in 0..<120 { lib.addLiked(song("v\(i)")) }
        let guesser = FakeGuesser([:])
        try await lib.guessMoods(using: guesser)
        #expect(guesser.askedBatches.map(\.count) == [50, 50, 20])
    }

    // A mood set by hand while the guess is in flight is not overwritten by the guess.
    @Test func moodSetByHandDuringAGuessSurvives() async throws {
        let lib = library()
        lib.addLiked(song("v1"))
        let guesser = FakeGuesser(["v1": .party])
        guesser.delay = .milliseconds(30)
        async let guessing: Void = lib.guessMoods(using: guesser)
        try await Task.sleep(for: .milliseconds(5))  // let the guess get in flight
        lib.setMood(.sad, for: "v1")  // the user picks a mood meanwhile
        try await guessing
        #expect(lib.songs.first?.mood == .sad)
        #expect(lib.songs.first?.moodByHand == true)
    }

    // A file that won't decode is moved aside, not overwritten with an empty library.
    @Test func undecodableFileIsMovedAside() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moods-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("liked-moods.json")
        let bad = dir.appendingPathComponent("liked-moods.bad.json")
        try? Data("not json at all".utf8).write(to: file)
        let lib = library(file: file)
        #expect(lib.songs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: bad.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // An unknown mood raw value decodes as nil instead of failing the whole file.
    @Test func unknownStoredMoodDecodesAsNil() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moods-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("liked-moods.json")
        let json = """
            [{"videoId":"v1","title":"Song","artists":["A"],"mood":"groovy","moodByHand":true,"guessed":true}]
            """
        try? Data(json.utf8).write(to: file)
        let lib = library(file: file)
        // The record survives; only the unknown mood becomes nil.
        #expect(lib.songs.map(\.videoId) == ["v1"])
        #expect(lib.songs.first?.mood == nil)
        #expect(lib.songs.first?.moodByHand == true)
    }
}
