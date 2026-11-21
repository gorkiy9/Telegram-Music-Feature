# Music section for Telegram iOS

A design concept implemented as working code on top of Telegram-iOS 13.2: a full music library inside Telegram, built from the client's own components and theme.

## Problem

Telegram is already where many people keep their music: tracks in channels, groups, bots and chats with friends, plus music on the profile. But there is no place to *listen* to it. Tracks are scattered across chats, the player only knows the chat it was started from, there are no playlists, no favorites and no way to build a queue across chats.

## What is changed

**Music tab and hub** (`MusicScreen`, `MusicHubItems`)
- Optional Music tab (on/off in Settings ▸ Music, long press opens a context menu with sections, Play and Shuffle).
- Hub with Tracks / Artists / Playlists / Favorites tiles and the library track list.

**Library** (`MusicLibrary`)
- Collects profile music and all music from chats, deduplicated by file.
- Sources: all chats or selected chats. Playlists keep their tracks whatever sources are chosen.
- Removing a track from Music only hides it; chats and the profile are never touched.
- Adding an audio file from Files with title, artist and cover editing (`MusicTrackEditScreen`).

**Lists**
- Tracks, Artists, Favorites, playlists: sorting with letter index, scoped search with filter tabs and recent results, multi-selection with Delete / Forward, swipe actions, track and playlist context menus, Play Next / Add to Queue.

**Playlists** (`MusicPlaylistEditScreen`, `MusicPlaylistHeader`)
- Create and edit with cover, description and reorderable tracks; add to profile.
- Playlist screen with a profile-style collapsing header (cover → avatar into the Dynamic Island).
- Sharing a playlist sends a playlist bubble (`ChatMessageMusicPlaylistBubbleContentNode`) that opens as a sheet.
- Another user's playlist (`MusicPlaylistOwner`, taken from the bubble's message) is read-only and names its author; Add to Music in its menu, header, bubble and the player's queue menu saves it with its tracks.

**Player** (`OverlayAudioPlayerControlsNode`, `MusicPlayerQueueList`)
- Compact player sheet with add to Music, favorite, add to playlist.
- Queue sheet: whole queue in play order, drag to reorder, Shuffle and Reverse that keep the queue editable, playing-now indicator in every track list.

**Chats**
- Music files in bubbles show the track cover and the playing indicator.
- Shares from Music hide the "Forwarded from" header and captions.

Everything is built on existing client components (`ListMessageItem`, `ContactsPeerItem`, `ItemListController`, `GlassBackgroundView`, `ButtonComponent`, `ChatListSearchFiltersContainerNode`, `UndoOverlayController`, the context menu and share sheet) and colours from `PresentationTheme`. Small opt-in extensions were added to shared components (for example `ListView` reordering options, `ItemListRevealOption.displaysTitle`, `ToolbarAction.icon`); their defaults keep the existing behaviour.

## Feature flag

`isMusicSectionEnabled` in `submodules/AccountContext/Sources/AccountContext.swift`. With `false` the client behaves as upstream: no tab, no Settings item, chat bubbles and the player unchanged.

## Server

The server is not touched. Whatever the API does not support is stored locally (Postbox item cache, collection `music`). Methods that a real implementation would need:

| Feature | Stored now | Needed API |
|---|---|---|
| Playlists (name, description, cover, track order) | item cache | `music.getPlaylists`, `music.createPlaylist`, `music.editPlaylist`, `music.deletePlaylist`, `music.reorderPlaylistTracks` |
| Playlist in profile | local flag | `music.togglePlaylistInProfile` + playlists on `userFull` |
| Sharing a playlist | local webpage of type `telegram_music_playlist` (test chat only) | `inputMediaMusicPlaylist` / `messageMediaMusicPlaylist` |
| Another user's playlist, saved to Music | item cache, owner peer id + their playlist id | `music.getPlaylist(owner, id)`, `music.savePlaylist` / `music.unsavePlaylist`, owner on `musicPlaylist` |
| Favorites | item cache | `music.saveFavorite`, `music.getFavorites` |
| Library state (hidden tracks, added files, sources) | item cache | `music.getLibrary`, `music.editLibrary`, `music.setSources` |
| Track title / artist / cover edits | local overrides | `music.editTrackMetadata` (per user) |
| Broadcast what is playing to the profile | stub | `account.updateNowPlaying` |

Profile music uses the existing saved music API (`ProfileSavedMusicContext`).

## How to run

1. Follow the main [README](../../../../README.md) to set up Xcode, `api_id` and the configuration file.
2. Generate the project for the simulator without signing:
   ```bash
   python3 build-system/Make/Make.py --cacheDir="$HOME/telegram-bazel-cache" \
     generateProject \
     --configurationPath=build-system/template_minimal_development_configuration.json \
     --disableProvisioningProfiles
   ```
3. Run on an iOS simulator. Open Settings ▸ Music and turn on the Music tab.

### Demo mode

The demo video was recorded on an offline build with local content only. A build whose bundle id contains `MusicDemo` (`isMusicDemoBuild` in `TelegramCore/.../MusicDemo.swift`) signs in to a local account without a server and fills chats, tracks and playlists from `MusicScreen/Sources/MusicDemo.swift`. Launch with `-MusicDemoReset YES` to restore the initial state. The regular build never enables it.

## Demo video

8 chapters, one scenario: enabling Music, profile and sources, adding and editing a track, selecting and sending, creating a playlist, music in a chat, swipes, the new player.

## Main files

- `submodules/TelegramUI/Components/Music/MusicScreen/` — the section
- `submodules/TelegramUI/Components/Chat/ChatMessageMusicPlaylistBubbleContentNode/` — playlist bubble
- `submodules/TelegramUI/Sources/OverlayAudioPlayerControlsNode.swift`, `OverlayAudioPlayerControllerNode.swift` — player and queue sheets
- `submodules/TelegramUI/Components/DynamicIslandMask/` — Dynamic Island mask moved out of PeerInfoScreen for reuse
