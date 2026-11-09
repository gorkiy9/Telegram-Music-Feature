import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import UndoUI
import PresentationDataUtils
import PeerMessagesMediaPlaylist

/// What a queue started in the Music section plays: the player sheet's menu leads back to it.
public enum MusicPlayerQueueKind: Equatable {
    /// Tracks of the library that make no list of their own: all tracks, Favorites, a search.
    case tracks
    case playlist(Int)
    case artist(String)
    /// A chat's audio or a profile's music the sheet took over to turn it over or reorder it.
    case chat(EnginePeer.Id)
    case profile(EnginePeer.Id)
}

/// A queue started in the Music section: its tracks in play order and the list it was started from.
public struct MusicPlayerQueueInfo: Equatable {
    public let messageIds: [EngineMessage.Id]
    public let title: String
    public let kind: MusicPlayerQueueKind
    /// The queue plays from its end: Reverse turned it over. Independent of Shuffle.
    public let isReversed: Bool

    public init(messageIds: [EngineMessage.Id], title: String, kind: MusicPlayerQueueKind, isReversed: Bool) {
        self.messageIds = messageIds
        self.title = title
        self.kind = kind
        self.isReversed = isReversed
    }
}

/// The library as the player sheet reads it.
public struct MusicPlayerLibraryState: Equatable {
    public let favoriteFileIds: Set<Int64>
    /// Chat files taken out of Music.
    public let removedFileIds: Set<Int64>
    /// Files of the tracks loaded so far; chat audio arrives page by page.
    public let trackFileIds: Set<Int64>
}

func musicOwnMusicQueueTitle(strings: PresentationStrings) -> String {
    return musicString(strings, ru: "Ваша музыка", en: "Your Music")
}

func musicPlaylistQueueTitle(strings: PresentationStrings, playlist: MusicPlaylist) -> String {
    return musicString(strings, ru: "Ваш «\(playlist.title)»", en: "Your “\(playlist.title)”")
}

/// The sheet that adds tracks to one of the playlists, or to a new one.
/// Playlists are local stand-ins: the choice is kept with the playlist on this device.
func presentMusicAddToPlaylistSheet(context: AccountContext, library: MusicLibrary, tracks: [MusicTrack], excluding excludedId: Int?, present: @escaping (ViewController) -> Void, createPlaylist: @escaping (@escaping (MusicPlaylist) -> Void) -> Void, toast: @escaping (String) -> Void) {
    guard !tracks.isEmpty else {
        return
    }
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let strings = presentationData.strings
    let actionSheet = ActionSheetController(presentationData: presentationData)
    let added: (MusicPlaylist) -> Void = { [weak library] playlist in
        library?.add(tracks: tracks, to: playlist.id)
        toast(tracks.count == 1 ? musicString(strings, ru: "Трек добавлен в «\(playlist.title)»", en: "The track was added to “\(playlist.title)”") : musicString(strings, ru: "Треки добавлены в «\(playlist.title)»", en: "The tracks were added to “\(playlist.title)”"))
    }
    var items: [ActionSheetItem] = [ActionSheetTextItem(title: musicString(strings, ru: "Добавить в плейлист", en: "Add to Playlist"))]
    for playlist in library.playlists where playlist.id != excludedId {
        items.append(ActionSheetButtonItem(title: playlist.title, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
            added(playlist)
        }))
    }
    items.append(ActionSheetButtonItem(title: musicString(strings, ru: "Новый плейлист", en: "New Playlist"), action: { [weak actionSheet] in
        actionSheet?.dismissAnimated()
        createPlaylist({ playlist in
            added(playlist)
        })
    }))
    actionSheet.setItemGroups([
        ActionSheetItemGroup(items: items),
        ActionSheetItemGroup(items: [ActionSheetButtonItem(title: strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
            actionSheet?.dismissAnimated()
        })])
    ])
    present(actionSheet)
}

/// What the player sheet reads from and writes to the Music section. Every call goes to the account's shared
/// library, so a change made in the sheet shows on the section's screens and the other way round. Main queue only.
public enum MusicPlayerSupport {
    /// The queue last started in the section; the sheet shows it while the playing track belongs to it.
    public static func queueInfo(context: AccountContext) -> Signal<MusicPlayerQueueInfo?, NoError> {
        return MusicLibrary.shared(context: context).queueInfo.get()
    }

    public static func favoriteFileIds(context: AccountContext) -> Signal<Set<Int64>, NoError> {
        return MusicLibrary.shared(context: context).favoriteFileIdsSignal
    }

    public static func libraryState(context: AccountContext) -> Signal<MusicPlayerLibraryState, NoError> {
        return MusicLibrary.shared(context: context).playerStateSignal
    }

    /// Adding to and taking out of Music never touches the profile: a file from outside the account's chats and
    /// profile is kept on this device.
    public static func addToMusic(context: AccountContext, file: TelegramMediaFile) {
        MusicLibrary.shared(context: context).addToMusic(file: file)
    }

    public static func removeFromMusic(context: AccountContext, fileId: Int64) {
        MusicLibrary.shared(context: context).removeFromMusic(fileId: fileId)
    }

    public static func setFavorite(context: AccountContext, fileId: Int64, isFavorite: Bool) {
        MusicLibrary.shared(context: context).setFavorite(fileId: fileId, isFavorite)
    }

    /// The same sheet as the track menu's Add to Playlist. A new playlist is created on its own screen, so the
    /// player is dismissed first (`dismissPlayer`).
    public static func addToPlaylist(context: AccountContext, fileId: Int64, messageId: EngineMessage.Id?, present: @escaping (ViewController) -> Void, dismissPlayer: @escaping () -> Void) {
        let library = MusicLibrary.shared(context: context)
        let toast: (String) -> Void = { text in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            guard let image = generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/AddCaption"), color: .white) else {
                return
            }
            context.sharedContext.mainWindow?.present(UndoOverlayController(presentationData: presentationData, content: .universalImage(image: image, size: nil, title: nil, text: text, customUndoText: nil, timeout: 3.0), action: { _ in
                return true
            }), on: .root)
        }
        let presentSheet: (MusicTrack) -> Void = { track in
            presentMusicAddToPlaylistSheet(context: context, library: library, tracks: [track], excluding: nil, present: present, createPlaylist: { completion in
                dismissPlayer()
                guard let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController else {
                    return
                }
                navigationController.pushViewController(musicPlaylistEditScreen(context: context, library: library, playlist: nil, completion: completion))
            }, toast: toast)
        }
        if let track = library.track(fileId: fileId) {
            presentSheet(track)
            return
        }
        // A chat track the library has not loaded yet: its message is stored.
        guard let messageId else {
            return
        }
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
        |> deliverOnMainQueue).startStandalone(next: { message in
            guard let message else {
                return
            }
            presentSheet(MusicTrack(message: message._asMessage(), isSaved: false))
        })
    }

    // MARK: Queue sheet

    /// The section's queue in play order, now and after every edit.
    public static func queueMessages(context: AccountContext) -> Signal<[EngineRawMessage], NoError> {
        return MusicLibrary.shared(context: context).queueMessages
    }

    /// Moves a track of the section's queue: the player reads the queue again at the next track.
    public static func moveInQueue(context: AccountContext, messageId: EngineMessage.Id, toIndex: Int) {
        MusicLibrary.shared(context: context).moveInQueue(messageId: messageId, toIndex: toIndex)
    }

    /// Turns the section's queue over: the tracks before the playing one come next, from the nearest.
    public static func setQueueReversed(context: AccountContext, _ isReversed: Bool) {
        MusicLibrary.shared(context: context).setQueueReversed(isReversed)
    }

    /// Makes a queue the player was given (a chat's audio, a profile's music) the section's own, so it can be turned
    /// over and reordered. The playing track goes on from where it is.
    public static func adoptQueue(context: AccountContext, messages: [EngineRawMessage], currentId: EngineMessage.Id, title: String, kind: MusicPlayerQueueKind, timestamp: Double?) {
        let library = MusicLibrary.shared(context: context)
        let tracks = messages.map { MusicTrack(message: $0, isSaved: $0.id.namespace != Namespaces.Message.Cloud) }
        guard let current = tracks.first(where: { $0.message.id == currentId }) else {
            return
        }
        let location = library.playlistLocation(track: current, tracks: tracks, title: title, kind: kind)
        context.sharedContext.mediaManager.setPlaylist((context, PeerMessagesMediaPlaylist(context: context, location: location, chatLocationContextHolder: nil)), type: .music, control: .playback(.play))
        if let timestamp, timestamp > 1.0 {
            Queue.mainQueue().after(0.35, {
                context.sharedContext.mediaManager.playlistControl(.seek(timestamp), type: .music)
            })
        }
    }

    /// Plays a track of the section's queue without changing the queue.
    public static func playInQueue(context: AccountContext, messageId: EngineMessage.Id) {
        let location = MusicLibrary.shared(context: context).queueLocation(at: messageId)
        context.sharedContext.mediaManager.setPlaylist((context, PeerMessagesMediaPlaylist(context: context, location: location, chatLocationContextHolder: nil)), type: .music, control: .playback(.play))
    }

    /// A new playlist of the queue's tracks, opened on the playlist editor so it gets a name.
    /// The editor is a screen of its own, so the player is dismissed first.
    public static func createPlaylist(context: AccountContext, messages: [EngineRawMessage], dismissPlayer: @escaping () -> Void) {
        let library = MusicLibrary.shared(context: context)
        dismissPlayer()
        guard let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController else {
            return
        }
        navigationController.pushViewController(musicPlaylistEditScreen(context: context, library: library, playlist: nil, initialTrackIds: messages.map(\.id), completion: { _ in
        }))
    }

    /// The same sheet as the track menu's Add to Playlist, for every track of the queue.
    public static func addToPlaylist(context: AccountContext, messages: [EngineRawMessage], present: @escaping (ViewController) -> Void, dismissPlayer: @escaping () -> Void) {
        let library = MusicLibrary.shared(context: context)
        let tracks = messages.map { message -> MusicTrack in
            if let fileId = MusicTrack(message: message, isSaved: false).file?.fileId.id, let track = library.track(fileId: fileId) {
                return track
            }
            return MusicTrack(message: message, isSaved: false)
        }
        presentMusicAddToPlaylistSheet(context: context, library: library, tracks: tracks, excluding: nil, present: present, createPlaylist: { completion in
            dismissPlayer()
            guard let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController else {
                return
            }
            navigationController.pushViewController(musicPlaylistEditScreen(context: context, library: library, playlist: nil, completion: completion))
        }, toast: { text in
            musicPlayerToast(context: context, text: text, iconName: "Chat/Context Menu/AddCaption")
        })
    }

    public static func playlistExists(context: AccountContext, id: Int) -> Bool {
        return MusicLibrary.shared(context: context).playlist(id: id) != nil
    }

    /// Opens the playlist's own screen in the Music section.
    public static func openPlaylist(context: AccountContext, id: Int) {
        guard let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController else {
            return
        }
        navigationController.pushViewController(MusicScreen(context: context, mode: .navigation, section: .playlist(id), library: MusicLibrary.shared(context: context)))
    }

    /// Opens the artist's tracks in the Music section.
    public static func openArtist(context: AccountContext, name: String) {
        guard let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController else {
            return
        }
        navigationController.pushViewController(MusicScreen(context: context, mode: .navigation, section: .songs(artist: name), library: MusicLibrary.shared(context: context)))
    }

    public static func toast(context: AccountContext, text: String, iconName: String) {
        musicPlayerToast(context: context, text: text, iconName: iconName)
    }

    public static func libraryTitle(strings: PresentationStrings) -> String {
        return musicString(strings, ru: "Ваша медиатека", en: "Your Library")
    }

    public static func queueLabel(strings: PresentationStrings) -> String {
        return musicString(strings, ru: "Очередь", en: "Queue")
    }

    public static func ownMusicTitle(strings: PresentationStrings) -> String {
        return musicOwnMusicQueueTitle(strings: strings)
    }

    public static func userMusicTitle(strings: PresentationStrings, name: String) -> String {
        return musicString(strings, ru: "Музыка \(name)", en: "\(name)’s Music")
    }

    public static func chatTitle(strings: PresentationStrings, name: String) -> String {
        return musicString(strings, ru: "Диалог с \(name)", en: "Chat with \(name)")
    }
}

private func musicPlayerToast(context: AccountContext, text: String, iconName: String) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    guard let image = generateTintedImage(image: UIImage(bundleImageName: iconName), color: .white) else {
        return
    }
    context.sharedContext.mainWindow?.present(UndoOverlayController(presentationData: presentationData, content: .universalImage(image: image, size: nil, title: nil, text: text, customUndoText: nil, timeout: 3.0), action: { _ in
        return true
    }), on: .root)
}
