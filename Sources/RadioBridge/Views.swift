import RadioCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            AccountBar()
            Divider()
            if case .signedIn = model.signIn {
                TextField("Search YT Music for a song to start radio", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .padding(12)
                Divider()
                if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchResults()
                } else {
                    RadioView()
                }
            } else {
                SignInView()
            }
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 520, idealHeight: 680)
        .task {
            await model.connect()
            await model.checkShortcuts()
        }
    }
}

// MARK: - Account and sign-in

struct AccountBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            switch model.signIn {
            case .signedIn(let account, let profile):
                Artwork(url: account.photo, size: 28, round: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.name).font(.headline)
                    Text("\(model.browser.name) · \(profile.name)").font(.caption).foregroundStyle(.secondary)
                }
            case .checking:
                ProgressView().controlSize(.small)
                Text("Signing in from \(model.browser.name)…").foregroundStyle(.secondary)
            case .signedOut, .failed:
                Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
                Text("Not signed in").foregroundStyle(.secondary)
            }
            Spacer()
            SettingsMenu()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct SettingsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Browser", selection: Binding(get: { model.browser },
                                                 set: { b in Task { await model.choose(browser: b) } })) {
                ForEach(model.installedBrowsers) { Text($0.name).tag($0) }
            }
            if model.profiles.count > 1 {
                Menu("Profile") {
                    ForEach(model.profiles) { profile in
                        Button(profile.name) { Task { await model.choose(profile: profile) } }
                    }
                }
            }
            Divider()
            Toggle("Send plays and likes to YT", isOn: $model.reportToYT)
            Divider()
            Text("Store country: \(model.country.uppercased())")
            Text("Shortcut: \(model.shortcutName)")
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            switch model.signIn {
            case .checking:
                ProgressView()
                Text("If macOS asks for access to \(model.browser.name)'s saved data, click Allow.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            case .signedOut(let message), .failed(let message):
                Image(systemName: "music.note.house").font(.system(size: 36)).foregroundStyle(.secondary)
                Text(message).multilineTextAlignment(.center)
                Text("Radio Bridge uses the YT Music sign-in from your browser. Nothing is sent anywhere else.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Open YT Music in \(model.browser.name)") { model.openYTMusicInBrowser() }
                    Button("Try again") { Task { await model.connect() } }.keyboardShortcut(.defaultAction)
                }
            case .signedIn:
                EmptyView()
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Search

struct SearchResults: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let error = model.searchError {
                Notice(text: error, systemImage: "exclamationmark.triangle")
            } else if model.results.isEmpty {
                Notice(text: model.searching ? "Searching…" : "No songs found", systemImage: "magnifyingglass")
            } else {
                List(model.results) { song in
                    Button { model.play(song) } label: { SongRow(song: song) }
                        .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Radio

struct RadioView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let engine = model.engine
        if engine.seed == nil {
            Notice(text: "Search for a song. Its YT Music radio plays in Apple Music, and what you play and favourite there goes back to YT.",
                   systemImage: "dot.radiowaves.left.and.right")
                .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if !model.missingShortcuts.isEmpty { ShortcutNotice() }
                PhaseBanner()
                NowPlaying()
                if !engine.chips.isEmpty { Chips() }
                Divider()
                List {
                    Section("Up next") {
                        if let pending = engine.pending {
                            SongRow(song: pending.song, note: "In Music's queue") { model.play(pending.song) }
                        }
                        ForEach(engine.upcoming.prefix(20)) { song in
                            SongRow(song: song) { model.play(song) }
                        }
                    }
                    if !engine.notOnApple.isEmpty {
                        Section("Not on Apple Music (\(engine.notOnApple.count))") {
                            ForEach(engine.notOnApple.reversed()) { SongRow(song: $0).opacity(0.6) }
                        }
                    }
                    Section("Activity") {
                        ForEach(engine.activity.prefix(50)) { ActivityRow(item: $0) }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

struct PhaseBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let engine = model.engine
        switch engine.phase {
        case .failed(let message):
            Banner(text: message, systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                if let seed = engine.seed { Button("Start again") { model.play(seed) } }
            }
        case .signedOut:
            Banner(text: "YT Music signed out, so radio would stop being personal.",
                   systemImage: "person.crop.circle.badge.exclamationmark", tint: .orange) {
                Button("Sign in again") { Task { await model.connect() } }
            }
        case .idle:
            if let seed = engine.seed {
                Banner(text: "Stopped following Music.", systemImage: "pause.circle", tint: .secondary) {
                    Button("Start again") { model.play(seed) }
                }
            }
        case .starting, .running:
            EmptyView()
        }
    }
}

struct NowPlaying: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let engine = model.engine
        let song = engine.current?.song ?? engine.seed
        HStack(spacing: 12) {
            Artwork(url: song?.thumbnail, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(status).font(.caption).foregroundStyle(.secondary)
                Text(song?.title ?? "").font(.title3.weight(.semibold)).lineLimit(2)
                Text(song?.artistLine ?? "").foregroundStyle(.secondary).lineLimit(1)
                if engine.current?.favorited == true {
                    Label("Favourited, will be liked on YT", systemImage: "star.fill")
                        .font(.caption).foregroundStyle(.pink)
                }
            }
            Spacer()
            if engine.phase == .running || engine.phase == .starting {
                Button("Stop") { engine.stop() }
            }
        }
        .padding(12)
    }

    private var status: String {
        let engine = model.engine
        switch engine.phase {
        case .starting: return "Starting radio…"
        case .running:
            if engine.current == nil, engine.music.state != .stopped, !engine.music.name.isEmpty {
                return "Music is playing \(engine.music.name)"
            }
            return engine.music.state == .paused ? "Paused in Apple Music" : "Playing in Apple Music"
        default: return "Radio"
        }
    }
}

struct Chips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.engine.chips) { chip in
                    Button(chip.name) { Task { await model.engine.setFilter(chip.name) } }
                        .buttonStyle(.bordered)
                        .tint(chip.isSelected ? .accentColor : nil)
                        .fontWeight(chip.isSelected ? .semibold : .regular)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 10)
    }
}

struct ShortcutNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Banner(text: text, systemImage: "exclamationmark.triangle.fill", tint: .orange) {
            Button("Open Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
            Button("Check again") { Task { await model.checkShortcuts() } }
        }
    }

    private var text: String {
        model.missingShortcuts.map { name in
            name == model.clearShortcutName
                ? "Make a shortcut named '\(name)' with one action: Clear Playing Next. Without it, songs from an earlier radio play first."
                : "Make a shortcut named '\(name)': Find [Shortcut Input] on the iTunes Store (Music, Songs, 1 item), then Add [iTunes Products] to Next of Playing Next."
        }.joined(separator: "\n")
    }
}

// MARK: - Pieces

struct SongRow: View {
    let song: Song
    var note: String?
    /// Starts a new radio from this song; shown as a play button over the artwork on hover.
    var startRadio: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Artwork(url: song.thumbnail, size: 36)
                .overlay {
                    if let startRadio, hovering {
                        Button(action: startRadio) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .help("Start radio from this song")
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).lineLimit(1)
                Text(song.artistLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let note { Text(note).font(.caption2).foregroundStyle(.tint) }
            if let length = song.length {
                Text(String(format: "%d:%02d", length / 60, length % 60))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct ActivityRow: View {
    let item: Activity

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 14)
            Text(item.text).font(.caption).lineLimit(2)
            Spacer()
            Text(item.date, style: .time).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch item.kind {
        case .info: "info.circle"
        case .played: "checkmark.circle"
        case .skipped: "forward"
        case .liked: "hand.thumbsup"
        case .warning: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .played: .green
        case .liked: .pink
        case .warning: .orange
        default: .secondary
        }
    }
}

struct Artwork: View {
    let url: URL?
    let size: CGFloat
    var round = false

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: round ? size / 2 : 6))
    }
}

struct Notice: View {
    let text: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Banner<Actions: View>: View {
    let text: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: systemImage).foregroundStyle(tint).font(.callout)
            HStack { actions() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.1))
    }
}
