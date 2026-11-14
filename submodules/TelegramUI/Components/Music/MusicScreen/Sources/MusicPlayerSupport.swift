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
    /// Shuffle mixed the queue itself: it plays in the order it shows and can be reordered.
    public let isShuffled: Bool

    public init(messageIds: [EngineMessage.Id], title: String, kind: MusicPlayerQueueKind, isReversed: Bool, isShuffled: Bool) {
        self.messageIds = messageIds
        self.title = title
        self.kind = kind
        self.isReversed = isReversed
        self.isShuffled = isShuffled
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
    return strings.Music_YourMusic
}

func musicPlaylistQueueTitle(strings: PresentationStrings, playlist: MusicPlaylist) -> String {
    return strings.Music_YourPlaylist(playlist.title).string
}

/// The sheet that adds tracks to one of the playlists, or to a new one.
/// Playlists are local stand-ins: the choice is kept with the playlist on this device.
/// Add to Playlist: the section's Playlists list as a sheet (`MusicScreen.playlistChooser`), pushed with `push`.
func presentMusicAddToPlaylistSheet(context: AccountContext, library: MusicLibrary, tracks: [MusicTrack], excluding excludedId: Int?, push: @escaping (ViewController) -> Void, toast: @escaping (String) -> Void) {
    guard !tracks.isEmpty else {
        return
    }
    let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
    let chooser = MusicPlaylistChooser(excludedId: excludedId, completion: { [weak library] playlist in
        library?.add(tracks: tracks, to: playlist.id)
        toast(tracks.count == 1 ? strings.Music_TrackWasAddedTo(playlist.title).string : strings.Music_TracksWereAddedTo(playlist.title).string)
    })
    push(MusicScreen.playlistChooser(context: context, library: library, chooser: chooser))
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

    /// The toast's icon animation starts 0.2 s after it appears and runs 0.75 s (`anim_success`, 45 frames at 60).
    /// A change to the library rebuilds every Music screen under the sheet and the queue on the main thread, which
    /// stalled that animation, so the player shows its own state at once and the library follows once it ends.
    private static let libraryChangeDelay: Double = 1.0

    private static func applyAfterToast(_ f: @escaping () -> Void) {
        Queue.mainQueue().after(MusicPlayerSupport.libraryChangeDelay, f)
    }

    /// Adding to and taking out of Music never touches the profile: a file from outside the account's chats and
    /// profile is kept on this device.
    public static func addToMusic(context: AccountContext, file: TelegramMediaFile) {
        let toast = musicLibraryToast(strings: context.sharedContext.currentPresentationData.with { $0 }.strings, isInMusic: true, count: 1)
        musicPlayerToast(context: context, text: toast.text, iconName: toast.iconName)
        let library = MusicLibrary.shared(context: context)
        MusicPlayerSupport.applyAfterToast { [weak library] in
            library?.addToMusic(file: file)
        }
    }

    public static func removeFromMusic(context: AccountContext, fileId: Int64) {
        let toast = musicLibraryToast(strings: context.sharedContext.currentPresentationData.with { $0 }.strings, isInMusic: false, count: 1)
        musicPlayerToast(context: context, text: toast.text, iconName: toast.iconName)
        let library = MusicLibrary.shared(context: context)
        MusicPlayerSupport.applyAfterToast { [weak library] in
            library?.removeFromMusic(fileId: fileId)
        }
    }

    public static func setFavorite(context: AccountContext, fileId: Int64, isFavorite: Bool) {
        let toast = musicFavoriteToast(strings: context.sharedContext.currentPresentationData.with { $0 }.strings, isFavorite: isFavorite)
        musicPlayerToast(context: context, text: toast.text, iconName: toast.iconName)
        let library = MusicLibrary.shared(context: context)
        MusicPlayerSupport.applyAfterToast { [weak library] in
            library?.setFavorite(fileId: fileId, isFavorite)
        }
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
            presentMusicAddToPlaylistSheet(context: context, library: library, tracks: [track], excluding: nil, push: { controller in
                dismissPlayer()
                (context.sharedContext.mainWindow?.viewController as? NavigationController)?.pushViewController(controller)
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

    /// Mixes the section's queue in place, or brings its order back: the player reads it again at the next track.
    public static func setQueueShuffled(context: AccountContext, _ isShuffled: Bool) {
        MusicLibrary.shared(context: context).setQueueShuffled(isShuffled)
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
        presentMusicAddToPlaylistSheet(context: context, library: library, tracks: tracks, excluding: nil, push: { controller in
            dismissPlayer()
            (context.sharedContext.mainWindow?.viewController as? NavigationController)?.pushViewController(controller)
        }, toast: { text in
            musicPlayerToast(context: context, text: text, iconName: "Chat/Context Menu/AddCaption")
        })
    }

    /// The queue's tracks for the share sheet, sent as one group like selected tracks (albums of up to 10),
    /// not as separate forwards.
    public static func queueShareSubject(context: AccountContext, messages: [EngineRawMessage]) -> ShareControllerSubject {
        let library = MusicLibrary.shared(context: context)
        let tracks = messages.compactMap { message -> MusicTrack? in
            let track = MusicTrack(message: message, isSaved: message.id.namespace != Namespaces.Message.Cloud)
            guard let fileId = track.file?.fileId.id else {
                return nil
            }
            return library.track(fileId: fileId) ?? track
        }
        return musicShareTracksSubject(context: context, tracks: tracks)
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
        return strings.Music_YourLibrary
    }

    public static func queueLabel(strings: PresentationStrings) -> String {
        return strings.Music_Queue
    }

    public static func ownMusicTitle(strings: PresentationStrings) -> String {
        return musicOwnMusicQueueTitle(strings: strings)
    }

    public static func userMusicTitle(strings: PresentationStrings, name: String) -> String {
        return strings.Music_PeerMusic(name).string
    }

    public static func chatTitle(strings: PresentationStrings, name: String) -> String {
        return strings.Music_ChatWith(name).string
    }
}

func musicPlayerToast(context: AccountContext, text: String, iconName: String) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    guard let content = musicToastContent(text: text, iconName: iconName) else {
        return
    }
    context.sharedContext.mainWindow?.present(UndoOverlayController(presentationData: presentationData, content: content, action: { _ in
        return true
    }), on: .root)
}

/// Icon name that stands for the client's animated checkmark (`anim_success`, as in «Added to folder» toasts).
let musicAnimatedCheckIconName = "anim_success"

/// Favorites toasts: the Music hub's Favorites star (`anim_musicfavorites`, spins in) and the same star crossed
/// out: the slash is drawn while the full star fades into the cut star of the `Music/StarSlash` icon
/// (`anim_musicunfavorite`, no track mattes, so the gap renders in every Lottie backend).
let musicAnimatedFavoriteIconName = "anim_musicfavorites"
let musicAnimatedUnfavoriteIconName = "anim_musicunfavorite"

/// Removal from Music: the client's crossed-out double note (`anim_sound_off`, the «Sound disabled» toast), the same
/// filled ♫ as the hub's Tracks tile (`anim_sound_on`).
let musicAnimatedRemovedIconName = "anim_sound_off"

/// The toast content shared by every Music toast: the animated checkmark goes through the client's `.succeed`
/// toast, any other icon is a static white template image.
func musicToastContent(text: String, iconName: String) -> UndoOverlayContent? {
    if iconName == musicAnimatedCheckIconName {
        return .succeed(text: text, timeout: 3.0, customUndoText: nil)
    }
    if iconName == musicAnimatedRemovedIconName {
        // The client's scale for this animation in its own toasts.
        return .universal(animation: iconName, scale: 0.056, colors: [:], title: nil, text: text, customUndoText: nil, timeout: 3.0)
    }
    if iconName == musicAnimatedFavoriteIconName {
        // The star is 371 units wide on the 512 canvas; scaled so it matches the 19.5 pt star of the static
        // 24 pt `Music/Star` icon.
        return .universal(animation: iconName, scale: 19.5 / 371.0, colors: [:], title: nil, text: text, customUndoText: nil, timeout: 3.0)
    }
    if iconName == musicAnimatedUnfavoriteIconName {
        // Drawn on a 24 pt canvas from the `Music/Star` and `Music/StarSlash` vectors: it ends exactly on the
        // menu icon, so it is shown at 1:1.
        return .universal(animation: iconName, scale: 1.0, colors: [:], title: nil, text: text, customUndoText: nil, timeout: 3.0)
    }
    guard let image = generateTintedImage(image: UIImage(bundleImageName: iconName), color: .white) else {
        return nil
    }
    return .universalImage(image: image, size: nil, title: nil, text: text, customUndoText: nil, timeout: 3.0)
}

func musicFavoriteToast(strings: PresentationStrings, isFavorite: Bool) -> (text: String, iconName: String) {
    if isFavorite {
        return (strings.Music_TrackWasAddedToFavorites, musicAnimatedFavoriteIconName)
    } else {
        return (strings.Music_TrackWasRemovedFromFavorites, musicAnimatedUnfavoriteIconName)
    }
}

func musicLibraryToast(strings: PresentationStrings, isInMusic: Bool, count: Int) -> (text: String, iconName: String) {
    if isInMusic && count == 1 {
        return (strings.Music_TrackWasAddedToYourLibrary, musicAnimatedCheckIconName)
    } else if isInMusic {
        return (strings.Music_TracksWereAddedToYourLibrary("\(count)").string, musicAnimatedCheckIconName)
    } else if count == 1 {
        return (strings.Music_TrackWasRemovedFromYourLibrary, musicAnimatedRemovedIconName)
    } else {
        return (strings.Music_TracksWereRemovedFromYourLibrary("\(count)").string, musicAnimatedRemovedIconName)
    }
}

/// The profile's music row (PeerInfo) and the screen it opens.
public enum MusicProfileSupport {
    /// Profiles whose music row the section fills: the account's own and the local test user's (concept only).
    public static func hasLocalProfileMusic(context: AccountContext, peerId: EnginePeer.Id) -> Bool {
        return peerId == context.account.peerId || peerId == musicTestChatPeerId
    }

    /// The profile row of `peerId` (see `hasLocalProfileMusic`): the last track (or playlist) put in the profile, nil
    /// while there is none.
    public static func summary(context: AccountContext, peerId: EnginePeer.Id) -> Signal<MusicProfileSummary?, NoError> {
        return Signal<MusicProfileSummary?, NoError> { subscriber in
            let library = MusicLibrary.shared(context: context)
            let put: () -> Void = {
                let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
                subscriber.putNext(peerId == musicTestChatPeerId ? library.testProfileSummary(strings: strings) : library.profileSummary(strings: strings))
            }
            put()
            return library.updated.signal().start(next: { _ in
                put()
            })
        }
        |> runOn(Queue.mainQueue())
        |> distinctUntilChanged
    }

    public static func libraryTitle(strings: PresentationStrings) -> String {
        return musicProfileLibraryTitle(strings: strings)
    }

    public static func profileScreen(context: AccountContext, peerId: EnginePeer.Id, peerName: String?, savedMusicContext: ProfileSavedMusicContext?) -> ViewController {
        return MusicScreen.profileLibrary(context: context, peerId: peerId, peerName: peerName, savedMusicContext: savedMusicContext)
    }
}
