# Tasks

## Current

- [ ] End-to-end check: start radio from the app and let Music play several songs
- [ ] Sharing: Developer ID signing and notarisation, shareable "Queue AM" shortcut link

## Completed

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
