import Foundation
import Testing
@testable import RadioCore

/// Stands in for the iTunes Search API: answers from a table, or with an HTTP error.
final class FakeStore: @unchecked Sendable {
    var calls: [String] = []
    var status = 200
    var tracks: [AppleTrack] = []
    var now = Date(timeIntervalSince1970: 0)

    func fetch(_ url: URL) -> (Data, Int) {
        calls.append(URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == "term" }!.value!)
        let body = try! JSONSerialization.data(withJSONObject: ["results": tracks.map {
            ["trackId": $0.trackId, "trackName": $0.trackName, "artistName": $0.artistName,
             "collectionName": $0.collectionName ?? "", "trackTimeMillis": $0.trackTimeMillis ?? 0] as [String: Any]
        }])
        return (body, status)
    }
}

@Suite struct AppleCatalogCache {
    let store = FakeStore()
    let song = Song(videoId: "v1", title: "Pink + White", artists: ["Frank Ocean"], length: 184)
    let pink = AppleTrack(trackId: 2, trackName: "Pink + White", artistName: "Frank Ocean",
                          collectionName: "Blonde", trackTimeMillis: 184_000)

    func catalog(file: URL? = nil) -> AppleCatalog {
        let store = self.store
        return AppleCatalog(country: "in", cacheFile: file, fetch: { store.fetch($0) }, clock: { store.now })
    }

    @Test func foundSongIsNotSearchedAgain() async throws {
        store.tracks = [pink]
        let catalog = catalog()
        #expect(try await catalog.find(song)?.track.trackId == 2)
        #expect(try await catalog.find(song)?.track.trackId == 2)
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
        #expect(try await catalog.find(song)?.track.trackId == 2)
    }

    @Test func cacheSurvivesRestart() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        store.tracks = [pink]
        _ = try await catalog(file: file).find(song)
        store.calls = []
        #expect(try await catalog(file: file).find(song)?.track.trackId == 2)
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
        #expect(try await catalog.find(song)?.track.trackId == 2)
    }
}
