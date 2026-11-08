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
    /// The mood screen, opened with Back while a radio keeps playing.
    var showingMoods = false
    var searching = false
    var searchError: String?

    /// The user's liked songs grouped by mood.
    let library = MoodLibrary()
    /// Why YT's liked songs couldn't be loaded; kept until a later load works.
    private var likesError: String?
    /// Set only while the guess task runs, or when it fails.
    private var guessStatus: String?
    /// A short line for the start screen about loading YT likes and guessing moods.
    var moodStatus: String? { guessStatus ?? likesError }
    /// True when a Claude Code token is saved, so the UI knows whether moods can be guessed.
    var hasClaudeToken = ClaudeCodeToken.saved
    /// The one running guess; only it sets and clears "Sorting…".
    private var guessTask: Task<Void, Never>?
    /// Identifies the latest guess task, so an older one can't clear the newer one's slot.
    private var guessRun = UUID()

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
        engine.onLiked = { [weak self] song in
            guard let self else { return }
            self.library.addLiked(song)
            self.guessMoods()  // place the newly liked song too, if a token is saved
        }
        engine.isLikedOnYT = { [weak self] song in self?.library.contains(song) ?? false }

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
                    refreshLikes()
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
        showingMoods = false
        Task { await engine.start(song) }
    }

    // MARK: - Moods

    /// Fetches YT's "Liked music", merges it into the library, then guesses moods if a token is saved.
    /// Nothing here blocks sign-in or playback; failures only set `moodStatus`.
    func refreshLikes() {
        Task {
            do {
                let liked = try await yt.likedSongs()
                library.mergeYT(liked)
                likesError = nil
            } catch {
                likesError = "Couldn't load your YT likes: \(error.localizedDescription)"
            }
            guessMoods()
        }
    }

    /// Guesses moods for songs that have none, if a Claude Code token is saved. One run at a time.
    /// The token is read only when there is something to send.
    func guessMoods() {
        guard guessTask == nil, library.songsToGuess > 0 else { return }
        startGuessing(after: nil)
    }

    /// Starts the guess task, once `previous` (a cancelled run) has finished with its songs.
    /// The task goes on until nothing is left to send (songs liked meanwhile), stops at a failure,
    /// and says nothing if it was cancelled or the token was removed: that was on purpose.
    private func startGuessing(after previous: Task<Void, Never>?) {
        guard hasClaudeToken else { return }
        let run = UUID()
        guessRun = run
        guessTask = Task {
            await previous?.value
            // Only the latest run clears the slot; an older, cancelled one must not clear a newer.
            defer { if guessRun == run { guessTask = nil } }
            while hasClaudeToken, !Task.isCancelled, library.songsToGuess > 0 {
                guard let token = ClaudeCodeToken.read() else {
                    guessStatus = "Couldn't read the Claude Code token from the Keychain."
                    return
                }
                guessStatus = "Sorting songs into moods…"
                do {
                    try await library.guessMoods(using: ClaudeCodeMoodGuesser(token: token, run: ClaudeCode.run))
                    guessStatus = nil
                } catch {
                    if !Task.isCancelled { guessStatus = "Couldn't guess moods: \(error.localizedDescription)" }
                    return
                }
            }
        }
    }

    /// Sends every song not set by hand to Claude again; a run in progress picks them up too.
    func resortMoods() {
        library.resortMoods()
        guessMoods()
    }

    /// A guess run is going (for the "Sorting…" state of the re-sort button).
    var isGuessing: Bool { guessTask != nil }

    func play(mood: Mood) {
        query = ""
        showingMoods = false
        let songs = library.songs(in: mood).map(\.song)
        Task { await engine.start(mood: mood, from: songs) }
    }

    /// Songs with no mood yet that the user hasn't deliberately left that way, for the start-screen hint.
    var songsNeedingMood: Int {
        library.songs(in: nil).filter { !$0.moodByHand }.count
    }

    /// Throws if the Keychain refuses, so the sheet can say so; the token counts as saved only if it was.
    /// A run in progress used the old token, so it is ended and a new one starts with this token.
    func saveClaudeToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try ClaudeCodeToken.save(trimmed)
        hasClaudeToken = true
        let old = guessTask
        old?.cancel()
        guessStatus = nil
        startGuessing(after: old)  // place the songs that have no mood
    }

    /// Ends a run in progress too, without an error: removing the token was on purpose.
    func removeClaudeToken() throws {
        try ClaudeCodeToken.remove()
        hasClaudeToken = false
        // Left set until the run ends (its defer clears it), so a token saved meanwhile waits for it.
        guessTask?.cancel()
        guessStatus = nil
    }
}
