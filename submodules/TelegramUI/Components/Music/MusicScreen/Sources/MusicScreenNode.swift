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
import EdgeEffect
import SearchInputPanelComponent
import MultilineTextComponent

private enum MusicListEntryId: Hashable {
    case tabSwitch
    case tabFooter
    case hubTiles
    case playback
    case addTracks
    case playlistHeaderSpacer
    case playlistInfo
    case playlistActions
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
    case hubTiles(iconPlayTokens: [MusicSection.Row: Int])
    case playback
    case addTracks
    /// The difference between the expanded cover and the round header, as a row: the list's inset stays the round
    /// header's, so folding the cover animates this row's height and the offset the header follows stays continuous.
    case playlistHeaderSpacer(CGFloat)
    case playlistInfo(String)
    case playlistActions(isEmpty: Bool, isFavorite: Bool)
    /// `isSelected` is nil outside of selection, `isPicked` outside of the track picker.
    case track(MusicTrack, isSelected: Bool?, isFavorite: Bool, isPicked: Bool?)
    case artist(MusicArtist)
    case playlist(MusicPlaylist, subtitle: String)
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
        case let .hubTiles(iconPlayTokens):
            return [MusicSection.Row.songs, .artists, .playlists, .favorites].map { "\(iconPlayTokens[$0] ?? 0)" }.joined(separator: " ")
        case .playback, .addTracks:
            return ""
        case let .playlistHeaderSpacer(height):
            return "\(height)"
        case let .playlistInfo(text):
            return text
        case let .playlistActions(isEmpty, isFavorite):
            return "\(isEmpty) \(isFavorite)"
        case let .track(track, isSelected, isFavorite, isPicked):
            return "\(track.isSaved) \(String(describing: isSelected)) \(isFavorite) \(String(describing: isPicked))"
        case let .artist(artist):
            return artist.name
        case let .playlist(playlist, subtitle):
            return "\(playlist.title) \(subtitle) \(playlist.isFavorite) \(String(describing: playlist.cover?.resource.id))"
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
    private let picker: MusicTrackPicker?
    private var pickerDisposable: Disposable?
    private let listNode = ListViewImpl()
    private let indexNode = CollectionIndexNode()
    let navigationBarView = ComponentView<Empty>()

    private var entries: [MusicListEntry] = []
    /// Bumped to replay a hub row's icon animation.
    private var hubIconPlayTokens: [MusicSection.Row: Int] = [:]
    private var currentTracks: [MusicTrack] = []
    private var sorting: MusicSorting
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

    /// A playlist opened from the section draws a profile-like header instead of the list bar (Figma Playlist / Default).
    private var playlistHeaderView: MusicPlaylistHeaderView?
    private let playlistControls = ComponentView<Empty>()
    private let playlistControlsTag = NSObject()
    private let playlistNavigationTitle = ComponentView<Empty>()
    private var playlistEdgeEffectView: EdgeEffectView?
    private var playlistOwnerName: String = ""
    private var playlistOwnerDisposable: Disposable?
    private var playlistCoverResourceId: EngineMediaResource.Id?
    private var playlistCoverImage: UIImage?
    private var playlistCoverDisposable: Disposable?
    private var isPlaylistStatusBarLight = false
    /// A cover opens expanded; scrolling folds it into the round avatar and a pull at the top unfolds it.
    private var isPlaylistCoverExpanded = true
    private let hapticFeedback = HapticFeedback()
    private var isTogglingPlaylistHeader = false
    private var isPlaylistHeaderTogglePending = false
    private var playlistHeaderTransition: ContainedViewLayoutTransition?
    /// Search in the playlist (Figma Playlist / Search): nil while it is closed; the header gives way to the field.
    private var playlistSearchQuery: String?
    private var playlistSearchPanel: ComponentView<Empty>?

    private var playlistHeaderSpacerHeight: CGFloat {
        guard self.isPlaylistHeaderExpanded, let layout = self.validLayout else {
            return 0.0
        }
        let statusBarHeight = layout.statusBarHeight ?? 0.0
        return MusicPlaylistHeaderView.height(width: layout.size.width, statusBarHeight: statusBarHeight, isExpanded: true) - MusicPlaylistHeaderView.height(width: layout.size.width, statusBarHeight: statusBarHeight, isExpanded: false)
    }

    private var isPlaylistHeaderExpanded: Bool {
        return self.playlistCoverImage != nil && self.isPlaylistCoverExpanded
    }

    init(context: AccountContext, controller: MusicScreen, presentationData: PresentationData, library: MusicLibrary) {
        self.context = context
        self.controller = controller
        self.presentationData = presentationData
        self.library = library
        self.section = controller.section
        self.picker = controller.picker
        switch controller.section {
        case .songs, .favorites:
            // Newest first, as on the hub (Figma Songs / Default); a title or artist sort adds the letters.
            self.sorting = MusicSorting(key: .dateAdded, ascending: false)
        case .playlist:
            self.sorting = MusicSorting(key: .playlistOrder, ascending: true)
        case .hub, .artists, .playlists:
            self.sorting = MusicSorting(key: .title, ascending: true)
        }

        super.init()

        self.backgroundColor = self.backgroundColor(theme: presentationData.theme)
        self.addSubnode(self.listNode)
        self.addSubnode(self.indexNode)

        if case .playlist = controller.section, controller.picker == nil {
            let headerView = MusicPlaylistHeaderView()
            // Under the list, which takes the touches: the header only follows its offset.
            self.view.insertSubview(headerView, belowSubview: self.listNode.view)
            self.playlistHeaderView = headerView
            let edgeEffectView = EdgeEffectView()
            edgeEffectView.isUserInteractionEnabled = false
            self.view.addSubview(edgeEffectView)
            self.playlistEdgeEffectView = edgeEffectView
            self.view.addSubview(headerView.overlayView)

            self.playlistOwnerDisposable = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
            |> deliverOnMainQueue).start(next: { [weak self] peer in
                guard let self, let peer else {
                    return
                }
                self.playlistOwnerName = peer.displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)
                self.applyNavigationScroll(transition: .immediate)
            })
            self.updatePlaylistCover()
        }

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
            guard let self else {
                return
            }
            if case .playlist = self.section {
                // The title follows an edit, and a deleted playlist closes its screen.
                if self.currentPlaylist == nil {
                    self.controller?.goBack()
                    return
                }
                self.updatePlaylistCover()
                self.controller?.requestLayout(transition: .immediate)
            }
            // The playlist's header rows depend on its description and cover as well.
            self.updateList(allUpdated: self.isPlaylistScreen)
        })
        if let picker = self.picker {
            self.pickerDisposable = (picker.updated.signal()
            |> deliverOnMainQueue).start(next: { [weak self] _ in
                self?.updateList()
            })
        }
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
        self.playlistOwnerDisposable?.dispose()
        self.playlistCoverDisposable?.dispose()
        self.libraryDisposable?.dispose()
        self.tabShownDisposable?.dispose()
        self.pickerDisposable?.dispose()
    }

    /// The tab can be turned off only where the section stays reachable: the hub opened from Settings.
    private var displaysTabSwitch: Bool {
        return self.section == .hub && self.controller?.mode == .navigation && self.picker == nil
    }

    /// Every Music screen is a plain list on one fill; tracks lie on it under Play and Shuffle (Figma Songs / Default).
    private func backgroundColor(theme: PresentationTheme) -> UIColor {
        return theme.chatList.pinnedItemBackgroundColor
    }

    /// Screens that open with Play and Shuffle under the bar rather than a list row.
    private var startsWithPlayback: Bool {
        switch self.section {
        case .hub, .songs, .favorites, .playlist:
            return true
        case .artists, .playlists:
            return false
        }
    }

    /// Tracks, an artist's tracks and favorites: lists whose menu also selects.
    private var listsTracks: Bool {
        switch self.section {
        case .songs, .favorites:
            return true
        case .hub, .artists, .playlists, .playlist:
            return false
        }
    }

    private var hasAlphabetSections: Bool {
        switch self.section {
        case .hub, .playlists, .playlist:
            return false
        case .artists:
            return self.picker == nil
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
            return .track(
                track,
                isSelected: self.isSelecting ? self.selectedTrackIds.contains(track.message.id) : nil,
                isFavorite: self.library.isFavorite(track),
                isPicked: self.picker.flatMap { $0.contains(track) }
            )
        }
        // Play and Shuffle head every list of tracks, except while picking them; they stay while selecting (Figma Music / List Edit).
        let appendPlaybackPanel: ([MusicTrack]) -> Void = { tracks in
            if self.picker == nil && !tracks.isEmpty {
                contents.append((.playback, .playback, nil))
            }
        }
        switch self.section {
        case .hub:
            if self.displaysTabSwitch {
                contents.append((.tabSwitch, .tabSwitch(isOn: self.isTabShown), nil))
                contents.append((.tabFooter, .tabFooter, nil))
            }
            let tracks = self.library.tracks(source: .all, sorting: MusicSorting(key: .dateAdded, ascending: false))
            self.currentTracks = tracks
            contents.append((.hubTiles, .hubTiles(iconPlayTokens: self.hubIconPlayTokens), nil))
            appendPlaybackPanel(tracks)
            contents += tracks.map { (.track($0.message.id), trackContent($0), nil) }
        case .songs, .favorites:
            self.currentTracks = self.library.tracks(source: self.trackSource, sorting: self.sorting)
            appendPlaybackPanel(self.currentTracks)
            let byArtist = self.sorting.key == .artist
            let hasSections = self.hasAlphabetSections
            contents += self.currentTracks.map { track in
                let letter = hasSections ? musicIndexLetter(byArtist ? track.artist ?? "" : track.title) : nil
                return (.track(track.message.id), trackContent(track), letter)
            }
        case .playlist:
            self.currentTracks = self.library.tracks(source: self.trackSource, sorting: self.sorting)
            if let query = self.playlistSearchQuery?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                if !query.isEmpty {
                    self.currentTracks = self.currentTracks.filter { track in
                        return track.title.lowercased().contains(query) || (track.artist?.lowercased().contains(query) ?? false)
                    }
                }
            } else if self.isPlaylistScreen, let playlist = self.currentPlaylist {
                contents.append((.playlistHeaderSpacer, .playlistHeaderSpacer(self.playlistHeaderSpacerHeight), nil))
                let description = playlist.description.trimmingCharacters(in: .whitespacesAndNewlines)
                if !description.isEmpty {
                    contents.append((.playlistInfo, .playlistInfo(description), nil))
                }
                contents.append((.playlistActions, .playlistActions(isEmpty: self.currentTracks.isEmpty, isFavorite: playlist.isFavorite), nil))
            } else {
                appendPlaybackPanel(self.currentTracks)
            }
            contents += self.currentTracks.map { (.track($0.message.id), trackContent($0), nil) }
        case .artists:
            contents += self.library.artists.map { (.artist($0.name.lowercased()), .artist($0), self.picker == nil ? musicIndexLetter($0.name) : nil) }
        case .playlists:
            let strings = self.presentationData.strings
            contents += self.library.playlists(sorting: self.sorting).map { playlist in
                return (.playlist(playlist.id), .playlist(playlist, subtitle: musicPlaylistSubtitle(strings, playlist: playlist, library: self.library)), nil)
            }
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
        case let .playlist(id):
            return .playlist(id)
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
        if let picker = self.picker {
            picker.toggle(track)
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
    /// Gap between cards on every Music list: hub rows, Play/Shuffle, Add Tracks, tracks.
    static let blockSpacing: CGFloat = 24.0

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
            // Icon-only capsules (Figma "Swipe Actions Symbol Only"); the title stays for VoiceOver.
            return ListMessageItemRevealOption(option: ItemListRevealOption(key: key, title: title, icon: icon, color: colors.fillColor, iconColor: colors.foregroundColor, textColor: theme.list.itemSecondaryTextColor, isDestructive: isDestructive, displaysTitle: false), action: action)
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

    /// Replays the hub icons, all of them or one, the way tab icons animate on selection.
    func playHubIcons() {
        self.playHubIcons(rows: [.songs, .artists, .playlists, .favorites])
    }

    private func playHubIcons(rows: [MusicSection.Row]) {
        guard case .hub = self.section else {
            return
        }
        for row in rows {
            self.hubIconPlayTokens[row, default: 0] += 1
        }
        self.updateList()
    }

    private func open(row: MusicSection.Row) {
        self.playHubIcons(rows: [row])
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

    private func hubTilesItem(iconPlayTokens: [MusicSection.Row: Int]) -> ListViewItem {
        let strings = self.presentationData.strings
        // Rows fill first, as in Figma: Tracks, Artists, then Playlists, Favorites.
        let rows: [(MusicSection.Row, MusicHubTile.Kind, String, String)] = [
            (.songs, .songs, musicString(strings, ru: "Треки", en: "Tracks"), "anim_sound_on"),
            (.artists, .artists, musicString(strings, ru: "Артисты", en: "Artists"), "anim_vcspeak"),
            (.playlists, .playlists, musicString(strings, ru: "Плейлисты", en: "Playlists"), "anim_musicplaylists"),
            (.favorites, .favorites, musicString(strings, ru: "Избранное", en: "Favorites"), "anim_musicfavorites")
        ]
        let tiles = rows.map { MusicHubTile(kind: $0.1, title: $0.2, animation: $0.3, playToken: iconPlayTokens[$0.0] ?? 0) }
        return MusicHubTilesItem(theme: self.presentationData.theme, tiles: tiles, sideInset: 16.0, topInset: self.displaysTabSwitch ? MusicScreenNode.blockSpacing : 16.0, sectionId: 1, action: { [weak self] kind in
            let row: MusicSection.Row
            switch kind {
            case .songs:
                row = .songs
            case .artists:
                row = .artists
            case .playlists:
                row = .playlists
            case .favorites:
                row = .favorites
            }
            self?.open(row: row)
        })
    }

    private func tabSwitchItem(isOn: Bool) -> ListViewItem {
        let strings = self.presentationData.strings
        return MusicGlassSwitchItem(presentationData: ItemListPresentationData(self.presentationData), title: musicString(strings, ru: "Вкладка «Музыка»", en: "Music Tab"), value: isOn, sideInset: 16.0, topInset: 16.0, sectionId: 0, updated: { [weak self] value in
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

    private func trackItem(track: MusicTrack, isSelected: Bool?, isFavorite: Bool, isPicked: Bool?, header: ListViewItemHeader?) -> ListViewItem {
        let presentationData = self.presentationData
        let chatPresentationData = musicChatPresentationData(presentationData)
        let interaction = ListMessageItemInteraction(openMessage: { [weak self] message, _ in
            self?.play(message: message)
            return true
        }, openMessageContextMenu: { [weak self] message, _, node, _, gesture in
            guard let self, !self.isSelecting, self.picker == nil, let track = self.track(message: message) else {
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
        // Every letter of a sorted list is a section of its own: its last row draws no separator above the next letter.
        var sectionId: ItemListSectionId = 2
        if let header = header as? ChatListSearchItemHeader, case let .text(letter, _) = header.type {
            sectionId = 100 + Int32(truncatingIfNeeded: letter.hashValue & 0xffff)
        }
        var selection = ChatHistoryMessageSelection.none
        if let isSelected {
            selection = .selectable(selected: isSelected, num: nil)
        }
        let revealOptions = isSelected == nil && isPicked == nil ? self.revealOptions(track: track) : (left: [], right: [])
        var editControl: ListMessageItemEditControl?
        if let isPicked {
            let theme = presentationData.theme
            if let icon = isPicked ? MusicResources.removeControl(theme: theme) : MusicResources.addControl(theme: theme) {
                editControl = ListMessageItemEditControl(icon: icon, action: { [weak self] in
                    self?.picker?.toggle(track)
                })
            }
        }
        let trailingIcon = isFavorite && isPicked == nil && isSelected == nil ? MusicResources.favoriteMark(theme: presentationData.theme) : nil
        // Play and Shuffle keep the space above the first track; a letter further down follows the previous row directly (Figma Songs / Sort).
        let blockTopInset: CGFloat = 0.0
        return ListMessageItem(presentationData: chatPresentationData, systemStyle: .glass, context: self.context, chatLocation: .peer(id: message.id.peerId), interaction: interaction, message: message, selection: selection, selectionSide: .left, displayHeader: false, customHeader: header, isGlobalSearchResult: !track.isSaved, isSavedMusic: track.isSaved, displayFileInfo: true, audioInfo: .performer, hidesAudioFileExtension: true, additionalSideInset: 0.0, blockTopInset: blockTopInset, displayBackground: false, leftRevealOptions: revealOptions.left, rightRevealOptions: revealOptions.right, trailingIcon: trailingIcon, editControl: editControl, displaysAudioCover: true, style: .plain, sectionId: sectionId)
    }

    private func nameRowItem(id: String, name: String, subtitle: String? = nil, isFavorite: Bool = false, isLarge: Bool = false, cover: TelegramMediaImageRepresentation? = nil, header: ListViewItemHeader?, contextAction: ((ASDisplayNode, ContextGesture?) -> Void)? = nil, action: @escaping () -> Void) -> ListViewItem {
        let presentationData = self.presentationData
        var status: ContactsPeerItemStatus = .none
        if let subtitle {
            status = .custom(string: NSAttributedString(string: subtitle), multiline: false, isActive: false, icon: nil)
        }
        // Neither an artist nor a playlist is a peer: a nameless contact gives the row its letter avatar,
        // and a playlist with a cover is drawn as a placeholder group whose photo is that cover, as in its editor.
        let peer: ContactsPeerItemPeer
        if let cover {
            peer = .peer(peer: EnginePeer(TelegramGroup(id: EnginePeer.Id(namespace: Namespaces.Peer.CloudGroup, id: EnginePeer.Id.Id._internalFromInt64Value(0)), title: name, photo: [cover], participantCount: 0, role: .creator(rank: nil), membership: .Member, flags: [], defaultBannedRights: nil, migrationReference: nil, creationDate: 0, version: 0)), chatPeer: nil)
        } else {
            peer = .deviceContact(stableId: id, contact: DeviceContactBasicData(firstName: name, lastName: "", phoneNumbers: []))
        }
        return ContactsPeerItem(presentationData: ItemListPresentationData(presentationData), systemStyle: .glass, sectionId: 1, sortOrder: presentationData.nameSortOrder, displayOrder: presentationData.nameDisplayOrder, context: self.context, peerMode: .peer, peer: peer, status: status, enabled: true, selection: .none, editing: ContactsPeerItemEditing(editable: false, editing: false, revealed: false), index: nil, header: header, hideBackground: true, action: { _ in
            action()
        }, contextAction: contextAction.flatMap { contextAction in
            return { node, gesture, _ in
                contextAction(node, gesture)
            }
        }, arrowAction: action, arrowIsDisclosure: true, trailingIcon: isFavorite ? MusicResources.favoriteMark(theme: presentationData.theme) : nil, isLarge: isLarge)
    }

    private func playbackItem() -> ListViewItem {
        let strings = self.presentationData.strings
        return MusicPlaybackButtonsItem(theme: self.presentationData.theme, playTitle: musicString(strings, ru: "Слушать", en: "Play"), shuffleTitle: musicString(strings, ru: "Перемешать", en: "Shuffle"), sideInset: 16.0, topInset: self.section == .hub ? MusicScreenNode.blockSpacing : 16.0, bottomInset: self.section == .hub ? MusicScreenNode.blockSpacing : 16.0, sectionId: 3, action: { [weak self] shuffled in
            self?.playAll(shuffled: shuffled)
        })
    }

    private func addTracksItem() -> ListViewItem {
        let strings = self.presentationData.strings
        return ItemListDisclosureItem(presentationData: ItemListPresentationData(self.presentationData), systemStyle: .glass, icon: PresentationResourcesItemList.plusIconImage(self.presentationData.theme), title: musicString(strings, ru: "Добавить треки", en: "Add Tracks"), titleColor: .accent, label: "", sectionId: 4, style: .blocks, disclosureStyle: .none, additionalSideInset: 16.0, blockTopInset: MusicScreenNode.blockSpacing, action: { [weak self] in
            guard let self, let playlist = self.currentPlaylist else {
                return
            }
            self.controller?.addTracks(to: playlist, library: self.library)
        })
    }

    /// The playlist's own screen, as opposed to the list the track picker pushes.
    private var isPlaylistScreen: Bool {
        if case .playlist = self.section, self.picker == nil {
            return true
        }
        return false
    }

    private func playlistActionsItem(isEmpty: Bool, isFavorite: Bool) -> ListViewItem {
        let strings = self.presentationData.strings
        let hasDescription = !(self.currentPlaylist?.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        // The round header already ends 16 pt under the name; under the cover and the description the buttons keep 16 pt of their own.
        let topInset: CGFloat = !hasDescription && !self.isPlaylistHeaderExpanded ? 8.0 : 16.0
        return MusicPlaylistActionsItem(theme: self.presentationData.theme, isEmpty: isEmpty, isFavorite: isFavorite, playTitle: musicString(strings, ru: "Слушать", en: "Play"), addTracksTitle: musicString(strings, ru: "Добавить треки", en: "Add Tracks"), topInset: topInset, bottomInset: 16.0, sectionId: 3, action: { [weak self] action in
            guard let self, let playlist = self.currentPlaylist else {
                return
            }
            switch action {
            case .play:
                self.playAll(shuffled: false)
            case .shuffle:
                self.playAll(shuffled: true)
            case .favorite:
                self.controller?.setFavorite(playlist: playlist, isFavorite: !playlist.isFavorite, library: self.library)
            case .search:
                self.setPlaylistSearchActive(true)
            case .addTracks:
                self.controller?.addTracks(to: playlist, library: self.library)
            }
        })
    }

    /// The cover is a local file in the media box: read once per picked cover.
    private func updatePlaylistCover() {
        guard self.isPlaylistScreen else {
            return
        }
        let resourceId = self.currentPlaylist?.cover.flatMap { EngineMediaResource.Id($0.resource.id) }
        if resourceId == self.playlistCoverResourceId {
            return
        }
        self.playlistCoverResourceId = resourceId
        self.isPlaylistCoverExpanded = true
        self.playlistCoverDisposable?.dispose()
        self.playlistCoverDisposable = nil
        guard let resourceId else {
            self.playlistCoverImage = nil
            self.updateList(allUpdated: true)
            return
        }
        self.playlistCoverDisposable = (self.context.engine.resources.data(id: resourceId, attemptSynchronously: true)
        |> filter { $0.isComplete }
        |> take(1)
        |> map { data -> UIImage? in
            return UIImage(contentsOfFile: data.path)
        }
        |> deliverOnMainQueue).start(next: { [weak self] image in
            guard let self else {
                return
            }
            self.playlistCoverImage = image
            if let layout = self.validLayout {
                self.containerLayoutUpdated(layout, transition: .immediate)
            }
            self.updateList(allUpdated: true)
        })
    }

    private var currentPlaylist: MusicPlaylist? {
        if case let .playlist(id) = self.section {
            return self.library.playlist(id: id)
        }
        return nil
    }

    /// The list's tracks in its order, or in a random one.
    private func playAll(shuffled: Bool) {
        var tracks = self.currentTracks
        if shuffled {
            tracks.shuffle()
        }
        guard let first = tracks.first else {
            return
        }
        self.controller?.play(track: first, tracks: tracks, library: self.library)
    }

    private func presentContextMenu(playlist: MusicPlaylist, node: ASDisplayNode, gesture: ContextGesture?) {
        guard let controller = self.controller, let sourceNode = node.subnodes?.first(where: { $0 is ContextExtractedContentContainingNode }) as? ContextExtractedContentContainingNode else {
            return
        }
        let strings = self.presentationData.strings
        let library = self.library
        let action: (String, String, Bool, @escaping () -> Void) -> ContextMenuItem = { title, iconName, isDestructive, action in
            return .action(ContextMenuActionItem(text: title, textColor: isDestructive ? .destructive : .primary, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: iconName), color: isDestructive ? theme.contextMenu.destructiveColor : theme.contextMenu.primaryColor)
            }, action: { _, f in
                f(.default)
                action()
            }))
        }
        let items: [ContextMenuItem] = [
            .custom(MusicTrackActionsContextItem(actions: [
                MusicTrackActionsContextItem.Action(
                    title: playlist.isInProfile ? musicString(strings, ru: "Из профиля", en: "Unpin") : musicString(strings, ru: "В профиль", en: "To Profile"),
                    iconName: "Peer Info/SaveMusic",
                    action: { [weak controller] in
                        controller?.setInProfile(playlist: playlist, isInProfile: !playlist.isInProfile, library: library)
                    }
                ),
                MusicTrackActionsContextItem.Action(
                    title: playlist.isFavorite ? musicString(strings, ru: "Убрать", en: "Unfavorite") : musicString(strings, ru: "Избранное", en: "Favorite"),
                    iconName: playlist.isFavorite ? "Music/StarSlash" : "Music/Star",
                    action: { [weak controller] in
                        controller?.setFavorite(playlist: playlist, isFavorite: !playlist.isFavorite, library: library)
                    }
                ),
                MusicTrackActionsContextItem.Action(
                    title: musicString(strings, ru: "Поделиться", en: "Share"),
                    iconName: "Music/ShareFilled",
                    action: { [weak controller] in
                        controller?.share(playlist: playlist, library: library)
                    }
                )
            ]), false),
            .separator,
            action(musicString(strings, ru: "Редактировать", en: "Edit"), "Chat/Context Menu/Edit", false, { [weak controller] in
                controller?.editPlaylist(playlist, library: library)
            }),
            .separator,
            action(musicString(strings, ru: "Добавить в плейлист", en: "Add to Playlist"), "Chat/Context Menu/AddCaption", false, { [weak controller] in
                controller?.addToPlaylist(tracks: library.tracks(of: playlist), excluding: playlist.id, library: library)
            }),
            action(musicString(strings, ru: "Воспроизвести далее", en: "Play Next"), "Chat/Context Menu/MoveUp", false, { [weak controller] in
                controller?.enqueue(playlist: playlist, next: true, library: library)
            }),
            action(musicString(strings, ru: "Добавить в очередь", en: "Add to Queue"), "Chat/Context Menu/MoveDown", false, { [weak controller] in
                controller?.enqueue(playlist: playlist, next: false, library: library)
            }),
            .separator,
            action(musicString(strings, ru: "Воспроизвести", en: "Play"), "Chat/Context Menu/Play", false, { [weak controller] in
                controller?.play(playlist: playlist, shuffled: false, library: library)
            }),
            action(musicString(strings, ru: "Перемешать", en: "Shuffle"), "Music/Shuffle", false, { [weak controller] in
                controller?.play(playlist: playlist, shuffled: true, library: library)
            }),
            .separator,
            action(musicString(strings, ru: "Удалить из музыки", en: "Remove from Music"), "Chat/Context Menu/Delete", true, { [weak controller] in
                controller?.confirmRemoval(playlist: playlist, library: library)
            })
        ]
        let contextController = makeContextController(presentationData: self.presentationData, source: .extracted(MusicTrackContextExtractedContentSource(contentNode: sourceNode)), items: .single(ContextController.Items(content: .list(items))), recognizer: nil, gesture: gesture)
        controller.presentInGlobalOverlay(contextController)
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
        case let .hubTiles(iconPlayTokens):
            return self.hubTilesItem(iconPlayTokens: iconPlayTokens)
        case .playback:
            return self.playbackItem()
        case .addTracks:
            return self.addTracksItem()
        case let .playlistHeaderSpacer(height):
            return MusicPlaylistSpacerItem(height: height)
        case let .playlistInfo(text):
            return MusicPlaylistInfoItem(presentationData: ItemListPresentationData(self.presentationData), label: musicString(self.presentationData.strings, ru: "описание", en: "description"), text: text, sectionId: 4)
        case let .playlistActions(isEmpty, isFavorite):
            return self.playlistActionsItem(isEmpty: isEmpty, isFavorite: isFavorite)
        case let .track(track, isSelected, isFavorite, isPicked):
            return self.trackItem(track: track, isSelected: isSelected, isFavorite: isFavorite, isPicked: isPicked, header: header)
        case let .artist(artist):
            return self.nameRowItem(id: artist.name, name: artist.name, header: header, action: { [weak self] in
                guard let self else {
                    return
                }
                self.controller?.open(section: .songs(artist: artist.name), library: self.library)
            })
        case let .playlist(playlist, subtitle):
            let contextAction: ((ASDisplayNode, ContextGesture?) -> Void)? = self.picker == nil ? { [weak self] node, gesture in
                guard let self, let playlist = self.library.playlist(id: playlist.id) else {
                    return
                }
                self.presentContextMenu(playlist: playlist, node: node, gesture: gesture)
            } : nil
            return self.nameRowItem(id: "\(playlist.id)", name: playlist.title, subtitle: subtitle, isFavorite: playlist.isFavorite, isLarge: true, cover: playlist.cover, header: nil, contextAction: contextAction, action: { [weak self] in
                guard let self else {
                    return
                }
                self.controller?.open(section: .playlist(playlist.id), library: self.library)
            })
        }
    }

    private func updateList(allUpdated: Bool = false, scrollToTop: Bool = false, animated: Bool = false) {
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
            options: animated ? [.Synchronous, .LowLatency, .AnimateInsertion] : [.Synchronous, .LowLatency],
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
        case .playlistOrder:
            return musicString(strings, ru: "Порядок плейлиста", en: "Playlist Order")
        }
    }

    private func sortOrderTitle() -> String {
        let strings = self.presentationData.strings
        switch self.sorting.key {
        case .title, .artist:
            return self.sorting.ascending ? musicString(strings, ru: "А—Я", en: "A—Z") : musicString(strings, ru: "Я—А", en: "Z—A")
        case .playlistOrder:
            return self.sorting.ascending ? musicString(strings, ru: "Как добавлены", en: "As Added") : musicString(strings, ru: "В обратном порядке", en: "Reversed")
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


    /// The playlist's "•••" menu (Figma Playlist / Menu): its profile place, editing and sorting, the queue, removal.
    private func presentPlaylistMenu(sourceView: UIView) {
        guard let controller = self.controller, let playlist = self.currentPlaylist else {
            return
        }
        let strings = self.presentationData.strings
        let library = self.library
        let action: (String, String, Bool, @escaping () -> Void) -> ContextMenuItem = { title, iconName, isDestructive, action in
            return .action(ContextMenuActionItem(text: title, textColor: isDestructive ? .destructive : .primary, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: iconName), color: isDestructive ? theme.contextMenu.destructiveColor : theme.contextMenu.primaryColor)
            }, action: { _, f in
                f(.default)
                action()
            }))
        }
        let hasTracks = !library.tracks(of: playlist).isEmpty
        var items: [ContextMenuItem] = [
            playlist.isInProfile ? action(musicString(strings, ru: "Убрать из профиля", en: "Remove from Profile"), "Chat/Context Menu/Remove", false, { [weak controller] in
                controller?.setInProfile(playlist: playlist, isInProfile: false, library: library)
            }) : action(musicString(strings, ru: "Добавить в профиль", en: "Add to Profile"), "Chat/Context Menu/AddUser", false, { [weak controller] in
                controller?.setInProfile(playlist: playlist, isInProfile: true, library: library)
            }),
            .separator,
            action(musicString(strings, ru: "Редактировать", en: "Edit"), "Chat/Context Menu/Edit", false, { [weak controller] in
                controller?.editPlaylist(playlist, library: library)
            })
        ]
        if hasTracks {
            // Sorting opens as a submenu, the way the client's menus step into a second level.
            items.append(.action(ContextMenuActionItem(text: musicString(strings, ru: "Сортировка", en: "Sort"), icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Music/Sort"), color: theme.contextMenu.primaryColor)
            }, additionalLeftIcon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Arrow"), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] menu, _ in
                guard let self else {
                    return
                }
                menu?.pushItems(items: .single(ContextController.Items(content: .list(self.playlistSortItems()))))
            })))
            items.append(.separator)
            items.append(action(musicString(strings, ru: "Добавить в плейлист", en: "Add to Playlist"), "Chat/Context Menu/AddCaption", false, { [weak controller] in
                controller?.addToPlaylist(tracks: library.tracks(of: playlist), excluding: playlist.id, library: library)
            }))
            items.append(action(musicString(strings, ru: "Воспроизвести далее", en: "Play Next"), "Chat/Context Menu/MoveUp", false, { [weak controller] in
                controller?.enqueue(playlist: playlist, next: true, library: library)
            }))
            items.append(action(musicString(strings, ru: "Добавить в очередь", en: "Add to Queue"), "Chat/Context Menu/MoveDown", false, { [weak controller] in
                controller?.enqueue(playlist: playlist, next: false, library: library)
            }))
        }
        items.append(.separator)
        items.append(action(musicString(strings, ru: "Удалить из музыки", en: "Remove from Music"), "Chat/Context Menu/Delete", true, { [weak controller] in
            controller?.confirmRemoval(playlist: playlist, library: library)
        }))
        let contextController = makeContextController(presentationData: self.presentationData, source: .reference(MusicContextReferenceContentSource(sourceView: sourceView)), items: .single(ContextController.Items(content: .list(items))), gesture: nil)
        controller.presentInGlobalOverlay(contextController)
    }

    /// The sort keys of a playlist: its own order first.
    private func playlistSortItems() -> [ContextMenuItem] {
        let strings = self.presentationData.strings
        let emptyIcon = generateImage(CGSize(width: 24.0, height: 24.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
        })
        var items: [ContextMenuItem] = [
            .action(ContextMenuActionItem(text: strings.Common_Back, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.contextMenu.primaryColor)
            }, iconPosition: .left, action: { menu, _ in
                menu?.popItems()
            })),
            .separator
        ]
        items += [MusicSorting.Key.playlistOrder, .title, .artist, .dateAdded].map { key -> ContextMenuItem in
            let isSelected = key == self.sorting.key
            return .action(ContextMenuActionItem(text: self.sortTitle(key: key), textLayout: isSelected ? .secondLineWithValue(self.sortOrderTitle()) : .twoLinesMax, icon: { theme in
                return isSelected ? generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Check"), color: theme.contextMenu.primaryColor) : emptyIcon
            }, iconPosition: .left, action: { [weak self] _, f in
                f(.default)
                guard let self else {
                    return
                }
                self.sorting = self.sorting.selecting(key)
                self.updateList()
            }))
        }
        return items
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
        case .playlist:
            title = self.currentPlaylist?.title ?? musicString(strings, ru: "Плейлист", en: "Playlist")
            rightButtons = [
                NavigationBarComponent.Button(id: "editPlaylist", content: .text(title: musicString(strings, ru: "Изм.", en: "Edit"), isBold: false), action: { [weak self] _ in
                    guard let self, let playlist = self.currentPlaylist else {
                        return
                    }
                    self.controller?.editPlaylist(playlist, library: self.library)
                })
            ]
        }

        var leftButton: NavigationBarComponent.Button?
        var backPressed: (() -> Void)?
        if self.picker != nil {
            // The sheet's lists keep their titles; each of them confirms the whole choice.
            rightButtons = [
                NavigationBarComponent.Button(id: "pickerDone", content: .text(title: "___done", isBold: true), tint: .accent, action: { [weak self] _ in
                    self?.controller?.finishPicking()
                })
            ]
            backPressed = { [weak self] in
                self?.controller?.goBack()
            }
        } else if self.isSelecting {
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
        case .playlist:
            return musicString(strings, ru: "Поиск в плейлисте", en: "Search Playlist")
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
        if self.isPlaylistScreen {
            self.playlistContainerLayoutUpdated(layout, isFirstLayout: isFirstLayout, transition: transition)
            return
        }
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
        if (self.startsWithPlayback && self.picker == nil) || self.section == .hub {
            // The first block's own top inset is for a list under a plain bar.
            insets.top -= 16.0
            if !self.displaysTabSwitch {
                // The first block keeps 16 pt from the player or the search field (Figma Music / Default, Songs / Default):
                // the bar ends 3 pt below the player, and the search field reaches 3 pt past the bar's end.
                insets.top += self.controller?.globalControlPanelsContextState?.mediaPlayback != nil ? 13.0 : 3.0
            }
        }
        insets.left = layout.safeInsets.left
        insets.right = layout.safeInsets.right
        if self.hasAlphabetSections && self.section == .artists {
            // Keeps the artists clear of the index; track rows run under it, as in Figma Songs / Sort.
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

    /// The bottom of the playlist's buttons' row: 10 pt under the status bar, as the list bar places its buttons.
    private func playlistNavigationHeight(layout: ContainerViewLayout) -> CGFloat {
        return (layout.statusBarHeight ?? 0.0) + 10.0 + 44.0
    }

    private func playlistContainerLayoutUpdated(_ layout: ContainerViewLayout, isFirstLayout: Bool, transition: ContainedViewLayoutTransition, applyScroll: Bool = true) {
        var insets = layout.insets(options: [.input])
        if self.playlistSearchQuery != nil {
            // The list starts 12 pt under the search field (Figma Playlist / Search).
            insets.top = (layout.statusBarHeight ?? 0.0) + MusicScreenNode.playlistSearchPanelHeight + 2.0
        } else {
            insets.top = MusicPlaylistHeaderView.height(width: layout.size.width, statusBarHeight: layout.statusBarHeight ?? 0.0, isExpanded: false)
        }
        insets.left = layout.safeInsets.left
        insets.right = layout.safeInsets.right
        if self.isSelecting && self.controller?.mode == .navigation {
            insets.bottom = self.selectionPanelBottomInset(layout: layout) + MusicScreenNode.selectionPanelHeight + 8.0
        }
        transition.updateFrame(node: self.listNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: layout.size, insets: insets, duration: duration, curve: curve), updateOpaqueState: nil)
        if isFirstLayout {
            self.updateList()
        }
        self.updateSelectionPanel(layout: layout, transition: transition)
        if applyScroll {
            self.applyNavigationScroll(transition: ComponentTransition(transition))
        }
    }

    /// Lays the playlist's header out at the list's offset, and its bar over it: the name moves into the bar once it passes under it.
    private func applyPlaylistScroll(layout: ContainerViewLayout, transition: ComponentTransition) {
        guard let headerView = self.playlistHeaderView, let playlist = self.currentPlaylist else {
            return
        }
        let theme = self.presentationData.theme
        var offset: CGFloat = 0.0
        if case let .known(value) = self.listNode.visibleContentOffset() {
            offset = value
        }
        let navigationHeight = self.playlistNavigationHeight(layout: layout)
        let hasCover = self.playlistCoverImage != nil

        let isSearching = self.playlistSearchQuery != nil
        self.updatePlaylistSearchPanel(layout: layout, transition: transition)

        // The profile's rule (`PeerInfoScreen`): any scroll up folds the cover into the avatar, a pull of 32 pt at the top
        // unfolds it; both with a 0.35 s spring, the list's inset with them.
        var headerTransition: ContainedViewLayoutTransition = .immediate
        if hasCover && !isSearching {
            var shouldBeExpanded: Bool?
            if offset <= -32.0 && self.listNode.isTracking {
                shouldBeExpanded = true
            } else if offset >= 1.0 {
                shouldBeExpanded = false
            }
            if let shouldBeExpanded, shouldBeExpanded != self.isPlaylistCoverExpanded, !self.isPlaylistHeaderTogglePending {
                // This runs inside the list's own update: its inset changes on the next turn of the run loop.
                self.isPlaylistHeaderTogglePending = true
                DispatchQueue.main.async { [weak self] in
                    self?.togglePlaylistHeader(isExpanded: shouldBeExpanded)
                }
            }
        }
        if let forcedTransition = self.playlistHeaderTransition {
            self.playlistHeaderTransition = nil
            headerTransition = forcedTransition
        }

        let isExpanded = self.isPlaylistHeaderExpanded
        let headerHeight = MusicPlaylistHeaderView.height(width: layout.size.width, statusBarHeight: layout.statusBarHeight ?? 0.0, isExpanded: isExpanded)
        headerView.frame = CGRect(origin: CGPoint(), size: CGSize(width: layout.size.width, height: layout.size.height))
        headerView.update(theme: theme, title: playlist.title, subtitle: self.playlistOwnerName, cover: self.playlistCoverImage, isExpanded: isExpanded, size: layout.size, statusBarHeight: layout.statusBarHeight ?? 0.0, hasDynamicIsland: layout.deviceMetrics.hasDynamicIsland, offset: offset, transition: headerTransition)

        // The bar's fade comes in as soon as content passes under it, never over the expanded cover.
        let edgeAlpha: CGFloat
        if isExpanded {
            edgeAlpha = max(0.0, min(1.0, (offset - (headerHeight - navigationHeight - 24.0)) / 24.0))
        } else {
            edgeAlpha = max(0.0, min(1.0, offset / 24.0))
        }
        // The header's own name rises into the bar; a name too long for it leaves the bar its own truncated title.
        let titleAlpha: CGFloat
        if isExpanded || headerView.titleRisesIntoBar {
            titleAlpha = 0.0
        } else {
            titleAlpha = max(0.0, min(1.0, (offset - MusicPlaylistHeaderView.avatarSize - 9.0) / 24.0))
        }
        if let edgeEffectView = self.playlistEdgeEffectView {
            let edgeEffectFrame = CGRect(origin: CGPoint(), size: CGSize(width: layout.size.width, height: navigationHeight + 14.0))
            edgeEffectView.frame = edgeEffectFrame
            edgeEffectView.update(content: self.backgroundColor(theme: theme), blur: true, alpha: 0.85, rect: edgeEffectFrame, edge: .top, edgeSize: min(54.0, edgeEffectFrame.height), transition: .immediate)
            edgeEffectView.alpha = edgeAlpha
        }

        let sideInset: CGFloat = 16.0
        let controlsSize = CGSize(width: layout.size.width - layout.safeInsets.left - layout.safeInsets.right - sideInset * 2.0, height: 44.0)
        let _ = self.playlistControls.update(
            transition: transition,
            component: AnyComponent(GlassControlPanelComponent(
                theme: theme,
                leftItem: GlassControlPanelComponent.Item(
                    items: [GlassControlGroupComponent.Item(id: AnyHashable("back"), content: .icon("Navigation/Back"), action: { [weak self] in
                        self?.controller?.goBack()
                    })],
                    background: .panel
                ),
                centralItem: nil,
                rightItem: GlassControlPanelComponent.Item(
                    items: [
                        GlassControlGroupComponent.Item(id: AnyHashable("share"), content: .icon("Navigation/Share"), action: { [weak self] in
                            guard let self, let playlist = self.currentPlaylist else {
                                return
                            }
                            self.controller?.share(playlist: playlist, library: self.library)
                        }),
                        GlassControlGroupComponent.Item(id: AnyHashable("more"), content: .animation("anim_morewide"), action: { [weak self] in
                            guard let self, let controlsView = self.playlistControls.view as? GlassControlPanelComponent.View, let sourceView = controlsView.rightItemView?.itemView(id: AnyHashable("more")) else {
                                return
                            }
                            self.presentPlaylistMenu(sourceView: sourceView)
                        })
                    ],
                    background: .panel
                ),
                tag: self.playlistControlsTag
            )),
            environment: {},
            containerSize: controlsSize
        )
        if let controlsView = self.playlistControls.view {
            if controlsView.superview == nil {
                self.view.addSubview(controlsView)
            }
            controlsView.frame = CGRect(origin: CGPoint(x: layout.safeInsets.left + sideInset, y: navigationHeight - 44.0), size: controlsSize)
            controlsView.isUserInteractionEnabled = !isSearching
            transition.setAlpha(view: controlsView, alpha: isSearching ? 0.0 : 1.0)
        }
        // While searching the header and its name give way to the field and the results.
        transition.setAlpha(view: headerView, alpha: isSearching ? 0.0 : 1.0)
        transition.setAlpha(view: headerView.overlayView, alpha: isSearching ? 0.0 : 1.0)

        // Between the back button and the share and more pair.
        let titleSize = self.playlistNavigationTitle.update(
            transition: .immediate,
            component: AnyComponent(MultilineTextComponent(text: .plain(NSAttributedString(string: playlist.title, font: Font.semibold(17.0), textColor: theme.rootController.navigationBar.primaryTextColor)), truncationType: .end, maximumNumberOfLines: 1)),
            environment: {},
            containerSize: CGSize(width: layout.size.width - 2.0 * (sideInset + 104.0 + 8.0), height: 44.0)
        )
        if let titleView = self.playlistNavigationTitle.view {
            if titleView.superview == nil {
                titleView.isUserInteractionEnabled = false
                if let controlsView = self.playlistControls.view {
                    self.view.insertSubview(titleView, belowSubview: controlsView)
                } else {
                    self.view.addSubview(titleView)
                }
            }
            titleView.frame = CGRect(origin: CGPoint(x: floor((layout.size.width - titleSize.width) * 0.5), y: navigationHeight - 44.0 + floor((44.0 - titleSize.height) * 0.5)), size: titleSize)
            titleView.alpha = isSearching ? 0.0 : titleAlpha
        }

        // White over the cover, as on an expanded profile photo.
        let isStatusBarLight = isExpanded && !isSearching && edgeAlpha < 0.5
        if isStatusBarLight != self.isPlaylistStatusBarLight {
            self.isPlaylistStatusBarLight = isStatusBarLight
            self.controller?.updateStatusBar(overCover: isStatusBarLight)
        }
    }

    /// The client's glass search field with its close button, at the bar's place.
    private static let playlistSearchPanelHeight: CGFloat = 10.0 + 48.0 + 10.0

    private func setPlaylistSearchActive(_ isActive: Bool) {
        guard (self.playlistSearchQuery != nil) != isActive, let layout = self.validLayout else {
            return
        }
        self.playlistSearchQuery = isActive ? "" : nil
        self.updateList(allUpdated: true, scrollToTop: true)
        self.containerLayoutUpdated(layout, transition: .animated(duration: 0.3, curve: .easeInOut))
        if isActive, let panelView = self.playlistSearchPanel?.view as? SearchInputPanelComponent.View {
            panelView.activateInput()
        }
    }

    private func updatePlaylistSearchPanel(layout: ContainerViewLayout, transition: ComponentTransition) {
        if self.playlistSearchQuery != nil {
            let panel: ComponentView<Empty>
            var panelTransition = transition
            if let current = self.playlistSearchPanel {
                panel = current
            } else {
                panel = ComponentView()
                self.playlistSearchPanel = panel
                panelTransition = .immediate
            }
            let strings = self.presentationData.strings
            // The panel keeps 11 pt to the edges; the bar's buttons keep 16.
            let panelSize = panel.update(
                transition: panelTransition,
                component: AnyComponent(SearchInputPanelComponent(
                    theme: self.presentationData.theme,
                    strings: strings,
                    metrics: layout.metrics,
                    safeInsets: UIEdgeInsets(top: 0.0, left: layout.safeInsets.left + 5.0, bottom: 0.0, right: layout.safeInsets.right + 5.0),
                    placeholder: musicString(strings, ru: "Поиск треков", en: "Search Tracks"),
                    hasEdgeEffect: false,
                    updated: { [weak self] query in
                        guard let self, self.playlistSearchQuery != nil, self.playlistSearchQuery != query else {
                            return
                        }
                        self.playlistSearchQuery = query
                        self.updateList(scrollToTop: true)
                    },
                    cancel: { [weak self] in
                        self?.setPlaylistSearchActive(false)
                    }
                )),
                environment: {},
                containerSize: CGSize(width: layout.size.width, height: MusicScreenNode.playlistSearchPanelHeight)
            )
            if let panelView = panel.view {
                if panelView.superview == nil {
                    self.view.addSubview(panelView)
                    panelView.alpha = 0.0
                }
                panelView.frame = CGRect(origin: CGPoint(x: 0.0, y: layout.statusBarHeight ?? 0.0), size: panelSize)
                transition.setAlpha(view: panelView, alpha: 1.0)
            }
        } else if let panel = self.playlistSearchPanel {
            self.playlistSearchPanel = nil
            if let panelView = panel.view {
                transition.setAlpha(view: panelView, alpha: 0.0, completion: { [weak panelView] _ in
                    panelView?.removeFromSuperview()
                })
            }
        }
    }

    /// Folds or unfolds the cover with the list's inset, as the profile's photo collapses into its avatar.
    private func togglePlaylistHeader(isExpanded: Bool) {
        self.isPlaylistHeaderTogglePending = false
        guard let layout = self.validLayout, self.isPlaylistCoverExpanded != isExpanded else {
            return
        }
        self.isPlaylistCoverExpanded = isExpanded
        if isExpanded {
            self.hapticFeedback.impact()
        } else {
            self.hapticFeedback.tap()
        }
        let _ = layout
        // The rows move with the spacer's height in the list's own animation; the header morphs over the same time.
        self.isTogglingPlaylistHeader = true
        self.updateList(allUpdated: true, animated: true)
        self.isTogglingPlaylistHeader = false
        self.playlistHeaderTransition = .animated(duration: 0.35, curve: .spring)
        self.applyNavigationScroll(transition: .immediate)
    }

    private func applyNavigationScroll(transition: ComponentTransition) {
        if self.isPlaylistScreen {
            if let layout = self.validLayout, !self.isTogglingPlaylistHeader {
                self.applyPlaylistScroll(layout: layout, transition: transition)
            }
            return
        }
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
        if self.isPlaylistScreen {
            return
        }
        let searchHeight = ChatListNavigationBar.searchScrollHeight
        guard case let .known(offset) = self.listNode.visibleContentOffset(), offset > 0.0 && offset < searchHeight else {
            return
        }
        let _ = self.listNode.scrollToOffsetFromTop(offset < searchHeight * 0.5 ? 0.0 : searchHeight, animated: true)
    }
}
