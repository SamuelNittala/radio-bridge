import Foundation

/// A song as YT Music lists it.
public struct Song: Hashable, Identifiable, Sendable {
    public var videoId: String
    public var title: String
    public var artists: [String]
    /// Seconds; nil when YT doesn't say.
    public var length: Int?
    public var thumbnail: URL?

    public var id: String { videoId }
    public var artistLine: String { artists.joined(separator: ", ") }
    public var label: String { artists.isEmpty ? title : "\(artistLine) - \(title)" }

    public init(videoId: String, title: String, artists: [String], length: Int? = nil, thumbnail: URL? = nil) {
        self.videoId = videoId
        self.title = title
        self.artists = artists
        self.length = length
        self.thumbnail = thumbnail
    }
}

/// A radio filter button (All, Familiar, Discover, a mood or language...).
public struct Chip: Hashable, Identifiable, Sendable {
    public var name: String
    public var playlistId: String
    public var params: String
    public var isSelected: Bool
    public var id: String { name }
}

public struct RadioPage: Sendable {
    public var songs: [Song]
    public var chips: [Chip]
    /// The requested filter isn't offered for this song, so `songs` is plain radio.
    public var filterMissing = false
}

public struct Account: Equatable, Sendable {
    public var name: String
    public var photo: URL?
}

public enum HistoryResult: Equatable, Sendable {
    case added
    /// YT won't play this song for the account or region, so it can't be in history.
    case notPossible(String)
    case failed(Int)
}

/// A song in Apple's catalog, as the iTunes Search API returns it.
public struct AppleTrack: Codable, Hashable, Sendable {
    public var trackId: Int
    public var trackName: String
    public var artistName: String
    public var collectionName: String?
    public var trackTimeMillis: Int?
    public var artworkUrl100: URL?

    public init(trackId: Int, trackName: String, artistName: String, collectionName: String? = nil,
                trackTimeMillis: Int? = nil, artworkUrl100: URL? = nil) {
        self.trackId = trackId
        self.trackName = trackName
        self.artistName = artistName
        self.collectionName = collectionName
        self.trackTimeMillis = trackTimeMillis
        self.artworkUrl100 = artworkUrl100
    }
}

/// A store search whose top result is the song, plus that result.
public struct CatalogMatch: Codable, Equatable, Sendable {
    public var query: String
    public var track: AppleTrack
}

/// What the shortcut reports it queued.
public struct QueuedTrack: Equatable, Sendable {
    public var trackId: Int?
    public var name: String

    public init(trackId: Int?, name: String) {
        self.trackId = trackId
        self.name = name
    }
}

public enum PlayerState: Sendable { case stopped, playing, paused }

public struct PlayerStatus: Equatable, Sendable {
    public var state: PlayerState
    public var pid = ""
    public var name = ""
    public var duration = 0.0
    public var position = 0.0
    public var favorited = false

    public static let stopped = PlayerStatus(state: .stopped)

    public init(state: PlayerState, pid: String = "", name: String = "", duration: Double = 0,
                position: Double = 0, favorited: Bool = false) {
        self.state = state
        self.pid = pid
        self.name = name
        self.duration = duration
        self.position = position
        self.favorited = favorited
    }
}
