import AppKit
import Observation
import RadioCore

@MainActor @Observable
final class AppModel {
    enum SignIn: Equatable {
        case checking
        case signedIn(Account, BrowserProfile)
        case signedOut(String)
        case failed(String)
    }

    var signIn = SignIn.checking
    var browser: Browser
    var profiles: [BrowserProfile] = []

    var query = "" {
        didSet { scheduleSearch() }
    }
    var results: [Song] = []
    var searching = false
    var searchError: String?

    /// Shortcuts the app needs that the user hasn't made yet.
    var missingShortcuts: [String] = []
    /// False until the first check, so the setup screen doesn't flash on every launch.
    var shortcutsChecked = false
    /// Chose to go on without "Clear AM" for this session.
    var skippedClearShortcut = false
    /// The setup screen shows until the shortcuts exist; only "Clear AM" can be skipped.
    var needsShortcutSetup: Bool {
        shortcutsChecked && missingShortcuts.contains { $0 != clearShortcutName || !skippedClearShortcut }
    }
    let clearShortcutName = "Clear AM"

    var country: String {
        didSet { defaults.set(country, forKey: "country"); engine.catalog = AppleCatalog(country: country) }
    }
    var shortcutName: String {
        didSet { defaults.set(shortcutName, forKey: "linkShortcut"); engine.queuer = ShortcutQueuer(name: shortcutName, clearName: clearShortcutName) }
    }
    var reportToYT: Bool {
        didSet { defaults.set(reportToYT, forKey: "report"); engine.reportToYT = reportToYT }
    }

    let engine: RadioEngine
    private let yt: YTClient
    private let reader = CookieReader()
    private let defaults = UserDefaults.standard
    private var searchTask: Task<Void, Never>?

    init() {
        let installed = Browser.all.filter(\.isInstalled)
        browser = Browser.named(defaults.string(forKey: "browser") ?? "") ?? installed.first ?? Browser.all[0]
        let country = defaults.string(forKey: "country") ?? Locale.current.region?.identifier.lowercased() ?? "us"
        // "shortcut" held the older search-based one ("Queue AM"), which takes words, not links.
        let shortcutName = defaults.string(forKey: "linkShortcut") ?? "Queue AM Link"
        self.country = country
        self.shortcutName = shortcutName
        reportToYT = defaults.object(forKey: "report") as? Bool ?? true
        yt = YTClient(cookies: { [:] })
        engine = RadioEngine(player: MusicAppPlayer(), queuer: ShortcutQueuer(name: shortcutName, clearName: "Clear AM"),
                             yt: yt, catalog: AppleCatalog(country: country))
        engine.reportToYT = reportToYT

        // Music announces every play, pause and track change; react at once instead of waiting for the poll.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.musicChanged() }
        }
    }

    var installedBrowsers: [Browser] { Browser.all.filter(\.isInstalled) }

    // MARK: - Sign-in

    /// Signs in with the chosen profile if it works, else the first profile signed in to YT Music.
    func connect(preferring preferred: String? = nil) async {
        signIn = .checking
        profiles = browser.profiles()
        guard !profiles.isEmpty else {
            signIn = .signedOut("No \(browser.name) profiles with cookies were found.")
            return
        }
        let saved = preferred ?? defaults.string(forKey: "profile.\(browser.id)")
        let order = profiles.filter { $0.dir == saved } + profiles.filter { $0.dir != saved }
        var lastError: Error?
        for profile in order {
            await use(profile)
            do {
                if let account = try await yt.account() {
                    defaults.set(browser.id, forKey: "browser")
                    defaults.set(profile.dir, forKey: "profile.\(browser.id)")
                    signIn = .signedIn(account, profile)
                    return
                }
            } catch let error as CookieError {
                // Keychain refused: asking again for every profile would only repeat the dialog.
                signIn = .failed(error.localizedDescription)
                return
            } catch {
                lastError = error
            }
            // A profile that isn't the user's pick is only tried as a fallback.
            if preferred != nil { break }
        }
        if let lastError {
            signIn = .failed(lastError.localizedDescription)
        } else {
            signIn = .signedOut(preferred == nil
                ? "None of your \(browser.name) profiles is signed in to YT Music."
                : "That profile isn't signed in to YT Music.")
        }
    }

    func choose(browser: Browser) async {
        self.browser = browser
        await connect()
    }

    func choose(profile: BrowserProfile) async {
        await connect(preferring: profile.dir)
    }

    private func use(_ profile: BrowserProfile) async {
        let reader = self.reader, browser = self.browser
        await yt.setCookies { try reader.youtubeCookies(browser: browser, profile: profile.dir) }
    }

    func openYTMusicInBrowser() {
        let url = URL(string: "https://music.youtube.com")!
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Setup

    func checkShortcuts() async {
        missingShortcuts = await ShortcutQueuer.missing([shortcutName, clearShortcutName])
        shortcutsChecked = true
    }

    // MARK: - Search and playback

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            results = []
            searching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))  // wait for typing to pause
            guard !Task.isCancelled else { return }
            searching = true
            defer { if !Task.isCancelled { searching = false } }
            do {
                let found = try await yt.search(text)
                guard !Task.isCancelled else { return }
                results = found
                searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                searchError = error.localizedDescription
            }
        }
    }

    func play(_ song: Song) {
        query = ""
        Task { await engine.start(song) }
    }
}
