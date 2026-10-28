import Foundation

/// Reads the parts of YT Music's JSON responses the app needs.
/// Searches by renderer name instead of fixed paths, so small layout changes don't break it.
public enum YTParser {
    typealias JSON = [String: Any]

    static func dig(_ node: Any?, _ path: Any...) -> Any? {
        var node = node
        for key in path {
            switch key {
            case let k as String: node = (node as? JSON)?[k]
            case let i as Int:
                guard let list = node as? [Any], list.indices.contains(i) else { return nil }
                node = list[i]
            default: return nil
            }
        }
        return node
    }

    /// Every value stored under `key`, anywhere in the response, in document order.
    static func findAll(_ key: String, in node: Any) -> [JSON] {
        var found: [JSON] = []
        func walk(_ node: Any) {
            if let dict = node as? JSON {
                if let value = dict[key] as? JSON { found.append(value) }
                for (k, v) in dict where k != key { walk(v) }
            } else if let list = node as? [Any] {
                list.forEach(walk)
            }
        }
        walk(node)
        return found
    }

    static func text(_ node: Any?) -> String {
        ((dig(node, "runs") as? [JSON]) ?? []).compactMap { $0["text"] as? String }.joined()
    }

    static func thumbnail(_ node: Any?) -> URL? {
        let thumbs = (dig(node, "thumbnails") as? [JSON])
            ?? (dig(node, "musicThumbnailRenderer", "thumbnail", "thumbnails") as? [JSON]) ?? []
        return (thumbs.last?["url"] as? String).flatMap(URL.init(string:))
    }

    /// Artists from a byline like "A, B & C • Album • 2024": the runs before the first " • ",
    /// without the separators between them.
    static func artists(_ runs: [JSON]) -> [String] {
        let texts = runs.compactMap { $0["text"] as? String }
        let head = texts.prefix { $0 != " • " }
        return head.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
    }

    // MARK: - Responses

    public static func parseSearch(_ data: Data) throws -> [Song] {
        let json = try JSONSerialization.jsonObject(with: data)
        return findAll("musicResponsiveListItemRenderer", in: json).compactMap { item in
            guard let videoId = dig(item, "playlistItemData", "videoId") as? String,
                  let columns = item["flexColumns"] as? [JSON] else { return nil }
            let column = { (i: Int) in dig(columns, i, "musicResponsiveListItemFlexColumnRenderer", "text") }
            let byline = (dig(column(1), "runs") as? [JSON]) ?? []
            let length = byline.compactMap { $0["text"] as? String }.last(where: Matching.isDuration)
            return Song(videoId: videoId, title: text(column(0)), artists: artists(byline),
                        length: Matching.seconds(length), thumbnail: thumbnail(item["thumbnail"]))
        }
    }

    public static func parseRadio(_ data: Data) throws -> RadioPage {
        let json = try JSONSerialization.jsonObject(with: data)
        let panel = findAll("playlistPanelRenderer", in: json).first
        let songs: [Song] = ((panel?["contents"] as? [JSON]) ?? []).compactMap { item in
            let renderer = (item["playlistPanelVideoRenderer"]
                ?? dig(item, "playlistPanelVideoWrapperRenderer", "primaryRenderer", "playlistPanelVideoRenderer"))
                as? JSON
            guard let renderer, renderer["unplayableText"] == nil,
                  let videoId = renderer["videoId"] as? String else { return nil }
            let byline = (dig(renderer, "longBylineText", "runs") as? [JSON]) ?? []
            return Song(videoId: videoId, title: text(renderer["title"]), artists: artists(byline),
                        length: Matching.seconds(dig(renderer, "lengthText", "runs", 0, "text") as? String),
                        thumbnail: thumbnail(renderer["thumbnail"]))
        }
        let chips: [Chip] = findAll("chipCloudChipRenderer", in: json).compactMap { chip in
            guard let endpoint = dig(chip, "navigationEndpoint", "queueUpdateCommand",
                                     "fetchContentsCommand", "watchEndpoint") as? JSON,
                  let playlistId = endpoint["playlistId"] as? String else { return nil }
            return Chip(name: text(chip["text"]), playlistId: playlistId,
                        params: endpoint["params"] as? String ?? "",
                        isSelected: chip["isSelected"] as? Bool ?? false)
        }
        return RadioPage(songs: songs, chips: chips)
    }

    /// The signed-in account, or nil when YT treats the request as signed out.
    public static func parseAccount(_ data: Data) throws -> Account? {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let header = findAll("activeAccountHeaderRenderer", in: json).first else { return nil }
        return Account(name: text(header["accountName"]), photo: thumbnail(header["accountPhoto"]))
    }

    /// The URL that records a play, or why there is none.
    public static func parsePlaybackTracking(_ data: Data) throws -> Result<URL, HistoryError> {
        let json = try JSONSerialization.jsonObject(with: data)
        if let base = dig(json, "playbackTracking", "videostatsPlaybackUrl", "baseUrl") as? String,
           let url = URL(string: base) {
            return .success(url)
        }
        let status = dig(json, "playabilityStatus", "status") as? String ?? "unknown"
        let reason = dig(json, "playabilityStatus", "reason") as? String
        return .failure(HistoryError(reason: [status, reason].compactMap { $0 }.joined(separator: " ")))
    }

    public struct HistoryError: Error, Equatable {
        public var reason: String
    }
}
