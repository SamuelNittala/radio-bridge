import Foundation
import Testing
@testable import RadioCore

// Fakes standing in for Music.app, the shortcut, YT and Apple's catalog.

final class FakePlayer: MusicPlayer {
    var now = PlayerStatus.stopped
    var commands: [String] = []
    /// Like Music: a new favourite isn't reported until later (never, here).
    var lagsFavorites = false
    func status() -> PlayerStatus { now }
    func nextTrack() { commands.append("next") }
    func play() {
        commands.append("play")
        if now.state == .paused { now.state = .playing }
    }
    func pause() {
        commands.append("pause")
        if now.state == .playing { now.state = .paused }
    }
    func setFavorited(_ on: Bool) {
        commands.append(on ? "favorite" : "unfavorite")
        if !(on && lagsFavorites) { now.favorited = on }
    }
}

final class FakeQueuer: TrackQueuer, @unchecked Sendable {
    /// Songs added to Playing Next, by the title in their link.
    var queries: [String] = []
    /// Makes the next clear() wait until `held` is set back to false, so a start can be slowed down.
    var holdNextClear = false
    var held = false
    func queue(_ link: URL) async throws { queries.append(link.lastPathComponent) }
    func clear() async throws {
        queries.append("<clear>")
        if holdNextClear {
            holdNextClear = false
            held = true
            while held { try await Task.sleep(for: .milliseconds(1)) }
        }
    }
}

final class FakeYT: Recommender, @unchecked Sendable {
    var signedIn = true
    var songs: [Song]
    var reported: [String] = []
    var liked: [String] = []
    var filters: [String?] = []
    var historyResult = HistoryResult.added
    /// Extra chips the radio offers, so a mood's filters can match.
    var extraChips: [Chip] = []
    var extraChip: Chip? {
        get { extraChips.first }
        set { extraChips = newValue.map { [$0] } ?? [] }
    }
    init(songs: [Song]) { self.songs = songs }
    func account() async throws -> Account? { signedIn ? Account(name: "Sam") : nil }
    func radio(from videoId: String, filter: String?) async throws -> RadioPage {
        filters.append(filter)
        // Like YT, radio starts with the song it was made from.
        let start = songs.firstIndex { $0.videoId == videoId } ?? 0
        var chips = [Chip(name: "All", playlistId: "a", params: "", isSelected: true),
                     Chip(name: "Familiar", playlistId: "f", params: "p", isSelected: false)]
        chips += extraChips
        return RadioPage(songs: Array(songs[start...] + songs[..<start]), chips: chips)
    }
    func reportPlay(_ videoId: String) async throws -> HistoryResult { reported.append(videoId); return historyResult }
    func like(_ videoId: String) async throws { liked.append(videoId) }
    func likedSongs() async throws -> [Song] { songs }
}

/// Every song is on Apple Music under its own title, except titles starting with "Missing".
struct FakeCatalog: Catalog {
    func find(_ song: Song) async throws -> AppleTrack? {
        if song.title.hasPrefix("Missing") { return nil }
        return AppleTrack(trackId: 1, trackName: song.title, artistName: "A",
                          trackViewUrl: URL(string: "https://music.apple.com/in/song/")!.appendingPathComponent(song.title))
    }
}

@MainActor
@Suite struct Engine {
    let player = FakePlayer()
    let queuer = FakeQueuer()
    let yt: FakeYT
    let engine: RadioEngine

    init() {
        yt = FakeYT(songs: ["Seed", "Missing One", "Two", "Three", "Four", "Five", "Six"].enumerated().map {
            Song(videoId: "v\($0.offset)", title: $0.element, artists: ["A"])
        })
        let clock = Clock()
        engine = RadioEngine(player: player, queuer: queuer, yt: yt, catalog: FakeCatalog(),
                             clock: { clock.now })
        self.clock = clock
    }

    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
    let clock: Clock

    /// Music starts playing a track the shortcut queued (its name is the query).
    func plays(_ name: String, at position: Double = 1, favorited: Bool = false) {
        player.now = PlayerStatus(state: .playing, pid: "pid-\(name)", name: name, duration: 100,
                                  position: position, favorited: favorited)
    }

    func advance(_ seconds: TimeInterval) { clock.now += seconds }

    @Test func startsWithTheSeedThenFollowsRadio() async {
        await engine.start(yt.songs[0], poll: false)
        #expect(engine.phase == .running)
        // Playing Next is emptied before the new radio's first song goes in.
        #expect(queuer.queries == ["<clear>", "Seed"])
        #expect(player.commands == ["next", "play"])

        plays("Seed")
        await engine.tick()
        #expect(engine.current?.song.title == "Seed")
        // Three songs are kept queued ahead once the first one plays; songs not on Apple Music are skipped.
        #expect(queuer.queries == ["<clear>", "Seed", "Two", "Three", "Four"])
        #expect(engine.queued.map(\.name) == ["Two", "Three", "Four"])
        #expect(engine.notOnApple.map(\.title) == ["Missing One"])
        #expect(engine.upcoming.first?.title == "Five")

        // Topped up, not added to, while the same song plays.
        await engine.tick()
        #expect(queuer.queries.count == 5)
        plays("Two")
        await engine.tick()
        #expect(engine.queued.map(\.name) == ["Three", "Four", "Five"])
    }

    @Test func skippingAheadInMusicStaysOnTheRadio() async {
        await engine.start(yt.songs[0], poll: false)
        plays("Seed")
        await engine.tick()
        player.commands = []
        plays("Three")  // "Two" was skipped in Music before it started
        await engine.tick()
        #expect(engine.current?.song.title == "Three")
        #expect(player.commands.isEmpty)
        #expect(engine.activity.contains { $0.kind == .skipped && $0.text == "Skipped: A - Two" })
        #expect(engine.queued.map(\.name) == ["Four", "Five", "Six"])
    }

    @Test func playPauseTogglesMusicAndShowsTheNewState() async {
        await engine.start(yt.songs[0], poll: false)
        plays("Seed")
        await engine.tick()
        player.commands = []
        engine.togglePlayback()
        #expect(player.commands == ["pause"])
        #expect(engine.music.state == .paused)  // shown now, not at the next check
        engine.togglePlayback()
        #expect(player.commands == ["pause", "play"])
        #expect(engine.music.state == .playing)
    }

    @Test func nextSkipsToTheFirstQueuedSongAndPlays() async {
        await engine.start(yt.songs[0], poll: false)
        plays("Seed", at: 10)
        await engine.tick()
        player.commands = []
        engine.playNext()
        #expect(player.commands == ["next", "play"])
        plays("Two")
        await engine.tick()
        #expect(engine.current?.song.title == "Two")
        #expect(engine.activity.contains { $0.kind == .skipped && $0.text.hasPrefix("Skipped: A - Seed") })
    }

    @Test func heartFavouritesInMusicAndLikesOnYTWhenTheSongEnds() async {
        await engine.start(yt.songs[0], poll: false)
        plays("Seed", at: 10)
        await engine.tick()
        player.commands = []
        engine.toggleFavorite()
        #expect(player.commands == ["favorite"])
        #expect(engine.current?.favorited == true)  // shown now, not at the next check
        #expect(yt.liked.isEmpty)
        plays("Seed", at: 80, favorited: true)
        await engine.tick()
        plays("Two")
        await engine.tick()
        try? await Task.sleep(for: .milliseconds(50))  // reports run in the background
        #expect(yt.liked == ["v0"])
    }

    @Test func heartTakenBackBeforeTheEndIsNotLiked() async {
        await engine.start(yt.songs[0], poll: false)
        plays("Seed", at: 10)
        await engine.tick()
        engine.toggleFavorite()
        engine.toggleFavorite()
        #expect(player.commands.suffix(2) == ["favorite", "unfavorite"])
        #expect(engine.current?.favorited == false)
        plays("Seed", at: 80)
        await engine.tick()
        plays("Two")
        await engine.tick()
        try? await Task.sleep(for: .milliseconds(50))  // reports run in the background
        #expect(yt.liked.isEmpty)
    }

    // Music records a new favourite a few seconds late; the star must not flip back meanwhile.
    @Test func heartStaysOnWhileMusicCatchesUp() async {
        await engine.start(yt.songs[0], poll: false)
        plays("Seed", at: 10)
        await engine.tick()
        player.lagsFavorites = true
        engine.toggleFavorite()
        #expect(engine.current?.favorited == true)
        advance(2)
        await engine.tick()
        #expect(engine.current?.favorited == true)
        // Ends before Music caught up: still liked.
        plays("Two")
        await engine.tick()
        try? await Task.sleep(for: .milliseconds(50))  // reports run in the background
        #expect(yt.liked == ["v0"])
    }

    // If Music never takes the favourite, the star goes back to what Music says.
    @Test func heartFollowsMusicAgainAfterAWhile() async {
        await engine.start(yt.songs[0], poll: false)
        plays("Seed", at: 10)
        await engine.tick()
        player.lagsFavorites = true
        engine.toggleFavorite()
        advance(11)
        await engine.tick()
        #expect(engine.current?.favorited == false)
    }

    // Music is playing something that isn't from the radio: leave it alone.
    @Test func heartDoesNothingForOtherSongs() async {
        await engine.start(yt.songs[0], poll: false)
        plays("Seed", at: 10)
        await engine.tick()
        plays("Not from the radio")
        player.commands = []
        engine.toggleFavorite()
        #expect(player.commands.isEmpty)
    }

    @Test func reportsFullPlaysAndLikes() async {
        await engine.start(yt.songs[0], poll: false)
        plays("Seed", at: 10)
        await engine.tick()
        plays("Seed", at: 80, favorited: true)
        await engine.tick()
        plays("Two")
        await engine.tick()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))  // reports run in the background
        #expect(yt.reported == ["v0"])
        #expect(yt.liked == ["v0"])
        #expect(engine.current?.song.title == "Two")
    }

    @Test func earlySkipIsNotReported() async {
        await engine.start(yt.songs[0], poll: false)
        plays("Seed", at: 10)
        await engine.tick()
        plays("Two")
        await engine.tick()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(yt.reported.isEmpty)
        #expect(engine.activity.contains { $0.kind == .skipped && $0.text.hasPrefix("Skipped: A - Seed") })
    }

    @Test func foreignTrackIsSkippedAfterGracePeriod() async {
        await engine.start(yt.songs[0], poll: false)
        plays("Seed")
        await engine.tick()
        player.commands = []
        plays("Some library song")
        // Right after a skip nothing happens: Music may still be switching tracks.
        await engine.tick()
        #expect(player.commands.isEmpty)
        advance(7)
        await engine.tick()
        #expect(player.commands == ["next", "play"])
    }

    @Test func stopsWhenQueuedSongsNeverArrive() async {
        await engine.start(yt.songs[0], poll: false)
        plays("Seed")
        await engine.tick()
        plays("Some library song")
        for _ in 0..<5 {
            advance(10)
            await engine.tick()
        }
        // The queued songs are added again, in order, on the third miss.
        #expect(queuer.queries.filter { $0 == "Two" }.count == 2)
        #expect(queuer.queries.suffix(3) == ["Two", "Three", "Four"])
        if case .failed = engine.phase {} else { Issue.record("expected failure, got \(engine.phase)") }
    }

    @Test func signedOutStops() async {
        yt.signedIn = false
        await engine.start(yt.songs[0], poll: false)
        #expect(engine.phase == .signedOut)
        #expect(queuer.queries == ["<clear>"])
    }

    @Test func startingFromAnotherSongClearsAndRestarts() async {
        await engine.start(yt.songs[0], poll: false)
        plays("Seed")
        await engine.tick()
        await engine.start(yt.songs[3], poll: false)
        #expect(queuer.queries.suffix(2) == ["<clear>", "Three"])
        #expect(engine.seed?.title == "Three")
        #expect(engine.current == nil)
    }

    @Test func filterRefetchesUpcoming() async {
        await engine.start(yt.songs[0], poll: false)
        await engine.setFilter("Familiar")
        #expect(yt.filters.last == "Familiar")
        #expect(engine.chips.first { $0.isSelected }?.name == "Familiar")
        #expect(!engine.upcoming.contains { $0.title == "Seed" })  // already played
    }

    @Test func onLikedFiresWhenASongIsLikedOnYT() async {
        var liked: [String] = []
        engine.onLiked = { liked.append($0.videoId) }
        await engine.start(yt.songs[0], poll: false)
        plays("Seed", at: 10)
        await engine.tick()
        engine.toggleFavorite()
        plays("Seed", at: 80, favorited: true)
        await engine.tick()
        plays("Two")
        await engine.tick()
        try? await Task.sleep(for: .milliseconds(50))  // the like runs in the background
        #expect(yt.liked == ["v0"])
        #expect(liked == ["v0"])
    }

    @Test func songLikedOnYTIsFavouritedInMusicAndNotLikedAgain() async {
        engine.isLikedOnYT = { $0.videoId == "v0" }
        await engine.start(yt.songs[0], poll: false)
        player.commands = []
        plays("Seed", at: 10)
        await engine.tick()
        #expect(player.commands == ["favorite"])
        #expect(engine.current?.favorited == true)  // shown now, though Music reports it late
        plays("Seed", at: 80, favorited: true)
        await engine.tick()
        plays("Two")
        await engine.tick()
        try? await Task.sleep(for: .milliseconds(50))  // reports run in the background
        #expect(yt.reported == ["v0"])
        #expect(yt.liked.isEmpty)  // already liked there
        #expect(!player.commands.contains("unfavorite"))
    }

    @Test func songNotLikedOnYTIsLeftAlone() async {
        engine.isLikedOnYT = { _ in false }
        await engine.start(yt.songs[0], poll: false)
        player.commands = []
        plays("Seed", at: 10)
        await engine.tick()
        #expect(!player.commands.contains("favorite"))
        #expect(engine.current?.favorited == false)
    }

    @Test func songAlreadyFavouritedInMusicIsNotFavouritedAgain() async {
        engine.isLikedOnYT = { _ in true }
        await engine.start(yt.songs[0], poll: false)
        player.commands = []
        plays("Seed", at: 10, favorited: true)
        await engine.tick()
        #expect(!player.commands.contains("favorite"))
    }

    @Test func moodStartPlaysFromAMoodSongAndAppliesTheFilter() async {
        // feelGood has no matching chip (the fake offers only "All" and "Familiar"), so the radio
        // stays on All.
        let moodSongs = [yt.songs[2]]  // "Two"
        await engine.start(mood: .feelGood, from: moodSongs, poll: false, pick: { $0.first })
        #expect(engine.phase == .running)
        #expect(engine.seed?.title == "Two")
        #expect(engine.activity.contains { $0.text == "Mood: Feel good" })
        // No chip matched feelGood's filters, so the filter stays "All".
        #expect(engine.filter == "All")
    }

    @Test func moodStartAppliesAMatchingFilter() async {
        // The fake radio also offers a "Chill" chip, which chill's filters match.
        yt.extraChip = Chip(name: "Chill", playlistId: "c", params: "cp", isSelected: false)
        await engine.start(mood: .chill, from: [yt.songs[2]], poll: false, pick: { $0.first })
        #expect(engine.filter == "Chill")
        #expect(yt.filters.contains("Chill"))
    }

    // The mood's filters are tried in order: energetic is ["Workout", "Energy", ...], so with both
    // "Energy" and "Workout" offered, "Workout" wins.
    @Test func moodStartTriesFiltersInOrder() async {
        yt.extraChips = [Chip(name: "Energy", playlistId: "e", params: "ep", isSelected: false),
                         Chip(name: "Workout", playlistId: "w", params: "wp", isSelected: false)]
        await engine.start(mood: .energetic, from: [yt.songs[2]], poll: false, pick: { $0.first })
        #expect(engine.filter == "Workout")
    }

    // A chip matches a mood's filter case-insensitively: a lowercase "chill" chip matches .chill.
    @Test func moodStartMatchesFiltersCaseInsensitively() async {
        yt.extraChip = Chip(name: "chill", playlistId: "c", params: "cp", isSelected: false)
        await engine.start(mood: .chill, from: [yt.songs[2]], poll: false, pick: { $0.first })
        #expect(engine.filter == "chill")
    }

    @Test func moodStartDoesNothingWithNoSongs() async {
        await engine.start(mood: .party, from: [], poll: false, pick: { $0.first })
        #expect(engine.phase == .idle)
        #expect(queuer.queries.isEmpty)
    }

    // A radio started while a mood radio is still starting must not get the mood's filter.
    @Test func slowMoodStartDoesNotFilterANewerRadio() async {
        yt.extraChip = Chip(name: "Chill", playlistId: "c", params: "cp", isSelected: false)
        let engine = self.engine, song = yt.songs[2]
        queuer.holdNextClear = true  // the mood radio's start stalls clearing Playing Next
        let moodStart = Task { @MainActor in
            await engine.start(mood: .chill, from: [song], poll: false, pick: { $0.first })
        }
        while !queuer.held { await Task.yield() }
        await engine.start(yt.songs[4], poll: false)  // a newer radio runs to completion meanwhile
        queuer.held = false  // now the older start resumes, after the newer radio is running
        await moodStart.value
        #expect(engine.seed?.title == "Four")
        #expect(engine.filter == "All")
    }
}
