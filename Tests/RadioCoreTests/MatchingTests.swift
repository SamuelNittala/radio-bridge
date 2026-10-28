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

    func track(_ id: Int, _ name: String, _ artist: String, ms: Int = 184_000) -> AppleTrack {
        AppleTrack(trackId: id, trackName: name, artistName: artist, collectionName: "Blonde", trackTimeMillis: ms)
    }

    @Test func sameSong() {
        #expect(Matching.isSameSong(song, track(1, "Pink + White", "Frank Ocean")))
        #expect(!Matching.isSameSong(song, track(1, "Pink + White", "Someone Else")))
        #expect(!Matching.isSameSong(song, track(1, "Pink + White", "Frank Ocean", ms: 240_000)))
        #expect(!Matching.isSameSong(song, track(1, "Nikes", "Frank Ocean")))
    }

    @Test func topResultIsUsedAsIs() async throws {
        let match = try await Matching.findQuery(for: song) { _, _ in [self.track(1, "Pink + White", "Frank Ocean")] }
        #expect(match == CatalogMatch(query: "Pink + White Frank Ocean", track: track(1, "Pink + White", "Frank Ocean")))
    }

    // The case from the log: the store put "White (feat. John Mayer)" first.
    @Test func refinesWhenRightSongIsNotFirst() async throws {
        let white = track(1, "White (feat. John Mayer)", "Frank Ocean"), pink = track(2, "Pink + White", "Frank Ocean")
        var searches: [String] = []
        let match = try await Matching.findQuery(for: song) { term, limit in
            searches.append("\(term) /\(limit)")
            if term.hasSuffix("Blonde") { return [pink] }
            return limit == 1 ? [white] : [white, pink]
        }
        #expect(match?.query == "Pink + White Frank Ocean Blonde")
        #expect(match?.track.trackId == 2)
        #expect(searches == ["Pink + White Frank Ocean /1", "Pink + White Frank Ocean /10", "Pink + White Frank Ocean Blonde /1"])
    }

    // "Adhento Gaani Vunnapaatuga": the store lists a "Vocals Only" single first, and the
    // precise search for the compilation release returns the soundtrack release instead.
    @Test func acceptsAnotherReleaseOfTheSong() async throws {
        let song = Song(videoId: "v", title: "Adhento Gaani Vunnapaatuga", artists: ["Anirudh Ravichander"], length: 238)
        let vocals = AppleTrack(trackId: 1, trackName: "Adhento Gaani Vunnapaatuga - Anirudh Ravichander Vocals Only",
                                artistName: "Anirudh Ravichander", collectionName: "Single", trackTimeMillis: 195_000)
        let compilation = AppleTrack(trackId: 2, trackName: "Adhento Gaani Vunnapaatuga", artistName: "Anirudh Ravichander",
                                     collectionName: "Telugu Romantic Hits", trackTimeMillis: 237_000)
        let soundtrack = AppleTrack(trackId: 3, trackName: "Adhento Gaani Vunnapaatuga", artistName: "Anirudh Ravichander",
                                    collectionName: "Jersey", trackTimeMillis: 237_000)
        let match = try await Matching.findQuery(for: song) { term, limit in
            if term.hasSuffix("Telugu Romantic Hits") { return [soundtrack] }
            return limit == 1 ? [vocals] : [vocals, compilation, soundtrack]
        }
        #expect(match?.track.trackId == 3)
        #expect(match?.query == "Adhento Gaani Vunnapaatuga Anirudh Ravichander Telugu Romantic Hits")
    }

    @Test func plainTitleIsTheLastSearch() {
        let one = Song(videoId: "v", title: "Song (Live)", artists: ["A"])
        #expect(Matching.queries(for: one) == ["Song (Live) A", "song A", "Song (Live)"])
    }

    @Test func notOnAppleMusic() async throws {
        let match = try await Matching.findQuery(for: song) { _, _ in [self.track(9, "Other", "Other")] }
        #expect(match == nil)
    }
}
