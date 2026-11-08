Plays YT Music radio in Apple Music. Plays and favourites go back to YT Music.

## What's new

- **Mood radio**: your liked songs (YT "Liked music" and songs liked in the app) are grouped into Chill, Feel good, Energetic, Party, Romantic and Sad. Pick a mood to start a radio from one of its songs.
- Moods are sorted by Claude Code. Change a song's mood by hand, or click **Re-sort moods** to sort the rest again.
- Songs already liked on YT are favourited in Music when they play, and aren't liked again.
- Back button on the radio screen: return to the moods while the radio keeps playing.
- Better matching for YT titles written "native - romanised" (森の小さなレストラン - Mori no chiisana restaurant).

## Install

1. Download `RadioBridge-*.zip`, unzip it and move **Radio Bridge** to Applications.
2. Open it. macOS blocks it the first time because it isn't notarised: open **System Settings → Privacy & Security** and click **Open Anyway**.
3. The setup screen adds two shortcuts, **Queue AM Link** and **Clear AM**. Click **Add Shortcut** for each.

## Needs

- macOS 14 or later, Apple silicon or Intel
- An Apple Music subscription
- Chrome, Brave, Edge, Arc, Vivaldi or Chromium, signed in to YT Music
- For mood radio only: [Claude Code](https://claude.com/claude-code) installed, and a token from `claude setup-token` pasted into the app (kept in your Keychain). Liked songs' titles and artists are sent to Claude to sort them.

## Permissions it asks for

- **Keychain access to your browser's "Safe Storage" key**, to read your YT Music sign-in from the browser's cookies. Nothing is sent anywhere except YT Music. Click **Always Allow**; after each update macOS asks again, because the app isn't signed with a Developer ID.
- **Control of Music**, to follow what's playing and skip to the next radio song.
- **Shortcuts access to Apple Music**, the first time a song is added.
