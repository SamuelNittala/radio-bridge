import CommonCrypto
import Foundation
import Security
import SQLite3

/// A Chromium-based browser whose saved cookies can be read.
public struct Browser: Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let bundleID: String
    /// Folder under ~/Library/Application Support holding the profiles.
    let dataDir: String
    /// Keychain item holding the key the browser encrypts cookies with.
    let keychainName: String

    public static let all: [Browser] = [
        Browser(id: "chrome", name: "Google Chrome", bundleID: "com.google.Chrome",
                dataDir: "Google/Chrome", keychainName: "Chrome"),
        Browser(id: "brave", name: "Brave", bundleID: "com.brave.Browser",
                dataDir: "BraveSoftware/Brave-Browser", keychainName: "Brave"),
        Browser(id: "edge", name: "Microsoft Edge", bundleID: "com.microsoft.edgemac",
                dataDir: "Microsoft Edge", keychainName: "Microsoft Edge"),
        Browser(id: "arc", name: "Arc", bundleID: "company.thebrowser.Browser",
                dataDir: "Arc/User Data", keychainName: "Arc"),
        Browser(id: "vivaldi", name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi",
                dataDir: "Vivaldi", keychainName: "Vivaldi"),
        Browser(id: "chromium", name: "Chromium", bundleID: "org.chromium.Chromium",
                dataDir: "Chromium", keychainName: "Chromium"),
    ]

    public static func named(_ id: String) -> Browser? { all.first { $0.id == id } }

    var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(dataDir)
    }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: root.path) }

    /// Profiles that have cookies, "Default" first, named as the browser shows them.
    public func profiles() -> [BrowserProfile] {
        let names = Self.profileNames(at: root.appendingPathComponent("Local State"))
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return dirs
            .filter { cookieFile(profile: $0) != nil }
            .sorted { a, b in
                if a == "Default" || b == "Default" { return a == "Default" && b != "Default" }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            .map { BrowserProfile(dir: $0, name: names[$0] ?? $0) }
    }

    func cookieFile(profile: String) -> URL? {
        let dir = root.appendingPathComponent(profile)
        return [dir.appendingPathComponent("Cookies"), dir.appendingPathComponent("Network/Cookies")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func profileNames(at localState: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: localState),
              let json = try? JSONSerialization.jsonObject(with: data),
              let cache = YTParser.dig(json, "profile", "info_cache") as? [String: [String: Any]]
        else { return [:] }
        return cache.compactMapValues { $0["name"] as? String }
    }
}

public struct BrowserProfile: Hashable, Identifiable, Sendable {
    public let dir: String
    public let name: String
    public var id: String { dir }
}

public enum CookieError: LocalizedError, Equatable {
    case noCookieFile(String)
    case keychain(String, OSStatus)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .noCookieFile(let where_): "No cookies found for \(where_)."
        case .keychain(let browser, let status) where status == errSecUserCanceled || status == errSecAuthFailed:
            "macOS didn't allow reading \(browser)'s cookies. Try again and click Allow."
        case .keychain(let browser, let status):
            "Couldn't get \(browser)'s cookie key from the Keychain (error \(status))."
        case .unreadable(let detail): "Couldn't read the browser's cookies: \(detail)"
        }
    }
}

/// Reads YouTube cookies from a Chromium browser's cookie database on disk.
///
/// The database is copied first, because the browser keeps it open. Values are
/// AES-encrypted with a key derived from a password in the Keychain; macOS asks
/// the user once per app launch before handing it over.
public final class CookieReader: @unchecked Sendable {
    private var keys: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    /// Cookies for youtube.com and its subdomains, name -> value.
    public func youtubeCookies(browser: Browser, profile: String) throws -> [String: String] {
        guard let file = browser.cookieFile(profile: profile) else {
            throw CookieError.noCookieFile("\(browser.name), profile \(profile)")
        }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("cookies-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: file, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CookieError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        let version = Int(Self.query(db, "SELECT value FROM meta WHERE key = 'version'").first?[0].text ?? "") ?? 0
        let rows = Self.query(db, """
            SELECT name, value, encrypted_value FROM cookies
            WHERE host_key = '.youtube.com' OR host_key = 'youtube.com' OR host_key LIKE '%.youtube.com'
            """)
        var cookies: [String: String] = [:]
        var key: Data?
        for row in rows {
            let name = row[0].text ?? "", plain = row[1].text ?? ""
            if !plain.isEmpty {
                cookies[name] = plain
                continue
            }
            if key == nil { key = try self.key(for: browser) }
            if let value = Self.decrypt(row[2].blob ?? Data(), key: key!, metaVersion: version) {
                cookies[name] = value
            }
        }
        return cookies
    }

    private func key(for browser: Browser) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let key = keys[browser.id] { return key }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(browser.keychainName) Safe Storage",
            kSecAttrAccount as String: browser.keychainName,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let password = item as? Data else {
            throw CookieError.keychain(browser.name, status)
        }
        let key = Self.deriveKey(password: password)
        keys[browser.id] = key
        return key
    }

    // MARK: - Crypto, as Chromium does it on macOS

    public static func deriveKey(password: Data) -> Data {
        let salt = Data("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        _ = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { pw in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        return key
    }

    /// Decrypts a "v10" value. From database version 24 on, the plaintext starts
    /// with a 32-byte hash of the cookie's domain, which is dropped.
    public static func decrypt(_ encrypted: Data, key: Data, metaVersion: Int) -> String? {
        guard encrypted.starts(with: Data("v10".utf8)) else { return nil }
        let body = encrypted.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: body.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            body.withUnsafeBytes { b in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress, b.baseAddress, body.count,
                                o.baseAddress, o.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        var plain = out.prefix(moved)
        if metaVersion >= 24 { plain = plain.dropFirst(32) }
        return String(data: plain, encoding: .utf8)
    }

    // MARK: - SQLite

    struct Value {
        var text: String?
        var blob: Data?
    }

    private static func query(_ db: OpaquePointer?, _ sql: String) -> [[Value]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [[Value]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(stmt)).map { i in
                if sqlite3_column_type(stmt, i) == SQLITE_BLOB {
                    let count = Int(sqlite3_column_bytes(stmt, i))
                    return Value(blob: sqlite3_column_blob(stmt, i).map { Data(bytes: $0, count: count) })
                }
                return Value(text: sqlite3_column_text(stmt, i).map { String(cString: $0) })
            })
        }
        return rows
    }
}
