import Foundation
import Testing
@testable import RadioCore

// Fakes standing in for Music.app, the shortcut, YT and Apple's catalog.

final class FakePlayer: MusicPlayer {
    var now = PlayerStatus.stopped
    var commands: [String] = []
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
}

final class FakeQueuer: TrackQueuer, @unchecked Sendable {
    /// Songs added to Playing Next, by the title in their link.
    var queries: [String] = []
    func queue(_ link: URL) async throws { queries.append(link.lastPathComponent) }
    func clear() async throws { queries.append("<clear>") }
}

final class FakeYT: Recommender, @unchecked Sendable {
    var signedIn = true
    var songs: [Song]
    var reported: [String] = []
    var liked: [String] = []
    var filters: [String?] = []
    var historyResult = HistoryResult.added
    init(songs: [Song]) { self.songs = songs }
    func account() async throws -> Account? { signedIn ? Account(name: "Sam") : nil }
    func radio(from videoId: String, filter: String?) async throws -> RadioPage {
        filters.append(filter)
        // Like YT, radio starts with the song it was made from.
        let start = songs.firstIndex { $0.videoId == videoId } ?? 0
        return RadioPage(songs: Array(songs[start...] + songs[..<start]), chips: [Chip(name: "All", playlistId: "a", params: "", isSelected: true),
                                               Chip(name: "Familiar", playlistId: "f", params: "p", isSelected: false)])
    }
    func reportPlay(_ videoId: String) async throws -> HistoryResult { reported.append(videoId); return historyResult }
    func like(_ videoId: String) async throws { liked.append(videoId) }
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
}
