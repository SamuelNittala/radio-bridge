import Foundation

public enum CatalogError: LocalizedError, Equatable {
    case http(Int)
    /// Searches are paused after a failure; nothing was sent.
    case backingOff(until: Date)

    public var errorDescription: String? {
        switch self {
        case .http(let code) where code == 403 || code == 429:
            "Apple's search refused the request (HTTP \(code)): too many searches. Pausing searches for a while."
        case .http(let code):
            "Apple's search returned HTTP \(code)."
        case .backingOff(let until):
            "Apple's search is paused until \(until.formatted(date: .omitted, time: .standard))."
        }
    }
}

/// Apple's catalog via the free iTunes Search API.
///
/// Remembers each YT song's result on disk, found or not, so a song that comes up
/// again costs no searches. Songs search can't find are looked for in their artist's
/// full song list (two more requests, once per artist). The API allows roughly 20 requests a minute; after a
/// failure, searches pause (1 minute, doubling up to 10) instead of retrying at once.
public actor AppleCatalog: Catalog {
    public typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    struct Cached: Codable {
        var track: AppleTrack?
        var date: Date
    }

    /// Catalogs change: songs not found are looked up again after a week, found ones after a month.
    static let missingLifetime: TimeInterval = 7 * 86400
    static let foundLifetime: TimeInterval = 30 * 86400
    static let firstPause: TimeInterval = 60
    static let longestPause: TimeInterval = 600
    static let resultsPerSearch = 10

    public nonisolated let country: String
    private let cacheFile: URL?
    private let fetch: Fetch
    private let clock: @Sendable () -> Date
    private var cache: [String: Cached]
    private var artistCache: [String: [AppleTrack]] = [:]
    private var pausedUntil: Date?
    private var failures = 0

    public init(country: String, cacheFile: URL? = AppleCatalog.defaultCacheFile,
                fetch: @escaping Fetch = AppleCatalog.urlSessionFetch,
                clock: @escaping @Sendable () -> Date = Date.init) {
        self.country = country
        self.cacheFile = cacheFile
        self.fetch = fetch
        self.clock = clock
        cache = cacheFile.flatMap { try? JSONDecoder().decode([String: Cached].self, from: Data(contentsOf: $0)) } ?? [:]
    }

    public static var defaultCacheFile: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Radio Bridge/apple-tracks.json")
    }

    public static let urlSessionFetch: Fetch = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func find(_ song: Song) async throws -> AppleTrack? {
        let key = "\(country)|\(song.videoId)"
        if let hit = cache[key],
           clock().timeIntervalSince(hit.date) < (hit.track == nil ? Self.missingLifetime : Self.foundLifetime) {
            return hit.track
        }
        let track = try await Matching.findTrack(for: song, search: { try await self.search($0) },
                                                 artistSongs: { try await self.artistSongs($0) })
        cache[key] = Cached(track: track, date: clock())
        save()
        return track
    }

    public func search(_ term: String) async throws -> [AppleTrack] {
        try await request("search", ["term": term, "entity": "song", "limit": String(Self.resultsPerSearch)])
    }

    /// Everything Apple has by an artist (up to 200 songs), including songs search hides.
    /// Kept for the session: a radio often plays several songs by one artist.
    public func artistSongs(_ name: String) async throws -> [AppleTrack] {
        let key = Matching.norm(name)
        if let songs = artistCache[key] { return songs }
        struct Artist: Decodable { var artistId: Int; var artistName: String }
        let artists: [Artist] = try await request("search", ["term": name, "entity": "musicArtist", "limit": "5"])
        var songs: [AppleTrack] = []
        if let artist = artists.first(where: { Matching.norm($0.artistName) == key }) {
            songs = try await request("lookup", ["id": String(artist.artistId), "entity": "song", "limit": "200"])
        }
        artistCache[key] = songs
        return songs
    }

    private func request<T: Decodable>(_ endpoint: String, _ items: [String: String]) async throws -> [T] {
        if let pausedUntil, clock() < pausedUntil { throw CatalogError.backingOff(until: pausedUntil) }
        var url = URLComponents(string: "https://itunes.apple.com/\(endpoint)")!
        url.queryItems = (items.merging(["country": country]) { a, _ in a })
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        do {
            let (data, status) = try await fetch(url.url!)
            guard status == 200 else { throw CatalogError.http(status) }
            let results = try JSONDecoder().decode(Response<T>.self, from: data).results.compactMap(\.item)
            failures = 0
            pausedUntil = nil
            return results
        } catch {
            failures += 1
            let pause = min(Self.firstPause * pow(2, Double(failures - 1)), Self.longestPause)
            pausedUntil = clock().addingTimeInterval(pause)
            throw error
        }
    }

    private func save() {
        guard let cacheFile, let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
    }
}

private struct Response<T: Decodable>: Decodable { var results: [Lossy<T>] }

/// Skips odd results (missing fields, or an artist row in a lookup) instead of failing the whole request.
private struct Lossy<T: Decodable>: Decodable {
    var item: T?
    init(from decoder: Decoder) throws { item = try? T(from: decoder) }
}
