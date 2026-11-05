import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import ItemListUI
import ItemListAvatarAndNameInfoItem
import ItemListPeerActionItem
import ListMessageItem
import Photos
import AvatarEditorScreen
import CameraScreen
import MediaEditorScreen

private final class MusicPlaylistEditArguments {
    let context: AccountContext
    let updateTitle: (String) -> Void
    let updateDescription: (String) -> Void
    let changeCover: () -> Void
    let addTracks: () -> Void
    let removeTrack: (EngineMessage.Id) -> Void
    let done: () -> Void

    init(context: AccountContext, updateTitle: @escaping (String) -> Void, updateDescription: @escaping (String) -> Void, changeCover: @escaping () -> Void, addTracks: @escaping () -> Void, removeTrack: @escaping (EngineMessage.Id) -> Void, done: @escaping () -> Void) {
        self.context = context
        self.updateTitle = updateTitle
        self.updateDescription = updateDescription
        self.changeCover = changeCover
        self.addTracks = addTracks
        self.removeTrack = removeTrack
        self.done = done
    }
}

private enum MusicPlaylistEditSection: Int32 {
    case info
    case description
    case addTracks
    case tracks
}

private enum MusicPlaylistEditEntryTag: ItemListItemTag {
    case info
    case description

    func isEqual(to other: ItemListItemTag) -> Bool {
        if let other = other as? MusicPlaylistEditEntryTag {
            return self == other
        }
        return false
    }
}

private enum MusicPlaylistEditEntryId: Hashable {
    case info
    case description
    case descriptionInfo
    case addTracks
    case track(EngineMessage.Id)
}

private enum MusicPlaylistEditEntry: ItemListNodeEntry {
    case info(title: String, cover: TelegramMediaImageRepresentation?)
    case description(text: String, placeholder: String)
    case descriptionInfo(String)
    case addTracks(String)
    case track(index: Int, track: MusicTrack)

    var section: ItemListSectionId {
        switch self {
        case .info:
            return MusicPlaylistEditSection.info.rawValue
        case .description, .descriptionInfo:
            return MusicPlaylistEditSection.description.rawValue
        case .addTracks:
            return MusicPlaylistEditSection.addTracks.rawValue
        case .track:
            return MusicPlaylistEditSection.tracks.rawValue
        }
    }

    var stableId: MusicPlaylistEditEntryId {
        switch self {
        case .info:
            return .info
        case .description:
            return .description
        case .descriptionInfo:
            return .descriptionInfo
        case .addTracks:
            return .addTracks
        case let .track(_, track):
            return .track(track.message.id)
        }
    }

    private var sortIndex: Int {
        switch self {
        case .info:
            return 0
        case .description:
            return 1
        case .descriptionInfo:
            return 2
        case .addTracks:
            return 3
        case let .track(index, _):
            return 4 + index
        }
    }

    static func ==(lhs: MusicPlaylistEditEntry, rhs: MusicPlaylistEditEntry) -> Bool {
        switch lhs {
        case let .info(title, cover):
            if case .info(title, cover) = rhs {
                return true
            }
            return false
        case let .description(text, placeholder):
            if case .description(text, placeholder) = rhs {
                return true
            }
            return false
        case let .descriptionInfo(text):
            if case .descriptionInfo(text) = rhs {
                return true
            }
            return false
        case let .addTracks(text):
            if case .addTracks(text) = rhs {
                return true
            }
            return false
        case let .track(index, track):
            if case let .track(rhsIndex, rhsTrack) = rhs, index == rhsIndex, track.message.id == rhsTrack.message.id, track.isSaved == rhsTrack.isSaved {
                return true
            }
            return false
        }
    }

    static func <(lhs: MusicPlaylistEditEntry, rhs: MusicPlaylistEditEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! MusicPlaylistEditArguments
        let strings = presentationData.strings
        switch self {
        case let .info(title, cover):
            // The item draws a peer; like a channel being created, the playlist is a placeholder group named after it.
            let peer = TelegramGroup(id: EnginePeer.Id(namespace: Namespaces.Peer.CloudGroup, id: EnginePeer.Id.Id._internalFromInt64Value(0)), title: title, photo: [], participantCount: 0, role: .creator(rank: nil), membership: .Member, flags: [], defaultBannedRights: nil, migrationReference: nil, creationDate: 0, version: 0)
            let name = ItemListAvatarAndNameInfoItemName.title(title: title, type: .group)
            return ItemListAvatarAndNameInfoItem(itemContext: .accountContext(arguments.context), presentationData: presentationData, systemStyle: .glass, dateTimeFormat: arguments.context.sharedContext.currentPresentationData.with { $0 }.dateTimeFormat, mode: .editSettings, peer: EnginePeer(peer), presence: nil, memberCount: nil, state: ItemListAvatarAndNameInfoItemState(editingName: name, updatingName: nil), sectionId: self.section, style: .blocks(withTopInset: false, withExtendedBottomInset: false), editingNameUpdated: { name in
                if case let .title(title, _) = name {
                    arguments.updateTitle(title)
                }
            }, editingNameCompleted: {
            }, avatarTapped: {
                arguments.changeCover()
            }, updatingImage: cover.flatMap { .image($0, false) }, tag: MusicPlaylistEditEntryTag.info, namePlaceholder: musicString(strings, ru: "Название плейлиста", en: "Playlist Name"))
        case let .description(text, placeholder):
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: text, placeholder: placeholder, maxLength: ItemListMultilineInputItemTextLimit(value: 255, display: true), sectionId: self.section, style: .blocks, textUpdated: { text in
                arguments.updateDescription(text)
            }, tag: MusicPlaylistEditEntryTag.description)
        case let .descriptionInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .addTracks(title):
            return ItemListPeerActionItem(presentationData: presentationData, style: .blocks, systemStyle: .glass, icon: PresentationResourcesItemList.plusIconImage(presentationData.theme), title: title, sectionId: self.section, height: .generic, color: .accent, action: {
                arguments.addTracks()
            })
        case let .track(_, track):
            let interaction = ListMessageItemInteraction(openMessage: { _, _ in
                return true
            }, openMessageContextMenu: { _, _, _, _, _ in
            }, toggleMediaPlayback: { _ in
            }, toggleMessagesSelection: { _, _ in
            }, openUrl: { _, _, _, _ in
            }, openInstantPage: { _, _ in
            }, longTap: { _, _ in
            }, getHiddenMedia: {
                return [:]
            })
            let messageId = track.message.id
            let editControl = MusicResources.removeControl(theme: presentationData.theme).flatMap { icon in
                return ListMessageItemEditControl(icon: icon, action: {
                    arguments.removeTrack(messageId)
                })
            }
            let currentPresentationData = arguments.context.sharedContext.currentPresentationData.with { $0 }
            return ListMessageItem(presentationData: musicChatPresentationData(currentPresentationData), systemStyle: .glass, context: arguments.context, chatLocation: .peer(id: track.message.id.peerId), interaction: interaction, message: track.message, selection: .none, displayHeader: false, isGlobalSearchResult: !track.isSaved, isSavedMusic: track.isSaved, displayFileInfo: true, audioInfo: .performer, hidesAudioFileExtension: true, blockTopInset: 24.0, displayBackground: true, editControl: editControl, style: .blocks, sectionId: self.section)
        }
    }
}

private struct MusicPlaylistEditState: Equatable {
    var title: String
    var description: String
    var trackIds: [EngineMessage.Id]
    var cover: TelegramMediaImageRepresentation?
}

/// Creating a playlist, and editing one: the name and photo card, a description and the tracks, as a channel is created.
/// The result is kept in the library's memory: the API has no playlists.
func musicPlaylistEditScreen(context: AccountContext, library: MusicLibrary, playlist: MusicPlaylist?, completion: @escaping (MusicPlaylist) -> Void) -> ViewController {
    let initialState = MusicPlaylistEditState(title: playlist?.title ?? "", description: playlist?.description ?? "", trackIds: playlist?.trackIds ?? [], cover: playlist?.cover)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((MusicPlaylistEditState) -> MusicPlaylistEditState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    var dismissImpl: (() -> Void)?
    var pushImpl: ((ViewController) -> Void)?
    var endEditingImpl: (() -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    var avatarPickerHolder: Any?
    let setCover: (TelegramMediaImageRepresentation?) -> Void = { cover in
        updateState { state in
            var state = state
            state.cover = cover
            return state
        }
    }

    let arguments = MusicPlaylistEditArguments(context: context, updateTitle: { title in
        updateState { state in
            var state = state
            state.title = title
            return state
        }
    }, updateDescription: { text in
        updateState { state in
            var state = state
            state.description = text
            return state
        }
    }, changeCover: {
        endEditingImpl?()
        presentMusicPlaylistCoverPicker(context: context, hasCover: stateValue.with { $0.cover != nil }, pickerHolder: { holder in
            avatarPickerHolder = holder
        }, push: { controller in
            pushImpl?(controller)
        }, present: { controller in
            presentImpl?(controller)
        }, completion: setCover)
    }, addTracks: {
        endEditingImpl?()
        let state = stateValue.with { $0 }
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let title = state.title.isEmpty ? musicString(strings, ru: "Плейлист", en: "Playlist") : state.title
        let picker = MusicTrackPicker(playlistTitle: title, trackIds: state.trackIds, completion: { trackIds in
            updateState { state in
                var state = state
                state.trackIds = trackIds
                return state
            }
        })
        pushImpl?(MusicScreen.trackPicker(context: context, library: library, picker: picker))
    }, removeTrack: { id in
        updateState { state in
            var state = state
            state.trackIds.removeAll(where: { $0 == id })
            return state
        }
    }, done: {
        endEditingImpl?()
        let state = stateValue.with { $0 }
        let title = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return
        }
        let description = state.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: MusicPlaylist?
        if let playlist {
            library.updatePlaylist(id: playlist.id, { playlist in
                playlist.title = title
                playlist.description = description
                playlist.trackIds = state.trackIds
                playlist.cover = state.cover
            })
            result = library.playlist(id: playlist.id)
        } else {
            result = library.createPlaylist(title: title, description: description, trackIds: state.trackIds, cover: state.cover)
        }
        dismissImpl?()
        if let result {
            completion(result)
        }
    })

    // The track rows follow the library: a track removed from the music leaves this list too.
    let libraryUpdated = Signal<Void, NoError> { subscriber in
        subscriber.putNext(Void())
        return library.updated.signal().start(next: { _ in
            subscriber.putNext(Void())
        })
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, statePromise.get(), libraryUpdated)
    |> map { presentationData, state, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        let rightButton = ItemListNavigationButton(content: .icon(.done), style: .bold, enabled: !state.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: {
            arguments.done()
        })
        let leftButton = ItemListNavigationButton(content: .icon(.close), style: .regular, enabled: true, action: {
            dismissImpl?()
        })
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(musicString(strings, ru: "Плейлист", en: "Playlist")), leftNavigationButton: leftButton, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: strings.Common_Back))

        var entries: [MusicPlaylistEditEntry] = [
            .info(title: state.title, cover: state.cover),
            .description(text: state.description, placeholder: musicString(strings, ru: "Описание", en: "Description")),
            .descriptionInfo(musicString(strings, ru: "Можете описать свой плейлист.", en: "You can describe your playlist.")),
            .addTracks(musicString(strings, ru: "Добавить треки", en: "Add Tracks"))
        ]
        var byId: [EngineMessage.Id: MusicTrack] = [:]
        for track in library.allTracks {
            byId[track.message.id] = track
        }
        for (index, id) in state.trackIds.enumerated() {
            if let track = byId[id] {
                entries.append(.track(index: index, track: track))
            }
        }
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, focusItemTag: playlist == nil ? MusicPlaylistEditEntryTag.info : nil)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    endEditingImpl = { [weak controller] in
        controller?.view.endEditing(true)
    }
    controller.willDisappear = { _ in
        endEditingImpl?()
        // The picker lives as long as this screen, as in channel creation.
        let _ = avatarPickerHolder
    }
    return controller
}

/// Stores a picked image as a local file: the playlist keeps it on this device until an API can hold a cover.
private func musicPlaylistCover(context: AccountContext, image: UIImage) -> TelegramMediaImageRepresentation? {
    guard let data = image.jpegData(compressionQuality: 0.6) else {
        return nil
    }
    let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max))
    context.engine.resources.storeResourceData(id: EngineMediaResource.Id(resource.id), data: data)
    return TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 640, height: 640), resource: resource, progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false)
}

/// The avatar picker of a new channel: gallery, camera or an emoji, then the round crop. A video keeps only its cover frame.
private func presentMusicPlaylistCoverPicker(context: AccountContext, hasCover: Bool, pickerHolder: @escaping (Any?) -> Void, push: @escaping (ViewController) -> Void, present: @escaping (ViewController) -> Void, completion: @escaping (TelegramMediaImageRepresentation?) -> Void) {
    let keyboardInputData = Promise<AvatarKeyboardInputData>()
    keyboardInputData.set(AvatarEditorScreen.inputData(context: context, isGroup: true))

    let applyImage: (UIImage) -> Void = { image in
        if let cover = musicPlaylistCover(context: context, image: image) {
            completion(cover)
        }
    }

    var dismissPickerImpl: (() -> Void)?
    let (mainController, holder) = context.sharedContext.makeAvatarMediaPickerScreen(context: context, peerType: .channel, getSourceRect: { return nil }, canDelete: hasCover, performDelete: {
        completion(nil)
    }, completion: { result, transitionView, transitionRect, transitionImage, fromCamera, _, cancelled in
        pickerHolder(nil)

        let subject: Signal<MediaEditorScreenImpl.Subject?, NoError>
        if let asset = result as? PHAsset {
            subject = .single(.asset(asset))
        } else if let image = result as? UIImage {
            subject = .single(.image(image: image, dimensions: PixelDimensions(image.size), additionalImage: nil, additionalImagePosition: .bottomRight, fromCamera: false))
        } else if let result = result as? Signal<CameraScreenImpl.Result, NoError> {
            subject = result
            |> map { value -> MediaEditorScreenImpl.Subject? in
                switch value {
                case .pendingImage:
                    return nil
                case let .image(image):
                    return .image(image: image.image, dimensions: PixelDimensions(image.image.size), additionalImage: nil, additionalImagePosition: .topLeft, fromCamera: false)
                case let .video(video):
                    return .video(videoPath: video.videoPath, thumbnail: video.coverImage, mirror: video.mirror, additionalVideoPath: nil, additionalThumbnail: nil, dimensions: video.dimensions, duration: video.duration, videoPositionChanges: [], additionalVideoPosition: .topLeft, fromCamera: false)
                default:
                    return nil
                }
            }
        } else {
            let controller = AvatarEditorScreen(context: context, inputData: keyboardInputData.get(), peerType: .channel, markup: nil)
            controller.imageCompletion = { image, commit in
                applyImage(image)
                commit()
            }
            controller.videoCompletion = { image, _, _, _, commit in
                applyImage(image)
                commit()
            }
            push(controller)
            return
        }

        let editorController = MediaEditorScreenImpl(
            context: context,
            mode: .avatarEditor(clipStyle: .round),
            subject: subject,
            transitionIn: fromCamera ? .camera : transitionView.flatMap({ .gallery(
                MediaEditorScreenImpl.TransitionIn.GalleryTransitionIn(
                    sourceView: $0,
                    sourceRect: transitionRect,
                    sourceImage: transitionImage
                )
            ) }),
            transitionOut: { finished, _ in
                if !finished, let transitionView {
                    return MediaEditorScreenImpl.TransitionOut(
                        destinationView: transitionView,
                        destinationRect: transitionView.bounds,
                        destinationCornerRadius: 0.0
                    )
                }
                return nil
            },
            completion: { results, commit in
                guard let result = results.first else {
                    return
                }
                switch result.media {
                case let .image(image, _):
                    applyImage(image)
                    commit({})
                case let .video(_, coverImage, _, _, _):
                    if let coverImage {
                        applyImage(coverImage)
                    }
                    commit({})
                default:
                    break
                }
                dismissPickerImpl?()
            } as ([MediaEditorScreenImpl.Result], @escaping (@escaping () -> Void) -> Void) -> Void
        )
        editorController.cancelled = { _ in
            cancelled()
        }
        push(editorController)
    }, dismissed: {
        pickerHolder(nil)
    })
    pickerHolder(holder)
    if let mainController {
        dismissPickerImpl = { [weak mainController] in
            if let mainController, let navigationController = mainController.navigationController {
                let viewControllers = navigationController.viewControllers.filter { controller in
                    return !(controller is CameraScreen) && controller !== mainController
                }
                navigationController.setViewControllers(viewControllers, animated: false)
            }
        }
        if mainController is ActionSheetController {
            present(mainController)
        } else {
            mainController.navigationPresentation = .flatModal
            mainController.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
            push(mainController)
        }
    }
}
