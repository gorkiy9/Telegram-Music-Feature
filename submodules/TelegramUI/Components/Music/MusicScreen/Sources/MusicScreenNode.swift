import Foundation
import UIKit
import AsyncDisplayKit
import Display
import ComponentFlow
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import MergeLists
import ItemListUI
import ListMessageItem
import ContactsPeerItem
import ChatListSearchItemHeader
import ContextUI
import ChatListHeaderComponent
import NavigationBarComponent
import HeaderPanelContainerComponent
import MediaPlaybackHeaderPanelComponent
import GlassControls

private enum MusicListEntryId: Hashable {
    case tabSwitch
    case tabFooter
    case hubRow(MusicSection.Row)
    case track(EngineMessage.Id)
    case artist(String)
    case playlist(Int)
}

private extension MusicSection {
    enum Row: Hashable {
        case songs
        case artists
        case playlists
        case favorites
    }
}

private enum MusicListEntryContent {
    case tabSwitch(isOn: Bool)
    case tabFooter
    case hubRow(MusicSection.Row, count: Int)
    /// `isSelected` is nil outside of selection.
    case track(MusicTrack, isSelected: Bool?)
    case artist(MusicArtist)
    case playlist(MusicPlaylist)
}

private struct MusicListEntry: Comparable, Identifiable {
    let index: Int
    let stableId: MusicListEntryId
    let content: MusicListEntryContent
    /// The alphabet section the row belongs to, when the list has them.
    let letter: String?

    /// Changes when the row must be redrawn.
    private var revision: String {
        switch self.content {
        case let .tabSwitch(isOn):
            return "\(isOn)"
        case .tabFooter:
            return ""
        case let .hubRow(_, count):
            return "\(count)"
        case let .track(track, isSelected):
            return "\(track.isSaved) \(String(describing: isSelected))"
        case let .artist(artist):
            return artist.name
        case let .playlist(playlist):
            return playlist.title
        }
    }

    static func ==(lhs: MusicListEntry, rhs: MusicListEntry) -> Bool {
        return lhs.index == rhs.index && lhs.stableId == rhs.stableId && lhs.letter == rhs.letter && lhs.revision == rhs.revision
    }

    static func <(lhs: MusicListEntry, rhs: MusicListEntry) -> Bool {
        return lhs.index < rhs.index
    }
}

/// Diacritics are folded because the sorted lists keep such letters together, and a section must be contiguous.
private func musicIndexLetter(_ name: String) -> String {
    guard let first = name.folding(options: .diacriticInsensitive, locale: nil).first?.uppercased().unicodeScalars.first else {
        return "#"
    }
    switch first.value {
    case 0x41 ... 0x5A, 0x400 ... 0x42F:
        return String(first)
    default:
        return "#"
    }
}

private final class MusicTrackContextExtractedContentSource: ContextExtractedContentSource {
    let keepInPlace: Bool = false
    let ignoreContentTouches: Bool = false
    let blurBackground: Bool = true

    private let contentNode: ContextExtractedContentContainingNode

    init(contentNode: ContextExtractedContentContainingNode) {
        self.contentNode = contentNode
    }

    func takeView() -> ContextControllerTakeViewInfo? {
        return ContextControllerTakeViewInfo(containingItem: .node(self.contentNode), contentAreaInScreenSpace: mainWindowScreenBounds)
    }

    func putBack() -> ContextControllerPutBackViewInfo? {
        return ContextControllerPutBackViewInfo(contentAreaInScreenSpace: mainWindowScreenBounds)
    }
}

private final class MusicContextReferenceContentSource: ContextReferenceContentSource {
    private let sourceView: UIView

    init(sourceView: UIView) {
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView, contentAreaInScreenSpace: mainWindowScreenBounds)
    }
}

/// One node for the hub and the three lists: their header, rows and sorting depend on `section`.
final class MusicScreenNode: ASDisplayNode {
    private let context: AccountContext
    private weak var controller: MusicScreen?
    private var presentationData: PresentationData

    private let library: MusicLibrary
    private let section: MusicSection
    private let listNode = ListViewImpl()
    private let indexNode = CollectionIndexNode()
    let navigationBarView = ComponentView<Empty>()

    private var entries: [MusicListEntry] = []
    private var currentTracks: [MusicTrack] = []
    private var sorting = MusicSorting(key: .title, ascending: true)
    private var navigationScrollOffset: CGFloat = 0.0
    private var validLayout: ContainerViewLayout?
    private var libraryDisposable: Disposable?

    /// Selection of tracks to remove: Edit on the tab, the check button from Settings, Select Tracks in a list's menu.
    private(set) var isSelecting = false
    private var selectedTrackIds = Set<EngineMessage.Id>()
    /// Bottom actions while selecting on a pushed screen; on the tab the tab bar shows them as the controller's toolbar.
    private var selectionPanel: ComponentView<Empty>?

    private var isTabShown = true
    private var tabShownDisposable: Disposable?

    init(context: AccountContext, controller: MusicScreen, presentationData: PresentationData, library: MusicLibrary) {
        self.context = context
        self.controller = controller
        self.presentationData = presentationData
        self.library = library
        self.section = controller.section

        super.init()

        self.backgroundColor = self.backgroundColor(theme: presentationData.theme)
        self.addSubnode(self.listNode)
        self.addSubnode(self.indexNode)

        self.listNode.visibleContentOffsetChanged = { [weak self] _, _ in
            self?.applyNavigationScroll(transition: .immediate)
        }
        self.listNode.didEndScrolling = { [weak self] _ in
            self?.snapNavigationScroll()
        }
        self.indexNode.indexSelected = { [weak self] letter in
            self?.scrollToSection(letter: letter)
        }
        self.libraryDisposable = (library.updated.signal()
        |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.updateList()
        })
        if self.displaysTabSwitch {
            self.tabShownDisposable = (musicTabIsShown(context: context)
            |> deliverOnMainQueue).start(next: { [weak self] isShown in
                guard let self else {
                    return
                }
                self.isTabShown = isShown
                self.updateList()
            })
        }
    }

    deinit {
        self.libraryDisposable?.dispose()
        self.tabShownDisposable?.dispose()
    }

    /// The tab can be turned off only where the section stays reachable: the hub opened from Settings.
    private var displaysTabSwitch: Bool {
        return self.section == .hub && self.controller?.mode == .navigation
    }

    private func backgroundColor(theme: PresentationTheme) -> UIColor {
        return self.section == .hub ? theme.list.blocksBackgroundColor : theme.chatList.pinnedItemBackgroundColor
    }

    /// Tracks, an artist's tracks and favorites: lists whose menu also selects.
    private var listsTracks: Bool {
        switch self.section {
        case .songs, .favorites:
            return true
        case .hub, .artists, .playlists:
            return false
        }
    }

    private var hasAlphabetSections: Bool {
        switch self.section {
        case .hub, .playlists:
            return false
        case .artists:
            return true
        case .songs, .favorites:
            return self.sorting.key == .title || self.sorting.key == .artist
        }
    }

    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        self.backgroundColor = self.backgroundColor(theme: presentationData.theme)
        self.updateList(allUpdated: true)
    }

    func scrollToTop() {
        let _ = self.listNode.scrollToOffsetFromTop(0.0, animated: true)
    }

    func revealSearch() {
        self.navigationScrollOffset = 0.0
        self.updateList(scrollToTop: true)
        self.applyNavigationScroll(transition: .immediate)
    }

    func refresh() {
        self.library.refreshChatMusic()
    }

    private func makeEntries() -> [MusicListEntry] {
        var contents: [(MusicListEntryId, MusicListEntryContent, String?)] = []
        self.currentTracks = []
        let trackContent: (MusicTrack) -> MusicListEntryContent = { track in
            return .track(track, isSelected: self.isSelecting ? self.selectedTrackIds.contains(track.message.id) : nil)
        }
        switch self.section {
        case .hub:
            if self.displaysTabSwitch {
                contents.append((.tabSwitch, .tabSwitch(isOn: self.isTabShown), nil))
                contents.append((.tabFooter, .tabFooter, nil))
            }
            let tracks = self.library.tracks(source: .all, sorting: MusicSorting(key: .dateAdded, ascending: false))
            self.currentTracks = tracks
            contents.append((.hubRow(.songs), .hubRow(.songs, count: tracks.count), nil))
            contents.append((.hubRow(.artists), .hubRow(.artists, count: self.library.artists.count), nil))
            contents.append((.hubRow(.playlists), .hubRow(.playlists, count: self.library.playlists.count), nil))
            contents.append((.hubRow(.favorites), .hubRow(.favorites, count: self.library.favoriteCount), nil))
            contents += tracks.map { (.track($0.message.id), trackContent($0), nil) }
        case .songs, .favorites:
            self.currentTracks = self.library.tracks(source: self.trackSource, sorting: self.sorting)
            let byArtist = self.sorting.key == .artist
            let hasSections = self.hasAlphabetSections
            contents += self.currentTracks.map { track in
                let letter = hasSections ? musicIndexLetter(byArtist ? track.artist ?? "" : track.title) : nil
                return (.track(track.message.id), trackContent(track), letter)
            }
        case .artists:
            contents += self.library.artists.map { (.artist($0.name.lowercased()), .artist($0), musicIndexLetter($0.name)) }
        case .playlists:
            contents += self.library.playlists.map { (.playlist($0.id), .playlist($0), nil) }
        }
        // Tracks that left the list leave the selection too.
        let trackIds = Set(self.currentTracks.map(\.message.id))
        self.selectedTrackIds.formIntersection(trackIds)
        return contents.enumerated().map { MusicListEntry(index: $0.offset, stableId: $0.element.0, content: $0.element.1, letter: $0.element.2) }
    }

    private var trackSource: MusicTrackSource {
        switch self.section {
        case let .songs(artist):
            return artist.flatMap { .artist($0) } ?? .all
        case .favorites:
            return .favorites
        case .hub, .artists, .playlists:
            return .all
        }
    }

    private func track(message: EngineRawMessage) -> MusicTrack? {
        return self.currentTracks.first(where: { $0.message.id == message.id })
    }

    private func play(message: EngineRawMessage) {
        guard let track = self.track(message: message) else {
            return
        }
        if self.isSelecting {
            self.toggleSelection(track: track)
            return
        }
        self.controller?.play(track: track, tracks: self.currentTracks, library: self.library)
    }

    // MARK: Selection

    func setSelecting(_ isSelecting: Bool) {
        guard self.isSelecting != isSelecting else {
            return
        }
        self.isSelecting = isSelecting
        self.selectedTrackIds.removeAll()
        self.updateList()
        self.updateSelectionToolbar()
        self.controller?.requestLayout(transition: .animated(duration: 0.4, curve: .spring))
    }

    private func toggleSelection(track: MusicTrack) {
        self.setSelected(track: track, !self.selectedTrackIds.contains(track.message.id))
    }

    private func setSelected(track: MusicTrack, _ isSelected: Bool) {
        guard self.selectedTrackIds.contains(track.message.id) != isSelected else {
            return
        }
        if isSelected {
            self.selectedTrackIds.insert(track.message.id)
        } else {
            self.selectedTrackIds.remove(track.message.id)
        }
        self.updateList()
        self.updateSelectionToolbar()
    }

    private var allTracksSelected: Bool {
        return !self.currentTracks.isEmpty && self.selectedTrackIds.count == self.currentTracks.count
    }

    func toggleSelectAll() {
        if self.allTracksSelected {
            self.selectedTrackIds.removeAll()
        } else {
            self.selectedTrackIds = Set(self.currentTracks.map(\.message.id))
        }
        self.updateList()
        self.updateSelectionToolbar()
    }

    func deleteSelectedTracks() {
        let tracks = self.currentTracks.filter { self.selectedTrackIds.contains($0.message.id) }
        guard !tracks.isEmpty else {
            return
        }
        self.controller?.confirmRemoval(tracks: tracks, library: self.library, completion: { [weak self] in
            self?.setSelecting(false)
        })
    }

    private var selectAllTitle: String {
        let strings = self.presentationData.strings
        return self.allTracksSelected ? musicString(strings, ru: "Снять выбор", en: "Deselect All") : musicString(strings, ru: "Выбрать все", en: "Select All")
    }

    /// On the tab the tab bar draws the toolbar in its own place; a pushed screen draws the same panel itself.
    private func updateSelectionToolbar() {
        guard let controller = self.controller else {
            return
        }
        if controller.mode == .tab {
            let toolbar = self.isSelecting ? Toolbar(
                leftAction: ToolbarAction(title: self.selectAllTitle, isEnabled: !self.currentTracks.isEmpty),
                rightAction: ToolbarAction(title: self.presentationData.strings.Common_Delete, isEnabled: !self.selectedTrackIds.isEmpty),
                middleAction: nil
            ) : nil
            controller.setToolbar(toolbar, transition: .animated(duration: 0.4, curve: .spring))
        } else if let layout = self.validLayout {
            self.updateSelectionPanel(layout: layout, transition: .animated(duration: 0.4, curve: .spring))
        }
    }

    private static let selectionPanelHeight: CGFloat = 44.0

    private func selectionPanelBottomInset(layout: ContainerViewLayout) -> CGFloat {
        return max(layout.insets(options: []).bottom, 8.0)
    }

    private func updateSelectionPanel(layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        guard self.controller?.mode == .navigation else {
            return
        }
        if self.isSelecting {
            let panel: ComponentView<Empty>
            var panelTransition = ComponentTransition(transition)
            if let current = self.selectionPanel {
                panel = current
            } else {
                panel = ComponentView()
                self.selectionPanel = panel
                panelTransition = .immediate
            }
            let sideInset: CGFloat = 20.0
            let panelSize = CGSize(width: layout.size.width - sideInset * 2.0, height: MusicScreenNode.selectionPanelHeight)
            let selectAllTitle = self.selectAllTitle
            let deleteTitle = self.presentationData.strings.Common_Delete
            let _ = panel.update(
                transition: panelTransition,
                component: AnyComponent(GlassControlPanelComponent(
                    theme: self.presentationData.theme,
                    leftItem: GlassControlPanelComponent.Item(
                        items: [GlassControlGroupComponent.Item(id: "left_" + selectAllTitle, content: .text(selectAllTitle), action: self.currentTracks.isEmpty ? nil : { [weak self] in
                            self?.toggleSelectAll()
                        })],
                        background: .panel
                    ),
                    centralItem: nil,
                    rightItem: GlassControlPanelComponent.Item(
                        items: [GlassControlGroupComponent.Item(id: "right_" + deleteTitle, content: .text(deleteTitle), action: self.selectedTrackIds.isEmpty ? nil : { [weak self] in
                            self?.deleteSelectedTracks()
                        })],
                        background: .panel
                    ),
                    centerAlignmentIfPossible: true
                )),
                environment: {},
                containerSize: panelSize
            )
            if let panelView = panel.view {
                let panelFrame = CGRect(origin: CGPoint(x: sideInset, y: layout.size.height - self.selectionPanelBottomInset(layout: layout) - panelSize.height), size: panelSize)
                if panelView.superview == nil {
                    self.view.addSubview(panelView)
                    panelView.alpha = 0.0
                }
                panelTransition.setFrame(view: panelView, frame: panelFrame)
                ComponentTransition(transition).setAlpha(view: panelView, alpha: 1.0)
            }
        } else if let panel = self.selectionPanel {
            self.selectionPanel = nil
            if let panelView = panel.view {
                ComponentTransition(transition).setAlpha(view: panelView, alpha: 0.0, completion: { [weak panelView] _ in
                    panelView?.removeFromSuperview()
                })
            }
        }
    }

    // MARK: Track actions

    private func revealOptions(track: MusicTrack) -> (left: [ListMessageItemRevealOption], right: [ListMessageItemRevealOption]) {
        let theme = self.presentationData.theme
        let strings = self.presentationData.strings
        let actions = theme.list.itemDisclosureActions
        let option: (Int32, String, String, PresentationThemeFillForeground, Bool, @escaping () -> Void) -> ListMessageItemRevealOption = { key, title, iconName, colors, isDestructive, action in
            var icon = ItemListRevealOptionIcon.none
            if let image = generateTintedImage(image: UIImage(bundleImageName: iconName), color: colors.foregroundColor) {
                icon = .image(image: image)
            }
            return ListMessageItemRevealOption(option: ItemListRevealOption(key: key, title: title, icon: icon, color: colors.fillColor, iconColor: colors.foregroundColor, textColor: theme.list.itemSecondaryTextColor, isDestructive: isDestructive), action: action)
        }
        let left = [
            option(0, musicString(strings, ru: "Далее", en: "Play Next"), "Chat/Context Menu/MoveUp", actions.neutral1, false, { [weak self] in
                self?.enqueue(track: track, next: true)
            }),
            option(1, musicString(strings, ru: "В плейлист", en: "Add to Playlist"), "Chat/Context Menu/AddCaption", actions.warning, false, { [weak self] in
                self?.addToPlaylist(track: track)
            })
        ]
        let right = [
            option(2, strings.Common_Edit, "Chat/Context Menu/Edit", actions.accent, false, {
                // Track editing is not designed yet.
            }),
            option(3, strings.Common_Delete, "Chat/Context Menu/Delete", actions.destructive, true, { [weak self] in
                guard let self else {
                    return
                }
                self.library.remove(tracks: [track])
            })
        ]
        return (left, right)
    }

    private func enqueue(track: MusicTrack, next: Bool) {
        self.controller?.enqueue(track: track, next: next, library: self.library)
    }

    private func addToPlaylist(track: MusicTrack) {
        self.controller?.addToPlaylist(track: track, library: self.library)
    }

    private func presentContextMenu(track: MusicTrack, node: ASDisplayNode, gesture: UIGestureRecognizer?) {
        guard let controller = self.controller, let sourceNode = node as? ContextExtractedContentContainingNode else {
            return
        }
        let strings = self.presentationData.strings
        let library = self.library
        let action: (String, ContextMenuActionItemTextLayout, String, Bool, @escaping () -> Void) -> ContextMenuItem = { title, textLayout, iconName, isDestructive, action in
            return .action(ContextMenuActionItem(text: title, textColor: isDestructive ? .destructive : .primary, textLayout: textLayout, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: iconName), color: isDestructive ? theme.contextMenu.destructiveColor : theme.contextMenu.primaryColor)
            }, action: { _, f in
                f(.default)
                action()
            }))
        }

        let isFavorite = library.isFavorite(track)
        var items: [ContextMenuItem] = [
            .custom(MusicTrackActionsContextItem(actions: [
                MusicTrackActionsContextItem.Action(
                    title: track.isSaved ? musicString(strings, ru: "Из профиля", en: "Unpin") : musicString(strings, ru: "В профиль", en: "To Profile"),
                    iconName: "Peer Info/SaveMusic",
                    action: { [weak self] in
                        self?.controller?.setSavedToProfile(track: track, isSaved: !track.isSaved, library: library)
                    }
                ),
                MusicTrackActionsContextItem.Action(
                    // The title stays: the longer "remove" wording does not fit a third of the menu.
                    title: musicString(strings, ru: "Избранное", en: "Favorite"),
                    iconName: isFavorite ? "Music/StarSlash" : "Music/Star",
                    action: {
                        library.setFavorite(track, !isFavorite)
                    }
                ),
                MusicTrackActionsContextItem.Action(
                    title: musicString(strings, ru: "Поделиться", en: "Share"),
                    iconName: "Music/ShareFilled",
                    action: { [weak self] in
                        self?.controller?.share(track: track)
                    }
                )
            ]), false),
            .separator,
            action(musicString(strings, ru: "Редактировать", en: "Edit"), .singleLine, "Chat/Context Menu/Edit", false, {
                // Track editing is not designed yet.
            }),
            .separator,
            action(musicString(strings, ru: "Добавить в плейлист", en: "Add to Playlist"), .singleLine, "Chat/Context Menu/AddCaption", false, { [weak self] in
                self?.addToPlaylist(track: track)
            }),
            action(musicString(strings, ru: "Воспроизвести далее", en: "Play Next"), .singleLine, "Chat/Context Menu/MoveUp", false, { [weak self] in
                self?.enqueue(track: track, next: true)
            }),
            action(musicString(strings, ru: "Добавить в очередь", en: "Add to Queue"), .singleLine, "Chat/Context Menu/MoveDown", false, { [weak self] in
                self?.enqueue(track: track, next: false)
            })
        ]
        var isArtistList = false
        if case .songs(.some) = self.section {
            isArtistList = true
        }
        if let artist = track.artist, !isArtistList {
            items.append(.separator)
            items.append(action(musicString(strings, ru: "Перейти к артисту", en: "Go to Artist"), .secondLineWithValue(artist), "Music/Microphone", false, { [weak self] in
                guard let self else {
                    return
                }
                self.controller?.open(section: .songs(artist: artist), library: self.library)
            }))
        }
        items.append(.separator)
        items.append(action(musicString(strings, ru: "Удалить из музыки", en: "Remove from Music"), .singleLine, "Chat/Context Menu/Delete", true, {
            library.remove(tracks: [track])
        }))

        let contextController = makeContextController(presentationData: self.presentationData, source: .extracted(MusicTrackContextExtractedContentSource(contentNode: sourceNode)), items: .single(ContextController.Items(content: .list(items))), recognizer: nil, gesture: gesture as? ContextGesture)
        controller.presentInGlobalOverlay(contextController)
    }

    private func open(row: MusicSection.Row) {
        switch row {
        case .songs:
            self.controller?.open(section: .songs(artist: nil), library: self.library)
        case .artists:
            self.controller?.open(section: .artists, library: self.library)
        case .playlists:
            self.controller?.open(section: .playlists, library: self.library)
        case .favorites:
            self.controller?.open(section: .favorites, library: self.library)
        }
    }

    private func hubRowItem(row: MusicSection.Row, count: Int) -> ListViewItem {
        let strings = self.presentationData.strings
        let title: String
        let icon: UIImage?
        switch row {
        case .songs:
            title = musicString(strings, ru: "Треки", en: "Tracks")
            icon = PresentationResourcesSettings.musicSongs
        case .artists:
            title = musicString(strings, ru: "Артисты", en: "Artists")
            icon = PresentationResourcesSettings.musicArtists
        case .playlists:
            title = musicString(strings, ru: "Плейлисты", en: "Playlists")
            icon = PresentationResourcesSettings.musicPlaylists
        case .favorites:
            title = musicString(strings, ru: "Избранное", en: "Favorites")
            icon = PresentationResourcesSettings.musicFavorites
        }
        return ItemListDisclosureItem(presentationData: ItemListPresentationData(self.presentationData), systemStyle: .glass, icon: icon, title: title, label: "\(count)", sectionId: 1, style: .blocks, additionalSideInset: 16.0, action: { [weak self] in
            self?.open(row: row)
        })
    }

    private func tabSwitchItem(isOn: Bool) -> ListViewItem {
        let strings = self.presentationData.strings
        return ItemListSwitchItem(presentationData: ItemListPresentationData(self.presentationData), systemStyle: .glass, title: musicString(strings, ru: "Вкладка «Музыка»", en: "Music Tab"), value: isOn, additionalSideInset: 16.0, sectionId: 0, style: .blocks, updated: { [weak self] value in
            guard let self else {
                return
            }
            self.isTabShown = value
            setMusicTabIsShown(context: self.context, value)
        })
    }

    private func tabFooterItem() -> ListViewItem {
        let strings = self.presentationData.strings
        return ItemListTextItem(presentationData: ItemListPresentationData(self.presentationData), text: .plain(musicString(strings, ru: "Для перехода к музыке из главного меню.", en: "To open your music from the main menu.")), sectionId: 0, style: .blocks, additionalInsets: UIEdgeInsets(top: 0.0, left: 16.0, bottom: 0.0, right: 16.0))
    }

    private func trackItem(track: MusicTrack, isSelected: Bool?, header: ListViewItemHeader?) -> ListViewItem {
        let presentationData = self.presentationData
        let chatPresentationData = ChatPresentationData(theme: ChatPresentationThemeData(theme: presentationData.theme, wallpaper: .color(0)), fontSize: presentationData.listsFontSize, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat, nameDisplayOrder: presentationData.nameDisplayOrder, disableAnimations: false, largeEmoji: false, chatBubbleCorners: presentationData.chatBubbleCorners)
        let interaction = ListMessageItemInteraction(openMessage: { [weak self] message, _ in
            self?.play(message: message)
            return true
        }, openMessageContextMenu: { [weak self] message, _, node, _, gesture in
            guard let self, !self.isSelecting, let track = self.track(message: message) else {
                return
            }
            self.presentContextMenu(track: track, node: node, gesture: gesture)
        }, toggleMediaPlayback: { [weak self] message in
            self?.play(message: message)
        }, toggleMessagesSelection: { [weak self] ids, isSelected in
            // A row can report one tap twice; the value it asks for makes the second report a no-op.
            guard let self, let id = ids.first, let track = self.currentTracks.first(where: { $0.message.id == id }) else {
                return
            }
            self.setSelected(track: track, isSelected)
        }, openUrl: { _, _, _, _ in
        }, openInstantPage: { _, _ in
        }, longTap: { _, _ in
        }, getHiddenMedia: {
            return [:]
        })
        let message = track.message
        let isHub = self.section == .hub
        var selection = ChatHistoryMessageSelection.none
        if let isSelected {
            selection = .selectable(selected: isSelected, num: nil)
        }
        let revealOptions = isSelected == nil ? self.revealOptions(track: track) : (left: [], right: [])
        return ListMessageItem(presentationData: chatPresentationData, systemStyle: .glass, context: self.context, chatLocation: .peer(id: message.id.peerId), interaction: interaction, message: message, selection: selection, selectionSide: .left, displayHeader: false, customHeader: header, isGlobalSearchResult: !track.isSaved, isSavedMusic: track.isSaved, displayFileInfo: true, audioInfo: .performer, hidesAudioFileExtension: true, additionalSideInset: isHub ? 16.0 : 0.0, blockTopInset: isHub ? 24.0 : 0.0, displayBackground: isHub, leftRevealOptions: revealOptions.left, rightRevealOptions: revealOptions.right, style: isHub ? .blocks : .plain, sectionId: 2)
    }

    private func nameRowItem(id: String, name: String, header: ListViewItemHeader?, action: @escaping () -> Void) -> ListViewItem {
        let presentationData = self.presentationData
        // Neither an artist nor a playlist is a peer: a nameless contact gives the row its letter avatar.
        return ContactsPeerItem(presentationData: ItemListPresentationData(presentationData), systemStyle: .glass, sectionId: 1, sortOrder: presentationData.nameSortOrder, displayOrder: presentationData.nameDisplayOrder, context: self.context, peerMode: .peer, peer: .deviceContact(stableId: id, contact: DeviceContactBasicData(firstName: name, lastName: "", phoneNumbers: [])), status: .none, enabled: true, selection: .none, editing: ContactsPeerItemEditing(editable: false, editing: false, revealed: false), index: nil, header: header, hideBackground: true, action: { _ in
            action()
        }, arrowAction: action, arrowIsDisclosure: true)
    }

    private func item(entry: MusicListEntry) -> ListViewItem {
        var header: ListViewItemHeader?
        if let letter = entry.letter {
            header = ChatListSearchItemHeader(type: .text(letter, AnyHashable(letter)), theme: self.presentationData.theme, strings: self.presentationData.strings)
        }
        switch entry.content {
        case let .tabSwitch(isOn):
            return self.tabSwitchItem(isOn: isOn)
        case .tabFooter:
            return self.tabFooterItem()
        case let .hubRow(row, count):
            return self.hubRowItem(row: row, count: count)
        case let .track(track, isSelected):
            return self.trackItem(track: track, isSelected: isSelected, header: header)
        case let .artist(artist):
            return self.nameRowItem(id: artist.name, name: artist.name, header: header, action: { [weak self] in
                guard let self else {
                    return
                }
                self.controller?.open(section: .songs(artist: artist.name), library: self.library)
            })
        case let .playlist(playlist):
            return self.nameRowItem(id: "\(playlist.id)", name: playlist.title, header: nil, action: {
            })
        }
    }

    private func updateList(allUpdated: Bool = false, scrollToTop: Bool = false) {
        guard self.validLayout != nil else {
            return
        }
        let entries = self.makeEntries()
        let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: self.entries, rightList: entries, allUpdated: allUpdated)
        self.entries = entries

        var scrollToItem: ListViewScrollToItem?
        if scrollToTop && !entries.isEmpty {
            scrollToItem = ListViewScrollToItem(index: 0, position: .top(-self.navigationScrollOffset), animated: false, curve: .Default(duration: nil), directionHint: .Up)
        }
        self.listNode.transaction(
            deleteIndices: deleteIndices.map { ListViewDeleteItem(index: $0, directionHint: nil) },
            insertIndicesAndItems: indicesAndItems.map { ListViewInsertItem(index: $0.0, previousIndex: $0.2, item: self.item(entry: $0.1), directionHint: nil) },
            updateIndicesAndItems: updateIndices.map { ListViewUpdateItem(index: $0.0, previousIndex: $0.2, item: self.item(entry: $0.1), directionHint: nil) },
            options: [.Synchronous, .LowLatency],
            scrollToItem: scrollToItem,
            updateOpaqueState: nil
        )
        self.updateIndex(transition: .immediate)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.indexNode.isUserInteractionEnabled && self.indexNode.frame.contains(point) {
            return self.indexNode.view
        }
        return super.hitTest(point, with: event)
    }

    private func updateIndex(transition: ContainedViewLayoutTransition) {
        guard let layout = self.validLayout, let navigationBarHeight = self.navigationBarView.view?.bounds.height else {
            return
        }
        var sections: [String] = []
        for entry in self.entries {
            if let letter = entry.letter, !sections.contains(letter) {
                sections.append(letter)
            }
        }
        let insets = layout.insets(options: [.input])
        let frame = CGRect(x: layout.size.width - layout.safeInsets.right - 20.0, y: navigationBarHeight, width: 20.0, height: layout.size.height - navigationBarHeight - insets.bottom)
        transition.updateFrame(node: self.indexNode, frame: frame)
        self.indexNode.update(size: frame.size, color: self.presentationData.theme.list.itemAccentColor, sections: sections, transition: transition)
        self.indexNode.isUserInteractionEnabled = !sections.isEmpty
    }

    private func scrollToSection(letter: String) {
        guard let index = self.entries.firstIndex(where: { $0.letter == letter }) else {
            return
        }
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: ListViewScrollToItem(index: index, position: .top(0.0), animated: false, curve: .Default(duration: nil), directionHint: .Down), updateOpaqueState: nil)
    }

    private func sortTitle(key: MusicSorting.Key) -> String {
        let strings = self.presentationData.strings
        switch key {
        case .title:
            return musicString(strings, ru: "Название", en: "Title")
        case .dateAdded:
            return musicString(strings, ru: "Дата добавления", en: "Date Added")
        case .artist:
            return musicString(strings, ru: "Артист", en: "Artist")
        case .lastPlayed:
            return musicString(strings, ru: "Последнее воспроизведение", en: "Last Played")
        case .dateUpdated:
            return musicString(strings, ru: "Дата обновления", en: "Date Updated")
        }
    }

    private func sortOrderTitle() -> String {
        let strings = self.presentationData.strings
        switch self.sorting.key {
        case .title, .artist:
            return self.sorting.ascending ? musicString(strings, ru: "А—Я", en: "A—Z") : musicString(strings, ru: "Я—А", en: "Z—A")
        case .dateAdded, .lastPlayed, .dateUpdated:
            return self.sorting.ascending ? musicString(strings, ru: "Сначала старые", en: "Oldest First") : musicString(strings, ru: "Сначала новые", en: "Newest First")
        }
    }

    private func presentSortMenu(sourceView: UIView) {
        guard let controller = self.controller else {
            return
        }
        let keys: [MusicSorting.Key]
        if case .playlists = self.section {
            keys = [.title, .dateAdded, .lastPlayed, .dateUpdated]
        } else {
            keys = [.title, .dateAdded, .artist]
        }
        let emptyIcon = generateImage(CGSize(width: 24.0, height: 24.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
        })
        var items: [ContextMenuItem] = []
        if self.listsTracks {
            let strings = self.presentationData.strings
            items.append(.action(ContextMenuActionItem(text: musicString(strings, ru: "Выбрать треки", en: "Select Tracks"), icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Select"), color: theme.contextMenu.primaryColor)
            }, iconPosition: .left, action: { [weak self] _, f in
                f(.default)
                self?.setSelecting(true)
            })))
            items.append(.separator)
        }
        items += keys.map { key -> ContextMenuItem in
            let isSelected = key == self.sorting.key
            return .action(ContextMenuActionItem(text: self.sortTitle(key: key), textLayout: isSelected ? .secondLineWithValue(self.sortOrderTitle()) : .twoLinesMax, icon: { theme in
                return isSelected ? generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Check"), color: theme.contextMenu.primaryColor) : emptyIcon
            }, iconPosition: .left, action: { [weak self] _, f in
                f(.default)
                guard let self else {
                    return
                }
                self.sorting = self.sorting.selecting(key)
                self.updateList(scrollToTop: true)
                self.controller?.requestLayout(transition: .immediate)
            }))
        }
        let contextController = makeContextController(presentationData: self.presentationData, source: .reference(MusicContextReferenceContentSource(sourceView: sourceView)), items: .single(ContextController.Items(content: .list(items))), gesture: nil)
        controller.presentInGlobalOverlay(contextController)
    }

    private func headerContent() -> ChatListHeaderComponent.Content {
        let strings = self.presentationData.strings

        let addButton = NavigationBarComponent.Button(
            id: "add",
            content: .icon(imageName: "Chat List/AddIcon"),
            tint: .accent,
            action: { [weak self] _ in
                guard let self else {
                    return
                }
                self.controller?.addTrack(library: self.library)
            }
        )
        let sortButton = NavigationBarComponent.Button(
            id: "sort",
            content: self.listsTracks ? .more : .icon(imageName: "Peer Info/SortIcon"),
            action: { [weak self] sourceView in
                self?.presentSortMenu(sourceView: sourceView)
            }
        )
        let selectButton = NavigationBarComponent.Button(
            id: "select",
            content: .icon(imageName: "Music/Select"),
            action: { [weak self] _ in
                self?.setSelecting(true)
            }
        )

        let title: String
        var rightButtons: [NavigationBarComponent.Button]
        switch self.section {
        case .hub:
            title = musicSectionTitle(strings: strings)
            rightButtons = self.controller?.mode == .tab ? [addButton] : [addButton, selectButton]
        case let .songs(artist):
            title = artist ?? musicString(strings, ru: "Треки", en: "Tracks")
            rightButtons = [addButton, sortButton]
        case .favorites:
            title = musicString(strings, ru: "Избранное", en: "Favorites")
            rightButtons = [sortButton]
        case .artists:
            title = musicString(strings, ru: "Артисты", en: "Artists")
            rightButtons = []
        case .playlists:
            title = musicString(strings, ru: "Плейлисты", en: "Playlists")
            rightButtons = [
                sortButton,
                NavigationBarComponent.Button(id: "create", content: .icon(imageName: "Chat List/AddIcon"), action: { [weak self] _ in
                    guard let self else {
                        return
                    }
                    self.controller?.createPlaylist(library: self.library, completion: nil)
                })
            ]
        }

        var leftButton: NavigationBarComponent.Button?
        var backPressed: (() -> Void)?
        if self.isSelecting {
            rightButtons = []
            leftButton = NavigationBarComponent.Button(
                id: "done",
                content: .text(title: strings.Common_Done, isBold: true),
                action: { [weak self] _ in
                    self?.setSelecting(false)
                }
            )
        } else if self.controller?.mode == .tab {
            leftButton = NavigationBarComponent.Button(
                id: "edit",
                content: .text(title: strings.Common_Edit, isBold: false),
                action: { [weak self] _ in
                    self?.setSelecting(true)
                }
            )
        } else {
            backPressed = { [weak self] in
                self?.controller?.goBack()
            }
        }

        return ChatListHeaderComponent.Content(
            title: title,
            titleComponent: nil,
            chatListTitle: nil,
            leftButton: leftButton,
            rightButtons: rightButtons,
            backPressed: backPressed
        )
    }

    private func searchPlaceholder() -> String? {
        let strings = self.presentationData.strings
        switch self.section {
        case .hub:
            return nil
        case .songs:
            return musicString(strings, ru: "Поиск треков", en: "Search Tracks")
        case .favorites:
            return musicString(strings, ru: "Поиск в избранном", en: "Search Favorites")
        case .artists:
            return musicString(strings, ru: "Поиск артистов", en: "Search Artists")
        case .playlists:
            return musicString(strings, ru: "Поиск плейлистов", en: "Search Playlists")
        }
    }

    private func headerPanels() -> AnyComponent<Empty> {
        var panels: [HeaderPanelContainerComponent.Panel] = []
        if let mediaPlayback = self.controller?.globalControlPanelsContextState?.mediaPlayback {
            panels.append(HeaderPanelContainerComponent.Panel(
                key: "media",
                orderIndex: 0,
                component: AnyComponent(MediaPlaybackHeaderPanelComponent(
                    context: self.context,
                    theme: self.presentationData.theme,
                    strings: self.presentationData.strings,
                    data: mediaPlayback,
                    controller: { [weak self] in
                        return self?.controller
                    }
                ))
            ))
        }

        return AnyComponent(HeaderPanelContainerComponent(
            theme: self.presentationData.theme,
            tabs: nil,
            panels: panels
        ))
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        let isFirstLayout = self.validLayout == nil
        self.validLayout = layout

        let componentTransition = ComponentTransition(transition)
        let navigationBarSize = self.navigationBarView.update(
            transition: componentTransition,
            component: AnyComponent(ChatListNavigationBar(
                context: self.context,
                theme: self.presentationData.theme,
                strings: self.presentationData.strings,
                statusBarHeight: layout.navigationBarStatusBarHeight ?? 0.0,
                leftInset: layout.safeInsets.left,
                rightInset: layout.safeInsets.right,
                trailingButtonsInset: layout.navigationBarTrailingButtonsInset,
                search: ChatListNavigationBar.Search(isEnabled: true, placeholder: self.searchPlaceholder()),
                activeSearch: nil,
                primaryContent: self.headerContent(),
                secondaryContent: nil,
                secondaryTransition: 0.0,
                storySubscriptions: EngineStorySubscriptions(accountItem: nil, items: [], hasMoreToken: nil),
                storiesIncludeHidden: false,
                uploadProgress: [:],
                headerPanels: self.headerPanels(),
                tabsNode: nil,
                tabsNodeIsSearch: false,
                accessoryPanelContainer: nil,
                accessoryPanelContainerHeight: 0.0,
                activateSearch: { _ in
                },
                openStatusSetup: { _ in
                },
                allowAutomaticOrder: {
                }
            )),
            environment: {},
            containerSize: layout.size
        )
        if let navigationBarComponentView = self.navigationBarView.view as? ChatListNavigationBar.View {
            if navigationBarComponentView.superview == nil {
                self.view.addSubview(navigationBarComponentView)
            }
            componentTransition.setFrame(view: navigationBarComponentView, frame: CGRect(origin: CGPoint(), size: navigationBarSize))
        }

        var insets = layout.insets(options: [.input])
        insets.top = navigationBarSize.height
        if self.section == .hub {
            // The card's own top inset is for a list under a plain bar.
            insets.top -= 16.0
        }
        insets.left = layout.safeInsets.left
        insets.right = layout.safeInsets.right
        if self.hasAlphabetSections {
            // Keeps the rows clear of the index.
            insets.right += 16.0
        }
        if self.isSelecting && self.controller?.mode == .navigation {
            insets.bottom = self.selectionPanelBottomInset(layout: layout) + MusicScreenNode.selectionPanelHeight + 8.0
        }
        transition.updateFrame(node: self.listNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: layout.size, insets: insets, duration: duration, curve: curve), updateOpaqueState: nil)
        if isFirstLayout {
            self.updateList()
        }
        self.updateIndex(transition: transition)
        self.updateSelectionPanel(layout: layout, transition: transition)

        self.applyNavigationScroll(transition: componentTransition)
    }

    private func applyNavigationScroll(transition: ComponentTransition) {
        guard let navigationBarComponentView = self.navigationBarView.view as? ChatListNavigationBar.View else {
            return
        }
        // An empty list reports no offset, so the header stays as it was.
        if case let .known(value) = self.listNode.visibleContentOffset() {
            self.navigationScrollOffset = max(0.0, min(value, ChatListNavigationBar.searchScrollHeight))
        }
        navigationBarComponentView.applyScroll(offset: self.navigationScrollOffset, allowAvatarsExpansion: false, forceUpdate: true, transition: transition)
    }

    private func snapNavigationScroll() {
        let searchHeight = ChatListNavigationBar.searchScrollHeight
        guard case let .known(offset) = self.listNode.visibleContentOffset(), offset > 0.0 && offset < searchHeight else {
            return
        }
        let _ = self.listNode.scrollToOffsetFromTop(offset < searchHeight * 0.5 ? 0.0 : searchHeight, animated: true)
    }
}
