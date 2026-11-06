import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PhotoResources

/// What the track screen opens with: a picked file not yet uploaded, or a track of the library.
enum MusicTrackEditMode {
    case new(TelegramMediaFile)
    case edit(MusicTrack)
}

/// The cover of the track screen (Figma Songs / New, "Avatar"): a 200 pt circle, 24 pt under the bar and above the card.
/// Without a cover it is the client's empty avatar: accent tint with the large camera glyph.
final class MusicTrackCoverItem: ListViewItem, ItemListItem {
    static let size: CGFloat = 200.0

    enum Cover: Equatable {
        case none
        case image(UIImage)
        case file(FileMediaReference)

        static func ==(lhs: Cover, rhs: Cover) -> Bool {
            switch lhs {
            case .none:
                if case .none = rhs {
                    return true
                }
                return false
            case let .image(image):
                if case .image(image) = rhs {
                    return true
                }
                return false
            case let .file(file):
                if case let .file(rhsFile) = rhs, file.media.isEqual(to: rhsFile.media) {
                    return true
                }
                return false
            }
        }
    }

    let context: AccountContext
    let theme: PresentationTheme
    let cover: Cover
    let sectionId: ItemListSectionId
    let action: () -> Void

    let selectable: Bool = false
    // The card follows 24 pt below the circle, which this item's own bottom inset carries.
    let requestsNoInset: Bool = true

    init(context: AccountContext, theme: PresentationTheme, cover: Cover, sectionId: ItemListSectionId, action: @escaping () -> Void) {
        self.context = context
        self.theme = theme
        self.cover = cover
        self.sectionId = sectionId
        self.action = action
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            Queue.mainQueue().async {
                let node = MusicTrackCoverItemNode()
                let (layout, apply) = node.asyncLayout()(self, params)
                node.contentSize = layout.contentSize
                node.insets = layout.insets
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? MusicTrackCoverItemNode else {
                assertionFailure()
                return
            }
            let (layout, apply) = nodeValue.asyncLayout()(self, params)
            completion(layout, { _ in
                apply()
            })
        }
    }
}

final class MusicTrackCoverItemNode: ListViewItemNode {
    private let containerNode = HighlightTrackingButtonNode()
    private let tintNode = ASDisplayNode()
    private let iconNode = ASImageNode()
    private let imageNode = ASImageNode()
    private let artworkNode = TransformImageNode()
    private var item: MusicTrackCoverItem?
    private var currentTheme: PresentationTheme?

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)

        self.containerNode.clipsToBounds = true
        self.containerNode.cornerRadius = MusicTrackCoverItem.size * 0.5
        self.tintNode.isUserInteractionEnabled = false
        self.iconNode.isUserInteractionEnabled = false
        self.imageNode.isUserInteractionEnabled = false
        self.imageNode.contentMode = .scaleAspectFill
        self.artworkNode.isUserInteractionEnabled = false

        self.addSubnode(self.containerNode)
        self.containerNode.addSubnode(self.tintNode)
        self.containerNode.addSubnode(self.iconNode)
        self.containerNode.addSubnode(self.artworkNode)
        self.containerNode.addSubnode(self.imageNode)
        self.containerNode.addTarget(self, action: #selector(self.pressed), forControlEvents: .touchUpInside)
        self.containerNode.highligthedChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            if highlighted {
                self.containerNode.layer.removeAnimation(forKey: "opacity")
                self.containerNode.alpha = 0.6
            } else {
                self.containerNode.alpha = 1.0
                self.containerNode.layer.animateAlpha(from: 0.6, to: 1.0, duration: 0.2)
            }
        }
    }

    @objc private func pressed() {
        self.item?.action()
    }

    func asyncLayout() -> (_ item: MusicTrackCoverItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, () -> Void) {
        return { [weak self] item, params in
            let size = MusicTrackCoverItem.size
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: size), insets: UIEdgeInsets(top: 24.0, left: 0.0, bottom: 24.0, right: 0.0))
            return (layout, { [weak self] in
                guard let self else {
                    return
                }
                let previousCover = self.item?.cover
                self.item = item

                let frame = CGRect(x: floor((params.width - size) / 2.0), y: 0.0, width: size, height: size)
                self.containerNode.frame = frame
                let bounds = CGRect(origin: .zero, size: frame.size)
                self.tintNode.frame = bounds
                self.imageNode.frame = bounds
                self.artworkNode.frame = bounds

                if self.currentTheme !== item.theme {
                    self.currentTheme = item.theme
                    // The empty avatar of a new channel: accent at 10% under the large camera glyph.
                    self.tintNode.backgroundColor = item.theme.list.itemAccentColor.withAlphaComponent(0.1)
                    self.iconNode.image = generateTintedImage(image: UIImage(bundleImageName: "Avatar/EditAvatarIconLarge"), color: item.theme.list.itemAccentColor)
                }
                if let image = self.iconNode.image {
                    self.iconNode.frame = CGRect(x: floor((size - image.size.width) / 2.0) + 0.5, y: floor((size - image.size.height) / 2.0) + 1.0, width: image.size.width, height: image.size.height)
                }

                switch item.cover {
                case .none:
                    self.imageNode.image = nil
                    self.imageNode.isHidden = true
                    self.artworkNode.isHidden = true
                case let .image(image):
                    self.imageNode.image = image
                    self.imageNode.isHidden = false
                    self.artworkNode.isHidden = true
                case let .file(file):
                    self.imageNode.isHidden = true
                    self.artworkNode.isHidden = false
                    if previousCover != item.cover {
                        // The player's artwork: the file's cover when it has one, else its embedded art or a found one.
                        self.artworkNode.setSignal(playerAlbumArt(engine: item.context.engine, fileReference: file, albumArt: nil, thumbnail: !file.media.previewRepresentations.isEmpty, emptyColor: .clear, drawPlaceholderWhenEmpty: false))
                    }
                    let makeLayout = self.artworkNode.asyncLayout()
                    let apply = makeLayout(TransformImageArguments(corners: ImageCorners(), imageSize: bounds.size, boundingSize: bounds.size, intrinsicInsets: UIEdgeInsets()))
                    apply()
                }
            })
        }
    }
}

private final class MusicTrackEditArguments {
    let changeCover: () -> Void
    let updateTitle: (String) -> Void
    let updateArtist: (String) -> Void
    let focusArtist: () -> Void
    let done: () -> Void

    init(changeCover: @escaping () -> Void, updateTitle: @escaping (String) -> Void, updateArtist: @escaping (String) -> Void, focusArtist: @escaping () -> Void, done: @escaping () -> Void) {
        self.changeCover = changeCover
        self.updateTitle = updateTitle
        self.updateArtist = updateArtist
        self.focusArtist = focusArtist
        self.done = done
    }
}

private enum MusicTrackEditEntryTag: ItemListItemTag {
    case title
    case artist

    func isEqual(to other: ItemListItemTag) -> Bool {
        if let other = other as? MusicTrackEditEntryTag {
            return self == other
        }
        return false
    }
}

private enum MusicTrackEditEntry: Equatable, Comparable {
    case cover(MusicTrackCoverItem.Cover)
    case title(text: String, placeholder: String)
    case artist(text: String, placeholder: String)

    var section: ItemListSectionId {
        switch self {
        case .cover:
            return 0
        case .title, .artist:
            return 1
        }
    }

    var stableId: Int {
        switch self {
        case .cover:
            return 0
        case .title:
            return 1
        case .artist:
            return 2
        }
    }

    static func ==(lhs: MusicTrackEditEntry, rhs: MusicTrackEditEntry) -> Bool {
        switch lhs {
        case let .cover(cover):
            if case .cover(cover) = rhs {
                return true
            }
            return false
        case let .title(text, placeholder):
            if case .title(text, placeholder) = rhs {
                return true
            }
            return false
        case let .artist(text, placeholder):
            if case .artist(text, placeholder) = rhs {
                return true
            }
            return false
        }
    }

    static func <(lhs: MusicTrackEditEntry, rhs: MusicTrackEditEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(context: AccountContext, presentationData: ItemListPresentationData, arguments: MusicTrackEditArguments) -> ListViewItem {
        switch self {
        case let .cover(cover):
            return MusicTrackCoverItem(context: context, theme: presentationData.theme, cover: cover, sectionId: self.section, action: {
                arguments.changeCover()
            })
        case let .title(text, placeholder):
            // The name rows of the contact editor: one card, a separator between the fields.
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: placeholder, returnKeyType: .next, tag: MusicTrackEditEntryTag.title, sectionId: self.section, textUpdated: { text in
                arguments.updateTitle(text)
            }, action: {
                arguments.focusArtist()
            })
        case let .artist(text, placeholder):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: placeholder, returnKeyType: .done, tag: MusicTrackEditEntryTag.artist, sectionId: self.section, textUpdated: { text in
                arguments.updateArtist(text)
            }, action: {
                arguments.done()
            })
        }
    }
}

/// `ItemListNodeEntry` hands items only presentation data and arguments, so the context rides in the arguments box.
private struct MusicTrackEditEntryBox: ItemListNodeEntry {
    let entry: MusicTrackEditEntry
    let context: AccountContext

    var section: ItemListSectionId {
        return self.entry.section
    }

    var stableId: Int {
        return self.entry.stableId
    }

    static func ==(lhs: MusicTrackEditEntryBox, rhs: MusicTrackEditEntryBox) -> Bool {
        return lhs.entry == rhs.entry
    }

    static func <(lhs: MusicTrackEditEntryBox, rhs: MusicTrackEditEntryBox) -> Bool {
        return lhs.entry < rhs.entry
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        return self.entry.item(context: self.context, presentationData: presentationData, arguments: arguments as! MusicTrackEditArguments)
    }
}

private struct MusicTrackEditState: Equatable {
    var title: String
    var artist: String
    /// A cover picked on this screen; nil keeps the track's own.
    var pickedCover: UIImage?
}

/// Adding a track and editing one (Figma Songs / New, Songs / Edit): the cover and the title and artist card,
/// as a contact is edited. A new track is uploaded on Done; an edit is kept on this device.
func musicTrackEditScreen(context: AccountContext, library: MusicLibrary, mode: MusicTrackEditMode, completion: @escaping (Bool) -> Void) -> ViewController {
    let file: TelegramMediaFile?
    let fileReference: FileMediaReference?
    switch mode {
    case let .new(newFile):
        file = newFile
        fileReference = .standalone(media: newFile)
    case let .edit(track):
        file = track.file
        fileReference = track.file.flatMap { .message(message: MessageReference(track.message), media: $0) }
    }
    var initialTitle = ""
    var initialArtist = ""
    for attribute in file?.attributes ?? [] {
        if case let .Audio(_, _, title, performer, _) = attribute {
            initialTitle = title ?? ""
            initialArtist = performer ?? ""
        }
    }
    if initialTitle.isEmpty {
        initialTitle = audioTitleWithoutFileExtension(file?.fileName ?? "")
    }
    // Artwork the file carries is shown until another one is picked; a file without any opens empty.
    let hasOwnArtwork = !(file?.previewRepresentations.isEmpty ?? true)

    let initialState = MusicTrackEditState(title: initialTitle, artist: initialArtist, pickedCover: nil)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((MusicTrackEditState) -> MusicTrackEditState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    var dismissImpl: (() -> Void)?
    var pushImpl: ((ViewController) -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    var endEditingImpl: (() -> Void)?
    var focusArtistImpl: (() -> Void)?
    var avatarPickerHolder: Any?

    let arguments = MusicTrackEditArguments(changeCover: {
        endEditingImpl?()
        presentMusicCoverPicker(context: context, hasCover: stateValue.with { $0.pickedCover != nil }, pickerHolder: { holder in
            avatarPickerHolder = holder
        }, push: { controller in
            pushImpl?(controller)
        }, present: { controller in
            presentImpl?(controller)
        }, completion: { image in
            updateState { state in
                var state = state
                state.pickedCover = image
                return state
            }
        })
    }, updateTitle: { text in
        updateState { state in
            var state = state
            state.title = text
            return state
        }
    }, updateArtist: { text in
        updateState { state in
            var state = state
            state.artist = text
            return state
        }
    }, focusArtist: {
        focusArtistImpl?()
    }, done: {
        endEditingImpl?()
        let state = stateValue.with { $0 }
        let title = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = state.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return
        }
        switch mode {
        case let .new(file):
            let coverData = state.pickedCover.flatMap { $0.jpegData(compressionQuality: 0.8) }
            library.addTrack(file: file, title: title, artist: artist, coverData: coverData, completion: completion)
        case let .edit(track):
            var cover = library.edit(of: track)?.cover
            if let image = state.pickedCover, let picked = musicPlaylistCover(context: context, image: image) {
                cover = picked
            }
            library.setEdit(MusicTrackEdit(title: title, artist: artist, cover: cover), for: track)
            completion(true)
        }
        dismissImpl?()
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, statePromise.get())
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        let isNew: Bool
        if case .new = mode {
            isNew = true
        } else {
            isNew = false
        }
        let title = isNew ? musicString(strings, ru: "Новый трек", en: "New Track") : musicString(strings, ru: "Редактировать трек", en: "Edit Track")
        let rightButton = ItemListNavigationButton(content: .icon(.done), style: .bold, enabled: !state.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: {
            arguments.done()
        })
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: strings.Common_Back))

        let cover: MusicTrackCoverItem.Cover
        if let image = state.pickedCover {
            cover = .image(image)
        } else if hasOwnArtwork, let fileReference {
            cover = .file(fileReference)
        } else {
            cover = .none
        }
        let rawEntries: [MusicTrackEditEntry] = [
            .cover(cover),
            .title(text: state.title, placeholder: musicString(strings, ru: "Название трека", en: "Track Title")),
            .artist(text: state.artist, placeholder: musicString(strings, ru: "Исполнитель", en: "Artist"))
        ]
        let entries = rawEntries.map { MusicTrackEditEntryBox(entry: $0, context: context) }
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, focusItemTag: MusicTrackEditEntryTag.title)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    dismissImpl = { [weak controller] in
        let _ = controller?.navigationController?.popViewController(animated: true)
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
    focusArtistImpl = { [weak controller] in
        controller?.forEachItemNode { itemNode in
            if let itemNode = itemNode as? ItemListSingleLineInputItemNode, let tag = itemNode.tag as? MusicTrackEditEntryTag, tag == .artist {
                itemNode.focus()
            }
        }
    }
    controller.willDisappear = { _ in
        endEditingImpl?()
        // The picker lives as long as this screen, as in channel creation.
        let _ = avatarPickerHolder
    }
    return controller
}
