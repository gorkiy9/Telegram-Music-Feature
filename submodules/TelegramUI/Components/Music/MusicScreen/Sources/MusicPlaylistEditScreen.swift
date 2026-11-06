import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import ItemListUI
import ComponentFlow
import ButtonComponent
import BundleIconComponent
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
    case track(index: Int, track: MusicTrack, isFavorite: Bool)

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
        case let .track(_, track, _):
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
        case let .track(index, _, _):
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
        case let .track(index, track, isFavorite):
            if case let .track(rhsIndex, rhsTrack, rhsIsFavorite) = rhs, index == rhsIndex, track.message.id == rhsTrack.message.id, track.isSaved == rhsTrack.isSaved, isFavorite == rhsIsFavorite {
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
            }, tag: MusicPlaylistEditEntryTag.description, topInset: 24.0)
        case let .descriptionInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .addTracks(title):
            return MusicAddTracksButtonItem(theme: presentationData.theme, title: title, topInset: 19.0 + MusicPlaylistEditChrome.plateTopInset, bottomInset: 16.0, sectionId: self.section, action: {
                arguments.addTracks()
            })
        case let .track(_, track, isFavorite):
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
            return ListMessageItem(presentationData: musicChatPresentationData(currentPresentationData), systemStyle: .glass, context: arguments.context, chatLocation: .peer(id: track.message.id.peerId), interaction: interaction, message: track.message, selection: .none, displayHeader: false, isGlobalSearchResult: !track.isSaved, isSavedMusic: track.isSaved, displayFileInfo: true, audioInfo: .performer, hidesAudioFileExtension: true, blockTopInset: 0.0, displayBackground: false, canReorder: true, reorderBackgroundColor: presentationData.theme.list.itemBlocksBackgroundColor, reorderControlOutset: 16.0, additionalLeftInset: -14.0, trailingIcon: isFavorite ? MusicResources.favoriteMark(theme: presentationData.theme) : nil, editControl: editControl, displaysAudioCover: true, style: .plain, sectionId: self.section)
        }
    }
}


/// The full-width plate under Add Tracks and the track rows, and the bottom toolbar's Add button that appears once Add Tracks has
/// scrolled away (Figma Playlists / New / Filled and / Scroll). A custom block: the plate is wider than a card and its top is rounded.
final class MusicPlaylistEditChrome {
    static let plateTopInset: CGFloat = 16.0
    static let plateRadius: CGFloat = 32.0
    static let toolbarButtonSize: CGFloat = 48.0

    weak var controller: ItemListController?
    var theme: PresentationTheme
    var addAction: () -> Void = {}

    private let plate = UIView()
    /// The item list covers its side margins with background strips above the rows; this copy of the plate sits above them,
    /// masked to the margins and the band above Add Tracks, so the plate reads full width as in Figma.
    private let plateOverlay = UIView()
    private let plateOverlayMask = CAShapeLayer()
    private let addButton = ComponentView<Empty>()
    private var isToolbarShown = false

    init(theme: PresentationTheme) {
        self.theme = theme
        self.plate.layer.cornerRadius = MusicPlaylistEditChrome.plateRadius
        self.plate.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        self.plateOverlay.isUserInteractionEnabled = false
        self.plateOverlay.layer.cornerRadius = MusicPlaylistEditChrome.plateRadius
        self.plateOverlay.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        self.plateOverlay.layer.mask = self.plateOverlayMask
        if #available(iOS 13.0, *) {
            self.plate.layer.cornerCurve = .continuous
            self.plateOverlay.layer.cornerCurve = .continuous
        }
    }

    func update() {
        guard let controller = self.controller, controller.isViewLoaded, let node = controller.displayNode as? ItemListControllerNode else {
            return
        }
        let listNode = node.listNode
        let listView = listNode.view
        if self.plate.superview !== listView {
            listView.insertSubview(self.plate, at: 0)
        }
        self.plate.backgroundColor = self.theme.list.itemBlocksBackgroundColor
        self.plateOverlay.backgroundColor = self.theme.list.itemBlocksBackgroundColor
        if let container = listView.superview, self.plateOverlay.superview !== container {
            container.addSubview(self.plateOverlay)
        }

        var buttonFrame: CGRect?
        listNode.forEachItemNode { itemNode in
            if let itemNode = itemNode as? MusicAddTracksButtonItemNode {
                // The node's frame starts at its top inset; the plate is measured from the visible button.
                buttonFrame = CGRect(x: itemNode.frame.minX, y: itemNode.frame.minY + itemNode.insets.top, width: itemNode.frame.width, height: itemNode.frame.height - itemNode.insets.top - itemNode.insets.bottom)
            }
        }
        var scrolledPast = false
        if case let .known(offset) = listNode.visibleContentOffset(), offset > 0.0 {
            scrolledPast = true
        } else if case .unknown = listNode.visibleContentOffset() {
            scrolledPast = true
        }
        let top: CGFloat?
        if let buttonFrame {
            top = buttonFrame.minY - MusicPlaylistEditChrome.plateTopInset
        } else if scrolledPast {
            // The button's node is gone: the plate covers the whole list.
            top = -MusicPlaylistEditChrome.plateRadius - 1.0
        } else {
            top = nil
        }
        if let top {
            self.plate.isHidden = false
            self.plate.frame = CGRect(x: 0.0, y: top, width: listView.bounds.width, height: 20000.0)
        } else {
            self.plate.isHidden = true
        }
        self.updatePlateOverlay(listView: listView, buttonTop: buttonFrame?.minY)

        // The main button counts as hidden once it is under the top bar.
        var isMainButtonHidden = false
        if let buttonFrame {
            isMainButtonHidden = buttonFrame.maxY <= listNode.insets.top
        } else {
            isMainButtonHidden = scrolledPast
        }
        self.updateToolbar(isShown: isMainButtonHidden, in: node.view)
    }

    private func updatePlateOverlay(listView: UIView, buttonTop: CGFloat?) {
        guard let container = self.plateOverlay.superview, !self.plate.isHidden else {
            self.plateOverlay.isHidden = true
            return
        }
        self.plateOverlay.isHidden = false
        let frame = listView.convert(self.plate.frame, to: container)
        self.plateOverlay.frame = frame
        let side: CGFloat = 16.0
        let path = UIBezierPath()
        path.append(UIBezierPath(rect: CGRect(x: 0.0, y: 0.0, width: side, height: frame.height)))
        path.append(UIBezierPath(rect: CGRect(x: frame.width - side, y: 0.0, width: side, height: frame.height)))
        if let buttonTop {
            let band = listView.convert(CGPoint(x: 0.0, y: buttonTop), to: container).y - frame.minY
            path.append(UIBezierPath(rect: CGRect(x: 0.0, y: 0.0, width: frame.width, height: max(0.0, band))))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.plateOverlayMask.frame = CGRect(origin: .zero, size: frame.size)
        self.plateOverlayMask.path = path.cgPath
        CATransaction.commit()
    }

    private func updateToolbar(isShown: Bool, in container: UIView) {
        let size = MusicPlaylistEditChrome.toolbarButtonSize
        let glass = self.theme.overallDarkAppearance ? UIColor(white: 0.0, alpha: 0.01) : UIColor(white: 1.0, alpha: 0.01)
        let foreground = self.theme.list.itemPrimaryTextColor
        let _ = self.addButton.update(
            transition: .immediate,
            component: AnyComponent(ButtonComponent(
                background: ButtonComponent.Background(style: .actualGlass, color: glass, foreground: foreground, pressedColor: glass, cornerRadius: size * 0.5),
                content: AnyComponentWithIdentity(id: AnyHashable("add"), component: AnyComponent(BundleIconComponent(name: "Chat/Context Menu/Add", tintColor: foreground, maxSize: CGSize(width: 24.0, height: 24.0)))),
                action: { [weak self] in
                    self?.addAction()
                }
            )),
            environment: {},
            containerSize: CGSize(width: size, height: size)
        )
        guard let view = self.addButton.view else {
            return
        }
        if view.superview !== container {
            container.addSubview(view)
            view.alpha = 0.0
        }
        // Figma Toolbar - Bottom: the button sits 4 pt into an 84 pt bar, so 32 pt above the screen edge with a 34 pt home indicator.
        let safeBottom = container.window?.safeAreaInsets.bottom ?? container.safeAreaInsets.bottom
        let bottomInset = max(safeBottom, 18.0) - 2.0
        view.frame = CGRect(x: container.bounds.width - 16.0 - size, y: container.bounds.height - bottomInset - size, width: size, height: size)
        if isShown != self.isToolbarShown {
            self.isToolbarShown = isShown
            view.isUserInteractionEnabled = isShown
            UIView.animate(withDuration: 0.25, animations: {
                view.alpha = isShown ? 1.0 : 0.0
                view.transform = isShown ? .identity : CGAffineTransform(scaleX: 0.8, y: 0.8)
            })
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
        presentMusicCoverPicker(context: context, hasCover: stateValue.with { $0.cover != nil }, pickerHolder: { holder in
            avatarPickerHolder = holder
        }, push: { controller in
            pushImpl?(controller)
        }, present: { controller in
            presentImpl?(controller)
        }, completion: { image in
            if let image {
                if let cover = musicPlaylistCover(context: context, image: image) {
                    setCover(cover)
                }
            } else {
                setCover(nil)
            }
        })
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

    let chrome = MusicPlaylistEditChrome(theme: context.sharedContext.currentPresentationData.with { $0 }.theme)
    chrome.addAction = {
        arguments.addTracks()
    }
    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, statePromise.get(), libraryUpdated)
    |> map { presentationData, state, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        chrome.theme = presentationData.theme
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
                entries.append(.track(index: index, track: track, isFavorite: library.isFavorite(track)))
            }
        }
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, focusItemTag: playlist == nil ? MusicPlaylistEditEntryTag.info : nil)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    chrome.controller = controller
    controller.contentOffsetChanged = { _, _ in
        chrome.update()
    }
    controller.afterTransactionCompleted = {
        chrome.update()
    }
    controller.visibleEntriesUpdated = { _ in
        chrome.update()
    }
    controller.didAppear = { _ in
        chrome.update()
    }
    // The grabber at the end of a track row: the list moves the row, the state follows it.
    controller.setReorderEntry({ (fromIndex: Int, toIndex: Int, entries: [MusicPlaylistEditEntry]) -> Signal<Bool, NoError> in
        guard fromIndex >= 0, fromIndex < entries.count, case let .track(_, fromTrack, _) = entries[fromIndex] else {
            return .single(false)
        }
        let trackEntryIndices = entries.enumerated().compactMap { index, entry -> Int? in
            if case .track = entry {
                return index
            }
            return nil
        }
        guard let firstIndex = trackEntryIndices.first, let lastIndex = trackEntryIndices.last else {
            return .single(false)
        }
        let targetIndex = min(max(toIndex, firstIndex), lastIndex)
        let fromPosition = fromIndex - firstIndex
        let toPosition = targetIndex - firstIndex
        if fromPosition == toPosition {
            return .single(false)
        }
        // Only the tracks on screen are moved; any id the library no longer has stays at the end.
        var displayedIds: [EngineMessage.Id] = []
        for entry in entries {
            if case let .track(_, track, _) = entry {
                displayedIds.append(track.message.id)
            }
        }
        displayedIds.remove(at: fromPosition)
        displayedIds.insert(fromTrack.message.id, at: toPosition)
        updateState { state in
            var state = state
            state.trackIds = displayedIds + state.trackIds.filter { !displayedIds.contains($0) }
            return state
        }
        return .single(true)
    })
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
func musicPlaylistCover(context: AccountContext, image: UIImage) -> TelegramMediaImageRepresentation? {
    guard let data = image.jpegData(compressionQuality: 0.6) else {
        return nil
    }
    let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max))
    context.engine.resources.storeResourceData(id: EngineMediaResource.Id(resource.id), data: data)
    return TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 640, height: 640), resource: resource, progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false)
}

/// The avatar picker of a new channel: gallery, camera or an emoji, then the round crop. A video keeps only its cover frame.
/// Completes with the picked image, or nil when the cover is deleted.
func presentMusicCoverPicker(context: AccountContext, hasCover: Bool, pickerHolder: @escaping (Any?) -> Void, push: @escaping (ViewController) -> Void, present: @escaping (ViewController) -> Void, completion: @escaping (UIImage?) -> Void) {
    let keyboardInputData = Promise<AvatarKeyboardInputData>()
    keyboardInputData.set(AvatarEditorScreen.inputData(context: context, isGroup: true))

    let applyImage: (UIImage) -> Void = { image in
        completion(image)
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
