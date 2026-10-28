import Foundation
import Testing
@testable import RadioCore

@Suite struct Normalising {
    @Test func titles() {
        #expect(Matching.normTitle("Hey Jude - Remastered 2015") == "hey jude")
        #expect(Matching.normTitle(#"Killin' 'em (From "Scene")"#) == "killin em")
        #expect(Matching.normTitle("Pink + White [Live]") == "pink white")
    }

    @Test func artists() {
        #expect(Matching.normArtists("A, B & C feat. D") == ["a", "b", "c", "d"])
        #expect(Matching.normArtists("Simon and Garfunkel") == ["simon", "garfunkel"])
        #expect(Matching.normArtists("Sushin Shyam x Yung Raja") == ["sushin shyam", "yung raja"])
        // Not split inside words.
        #expect(Matching.normArtists("Alexandra") == ["alexandra"])
    }

    @Test func lengths() {
        #expect(Matching.seconds("3:45") == 225)
        #expect(Matching.seconds("1:02:03") == 3723)
        #expect(Matching.seconds(nil) == nil)
        #expect(Matching.seconds("2026") == nil)
    }
}

@Suite struct CatalogMatching {
    let song = Song(videoId: "v", title: "Pink + White", artists: ["Frank Ocean"], length: 184)

    func track(_ id: Int, _ name: String, _ artist: String, ms: Int = 184_000, album: String = "Blonde") -> AppleTrack {
        AppleTrack(trackId: id, trackName: name, artistName: artist, collectionName: album, trackTimeMillis: ms,
                   trackViewUrl: URL(string: "https://music.apple.com/in/album/x/1?i=\(id)"))
    }

    @Test func sameSong() {
        #expect(Matching.isSameSong(song, track(1, "Pink + White", "Frank Ocean")))
        #expect(!Matching.isSameSong(song, track(1, "Pink + White", "Someone Else")))
        #expect(!Matching.isSameSong(song, track(1, "Pink + White", "Frank Ocean", ms: 240_000)))
        #expect(!Matching.isSameSong(song, track(1, "Nikes", "Frank Ocean")))
    }

    @Test func oneSearchWhenTheSongIsInTheResults() async throws {
        var searches: [String] = []
        let found = try await Matching.findTrack(for: song) { searches.append($0); return [self.track(1, "Pink + White", "Frank Ocean")] }
        #expect(found?.trackId == 1)
        #expect(searches == ["Pink + White Frank Ocean"])
    }

    // The store put "White (feat. John Mayer)" first; "White" is in "Pink + White" but isn't that song.
    @Test func exactTitleWinsOverHigherRankedPartialOne() async throws {
        let white = track(1, "White (feat. John Mayer)", "Frank Ocean"), pink = track(2, "Pink + White", "Frank Ocean")
        let found = try await Matching.findTrack(for: song) { _ in [white, pink] }
        #expect(found?.trackId == 2)
    }

    // "Blinding Lights The Weeknd": the store's one-result search came back empty, and the
    // ROSALÍA remix has the same title once "(Remix)" is dropped; its length rules it out.
    @Test func picksTheRightVersionFromTheResults() async throws {
        let song = Song(videoId: "v", title: "Blinding Lights", artists: ["The Weeknd"], length: 202)
        let remix = track(1, "Blinding Lights (Remix)", "The Weeknd & ROSALÍA", ms: 216_000, album: "Single")
        let original = track(2, "Blinding Lights", "The Weeknd", ms: 200_000, album: "After Hours (Deluxe)")
        let found = try await Matching.findTrack(for: song) { _ in [remix, original] }
        #expect(found?.trackId == 2)
    }

    // "Adhento Gaani Vunnapaatuga": a "Vocals Only" single comes first; any full release will do.
    @Test func acceptsAnotherReleaseOfTheSong() async throws {
        let song = Song(videoId: "v", title: "Adhento Gaani Vunnapaatuga", artists: ["Anirudh Ravichander"], length: 238)
        let vocals = track(1, "Adhento Gaani Vunnapaatuga - Anirudh Ravichander Vocals Only", "Anirudh Ravichander",
                           ms: 195_000, album: "Single")
        let compilation = track(2, "Adhento Gaani Vunnapaatuga", "Anirudh Ravichander", ms: 237_000, album: "Telugu Romantic Hits")
        let soundtrack = track(3, "Adhento Gaani Vunnapaatuga", "Anirudh Ravichander", ms: 237_000, album: "Jersey")
        let found = try await Matching.findTrack(for: song) { _ in [vocals, compilation, soundtrack] }
        #expect(found?.trackId == 2)
    }

    @Test func resultsWithoutALinkCantBeQueued() async throws {
        var noLink = track(1, "Pink + White", "Frank Ocean")
        noLink.trackViewUrl = nil
        let found = try await Matching.findTrack(for: song) { _ in [noLink] }
        #expect(found == nil)
    }

    @Test func plainTitleIsTheLastSearch() {
        let one = Song(videoId: "v", title: "Song (Live)", artists: ["A"])
        #expect(Matching.queries(for: one) == ["Song (Live) A", "song A", "Song (Live)"])
    }

    @Test func notOnAppleMusic() async throws {
        var searches = 0
        let found = try await Matching.findTrack(for: song) { _ in searches += 1; return [self.track(9, "Other", "Other")] }
        #expect(found == nil)
        #expect(searches == Matching.queries(for: song).count)
    }
}
