import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import ContextUI
import PeerMessagesMediaPlaylist

/// Music section concept: a playlist shared into a chat travels as a link preview of its own type that carries the
/// playlist's name, owner, cover and every track, so the chat draws it without the sender's library. The API has no
/// playlists: a real one would come from the server as `webPage` with a playlist attribute (see the README).
public let musicSharedPlaylistWebpageType = "telegram_music_playlist"

/// The playlist's public link, named after the playlist: words joined by "_", only letters and digits kept (any script),
/// as public usernames and folder links read. The API has no playlists, so nothing resolves it yet (see the README).
func musicPlaylistLink(playlist: MusicPlaylist) -> String {
    let words = playlist.title.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    let slug = words.isEmpty ? "\(playlist.id)" : words.joined(separator: "_")
    return "https://t.me/music/playlist/\(slug)"
}

func musicSharedPlaylistWebpage(playlist: MusicPlaylist, files: [TelegramMediaFile], ownerName: String?) -> TelegramMediaWebpage {
    let image = playlist.cover.flatMap { cover in
        return TelegramMediaImage(imageId: EngineMedia.Id(namespace: Namespaces.Media.LocalImage, id: Int64.random(in: 1 ... Int64.max)), representations: [cover], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
    }
    let url = musicPlaylistLink(playlist: playlist)
    let content = TelegramMediaWebpageLoadedContent(
        url: url,
        displayUrl: String(url.dropFirst("https://".count)),
        hash: 0,
        type: musicSharedPlaylistWebpageType,
        websiteName: "Telegram",
        title: playlist.title,
        text: playlist.description.isEmpty ? nil : playlist.description,
        embedUrl: nil,
        embedType: nil,
        embedSize: nil,
        duration: nil,
        author: ownerName,
        isMediaLargeByDefault: nil,
        imageIsVideoCover: false,
        image: image,
        file: nil,
        story: nil,
        attributes: [.musicPlaylist(TelegramMediaWebpageMusicPlaylistAttribute(playlistId: Int64(playlist.id), files: files))],
        instantPage: nil
    )
    return TelegramMediaWebpage(webpageId: EngineMedia.Id(namespace: Namespaces.Media.LocalWebpage, id: Int64.random(in: 1 ... Int64.max)), content: .Loaded(content))
}

/// The test chat gets the playlist bubble. Real chats keep the old behaviour: the tracks themselves, chat ones
/// forwarded without the sender's name, saved ones as files.
func musicSharePlaylistSubject(context: AccountContext, playlist: MusicPlaylist, tracks: [MusicTrack]) -> ShareControllerSubject {
    let files = tracks.compactMap(\.file)
    return .fromExternal(1, { peerIds, threadIds, _, text, _, _ in
        let accountPeer = context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
        return .single(.preparing(false))
        |> castError(ShareControllerError.self)
        |> then(
            accountPeer
            |> castError(ShareControllerError.self)
            |> mapToSignal { accountPeer -> Signal<ShareControllerExternalStatus, ShareControllerError> in
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                let ownerName = accountPeer?.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                var signals: [Signal<[EngineMessage.Id?], NoError>] = []
                for peerId in peerIds {
                    let threadId = threadIds[peerId]
                    var messages: [EnqueueMessage] = []
                    if musicSendsPlaylistBubble(to: peerId) {
                        let webpage = musicSharedPlaylistWebpage(playlist: playlist, files: files, ownerName: ownerName)
                        messages.append(.message(text: text, attributes: [], inlineStickers: [:], mediaReference: .standalone(media: webpage), threadId: threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
                    } else {
                        if !text.isEmpty {
                            messages.append(.message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
                        }
                        for track in tracks {
                            if track.isSaved, let file = track.file {
                                // The profile's reference, as Share does for selected tracks: a standalone one cannot be
                                // refreshed once the file reference expires.
                                let mediaReference: AnyMediaReference = accountPeer.flatMap { PeerReference($0._asPeer()) }.flatMap { .savedMusic(peer: $0, media: file) } ?? .standalone(media: file)
                                messages.append(.message(text: "", attributes: [], inlineStickers: [:], mediaReference: mediaReference, threadId: threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: []))
                            } else {
                                messages.append(.forward(source: track.message.id, threadId: threadId, grouping: .auto, attributes: [ForwardOptionsMessageAttribute(hideNames: true, hideCaptions: true)], correlationId: nil))
                            }
                        }
                    }
                    signals.append(enqueueMessages(account: context.account, peerId: peerId, messages: messages))
                }
                // The enqueue signals can stay open after the messages are stored: one value is the send.
                return combineLatest(signals)
                |> take(1)
                |> castError(ShareControllerError.self)
                |> mapToSignal { _ -> Signal<ShareControllerExternalStatus, ShareControllerError> in
                    return .complete()
                }
            }
        )
        |> then(.single(.done))
    })
}

/// Selected tracks (selection toolbar) go out the way the attachment menu's Music tab sends them: as new file messages,
/// not forwards — a chat's track by its message reference, a saved one by the profile's — grouped into albums of up to
/// 10, the share sheet's comment under the last track.
func musicShareTracksSubject(context: AccountContext, tracks: [MusicTrack]) -> ShareControllerSubject {
    return .fromExternal(tracks.count, { peerIds, threadIds, _, text, _, _ in
        let accountPeer = context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
        return .single(.preparing(false))
        |> castError(ShareControllerError.self)
        |> then(
            accountPeer
            |> castError(ShareControllerError.self)
            |> mapToSignal { accountPeer -> Signal<ShareControllerExternalStatus, ShareControllerError> in
                let peerReference = accountPeer.flatMap { PeerReference($0._asPeer()) }
                let mediaReferences: [AnyMediaReference] = tracks.compactMap { track in
                    guard let file = track.file else {
                        return nil
                    }
                    if track.isSaved {
                        if let peerReference {
                            return .savedMusic(peer: peerReference, media: file)
                        } else {
                            return .standalone(media: file)
                        }
                    } else {
                        return .message(message: MessageReference(track.message), media: file)
                    }
                }
                var signals: [Signal<[EngineMessage.Id?], NoError>] = []
                for peerId in peerIds {
                    let threadId = threadIds[peerId]
                    var messages: [EnqueueMessage] = []
                    var groupingKey: Int64? = mediaReferences.count > 1 ? Int64.random(in: .min ..< .max) : nil
                    for (index, mediaReference) in mediaReferences.enumerated() {
                        if index > 0 && index % 10 == 0 {
                            groupingKey = Int64.random(in: .min ..< .max)
                        }
                        let hasCaption = index == mediaReferences.count - 1
                        messages.append(.message(text: hasCaption ? text : "", attributes: [], inlineStickers: [:], mediaReference: mediaReference, threadId: threadId, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: groupingKey, correlationId: nil, bubbleUpEmojiOrStickersets: []))
                    }
                    signals.append(enqueueMessages(account: context.account, peerId: peerId, messages: messages))
                }
                // The enqueue signals can stay open after the messages are stored: one value is the send.
                return combineLatest(signals)
                |> take(1)
                |> castError(ShareControllerError.self)
                |> mapToSignal { _ -> Signal<ShareControllerExternalStatus, ShareControllerError> in
                    return .complete()
                }
            }
        )
        |> then(.single(.done))
    })
}

private final class MusicSharedPlaylistReferenceContentSource: ContextReferenceContentSource {
    private let sourceView: UIView

    init(sourceView: UIView) {
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView, contentAreaInScreenSpace: mainWindowScreenBounds)
    }
}

extension MusicPlayerSupport {
    /// The actions of a playlist bubble. The playlist is looked up in this device's library: the API has no
    /// playlists, so only one shared from here can be played or opened.
    public static func handleSharedPlaylist(context: AccountContext, playlistId: Int64, action: MusicSharedPlaylistAction) {
        let library = MusicLibrary.shared(context: context)
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        guard let playlist = library.playlist(id: Int(playlistId)) else {
            MusicPlayerSupport.toast(context: context, text: strings.Music_PlaylistIsUnavailable, iconName: "Music/Playlists")
            return
        }
        switch action {
        case .open:
            guard let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController else {
                return
            }
            navigationController.pushViewController(MusicScreen.playlistSheet(context: context, library: library, playlistId: playlist.id))
        case let .play(shuffled):
            sharedPlaylistPlay(context: context, library: library, playlist: playlist, shuffled: shuffled, fileId: nil)
        case let .playTrack(fileId):
            sharedPlaylistPlay(context: context, library: library, playlist: playlist, shuffled: false, fileId: fileId)
        case let .menu(sourceView):
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let item: (String, String, @escaping () -> Void) -> ContextMenuItem = { title, iconName, action in
                return .action(ContextMenuActionItem(text: title, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: iconName), color: theme.contextMenu.primaryColor)
                }, action: { _, f in
                    f(.default)
                    action()
                }))
            }
            let items: [ContextMenuItem] = [
                item(strings.Music_Play2, "Chat/Context Menu/Play", {
                    sharedPlaylistPlay(context: context, library: library, playlist: playlist, shuffled: false, fileId: nil)
                }),
                item(strings.Music_Shuffle, "Music/Shuffle", {
                    sharedPlaylistPlay(context: context, library: library, playlist: playlist, shuffled: true, fileId: nil)
                }),
                .separator,
                item(strings.Music_PlayNext3, "Chat/Context Menu/MoveUp", {
                    sharedPlaylistEnqueue(context: context, library: library, playlist: playlist, next: true)
                }),
                item(strings.Music_AddToQueue, "Chat/Context Menu/MoveDown", {
                    sharedPlaylistEnqueue(context: context, library: library, playlist: playlist, next: false)
                }),
                .separator,
                item(strings.Music_OpenPlaylist, "Music/Playlists", {
                    MusicPlayerSupport.handleSharedPlaylist(context: context, playlistId: playlistId, action: .open)
                })
            ]
            let controller = makeContextController(context: context, presentationData: presentationData, source: .reference(MusicSharedPlaylistReferenceContentSource(sourceView: sourceView)), items: .single(ContextController.Items(content: .list(items))), recognizer: nil, gesture: nil)
            context.sharedContext.mainWindow?.presentInGlobalOverlay(controller)
        }
    }
}

private func sharedPlaylistPlay(context: AccountContext, library: MusicLibrary, playlist: MusicPlaylist, shuffled: Bool, fileId: Int64?) {
    var tracks = library.tracks(of: playlist)
    if shuffled {
        tracks.shuffle()
    }
    let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
    let start = fileId.flatMap { fileId in tracks.first(where: { $0.file?.fileId.id == fileId }) } ?? tracks.first
    guard let start else {
        MusicPlayerSupport.toast(context: context, text: strings.Music_TracksAreStillLoading, iconName: "Music/Playlists")
        return
    }
    let playlistId = playlist.id
    let location = library.playlistLocation(track: start, tracks: tracks, title: musicPlaylistQueueTitle(strings: strings, playlist: playlist), kind: .playlist(playlist.id), source: shuffled ? nil : { [weak library] in
        return library?.playlist(id: playlistId).flatMap { library?.tracks(of: $0) }
    })
    context.sharedContext.mediaManager.setPlaylist((context, PeerMessagesMediaPlaylist(context: context, location: location, chatLocationContextHolder: nil)), type: .music, control: .playback(.togglePlayPause))
}

private func sharedPlaylistEnqueue(context: AccountContext, library: MusicLibrary, playlist: MusicPlaylist, next: Bool) {
    let tracks = library.tracks(of: playlist)
    guard !tracks.isEmpty else {
        return
    }
    library.enqueue(tracks: tracks, next: next, completion: { queued in
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        if queued {
            MusicPlayerSupport.toast(context: context, text: next ? strings.Music_PlaylistWillPlayNext : strings.Music_PlaylistWasAddedToQueue, iconName: next ? "Chat/Context Menu/MoveUp" : "Chat/Context Menu/MoveDown")
        } else {
            sharedPlaylistPlay(context: context, library: library, playlist: playlist, shuffled: false, fileId: nil)
        }
    })
}
