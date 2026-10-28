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
/// again costs no searches. The API allows roughly 20 requests a minute; after a
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
        let track = try await Matching.findTrack(for: song) { try await self.search($0) }
        cache[key] = Cached(track: track, date: clock())
        save()
        return track
    }

    public func search(_ term: String) async throws -> [AppleTrack] {
        if let pausedUntil, clock() < pausedUntil { throw CatalogError.backingOff(until: pausedUntil) }
        var url = URLComponents(string: "https://itunes.apple.com/search")!
        url.queryItems = [
            URLQueryItem(name: "term", value: term), URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: "song"), URLQueryItem(name: "limit", value: String(Self.resultsPerSearch)),
        ]
        do {
            let (data, status) = try await fetch(url.url!)
            guard status == 200 else { throw CatalogError.http(status) }
            // Skip odd results (missing fields) instead of failing the whole search.
            struct Lossy: Decodable {
                var track: AppleTrack?
                init(from decoder: Decoder) throws { track = try? AppleTrack(from: decoder) }
            }
            struct Response: Decodable { var results: [Lossy] }
            let tracks = try JSONDecoder().decode(Response.self, from: data).results.compactMap(\.track)
            failures = 0
            pausedUntil = nil
            return tracks
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

