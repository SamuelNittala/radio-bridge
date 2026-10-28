import Foundation
import Testing
@testable import RadioCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct YTParsing {
    @Test func searchSongs() throws {
        let songs = try YTParser.parseSearch(fixture("search"))
        let first = try #require(songs.first)
        #expect(first.videoId == "VPI2ORXVwgg")
        #expect(first.title == #"Killin' 'em (From "Scene")"#)
        #expect(first.artists == ["Sushin Shyam", "Yung Raja"])
        #expect(first.length == 95)
        #expect(first.thumbnail != nil)
        #expect(songs.count > 5)
    }

    // Expected values are what ytmusicapi's parse_watch_playlist gives for the same response.
    @Test func radioSongs() throws {
        let page = try YTParser.parseRadio(fixture("next"))
        #expect(page.songs.count == 50)
        #expect(page.songs[0].videoId == "VPI2ORXVwgg")
        #expect(page.songs[1].title == "Kuthanthram")
        #expect(page.songs[1].artists == ["Sushin Shyam", "Vedan"])
        #expect(page.songs[1].length == 241)
        #expect(page.songs[2].artists == ["Anirudh Ravichander", "Super Subu", "M.S Krsna", "Heisenberg"])
        #expect(page.songs.last?.videoId == "IS-nxb-c_ME")
        #expect(page.songs.last?.artists == ["Jakes Bejoy", "Adhri Joe", "Tribemama Marykali"])
    }

    @Test func radioChips() throws {
        let chips = try YTParser.parseRadio(fixture("next")).chips
        // "Save" is a button in the same row but has no radio behind it.
        // Signed out, so there is no "Familiar" (it needs listening history).
        #expect(chips.map(\.name) == ["All", "Discover", "Party", "Workout", "Tamil", "Desi hip-hop"])
        #expect(chips.filter(\.isSelected).map(\.name) == ["All"])
        #expect(chips[1].playlistId.hasPrefix("RDAT"))
        #expect(!chips[1].params.isEmpty)
    }

    @Test func account() throws {
        let signedIn = Data(#"""
            {"actions":[{"openPopupAction":{"popup":{"multiPageMenuRenderer":{"header":{"activeAccountHeaderRenderer":
            {"accountName":{"runs":[{"text":"Sam"}]},"accountPhoto":{"thumbnails":[{"url":"https://x/a.jpg"}]}}}}}}}]}
            """#.utf8)
        #expect(try YTParser.parseAccount(signedIn) == Account(name: "Sam", photo: URL(string: "https://x/a.jpg")))
        #expect(try YTParser.parseAccount(Data(#"{"actions":[]}"#.utf8)) == nil)
    }

    @Test func playbackTracking() throws {
        let ok = Data(#"{"playbackTracking":{"videostatsPlaybackUrl":{"baseUrl":"https://s.youtube.com/api/stats/playback?a=1"}}}"#.utf8)
        #expect(try YTParser.parsePlaybackTracking(ok) == .success(URL(string: "https://s.youtube.com/api/stats/playback?a=1")!))
        // The J. Cole case: YT leaves playbackTracking out for songs it won't play.
        let blocked = Data(#"{"playabilityStatus":{"status":"UNPLAYABLE","reason":"This video is not available"}}"#.utf8)
        #expect(try YTParser.parsePlaybackTracking(blocked)
                == .failure(.init(reason: "UNPLAYABLE This video is not available")))
    }
}

@Suite struct Auth {
    @Test func sapisidHash() {
        // sha1("1700000000 abc https://music.youtube.com")
        #expect(YTClient.authorization(sapisid: "abc", now: Date(timeIntervalSince1970: 1_700_000_000))
                == "SAPISIDHASH 1700000000_2f3ec011e870f3fbd0238c090c2062c208cead32")
    }

    // Vectors made with Python's hashlib and the openssl CLI.
    @Test func cookieDecryption() {
        let key = CookieReader.deriveKey(password: Data("peanuts".utf8))
        #expect(key == Data(hex: "d9a09d499b4e1b7461f28e67972c6dbd"))
        let current = Data(hex: "763130dfedf6a25de951793acf97b7e0577316f5009863e773f7845c5b1d94c4dd66300f5c23c015dee37b739232f01274d110")
        #expect(CookieReader.decrypt(current, key: key, metaVersion: 24) == "value-123")
        let old = Data(hex: "763130dc7392934a14501d34bc5d2c08579b2d")
        #expect(CookieReader.decrypt(old, key: key, metaVersion: 18) == "old-style")
        #expect(CookieReader.decrypt(Data("plain".utf8), key: key, metaVersion: 24) == nil)
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        self.init(bytes)
    }
}
