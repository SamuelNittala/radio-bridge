import CryptoKit
import Foundation

public enum YTError: LocalizedError {
    case signedOut
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .signedOut: "Not signed in to YT Music."
        case .http(let code, let message): "YT Music returned HTTP \(code). \(message)"
        }
    }
}

/// The YT Music requests the app uses, sent the way the website (and ytmusicapi) sends them.
///
/// Cookies are read from the browser for every request, so the session is always as
/// fresh as the browser's own. Uses YT's private API: it can change without notice.
public actor YTClient {
    static let origin = "https://music.youtube.com"
    static let apiBase = origin + "/youtubei/v1/"
    // ytmusicapi's values; YT accepts these from any client.
    static let apiKey = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0"
    static let songsOnly = "EgWKAQIIAWoMEA4QChADEAQQCRAF"

    public typealias CookieSource = @Sendable () throws -> [String: String]

    private var cookies: CookieSource
    private let session: URLSession

    public init(cookies: @escaping CookieSource) {
        self.cookies = cookies
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false  // the Cookie header is set by hand
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    public func setCookies(_ source: @escaping CookieSource) {
        cookies = source
    }

    // MARK: - Requests

    public func account() async throws -> Account? {
        try YTParser.parseAccount(try await send("account/account_menu", [:]))
    }

    public func search(_ query: String) async throws -> [Song] {
        try YTParser.parseSearch(try await send("search", ["query": query, "params": Self.songsOnly]))
    }

    /// Radio from a song. With a filter name (Familiar, Discover...), applies that filter
    /// the way tapping its button does; if the song has no such filter, plain radio.
    public func radio(from videoId: String, filter: String?) async throws -> RadioPage {
        var body: [String: Any] = [
            "enablePersistentPlaylistPanel": true, "isAudioOnly": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL", "videoId": videoId,
        ]
        var page = try YTParser.parseRadio(try await send(
            "next", body.merging(["playlistId": "RDAMVM" + videoId, "params": "wAEB"]) { $1 }))
        guard let filter else { return page }
        guard let chip = page.chips.first(where: { $0.name.caseInsensitiveCompare(filter) == .orderedSame }) else {
            page.filterMissing = true
            return page
        }
        if chip.isSelected { return page }
        body["playlistId"] = chip.playlistId
        body["params"] = chip.params
        let filtered = try YTParser.parseRadio(try await send("next", body))
        return RadioPage(songs: filtered.songs, chips: page.chips)
    }

    /// Adds a song to the account's YT history, as if played there.
    public func reportPlay(_ videoId: String) async throws -> HistoryResult {
        let daysSinceEpoch = Int(Date().timeIntervalSince1970 / 86400)
        let player = try await send("player", [
            "playbackContext": ["contentPlaybackContext": ["signatureTimestamp": daysSinceEpoch - 1]],
            "video_id": videoId,
        ])
        switch try YTParser.parsePlaybackTracking(player) {
        case .failure(let error):
            return .notPossible(error.reason)
        case .success(let base):
            var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            url.queryItems = (url.queryItems ?? []) + [
                URLQueryItem(name: "ver", value: "2"), URLQueryItem(name: "c", value: "WEB_REMIX"),
                URLQueryItem(name: "cpn", value: Self.cpn()),
            ]
            var request = URLRequest(url: url.url!)
            try authorize(&request)
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return code == 204 ? .added : .failed(code)
        }
    }

    public func like(_ videoId: String) async throws {
        _ = try await send("like/like", ["target": ["videoId": videoId]])
    }

    // MARK: - Plumbing

    private func send(_ endpoint: String, _ body: [String: Any]) async throws -> Data {
        var body = body
        body["context"] = [
            "client": ["clientName": "WEB_REMIX", "clientVersion": Self.clientVersion(), "hl": "en"],
            "user": [String: Any](),
        ]
        var request = URLRequest(url: URL(string: "\(Self.apiBase)\(endpoint)?alt=json&key=\(Self.apiKey)")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try authorize(&request)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code < 400 else {
            let message = (try? JSONSerialization.jsonObject(with: data)).flatMap {
                YTParser.dig($0, "error", "message") as? String
            }
            throw YTError.http(code, message ?? "")
        }
        return data
    }

    private func authorize(_ request: inout URLRequest) throws {
        var jar = try cookies()
        jar["SOCS"] = jar["SOCS"] ?? "CAI"  // skips the cookie consent page
        guard let sapisid = jar["__Secure-3PAPISID"] ?? jar["SAPISID"] else { throw YTError.signedOut }
        request.setValue(jar.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        request.setValue(Self.authorization(sapisid: sapisid, now: Date()), forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    }

    /// "SAPISIDHASH <time>_<sha1 of 'time sapisid origin'>", which YT checks against the cookie.
    public static func authorization(sapisid: String, now: Date) -> String {
        let time = String(Int(now.timeIntervalSince1970))
        let digest = Insecure.SHA1.hash(data: Data("\(time) \(sapisid) \(origin)".utf8))
        return "SAPISIDHASH \(time)_" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func clientVersion() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        return "1.\(f.string(from: Date())).01.00"
    }

    /// Random playback ID YT expects with a history ping.
    static func cpn() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String((0..<16).map { _ in chars.randomElement()! })
    }
}
