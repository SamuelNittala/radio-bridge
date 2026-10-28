import Foundation
import Testing
@testable import RadioCore

/// Stands in for the iTunes Search API: answers from a table, or with an HTTP error.
final class FakeStore: @unchecked Sendable {
    /// Song searches by term, artist searches as "artist:<term>", lookups as "lookup:<id>".
    var calls: [String] = []
    var status = 200
    var tracks: [AppleTrack] = []
    /// Artist name -> ID for artist searches, and each artist's full song list for lookups.
    var artists: [String: Int] = [:]
    var artistSongs: [Int: [AppleTrack]] = [:]
    var now = Date(timeIntervalSince1970: 0)

    func fetch(_ url: URL) -> (Data, Int) {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let item = { (name: String) in parts.queryItems!.first { $0.name == name }?.value }
        let results: [[String: Any]]
        if parts.path == "/lookup" {
            calls.append("lookup:\(item("id")!)")
            results = [["wrapperType": "artist", "artistId": Int(item("id")!)!]] + json(artistSongs[Int(item("id")!)!] ?? [])
        } else if item("entity") == "musicArtist" {
            calls.append("artist:\(item("term")!)")
            results = artists.filter { $0.key == item("term") }.map { ["artistId": $0.value, "artistName": $0.key] }
        } else {
            calls.append(item("term")!)
            results = json(tracks)
        }
        return (try! JSONSerialization.data(withJSONObject: ["results": results]), status)
    }

    func json(_ tracks: [AppleTrack]) -> [[String: Any]] {
        tracks.map {
            ["trackId": $0.trackId, "trackName": $0.trackName, "artistName": $0.artistName,
             "collectionName": $0.collectionName ?? "", "trackTimeMillis": $0.trackTimeMillis ?? 0,
             "trackViewUrl": $0.trackViewUrl?.absoluteString ?? ""] as [String: Any]
        }
    }
}

@Suite struct AppleCatalogCache {
    let store = FakeStore()
    let song = Song(videoId: "v1", title: "Pink + White", artists: ["Frank Ocean"], length: 184)
    let pink = AppleTrack(trackId: 2, trackName: "Pink + White", artistName: "Frank Ocean",
                          collectionName: "Blonde", trackTimeMillis: 184_000,
                          trackViewUrl: URL(string: "https://music.apple.com/in/album/pink-white/1146195596?i=1146195714"))

    func catalog(file: URL? = nil) -> AppleCatalog {
        let store = self.store
        return AppleCatalog(country: "in", cacheFile: file, fetch: { store.fetch($0) }, clock: { store.now })
    }

    @Test func foundSongIsNotSearchedAgain() async throws {
        store.tracks = [pink]
        let catalog = catalog()
        #expect(try await catalog.find(song)?.trackId == 2)
        #expect(try await catalog.find(song)?.trackId == 2)
        #expect(store.calls.count == 1)
    }

    @Test func missingSongIsRetriedAfterAWeek() async throws {
        let catalog = catalog()
        #expect(try await catalog.find(song) == nil)
        let searches = store.calls.count
        store.now += 6 * 86400
        #expect(try await catalog.find(song) == nil)
        #expect(store.calls.count == searches)
        store.now += 2 * 86400
        store.tracks = [pink]
        #expect(try await catalog.find(song)?.trackId == 2)
    }

    // Search hides "Nikes"; the artist's song list has it, and is fetched once per artist.
    @Test func findsSongsSearchHidesThroughTheArtist() async throws {
        let nikes = AppleTrack(trackId: 1146195712, trackName: "Nikes", artistName: "Frank Ocean", collectionName: "Blonde",
                               trackTimeMillis: 314_000, trackViewUrl: URL(string: "https://music.apple.com/in/album/nikes/1146195596?i=1146195712"))
        store.artists = ["Frank Ocean": 442122051]
        store.artistSongs = [442122051: [pink, nikes]]
        let catalog = catalog()
        #expect(try await catalog.find(Song(videoId: "v2", title: "Nikes", artists: ["Frank Ocean"], length: 314))?.trackId == 1146195712)
        #expect(store.calls.filter { !$0.contains(":") }.count == Matching.queries(for: Song(videoId: "", title: "Nikes", artists: ["Frank Ocean"])).count)
        #expect(store.calls.filter { $0.contains(":") } == ["artist:Frank Ocean", "lookup:442122051"])

        // Another hidden song by the same artist: no more artist requests.
        #expect(try await catalog.find(song)?.trackId == 2)
        #expect(store.calls.filter { $0.contains(":") }.count == 2)
    }

    @Test func unknownArtistIsLookedUpOnce() async throws {
        let catalog = catalog()
        #expect(try await catalog.find(song) == nil)
        #expect(try await catalog.find(Song(videoId: "v3", title: "Nikes", artists: ["Frank Ocean"])) == nil)
        #expect(store.calls.filter { $0.contains(":") } == ["artist:Frank Ocean"])
    }

    @Test func cacheSurvivesRestart() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        store.tracks = [pink]
        _ = try await catalog(file: file).find(song)
        store.calls = []
        #expect(try await catalog(file: file).find(song)?.trackId == 2)
        #expect(store.calls.isEmpty)
    }

    @Test func pausesAfterRefusalAndDoublesThePause() async throws {
        let catalog = catalog()
        store.status = 403
        await #expect(throws: CatalogError.http(403)) { try await catalog.find(song) }
        // Paused for a minute: nothing is sent.
        store.now += 30
        await #expect(throws: CatalogError.backingOff(until: Date(timeIntervalSince1970: 60))) {
            try await catalog.find(song)
        }
        #expect(store.calls.count == 1)
        // Still refused after the pause: the next pause is two minutes.
        store.now += 31
        await #expect(throws: CatalogError.http(403)) { try await catalog.find(song) }
        store.now += 119
        await #expect(throws: CatalogError.backingOff(until: Date(timeIntervalSince1970: 181))) {
            try await catalog.find(song)
        }
        // Works again once the pause is over; a success resets it.
        store.now += 2
        store.status = 200
        store.tracks = [pink]
        #expect(try await catalog.find(song)?.trackId == 2)
    }
}
