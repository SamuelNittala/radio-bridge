import Foundation
import Observation

// What the engine needs from the outside world; the app passes real ones, tests fakes.

public protocol MusicPlayer: AnyObject {
    func status() -> PlayerStatus
    func nextTrack()
    func play()
}

public protocol TrackQueuer: Sendable {
    /// Adds the store's top result for `query` to Music's Playing Next.
    func queue(_ query: String) async throws -> QueuedTrack
    /// Empties Music's Playing Next, so songs from an earlier radio don't play first.
    func clear() async throws
}

public protocol Recommender: Sendable {
    func account() async throws -> Account?
    func radio(from videoId: String, filter: String?) async throws -> RadioPage
    func reportPlay(_ videoId: String) async throws -> HistoryResult
    func like(_ videoId: String) async throws
}

public protocol Catalog: Sendable {
    func find(_ song: Song) async throws -> CatalogMatch?
}

extension YTClient: Recommender {}

/// A YT song that was queued in Music, and how it is being played.
public struct Entry: Equatable, Sendable {
    public var song: Song
    /// Name the shortcut reported; Music shows the same name when it plays.
    public var name: String
    public var query: String
    public var track: AppleTrack
    public var queuedAt: Date
    public var pid = ""
    public var duration = 0.0
    public var maxPosition = 0.0
    public var favorited = false
}

public struct Activity: Identifiable, Sendable {
    public enum Kind: Sendable { case info, played, skipped, liked, warning }
    public let id = UUID()
    public let date: Date
    public let kind: Kind
    public let text: String
}

/// Plays YT Music radio in Apple Music: the logic of loop.py.
///
/// YT picks the songs; each is matched in Apple's catalog and queued as soon as the
/// previous one starts, so Music moves on by itself and skipping lands on the next
/// YT song. Finished songs go to YT history; songs favourited in Music are liked on YT.
@MainActor @Observable
public final class RadioEngine {
    public enum Phase: Equatable {
        case idle, starting, running
        case signedOut
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var seed: Song?
    public private(set) var chips: [Chip] = []
    public private(set) var filter = "All"
    public private(set) var upcoming: [Song] = []
    public private(set) var current: Entry?
    public private(set) var pending: Entry?
    /// What Music is playing right now, ours or not.
    public private(set) var music = PlayerStatus.stopped
    public private(set) var notOnApple: [Song] = []
    public private(set) var activity: [Activity] = []

    public var reportToYT = true
    /// Share of a song that must be played for it to count in YT history.
    public var minPlay = 0.5

    public var player: MusicPlayer
    public var queuer: TrackQueuer
    public var yt: Recommender
    public var catalog: Catalog

    /// Seconds a queued song may take to start playing before it counts as missing.
    let arrivalWait: TimeInterval
    let clock: () -> Date

    private var seen = Set<String>()
    private var skippedAt = Date.distantPast
    private var misses = 0
    private var busy = false
    /// Bumped on start and stop, so work still in flight from before is dropped.
    private var generation = 0
    private var poller: Task<Void, Never>?
    private var pollInterval: TimeInterval = 2

    public init(player: MusicPlayer, queuer: TrackQueuer, yt: Recommender, catalog: Catalog,
                arrivalWait: TimeInterval = 3, clock: @escaping () -> Date = Date.init) {
        self.player = player
        self.queuer = queuer
        self.yt = yt
        self.catalog = catalog
        self.arrivalWait = arrivalWait
        self.clock = clock
    }

    // MARK: - Controls

    /// Starts radio from a song: plays the song itself, then its radio.
    public func start(_ song: Song, poll: Bool = true) async {
        stop()
        let gen = generation
        seed = song
        filter = "All"
        chips = []
        upcoming = []
        notOnApple = []
        seen = []
        current = nil
        pending = nil
        misses = 0
        phase = .starting
        log(.info, "Starting radio from \(song.label)")
        do {
            try await queuer.clear()
        } catch {
            log(.warning, "Couldn't clear Playing Next, so older songs may play first: \(error.localizedDescription)")
        }
        guard gen == generation else { return }

        guard await refill(from: song.videoId), gen == generation else { return }
        let first = await queueNext()
        guard gen == generation, phase == .starting else { return }
        guard let first else { return fail("Nothing from this radio is on Apple Music.") }
        pending = first
        // The shortcut returns once the song is in Playing Next; if the skip lands elsewhere, step() retries.
        skip()
        phase = .running
        if poll { startPolling() }
    }

    public func stop() {
        generation += 1
        poller?.cancel()
        poller = nil
        if phase == .starting || phase == .running { phase = .idle }
    }

    /// Applies a radio filter: the songs after the one already queued in Music change.
    public func setFilter(_ name: String) async {
        guard name != filter, phase == .running || phase == .starting, let seed else { return }
        let gen = generation
        filter = name
        chips = chips.map { var c = $0; c.isSelected = (c.name == name); return c }
        upcoming = []
        log(.info, "Filter: \(name)")
        _ = await refill(from: current?.song.videoId ?? seed.videoId)
        guard gen == generation else { return }
    }

    /// Checks Music now instead of waiting for the next poll, e.g. on a track change.
    public func musicChanged() {
        Task { await tick() }
    }

    public func tick() async {
        guard phase == .running, !busy else { return }
        busy = true
        defer { busy = false }
        await step()
    }

    // MARK: - Following Music

    private func startPolling() {
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 2))
                await self?.tick()
            }
        }
    }

    private func step() async {
        let gen = generation
        let p = player.status()
        music = p
        if p.state == .stopped { return }

        if var cur = current, p.pid == cur.pid {
            cur.maxPosition = max(cur.maxPosition, p.position)
            cur.favorited = p.favorited
            current = cur
            if pending == nil {
                let next = await queueNext()
                if gen == generation { pending = next }
            }
            return
        }

        // Music moved to another track.
        if let cur = current {
            finish(cur)
            current = nil
        }
        if var next = pending, p.name == next.name {
            next.pid = p.pid
            next.duration = p.duration
            next.maxPosition = p.position
            next.favorited = p.favorited
            current = next
            pending = nil
            misses = 0
            // Queue the following song right away, so skipping lands on it.
            let queued = await queueNext()
            if gen == generation { pending = queued }
            return
        }
        // Something not from the YT queue (skipped early, or Music's own autoplay).
        let now = clock()
        if now.timeIntervalSince(skippedAt) < 6 { return }  // Music may still be switching to our song
        if let next = pending, now.timeIntervalSince(next.queuedAt) < arrivalWait { return }
        guard var next = pending else {
            log(.info, "Music is playing '\(p.name)', not from YT radio; queuing the next YT song")
            let queued = await queueNext()
            if gen == generation { pending = queued }
            return
        }
        misses += 1
        if misses > 4 {
            return fail("Queued songs aren't reaching Music. Check the shortcut, then start again.")
        }
        if misses == 3 {
            log(.warning, "'\(next.name)' never arrived; queuing it again")
            _ = try? await queuer.queue(next.query)
            guard gen == generation else { return }
            next.queuedAt = now
            pending = next
            return
        }
        log(.info, "Music is playing '\(p.name)', not from YT radio; skipping to the YT song")
        skip()
    }

    private func skip() {
        player.nextTrack()
        player.play()
        skippedAt = clock()
    }

    // MARK: - YT and Apple

    /// Adds radio songs not yet seen. False when signed out (the engine stops).
    private func refill(from videoId: String) async -> Bool {
        let gen = generation
        do {
            // Sessions can end mid-run; without this, radio silently goes generic.
            let account = try await yt.account()
            guard gen == generation else { return false }
            guard account != nil else {
                phase = .signedOut
                stop()
                return false
            }
            let page = try await yt.radio(from: videoId, filter: filter == "All" ? nil : filter)
            guard gen == generation else { return false }
            if page.filterMissing { log(.info, "This song has no '\(filter)' filter; using plain radio") }
            if chips.isEmpty { chips = page.chips }
            let waiting = Set(upcoming.map(\.videoId))
            upcoming += page.songs.filter { !seen.contains($0.videoId) && !waiting.contains($0.videoId) }
        } catch {
            guard gen == generation else { return false }
            log(.warning, "Couldn't get YT radio: \(error.localizedDescription)")
        }
        return true
    }

    /// Matches the next YT song on Apple Music and queues it in Music.
    private func queueNext() async -> Entry? {
        let gen = generation
        while gen == generation {
            if upcoming.count < 5, let base = current?.song.videoId ?? seed?.videoId {
                guard await refill(from: base), gen == generation else { return nil }
            }
            guard !upcoming.isEmpty else {
                log(.warning, "YT returned no more songs")
                return nil
            }
            let song = upcoming.removeFirst()
            seen.insert(song.videoId)
            let match: CatalogMatch?
            do {
                match = try await catalog.find(song)
            } catch {
                // Try this song again on the next check.
                if gen == generation {
                    seen.remove(song.videoId)
                    upcoming.insert(song, at: 0)
                    // While searches are paused, each check fails the same way; the first failure was logged.
                    if case CatalogError.backingOff = error {} else {
                        log(.warning, "Apple Music search failed: \(error.localizedDescription)")
                    }
                }
                return nil
            }
            guard gen == generation else { return nil }
            guard let match else {
                notOnApple.append(song)
                log(.skipped, "Not on Apple Music: \(song.label)")
                continue
            }
            do {
                let queued = try await queuer.queue(match.query)
                guard gen == generation else { return nil }
                if let id = queued.trackId, id != match.track.trackId {
                    log(.warning, "Shortcut queued '\(queued.name)', expected '\(match.track.trackName)'")
                }
                return Entry(song: song, name: queued.name, query: match.query, track: match.track, queuedAt: clock())
            } catch {
                if gen == generation { fail("Couldn't queue in Music: \(error.localizedDescription)") }
                return nil
            }
        }
        return nil
    }

    /// Reports a song that has stopped playing back to YT.
    private func finish(_ entry: Entry) {
        let full = entry.duration > 0 && entry.maxPosition >= minPlay * entry.duration
        let played = "\(Int(entry.maxPosition))s of \(Int(entry.duration))s"
        log(full ? .played : .skipped, "\(full ? "Played" : "Skipped"): \(entry.song.label) (\(played))")
        guard reportToYT else { return }
        let yt = self.yt, song = entry.song
        // A failed report must not stop the music.
        Task {
            if full {
                do {
                    switch try await yt.reportPlay(song.videoId) {
                    case .added: break
                    case .notPossible(let reason):
                        log(.warning, "Not added to YT history (\(reason)): \(song.label)")
                    case .failed(let code):
                        log(.warning, "YT history failed (HTTP \(code)): \(song.label)")
                    }
                } catch {
                    log(.warning, "YT history failed: \(error.localizedDescription)")
                }
            }
            if entry.favorited {
                do {
                    try await yt.like(song.videoId)
                    log(.liked, "Liked on YT: \(song.label)")
                } catch {
                    log(.warning, "YT like failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func fail(_ message: String) {
        stop()
        phase = .failed(message)
        log(.warning, message)
    }

    private func log(_ kind: Activity.Kind, _ text: String) {
        activity.insert(Activity(date: clock(), kind: kind, text: text), at: 0)
        if activity.count > 200 { activity.removeLast() }
    }
}
