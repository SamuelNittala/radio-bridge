# Tasks

## Current

- [ ] End-to-end check: start radio from the app and let Music play several songs
- [ ] Developer ID signing and notarisation, so macOS opens the app without "Open Anyway"

## Completed

- [x] Match YT titles written "native - romanised" (森の小さなレストラン - Mori no chiisana restaurant) against Apple's romanised title
- [x] "Re-sort moods" in Liked songs: sends every song not set by hand to Claude again; an "unknown" answer keeps the old mood
- [x] Songs already liked on YT (in the liked list: same id, or same title and an artist) are favourited in Music when they start, and not liked again
- [x] Back button on the radio screen: back to the moods while the radio keeps playing; a "Now playing" bar returns to it
- [x] Mood radio: liked songs grouped by mood; pick a mood to start a radio from one of its songs
  - [x] Liked songs from YT ("Liked music", first 100) and from the app's own likes, kept on disk
  - [x] Moods guessed by Claude Code (`claude -p`, token from `claude setup-token`, kept in Keychain); songs without a guess go to "No mood yet"
  - [x] Change a song's mood by hand; a hand-picked mood is never overwritten
  - [x] Mood row on the start screen; a click starts a radio from a random song of that mood, with YT's matching filter on

- [x] Favourite button in Now Playing: favourites the radio song in Music; liked on YT when it finishes, if still favourited
- [x] App icon: a play symbol sending out radio waves, drawn in code (Bundle/Icon)
- [x] Release workflow: a v* tag builds the universal app, tests it and publishes a GitHub release with the zip
- [x] Test data from a signed-out YT session, so the repo can be public
- [x] Bundle signed "Queue AM Link" and "Clear AM" files; the setup screen's Add Shortcut button opens them
- [x] First-run screen with the steps for both shortcuts; ticks each off as it appears, re-checks on return from Shortcuts
- [x] Next button beside play/pause; skips to the first queued radio song
- [x] Find songs search hides (Frank Ocean's "Nikes") in the artist's full song list (iTunes lookup), once per artist
- [x] Queue by link: pick the song from a 10-result search (exact title first) and add its link with the "Queue AM Link" shortcut; keep 3 songs queued ahead in Music, in order
- [x] Play/pause button next to Stop; switches Music at once and shows the new state
- [x] Start a new radio as soon as its first song is queued (no fixed 8 s wait); 3 s grace before a queued song counts as missing
- [x] Sign in from a Chromium browser's cookies; pick the profile signed in to YT Music
- [x] YT requests: account, search, radio with filter chips, history, like
- [x] Apple catalog match (iTunes Search API); exact titles win over partial ones
- [x] Follow Music.app: queue next song via the "Queue AM" shortcut, report plays and likes
- [x] UI: search, filter chips, now playing, up next, not on Apple Music, activity
- [x] Build script producing an .app bundle
- [x] Start a new radio from any Up next song; clear Playing Next first ("Clear AM" shortcut)
- [x] Apple matching mirrors the shortcut (one result per search, any release of the song)
- [x] Apple search: results cached on disk, pause after failures
