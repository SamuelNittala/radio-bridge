# Radio Bridge

Plays YT Music radio in Apple Music on the Mac, and sends your plays and likes back to YT Music.

Search for a song, and Radio Bridge plays its YT Music radio in the Music app. Songs you listen to go into your YT Music history, and songs you favourite in Music are liked on YT Music, so YT's recommendations keep learning from what you play.

## Install

1. Download `RadioBridge-<version>.zip` from [Releases](https://github.com/SamuelNittala/radio-bridge/releases), unzip it and move **Radio Bridge** to Applications.
2. Open it. macOS blocks it the first time because it isn't notarised: open **System Settings → Privacy & Security** and click **Open Anyway**.
3. The setup screen adds two shortcuts, **Queue AM Link** and **Clear AM**. Click **Add Shortcut** for each.

### Needs

- macOS 14 or later, Apple silicon or Intel
- An Apple Music subscription
- Chrome, Brave, Edge, Arc, Vivaldi or Chromium, signed in to YT Music

### Permissions it asks for

- **Keychain access to your browser's "Safe Storage" key**, to read your YT Music sign-in from the browser's cookies. Click **Always Allow**. macOS asks again after each update, because the app isn't signed with a Developer ID.
- **Control of Music**, to follow what's playing and skip to the next radio song.
- **Shortcuts access to Apple Music**, the first time a song is added.

## How it works

1. **YT Music picks the songs.** Radio Bridge signs in with your browser's YT Music cookies and fetches the song's radio, including filters like Discover or a language.
2. **Each song is found in Apple's catalog** with the free iTunes Search API, by title, artist and length. Songs that search misses are looked for in the artist's full song list.
3. **The Queue AM Link shortcut adds the song by its link** to Music's Playing Next. Three songs are kept queued ahead, so skipping in Music stays on the radio.
4. **Radio Bridge follows Music.** A song played at least halfway goes into your YT Music history; a song you favourite is liked on YT Music. Anything else that starts playing while the radio runs is skipped.

Your cookies stay on your Mac and are only sent to YT Music. Apple's search sees song titles and artists.

## Limits

- Songs that aren't on Apple Music are listed under **Not on Apple Music** and skipped.
- While a radio runs, songs you start yourself are skipped; press **Stop** first.
- Starting a radio clears Music's Playing Next.
- It uses YT Music's private web API, which can change without notice. It is not affiliated with Google or Apple.

## Build from source

Needs Xcode 16 or later.

```sh
./build.sh          # build/Radio Bridge.app, for this Mac's processor
swift test          # tests
./release.sh 0.1.0  # universal app, zipped: build/RadioBridge-0.1.0.zip
```

Pushing a tag like `v0.1.0` runs `.github/workflows/release.yml`, which tests, builds and publishes a release with the zip.
