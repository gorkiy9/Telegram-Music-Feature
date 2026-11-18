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
import UniversalMediaPlayer
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
import SearchBarNode
import ChatListSearchFiltersContainerNode
import MultilineTextComponent
import HorizontalTabsComponent
import PeerMessagesMediaPlaylist
import EmptyStateIndicatorComponent

private enum MusicListEntryId: Hashable {
    case tabSwitch
    case tabFooter
    case hubTiles
    case playback
    case addTracks
    case playlistHeaderSpacer
    case playlistInfo
    case playlistActions
    case favoritePlaylistsTile
    case newPlaylist
    case emptyInfo
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
    case favoritePlaylistsTile
    /// New Playlist on top of the Add to Playlist sheet.
    case newPlaylist
    /// What an empty list of the profile's music is for.
    case emptyInfo(String)
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

/// Which empty state a list shows in place of its rows.
private enum MusicEmptyState: Equatable {
    case hub
    case playlists
    case favorites
}

/// The tabs of the account's own profile music (folder tabs under the bar).
private enum MusicProfileTab: Int32 {
    case tracks
    case playlists
}

/// What an open search looks through, switched by the tabs above the keyboard (Figma Search, 251:22733).
private enum MusicSearchScope: Int64, CaseIterable {
    case all
    case tracks
    case playlists
    case artists
    case favorites
}

/// The All tab's categories: each shows a few rows until Show More (Figma Music / Search, 291:16311).
private enum MusicSearchCategory: CaseIterable {
    case playlists
    case artists
    case tracks

    var limit: Int {
        switch self {
        case .playlists, .artists:
            return 3
        case .tracks:
            return 5
        }
    }
}

private struct MusicListEntry: Comparable, Identifiable {
    let index: Int
    let stableId: MusicListEntryId
    let content: MusicListEntryContent
    /// The alphabet section the row belongs to, when the list has them.
    let letter: String?
    /// The player's state on this row (nil, playing or paused), so a play/pause redraws only the playing track's row.
    var playingState: Bool? = nil

    /// Changes when the row must be redrawn.
    private var revision: String {
        switch self.content {
        case let .tabSwitch(isOn):
            return "\(isOn)"
        case .tabFooter:
            return ""
        case let .hubTiles(iconPlayTokens):
            return [MusicSection.Row.songs, .artists, .playlists, .favorites].map { "\(iconPlayTokens[$0] ?? 0)" }.joined(separator: " ")
        case .playback, .addTracks, .favoritePlaylistsTile, .newPlaylist:
            return ""
        case let .playlistHeaderSpacer(height):
            return "\(height)"
        case let .playlistInfo(text), let .emptyInfo(text):
            return text
        case let .playlistActions(isEmpty, isFavorite):
            return "\(isEmpty) \(isFavorite)"
        case let .track(track, isSelected, isFavorite, isPicked):
            // Title, artist and cover too: an edit keeps the message id, so without them the row would keep the old text.
            let cover = track.file?.previewRepresentations.first.flatMap { "\($0.resource.id)" } ?? ""
            return "\(track.isSaved) \(String(describing: isSelected)) \(isFavorite) \(String(describing: isPicked)) \(track.title) \(track.artist ?? "") \(cover)"
        case let .artist(artist):
            return artist.name
        case let .playlist(playlist, subtitle):
            return "\(playlist.title) \(subtitle) \(playlist.isFavorite) \(String(describing: playlist.cover?.resource.id))"
        }
    }

    static func ==(lhs: MusicListEntry, rhs: MusicListEntry) -> Bool {
        return lhs.index == rhs.index && lhs.stableId == rhs.stableId && lhs.letter == rhs.letter && lhs.playingState == rhs.playingState && lhs.revision == rhs.revision
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
    private let playlistChooser: MusicPlaylistChooser?
    private let pickerPromptNode = ImmediateTextNode()
    private var pickerDisposable: Disposable?
    private let listNode = ListViewImpl()
    private let indexNode = CollectionIndexNode()
    let navigationBarView = ComponentView<Empty>()

    private var entries: [MusicListEntry] = []
    /// Bumped to replay a hub row's icon animation.
    private var hubIconPlayTokens: [MusicSection.Row: Int] = [:]
    private var currentTracks: [MusicTrack] = []
    /// The list has nothing to show once the music has loaded, so it shows the client's empty state instead:
    /// the hub with no tracks and no playlists (after Delete All Music, with no source chats), Playlists with none,
    /// Favorites with no favorite tracks or playlists.
    private var emptyState: MusicEmptyState?
    private var emptyStateView: ComponentView<Empty>?
    private var sorting: MusicSorting
    private var navigationScrollOffset: CGFloat = 0.0
    private var validLayout: ContainerViewLayout?
    private var libraryDisposable: Disposable?
    /// The track the player is on and whether it plays: its row shows the sound wave on the cover, as in the queue.
    private var playingTrack: (fileId: Int64, isPaused: Bool)?
    private var playingDisposable: Disposable?

    /// Selection of tracks to remove: Edit on the tab, the check button from Settings, Select Tracks in a list's menu.
    private(set) var isSelecting = false
    private var attachmentSelectionDisposable: Disposable?
    private var selectedTrackIds = Set<EngineMessage.Id>()
    /// Bottom actions while selecting on a pushed screen; on the tab the tab bar shows them as the controller's toolbar.
    private var selectionPanel: ComponentView<Empty>?
    /// A playlist (screen or sheet) has no list bar, so the playing track's mini player sits in the bottom toolbar.
    private var playlistPlaybackPanel: ComponentView<Empty>?
    /// Editing the playlist pauses the track and puts the player away until playback resumes.
    private var isPlaylistPlaybackPanelSuspended = false

    private var isTabShown = true
    private var tabShownDisposable: Disposable?

    /// A playlist opened from the section draws a profile-like header instead of the list bar (Figma Playlist / Default).
    private var playlistHeaderView: MusicPlaylistHeaderView?
    private let playlistControls = ComponentView<Empty>()
    private let playlistControlsTag = NSObject()
    private let playlistNavigationTitle = ComponentView<Empty>()
    private var playlistEdgeEffectView: EdgeEffectView?
    private var playlistOwnerName: String = ""
    private var playlistOwnerPeer: EnginePeer?
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
    /// The client's search bar for screens with the navigation bar: it grows out of the bar's field, as in Mini Apps and Contacts.
    private var searchBarNode: SearchBarNode?
    /// The scope tabs above the keyboard: the chat list search's filter bar.
    private var searchFiltersNode: ChatListSearchFiltersContainerNode?
    private var searchScope: MusicSearchScope = .all
    /// All tab: categories opened with Show More, and those that have rows hidden.
    private var expandedSearchCategories = Set<MusicSearchCategory>()
    private var searchCategoriesWithMore = Set<MusicSearchCategory>()

    /// The profile's music: the open tab (own profile), and another user's tracks as their profile lists them.
    private var profileTab: MusicProfileTab = .tracks
    private var foreignProfileTracks: [MusicTrack] = []
    private var foreignProfileDisposable: Disposable?
    private weak var foreignProfileSavedMusicContext: ProfileSavedMusicContext?

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
        self.playlistChooser = controller.playlistChooser
        switch controller.section {
        case .songs, .favorites:
            // Newest first, as on the hub (Figma Songs / Default); a title or artist sort adds the letters.
            self.sorting = MusicSorting(key: .dateAdded, ascending: false)
        case .playlist:
            self.sorting = MusicSorting(key: .playlistOrder, ascending: true)
        case .profile:
            self.sorting = MusicSorting(key: .dateAdded, ascending: false)
        case .hub, .artists, .playlists:
            self.sorting = MusicSorting(key: .title, ascending: true)
        }

        super.init()

        self.searchScope = self.defaultSearchScope
        self.backgroundColor = self.backgroundColor(theme: presentationData.theme)
        self.addSubnode(self.listNode)
        self.addSubnode(self.indexNode)

        if case .playlist = controller.section, controller.picker == nil {
            let headerView = MusicPlaylistHeaderView()
            let edgeEffectView = EdgeEffectView()
            edgeEffectView.isUserInteractionEnabled = false
            self.view.addSubview(edgeEffectView)
            self.playlistEdgeEffectView = edgeEffectView
            // Above the list and the bar's fade, as the profile's header over its scroll view: the fade never covers the
            // cover. It takes no touches, so the list under it still scrolls.
            self.view.addSubview(headerView)
            self.playlistHeaderView = headerView
            self.view.addSubview(headerView.overlayView)
            headerView.authorPressed = { [weak self] in
                self?.openPlaylistAuthor()
            }

            // A demo friend's playlist from a chat is hers; any other playlist is the account's.
            var ownerPeerId = context.account.peerId
            if case let .playlist(playlistId) = self.section, let foreignOwnerId = MusicDemo.ownerPeerId(playlistId: playlistId) {
                ownerPeerId = foreignOwnerId
            }
            self.playlistOwnerDisposable = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: ownerPeerId))
            |> deliverOnMainQueue).start(next: { [weak self] peer in
                guard let self, let peer else {
                    return
                }
                self.playlistOwnerName = peer.displayTitle(strings: self.presentationData.strings, displayOrder: self.presentationData.nameDisplayOrder)
                self.playlistOwnerPeer = peer
                self.applyNavigationScroll(transition: .immediate)
            })
            self.updatePlaylistCover()
        }

        self.listNode.visibleContentOffsetChanged = { [weak self] _, _ in
            self?.applyNavigationScroll(transition: .immediate)
        }
        self.listNode.beganInteractiveDragging = { [weak self] _ in
            self?.setHubTilesFlowPaused(true)
        }
        self.listNode.didEndScrolling = { [weak self] _ in
            self?.setHubTilesFlowPaused(false)
            self?.snapNavigationScroll()
        }
        if self.isPlaylistScreen {
            // The profile's `scrollViewWillEndDragging`: a drag never rests inside the header's first 140 pt, so the avatar
            // always finishes melting into the island, or comes back out of it, in one motion.
            self.listNode.adjustDecelerationDistance = { [weak self] distance in
                guard let self, self.playlistSearchQuery == nil, case let .known(offset) = self.listNode.visibleContentOffset() else {
                    return distance
                }
                let snapHeight: CGFloat = 140.0
                let target = offset + distance
                guard target < snapHeight else {
                    return distance
                }
                return (target < snapHeight * 0.5 ? 0.0 : snapHeight) - offset
            }
        }

        self.indexNode.indexSelected = { [weak self] letter in
            self?.scrollToSection(letter: letter)
        }
        self.playingDisposable = (context.sharedContext.mediaManager.musicMediaPlayerState
        |> map { state -> (Int64, Bool)? in
            // By file: a profile track's row can get a new local id while the player keeps the one it started with.
            guard let state, case let .state(itemState) = state.1, let source = itemState.item.playbackData?.source, case let .telegramFile(fileReference, _, _) = source else {
                return nil
            }
            let isPaused: Bool
            switch itemState.status.status {
            case .playing:
                isPaused = false
            case .paused:
                isPaused = true
            case let .buffering(_, whilePlaying, _, _):
                isPaused = !whilePlaying
            }
            return (fileReference.media.fileId.id, isPaused)
        }
        |> distinctUntilChanged(isEqual: { $0?.0 == $1?.0 && $0?.1 == $1?.1 })
        |> deliverOnMainQueue).start(next: { [weak self] value in
            guard let self else {
                return
            }
            self.playingTrack = value.map { (fileId: $0.0, isPaused: $0.1) }
            if self.isPlaylistPlaybackPanelSuspended, let value, !value.1 {
                self.isPlaylistPlaybackPanelSuspended = false
                if let layout = self.validLayout {
                    self.containerLayoutUpdated(layout, transition: .animated(duration: 0.4, curve: .spring))
                }
            }
            // Only rows whose playing state changed are redrawn: updating every row stalled the main thread
            // for ~0.25 s on each play/pause and the mini player's icon morph skipped to its end.
            self.updateList()
        })
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
            // Once everything has loaded, changes come from the user (delete, favorite, playlist edits) and animate.
            self.updateList(allUpdated: self.isPlaylistScreen, animated: self.library.isFullyLoaded)
        })
        if case .profile = controller.section, let savedMusicContext = controller.profileSavedMusicContext {
            // Another user's profile: their list turned into messages, as their profile's player gets it.
            self.foreignProfileSavedMusicContext = savedMusicContext
            let location = PeerMessagesPlaylistLocation.savedMusic(context: savedMusicContext, at: 0, canReorder: false)
            if case let .custom(messages, _, _, _, _) = location.effectiveLocation(context: context) {
                self.foreignProfileDisposable = (messages
                |> deliverOnMainQueue).start(next: { [weak self, weak savedMusicContext] messages, _, canLoadMore in
                    guard let self else {
                        return
                    }
                    self.foreignProfileTracks = messages.map { MusicTrack(message: $0, isSaved: true) }
                    self.updateList(animated: true)
                    if canLoadMore {
                        savedMusicContext?.loadMore()
                    }
                })
            }
        }
        if let selection = controller.attachmentSelection {
            self.attachmentSelectionDisposable = (selection.updated.signal()
            |> deliverOnMainQueue).start(next: { [weak self] _ in
                self?.updateList(allUpdated: true, animated: true)
            })
        }
        if let picker = self.picker {
            self.pickerDisposable = (picker.updated.signal()
            |> deliverOnMainQueue).start(next: { [weak self] _ in
                self?.updateList(animated: true)
            })
        }
        if self.displaysTabSwitch {
            self.tabShownDisposable = (musicTabIsShown(context: context)
            |> deliverOnMainQueue).start(next: { [weak self] isShown in
                guard let self else {
                    return
                }
                self.isTabShown = isShown
                self.updateList(animated: true)
            })
        }
    }

    deinit {
        self.playlistOwnerDisposable?.dispose()
        self.playlistCoverDisposable?.dispose()
        self.libraryDisposable?.dispose()
        self.playingDisposable?.dispose()
        self.tabShownDisposable?.dispose()
        self.pickerDisposable?.dispose()
        self.attachmentSelectionDisposable?.dispose()
        self.foreignProfileDisposable?.dispose()
    }

    /// The profile's music of the account itself: tracks and playlists in tabs, menus to take them out of the profile.
    private var isOwnProfile: Bool {
        if case let .profile(peerId) = self.section {
            return peerId == self.context.account.peerId
        }
        return false
    }

    /// Another user's profile music: their tracks only, nothing to change.
    private var isForeignProfile: Bool {
        if case let .profile(peerId) = self.section {
            return peerId != self.context.account.peerId
        }
        return false
    }

    /// The local test user's profile (concept only): music taken from this library, see `testProfileContent`.
    private var isTestProfile: Bool {
        if case let .profile(peerId) = self.section {
            return peerId == musicTestChatPeerId
        }
        return false
    }

    /// Profiles that have playlists to show: the own one and the test user's.
    private var hasProfileTabs: Bool {
        return self.isOwnProfile || self.isTestProfile
    }

    private var profileTracks: [MusicTrack] {
        if self.isTestProfile {
            return self.library.testProfileContent().tracks
        }
        return self.isForeignProfile ? self.foreignProfileTracks : self.library.profileTracks
    }

    private var profilePlaylists: [MusicPlaylist] {
        if self.isTestProfile {
            return self.library.testProfileContent().playlists
        }
        return self.isOwnProfile ? self.library.profilePlaylists : []
    }

    /// The tab can be turned off only where the section stays reachable: the hub opened from Settings.
    private var displaysTabSwitch: Bool {
        return self.section == .hub && self.controller?.mode == .navigation && self.picker == nil && self.controller?.attachmentSelection == nil
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
        case .profile:
            return self.profileTab == .tracks
        case .artists, .playlists:
            return false
        }
    }

    /// Tracks, an artist's tracks and favorites: lists whose menu also selects.
    private var listsTracks: Bool {
        switch self.section {
        case .songs, .favorites:
            return true
        case .hub, .artists, .playlists, .playlist, .profile:
            return false
        }
    }

    private var hasAlphabetSections: Bool {
        switch self.section {
        case .hub, .playlists, .playlist, .profile:
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

    /// The trimmed, lowercased query while search is open and not empty (Figma Search, 251:22733).
    private var activeSearchQuery: String? {
        guard let query = self.playlistSearchQuery?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !query.isEmpty else {
            return nil
        }
        return query
    }

    private func matchesSearch(_ track: MusicTrack) -> Bool {
        guard let query = self.activeSearchQuery else {
            return true
        }
        return track.title.lowercased().contains(query) || (track.artist?.lowercased().contains(query) ?? false)
    }

    /// Screens whose search switches scopes: every list under the navigation bar, outside of the track picker.
    private var usesSearchScopes: Bool {
        if self.picker != nil || self.playlistChooser != nil {
            return false
        }
        switch self.section {
        case .playlist, .profile:
            // The profile's music is searched in place: it is not the library the scopes look through.
            return false
        default:
            return true
        }
    }

    private var isScopedSearchActive: Bool {
        return self.usesSearchScopes && self.playlistSearchQuery != nil
    }

    /// The tab a search opens on: the section it was opened from.
    private var defaultSearchScope: MusicSearchScope {
        switch self.section {
        case .hub, .playlist, .profile:
            return .all
        case .songs:
            return .tracks
        case .artists:
            return .artists
        case let .playlists(favoritesOnly):
            return favoritesOnly ? .favorites : .playlists
        case .favorites:
            return .favorites
        }
    }

    private func searchScopeTitle(_ scope: MusicSearchScope) -> String {
        let strings = self.presentationData.strings
        switch scope {
        case .all:
            return strings.Music_All
        case .tracks:
            return strings.Music_Tracks
        case .playlists:
            return strings.Music_Playlists
        case .artists:
            return strings.Music_Artists
        case .favorites:
            return strings.Music_Favorites
        }
    }

    private func searchCategoryTitle(_ category: MusicSearchCategory) -> String {
        let strings = self.presentationData.strings
        switch category {
        case .playlists:
            return strings.Music_Playlists
        case .artists:
            return strings.Music_Artists
        case .tracks:
            return strings.Music_Tracks
        }
    }

    /// The All tab's category whose header this is.
    private func searchCategory(header title: String) -> MusicSearchCategory? {
        guard self.isScopedSearchActive, self.searchScope == .all else {
            return nil
        }
        return MusicSearchCategory.allCases.first(where: { self.searchCategoryTitle($0) == title })
    }

    /// `recent` in front, then the rest of `all`, keyed by `key`; recents no longer in the library are skipped.
    private func recentsFirst<T, K: Hashable>(_ all: [T], recent: [K], key: (T) -> K?) -> [T] {
        var byKey: [K: T] = [:]
        for item in all {
            if let itemKey = key(item), byKey[itemKey] == nil {
                byKey[itemKey] = item
            }
        }
        let recentItems = recent.compactMap { byKey[$0] }
        let recentKeys = Set(recent)
        return recentItems + all.filter { item in
            return key(item).flatMap { !recentKeys.contains($0) } ?? true
        }
    }

    private func toggleSearchCategory(_ category: MusicSearchCategory) {
        if self.expandedSearchCategories.contains(category) {
            self.expandedSearchCategories.remove(category)
        } else {
            self.expandedSearchCategories.insert(category)
        }
        // Headers change their action title, so every row is rebuilt.
        self.updateList(allUpdated: true, animated: true)
    }

    private func searchScopePlaceholder() -> String {
        let strings = self.presentationData.strings
        switch self.searchScope {
        case .all:
            return strings.Common_Search
        case .tracks:
            return strings.Music_SearchTracks
        case .playlists:
            return strings.Music_SearchPlaylists
        case .artists:
            return strings.Music_SearchArtists
        case .favorites:
            return strings.Music_SearchFavorites
        }
    }

    /// While searching only result rows are listed (Figma Search, 251:22733): All looks through playlists, artists and tracks
    /// under their headers, Favorites through favorite playlists and tracks, every other tab only through its own section.
    private func makeSearchEntries() -> [MusicListEntry] {
        var contents: [(MusicListEntryId, MusicListEntryContent, String?)] = []
        let strings = self.presentationData.strings
        let query = self.activeSearchQuery
        let matches: (String) -> Bool = { text in
            return query.flatMap { text.lowercased().contains($0) } ?? true
        }
        let playlistsTitle = strings.Music_Playlists
        let artistsTitle = strings.Music_Artists
        let tracksTitle = strings.Music_Tracks

        let playlistSorting: MusicSorting
        if case .playlists = self.section {
            playlistSorting = self.sorting
        } else {
            playlistSorting = MusicSorting(key: .title, ascending: true)
        }
        let trackSorting = self.listsTracks ? self.sorting : MusicSorting(key: .dateAdded, ascending: false)

        let appendPlaylists: (_ favoritesOnly: Bool, _ header: String?) -> Void = { favoritesOnly, header in
            let playlists = self.library.playlists(sorting: playlistSorting).filter { playlist in
                return (!favoritesOnly || playlist.isFavorite) && matches(playlist.title)
            }
            contents += playlists.map { playlist in
                return (.playlist(playlist.id), .playlist(playlist, subtitle: musicPlaylistSubtitle(strings, playlist: playlist, library: self.library)), header)
            }
        }
        let appendArtists: (_ header: String?) -> Void = { header in
            contents += self.library.artists.filter { matches($0.name) }.map { artist in
                return (.artist(artist.name.lowercased()), .artist(artist), header ?? musicIndexLetter(artist.name))
            }
        }
        let appendTracks: (_ source: MusicTrackSource, _ header: String?) -> Void = { source, header in
            let tracks = self.library.tracks(source: source, sorting: trackSorting).filter(self.matchesSearch)
            self.currentTracks = tracks
            contents += tracks.map { track in
                return (.track(track.message.id), .track(track, isSelected: nil, isFavorite: self.library.isFavorite(track), isPicked: nil), header)
            }
        }

        self.searchCategoriesWithMore.removeAll()
        // Shows the first rows of a category; the header's Show More reveals the rest.
        let limited: ([(MusicListEntryId, MusicListEntryContent, String?)], MusicSearchCategory) -> [(MusicListEntryId, MusicListEntryContent, String?)] = { rows, category in
            guard rows.count > category.limit else {
                return rows
            }
            self.searchCategoriesWithMore.insert(category)
            return self.expandedSearchCategories.contains(category) ? rows : Array(rows.prefix(category.limit))
        }

        switch self.searchScope {
        case .all:
            // Recently opened results lead each category, then the rest of the library (Figma Music / Search, 291:16311).
            let playlists = self.recentsFirst(self.library.playlists(sorting: playlistSorting), recent: self.library.recentSearchPlaylistIds, key: { $0.id }).filter { matches($0.title) }
            contents += limited(playlists.map { playlist in
                return (.playlist(playlist.id), .playlist(playlist, subtitle: musicPlaylistSubtitle(strings, playlist: playlist, library: self.library)), playlistsTitle)
            }, .playlists)
            let artists = self.recentsFirst(self.library.artists, recent: self.library.recentSearchArtists, key: { $0.name.lowercased() }).filter { matches($0.name) }
            contents += limited(artists.map { artist in
                return (.artist(artist.name.lowercased()), .artist(artist), artistsTitle)
            }, .artists)
            let allTracks = self.recentsFirst(self.library.tracks(source: .all, sorting: trackSorting), recent: self.library.recentSearchFileIds, key: { $0.file?.fileId.id }).filter(self.matchesSearch)
            let trackRows = limited(allTracks.map { track in
                return (.track(track.message.id), .track(track, isSelected: nil, isFavorite: self.library.isFavorite(track), isPicked: nil), tracksTitle)
            }, .tracks)
            self.currentTracks = Array(allTracks.prefix(trackRows.count))
            contents += trackRows
        case .favorites:
            appendPlaylists(true, playlistsTitle)
            appendTracks(.favorites, tracksTitle)
        case .tracks:
            if case let .songs(artist?) = self.section {
                appendTracks(.artist(artist), nil)
            } else {
                appendTracks(.all, nil)
            }
        case .playlists:
            appendPlaylists(false, nil)
        case .artists:
            appendArtists(nil)
        }
        return contents.enumerated().map { MusicListEntry(index: $0.offset, stableId: $0.element.0, content: $0.element.1, letter: $0.element.2, playingState: self.entryPlayingState($0.element.1)) }
    }

    /// Mirrors the playing indicator `item(entry:)` draws: paused (true), playing (false) or none.
    private func entryPlayingState(_ content: MusicListEntryContent) -> Bool? {
        guard case let .track(track, _, _, isPicked) = content, isPicked == nil, let playingTrack = self.playingTrack, track.file?.fileId.id == playingTrack.fileId else {
            return nil
        }
        return playingTrack.isPaused
    }

    private func makeEntries() -> [MusicListEntry] {
        var contents: [(MusicListEntryId, MusicListEntryContent, String?)] = []
        self.currentTracks = []
        self.emptyState = nil
        if self.isScopedSearchActive {
            return self.makeSearchEntries()
        }
        let trackContent: (MusicTrack) -> MusicListEntryContent = { track in
            return .track(
                track,
                isSelected: self.controller?.attachmentSelection.flatMap { $0.contains(track) } ?? (self.isSelecting ? self.selectedTrackIds.contains(track.message.id) : nil),
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
            let allTracks = self.library.tracks(source: .all, sorting: MusicSorting(key: .dateAdded, ascending: false))
            if allTracks.isEmpty && self.library.playlists.isEmpty && self.library.isFullyLoaded && self.playlistSearchQuery == nil && !self.displaysTabSwitch && self.picker == nil && self.controller?.attachmentSelection == nil {
                self.emptyState = .hub
                break
            }
            let tracks = allTracks.filter(self.matchesSearch)
            self.currentTracks = tracks
            contents.append((.hubTiles, .hubTiles(iconPlayTokens: self.hubIconPlayTokens), nil))
            appendPlaybackPanel(tracks)
            contents += tracks.map { (.track($0.message.id), trackContent($0), nil) }
        case .songs, .favorites:
            let sectionTracks = self.library.tracks(source: self.trackSource, sorting: self.sorting)
            self.currentTracks = sectionTracks.filter(self.matchesSearch)
            if case .favorites = self.section, self.picker == nil {
                let hasFavoritePlaylists = self.library.playlists.contains(where: { $0.isFavorite })
                if sectionTracks.isEmpty && !hasFavoritePlaylists && self.library.isFullyLoaded && self.playlistSearchQuery == nil && self.controller?.attachmentSelection == nil {
                    self.emptyState = .favorites
                    break
                }
                // Favorite playlists are their own category above the tracks (Figma Favorites), hidden while there are none.
                if hasFavoritePlaylists {
                    contents.append((.favoritePlaylistsTile, .favoritePlaylistsTile, nil))
                    if sectionTracks.isEmpty && self.playlistSearchQuery == nil {
                        contents.append((.emptyInfo, .emptyInfo(self.presentationData.strings.Music_FavoriteTracksAppearHere), nil))
                    }
                }
            }
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
                if self.picker != nil, !self.currentTracks.isEmpty {
                    // A playlist opened in the picker: Add and Search under the header (Figma Playlists / Add Track).
                    contents.append((.playlistActions, .playlistActions(isEmpty: false, isFavorite: false), nil))
                }
                appendPlaybackPanel(self.currentTracks)
            }
            contents += self.currentTracks.map { (.track($0.message.id), trackContent($0), nil) }
        case .profile:
            let strings = self.presentationData.strings
            let query = self.activeSearchQuery
            if self.profileTab == .playlists && self.hasProfileTabs {
                let playlists = self.profilePlaylists.filter { playlist in
                    return query.flatMap { playlist.title.lowercased().contains($0) } ?? true
                }
                if playlists.isEmpty && query == nil && self.isOwnProfile {
                    contents.append((.emptyInfo, .emptyInfo(strings.Music_PlaylistsYouAddToYourProfileAppearHere), nil))
                }
                contents += playlists.map { playlist in
                    return (.playlist(playlist.id), .playlist(playlist, subtitle: musicPlaylistSubtitle(strings, playlist: playlist, library: self.library)), nil)
                }
            } else {
                self.currentTracks = self.profileTracks.filter(self.matchesSearch)
                if self.currentTracks.isEmpty && query == nil {
                    let text = self.isOwnProfile ? strings.Music_TracksYouAddToYourProfileAppearHere : strings.Music_NoMusicInThisProfileYet
                    contents.append((.emptyInfo, .emptyInfo(text), nil))
                }
                appendPlaybackPanel(self.currentTracks)
                contents += self.currentTracks.map { (.track($0.message.id), trackContent($0), nil) }
            }
        case .artists:
            contents += self.library.artists.filter { artist in
                return self.activeSearchQuery.flatMap { artist.name.lowercased().contains($0) } ?? true
            }.map { (.artist($0.name.lowercased()), .artist($0), self.picker == nil ? musicIndexLetter($0.name) : nil) }
        case let .playlists(favoritesOnly):
            let strings = self.presentationData.strings
            if !favoritesOnly && self.library.playlists.isEmpty && self.playlistChooser == nil && self.picker == nil && self.playlistSearchQuery == nil && self.controller?.attachmentSelection == nil {
                self.emptyState = .playlists
                break
            }
            if self.playlistChooser != nil && self.activeSearchQuery == nil {
                contents.append((.newPlaylist, .newPlaylist, nil))
            }
            let excludedId = self.playlistChooser?.excludedId
            contents += self.library.playlists(sorting: self.sorting).filter { playlist in
                guard !favoritesOnly || playlist.isFavorite, playlist.id != excludedId else {
                    return false
                }
                return self.activeSearchQuery.flatMap { playlist.title.lowercased().contains($0) } ?? true
            }.map { playlist in
                return (.playlist(playlist.id), .playlist(playlist, subtitle: musicPlaylistSubtitle(strings, playlist: playlist, library: self.library)), nil)
            }
        }
        // Tracks that left the list leave the selection too.
        let trackIds = Set(self.currentTracks.map(\.message.id))
        self.selectedTrackIds.formIntersection(trackIds)
        return contents.enumerated().map { MusicListEntry(index: $0.offset, stableId: $0.element.0, content: $0.element.1, letter: $0.element.2, playingState: self.entryPlayingState($0.element.1)) }
    }

    private var trackSource: MusicTrackSource {
        switch self.section {
        case let .songs(artist):
            return artist.flatMap { .artist($0) } ?? .all
        case .favorites:
            return .favorites
        case let .playlist(id):
            return .playlist(id)
        case .hub, .artists, .playlists, .profile:
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
        if self.isScopedSearchActive {
            self.library.noteSearched(track: track)
        }
        self.controller?.play(track: track, tracks: self.currentTracks, library: self.library, source: self.queueSource())
    }

    /// The list a queue started here follows as the library changes: the section's tracks in its sorting, without the
    /// search. A queue started from search results, or from a list with no such source, keeps its tracks.
    private func queueSource() -> (() -> [MusicTrack]?)? {
        let full = self.queueSourceTracks()
        guard let full, full.count == self.currentTracks.count else {
            return nil
        }
        return { [weak self] in
            return self?.queueSourceTracks()
        }
    }

    private func queueSourceTracks() -> [MusicTrack]? {
        switch self.section {
        case .hub:
            return self.library.tracks(source: .all, sorting: MusicSorting(key: .dateAdded, ascending: false))
        case .songs, .favorites:
            return self.library.tracks(source: self.trackSource, sorting: self.sorting)
        case .profile:
            return self.profileTracks
        default:
            return nil
        }
    }

    // MARK: Selection

    func setSelecting(_ isSelecting: Bool) {
        guard self.isSelecting != isSelecting else {
            return
        }
        self.isSelecting = isSelecting
        self.selectedTrackIds.removeAll()
        self.updateList(animated: true)
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
        self.updateList(animated: true)
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
        self.updateList(animated: true)
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

    func forwardSelectedTracks() {
        let tracks = self.currentTracks.filter { self.selectedTrackIds.contains($0.message.id) }
        guard !tracks.isEmpty else {
            return
        }
        self.controller?.share(tracks: tracks, completion: { [weak self] in
            self?.setSelecting(false)
        })
    }

    /// The chat selection panel's icons: trash for Delete, the share arrow (Figma) for sending to chats.
    static let selectionDeleteIcon = "Chat/Input/Accessory Panels/MessageSelectionTrash"
    static let selectionForwardIcon = "Chat/Input/Accessory Panels/MessageSelectionAction"

    private var selectAllTitle: String {
        let strings = self.presentationData.strings
        return self.allTracksSelected ? strings.Music_DeselectAll : strings.Music_SelectAll
    }

    /// On the tab the tab bar draws the toolbar in its own place; a pushed screen draws the same panel itself.
    private func updateSelectionToolbar() {
        guard let controller = self.controller else {
            return
        }
        if controller.mode == .tab {
            // Figma List Edit 136:6397: Delete on the left, Forward on the right, round glass icon buttons.
            let toolbar = self.isSelecting ? Toolbar(
                leftAction: ToolbarAction(title: self.presentationData.strings.Common_Delete, isEnabled: !self.selectedTrackIds.isEmpty, icon: MusicScreenNode.selectionDeleteIcon),
                rightAction: ToolbarAction(title: self.presentationData.strings.VoiceOver_MessageContextForward, isEnabled: !self.selectedTrackIds.isEmpty, icon: MusicScreenNode.selectionForwardIcon),
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
    static let pickerPromptHeight: CGFloat = 22.0

    /// Opening the playlist's editor pauses the playing track and hides the bottom player.
    func suspendPlaybackForPlaylistEditing() {
        guard self.isPlaylistScreen, let mediaPlayback = self.controller?.globalControlPanelsContextState?.mediaPlayback else {
            return
        }
        self.isPlaylistPlaybackPanelSuspended = true
        self.context.sharedContext.mediaManager.playlistControl(.playback(.pause), type: mediaPlayback.kind)
        if let layout = self.validLayout {
            self.containerLayoutUpdated(layout, transition: .animated(duration: 0.4, curve: .spring))
        }
    }

    private static let playlistPlaybackPanelHeight: CGFloat = 40.0

    /// The player shows in the bottom toolbar's place: not while selecting, where the toolbar holds the selection actions.
    private var displaysPlaylistPlaybackPanel: Bool {
        return self.isPlaylistScreen && !self.isPlaylistPlaybackPanelSuspended && !self.isSelecting && self.controller?.globalControlPanelsContextState?.mediaPlayback != nil
    }

    /// The client's mini player in its glass capsule (the same panel the list bar shows on the other Music screens), on the toolbar's line.
    private func updatePlaylistPlaybackPanel(layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        if self.displaysPlaylistPlaybackPanel {
            let panel: ComponentView<Empty>
            var panelTransition = ComponentTransition(transition)
            if let current = self.playlistPlaybackPanel {
                panel = current
            } else {
                panel = ComponentView()
                self.playlistPlaybackPanel = panel
                panelTransition = .immediate
            }
            // The container insets its glass by 16 pt: the capsule keeps the selection toolbar's 20 pt sides.
            let sideInset: CGFloat = 20.0 - 16.0
            let panelSize = panel.update(
                transition: panelTransition,
                component: self.headerPanels(),
                environment: {},
                containerSize: CGSize(width: layout.size.width - sideInset * 2.0, height: 100.0)
            )
            if let panelView = panel.view {
                let panelFrame = CGRect(origin: CGPoint(x: sideInset, y: layout.size.height - self.selectionPanelBottomInset(layout: layout) - panelSize.height), size: panelSize)
                if panelView.superview == nil {
                    self.view.addSubview(panelView)
                    panelView.frame = panelFrame.offsetBy(dx: 0.0, dy: 16.0)
                    panelView.alpha = 0.0
                }
                ComponentTransition(transition).setFrame(view: panelView, frame: panelFrame)
                ComponentTransition(transition).setAlpha(view: panelView, alpha: 1.0)
            }
        } else if let panel = self.playlistPlaybackPanel {
            self.playlistPlaybackPanel = nil
            if let panelView = panel.view {
                ComponentTransition(transition).setFrame(view: panelView, frame: panelView.frame.offsetBy(dx: 0.0, dy: 16.0))
                ComponentTransition(transition).setAlpha(view: panelView, alpha: 0.0, completion: { [weak panelView] _ in
                    panelView?.removeFromSuperview()
                })
            }
        }
    }

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
            let hasSelection = !self.selectedTrackIds.isEmpty
            let _ = panel.update(
                transition: panelTransition,
                component: AnyComponent(GlassControlPanelComponent(
                    theme: self.presentationData.theme,
                    leftItem: GlassControlPanelComponent.Item(
                        items: [GlassControlGroupComponent.Item(id: "delete", content: .icon(MusicScreenNode.selectionDeleteIcon), action: hasSelection ? { [weak self] in
                            self?.deleteSelectedTracks()
                        } : nil)],
                        background: .panel
                    ),
                    centralItem: nil,
                    rightItem: GlassControlPanelComponent.Item(
                        items: [GlassControlGroupComponent.Item(id: "forward", content: .icon(MusicScreenNode.selectionForwardIcon), action: hasSelection ? { [weak self] in
                            self?.forwardSelectedTracks()
                        } : nil)],
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
            option(0, strings.Music_PlayNext, "Chat/Context Menu/MoveUp", actions.neutral1, false, { [weak self] in
                self?.enqueue(track: track, next: true)
            }),
            option(1, strings.Music_AddToPlaylist, "Chat/Context Menu/AddCaption", actions.warning, false, { [weak self] in
                self?.addToPlaylist(track: track)
            })
        ]
        if self.isOwnProfile {
            // The profile's list: the destructive swipe takes the track out of the profile, Music keeps it.
            return (left, [
                option(4, strings.Music_RemoveFromProfile, "Music/RemoveFromProfile", actions.destructive, true, { [weak self] in
                    guard let self else {
                        return
                    }
                    self.controller?.setSavedToProfile(track: track, isSaved: false, library: self.library)
                })
            ])
        }
        let right = [
            option(2, strings.Common_Edit, "Chat/Context Menu/Edit", actions.accent, false, { [weak self] in
                guard let self else {
                    return
                }
                self.controller?.editTrack(track, library: self.library)
            }),
            option(3, strings.Common_Delete, "Chat/Context Menu/Delete", actions.destructive, true, { [weak self] in
                guard let self else {
                    return
                }
                self.library.remove(tracks: [track])
                self.controller?.presentRemovedFromMusicToast(count: 1)
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
        let isSavedToProfile = library.isSavedToProfile(track)
        var items: [ContextMenuItem] = [
            .custom(MusicTrackActionsContextItem(actions: [
                MusicTrackActionsContextItem.Action(
                    title: isSavedToProfile ? strings.Music_Remove : strings.Music_ToProfile,
                    iconName: isSavedToProfile ? "Music/RemoveFromProfile" : "Peer Info/SaveMusic",
                    action: { [weak self] in
                        self?.controller?.setSavedToProfile(track: track, isSaved: !isSavedToProfile, library: library)
                    }
                ),
                MusicTrackActionsContextItem.Action(
                    // The title stays: the longer "remove" wording does not fit a third of the menu.
                    title: strings.Music_Favorite,
                    iconName: isFavorite ? "Music/StarSlash" : "Music/Star",
                    action: { [weak self] in
                        library.setFavorite(track, !isFavorite)
                        self?.controller?.presentFavoriteToast(isFavorite: !isFavorite)
                    }
                ),
                MusicTrackActionsContextItem.Action(
                    title: strings.Music_Share,
                    iconName: "Music/ShareFilled",
                    action: { [weak self] in
                        self?.controller?.share(track: track)
                    }
                )
            ]), false),
            .separator,
            action(strings.Music_Edit, .singleLine, "Chat/Context Menu/Edit", false, { [weak self] in
                guard let self else {
                    return
                }
                self.controller?.editTrack(track, library: self.library)
            }),
            .separator,
            action(strings.Music_AddToPlaylist2, .singleLine, "Chat/Context Menu/AddCaption", false, { [weak self] in
                self?.addToPlaylist(track: track)
            }),
            action(strings.Music_PlayNext2, .singleLine, "Chat/Context Menu/MoveUp", false, { [weak self] in
                self?.enqueue(track: track, next: true)
            }),
            action(strings.Music_AddToQueue, .singleLine, "Chat/Context Menu/MoveDown", false, { [weak self] in
                self?.enqueue(track: track, next: false)
            })
        ]
        var isArtistList = false
        if case .songs(.some) = self.section {
            isArtistList = true
        }
        if let artist = track.artist, !isArtistList {
            items.append(.separator)
            items.append(action(strings.Music_GoToArtist, .secondLineWithValue(artist), "Music/Microphone", false, { [weak self] in
                guard let self else {
                    return
                }
                self.controller?.open(section: .songs(artist: artist), library: self.library)
            }))
        }
        items.append(.separator)
        if case let .playlist(playlistId) = self.section, self.picker == nil {
            // Figma 247:17292: takes the track out of this playlist only, the track stays in Music.
            items.append(action(strings.Music_RemoveFromPlaylist, .singleLine, "Chat/Context Menu/Remove", true, {
                let messageId = track.message.id
                library.updatePlaylist(id: playlistId, { playlist in
                    playlist.trackIds.removeAll(where: { $0 == messageId })
                })
            }))
        }
        if self.isOwnProfile {
            items.append(action(strings.Music_RemoveFromProfile, .singleLine, "Music/RemoveFromProfile", true, { [weak controller] in
                controller?.setSavedToProfile(track: track, isSaved: false, library: library)
            }))
        } else {
            items.append(action(strings.Music_RemoveFromMusic, .singleLine, "Chat/Context Menu/Delete", true, { [weak controller] in
                library.remove(tracks: [track])
                controller?.presentRemovedFromMusicToast(count: 1)
            }))
        }

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
        switch row {
        case .songs:
            self.controller?.open(section: .songs(artist: nil), library: self.library)
        case .artists:
            self.controller?.open(section: .artists, library: self.library)
        case .playlists:
            self.controller?.open(section: .playlists(favoritesOnly: false), library: self.library)
        case .favorites:
            self.controller?.open(section: .favorites, library: self.library)
        }
    }

    private func hubTilesItem(iconPlayTokens: [MusicSection.Row: Int]) -> ListViewItem {
        let strings = self.presentationData.strings
        // Rows fill first, as in Figma: Tracks, Artists, then Playlists, Favorites.
        let rows: [(MusicSection.Row, MusicHubTile.Kind, String, String)] = [
            (.songs, .songs, strings.Music_Tracks, "anim_sound_on"),
            (.artists, .artists, strings.Music_Artists, "anim_vcspeak"),
            (.playlists, .playlists, strings.Music_Playlists, "anim_musicplaylists"),
            (.favorites, .favorites, strings.Music_Favorites, "anim_musicfavorites")
        ]
        let tiles = rows.map { MusicHubTile(kind: $0.1, title: $0.2, animation: $0.3, playToken: iconPlayTokens[$0.0] ?? 0) }
        return MusicHubTilesItem(theme: self.presentationData.theme, tiles: tiles, sideInset: 16.0, topInset: self.displaysTabSwitch ? MusicScreenNode.blockSpacing : 16.0, bottomInset: self.picker != nil ? MusicScreenNode.blockSpacing : 0.0, sectionId: 1, action: { [weak self] kind in
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

    /// The single full-width Playlists tile on top of Favorites: opens the favorite playlists.
    private func favoritePlaylistsTileItem() -> ListViewItem {
        let strings = self.presentationData.strings
        let tile = MusicHubTile(kind: .playlists, title: strings.Music_Playlists, animation: "anim_musicplaylists", playToken: 0)
        return MusicHubTilesItem(theme: self.presentationData.theme, tiles: [tile], sideInset: 16.0, topInset: 16.0, sectionId: 1, action: { [weak self] _ in
            guard let self else {
                return
            }
            self.controller?.open(section: .playlists(favoritesOnly: true), library: self.library)
        })
    }

    private func tabSwitchItem(isOn: Bool) -> ListViewItem {
        let strings = self.presentationData.strings
        return MusicGlassSwitchItem(presentationData: ItemListPresentationData(self.presentationData), title: strings.Music_MusicTab, value: isOn, sideInset: 16.0, topInset: 16.0, sectionId: 0, updated: { [weak self] value in
            guard let self else {
                return
            }
            self.isTabShown = value
            setMusicTabIsShown(context: self.context, value)
        })
    }

    private func tabFooterItem() -> ListViewItem {
        let strings = self.presentationData.strings
        return ItemListTextItem(presentationData: ItemListPresentationData(self.presentationData), text: .plain(strings.Music_ToOpenYourMusicFromMainMenu), sectionId: 0, style: .blocks, additionalInsets: UIEdgeInsets(top: 0.0, left: 16.0, bottom: 0.0, right: 16.0))
    }

    private func trackItem(track: MusicTrack, isSelected: Bool?, isFavorite: Bool, isPicked: Bool?, header: ListViewItemHeader?) -> ListViewItem {
        let presentationData = self.presentationData
        let chatPresentationData = musicChatPresentationData(presentationData)
        let interaction = ListMessageItemInteraction(openMessage: { [weak self] message, _ in
            self?.play(message: message)
            return true
        }, openMessageContextMenu: { [weak self] message, _, node, _, gesture in
            guard let self, !self.isSelecting, self.picker == nil, !self.isForeignProfile, let track = self.track(message: message) else {
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
            if let selection = self.controller?.attachmentSelection {
                selection.set(track, isSelected: isSelected)
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
        let revealOptions = isSelected == nil && isPicked == nil && !self.isForeignProfile ? self.revealOptions(track: track) : (left: [], right: [])
        var editControl: ListMessageItemEditControl?
        if let isPicked {
            let theme = presentationData.theme
            if let icon = isPicked ? MusicResources.removeControl(theme: theme) : MusicResources.addControl(theme: theme) {
                editControl = ListMessageItemEditControl(icon: icon, action: { [weak self] in
                    self?.picker?.toggle(track)
                })
            }
        }
        let isAttachment = self.controller?.attachmentSelection != nil
        let trailingIcon = isFavorite && isPicked == nil && (isSelected == nil || isAttachment) ? MusicResources.favoriteMark(theme: presentationData.theme) : nil
        var playingIndicator: ListMessageItemPlayingIndicator?
        if isPicked == nil, let playingTrack = self.playingTrack, track.file?.fileId.id == playingTrack.fileId {
            playingIndicator = playingTrack.isPaused ? .paused : .playing
        }
        // Play and Shuffle keep the space above the first track; a letter further down follows the previous row directly (Figma Songs / Sort).
        let blockTopInset: CGFloat = 0.0
        return ListMessageItem(presentationData: chatPresentationData, systemStyle: .glass, context: self.context, chatLocation: .peer(id: message.id.peerId), interaction: interaction, message: message, selection: selection, selectionSide: .left, displayHeader: false, customHeader: header, isGlobalSearchResult: !track.isSaved, isSavedMusic: track.isSaved, selectsOnControlOnly: isAttachment, displayFileInfo: true, audioInfo: .performer, hidesAudioFileExtension: true, additionalSideInset: 0.0, blockTopInset: blockTopInset, displayBackground: false, leftRevealOptions: revealOptions.left, rightRevealOptions: revealOptions.right, trailingIcon: trailingIcon, editControl: editControl, displaysAudioCover: true, playingIndicator: playingIndicator, style: .plain, sectionId: sectionId)
    }

    private func nameRowItem(id: String, name: String, subtitle: String? = nil, isFavorite: Bool = false, isLarge: Bool = false, isMedium: Bool = false, cover: TelegramMediaImageRepresentation? = nil, header: ListViewItemHeader?, isSelected: Bool? = nil, selectionAction: (() -> Void)? = nil, contextAction: ((ASDisplayNode, ContextGesture?) -> Void)? = nil, action: @escaping () -> Void) -> ListViewItem {
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
        return ContactsPeerItem(presentationData: ItemListPresentationData(presentationData), systemStyle: .glass, sectionId: 1, sortOrder: presentationData.nameSortOrder, displayOrder: presentationData.nameDisplayOrder, context: self.context, peerMode: .peer, peer: peer, status: status, enabled: true, selection: isSelected.flatMap { .selectable(selected: $0) } ?? .none, selectionPosition: .left, editing: ContactsPeerItemEditing(editable: false, editing: false, revealed: false), index: nil, header: header, hideBackground: true, action: { [weak self] _ in
            // As in the client's contact lists: the pressed fill goes away once the row opens its screen.
            self?.listNode.clearHighlightAnimated(true)
            action()
        }, contextAction: contextAction.flatMap { contextAction in
            return { node, gesture, _ in
                contextAction(node, gesture)
            }
        }, arrowAction: { [weak self] in
            self?.listNode.clearHighlightAnimated(true)
            action()
        }, arrowIsDisclosure: true, trailingIcon: isFavorite ? MusicResources.favoriteMark(theme: presentationData.theme) : nil, selectionAction: selectionAction, isLarge: isLarge, isMedium: isMedium)
    }

    private func playbackItem() -> ListViewItem {
        let strings = self.presentationData.strings
        return MusicPlaybackButtonsItem(theme: self.presentationData.theme, playTitle: strings.Music_Play2, shuffleTitle: strings.Music_Shuffle, sideInset: 16.0, topInset: self.section == .hub || self.section == .favorites ? MusicScreenNode.blockSpacing : 16.0, bottomInset: 16.0, sectionId: 3, action: { [weak self] shuffled in
            self?.playAll(shuffled: shuffled)
        })
    }

    private func addTracksItem() -> ListViewItem {
        let strings = self.presentationData.strings
        return ItemListDisclosureItem(presentationData: ItemListPresentationData(self.presentationData), systemStyle: .glass, icon: PresentationResourcesItemList.plusIconImage(self.presentationData.theme), title: strings.Music_AddTracks, titleColor: .accent, label: "", sectionId: 4, style: .blocks, disclosureStyle: .none, additionalSideInset: 16.0, blockTopInset: MusicScreenNode.blockSpacing, action: { [weak self] in
            guard let self, let playlist = self.currentPlaylist else {
                return
            }
            self.controller?.addTracks(to: playlist, library: self.library)
        })
    }

    /// The author's profile, pushed over the playlist: inside the sheet when the playlist was opened from a chat.
    private func openPlaylistAuthor() {
        guard let peer = self.playlistOwnerPeer, let navigationController = self.controller?.navigationController as? NavigationController else {
            return
        }
        guard let infoController = self.context.sharedContext.makePeerInfoController(context: self.context, updatedPresentationData: nil, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) else {
            return
        }
        navigationController.pushViewController(infoController)
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
        let topInset: CGFloat = self.picker != nil ? 16.0 : (!hasDescription && !self.isPlaylistHeaderExpanded ? 8.0 : 16.0)
        let pickerAddTitle: String? = self.picker != nil ? strings.Music_AddThisPlaylist : nil
        return MusicPlaylistActionsItem(theme: self.presentationData.theme, isEmpty: isEmpty, isFavorite: isFavorite, playTitle: strings.Music_Play2, addTracksTitle: strings.Music_AddTracks, pickerAddTitle: pickerAddTitle, topInset: topInset, bottomInset: 16.0, sectionId: 3, action: { [weak self] action in
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
            case .addAll:
                self.picker?.add(self.currentTracks)
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
        self.controller?.play(track: first, tracks: tracks, library: self.library, source: shuffled ? nil : self.queueSource())
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
                    title: playlist.isInProfile ? strings.Music_Remove : strings.Music_ToProfile,
                    iconName: playlist.isInProfile ? "Music/RemoveFromProfile" : "Peer Info/SaveMusic",
                    action: { [weak controller] in
                        controller?.setInProfile(playlist: playlist, isInProfile: !playlist.isInProfile, library: library)
                    }
                ),
                MusicTrackActionsContextItem.Action(
                    title: playlist.isFavorite ? strings.Music_Unfavorite : strings.Music_Favorite,
                    iconName: playlist.isFavorite ? "Music/StarSlash" : "Music/Star",
                    action: { [weak controller] in
                        controller?.setFavorite(playlist: playlist, isFavorite: !playlist.isFavorite, library: library)
                    }
                ),
                MusicTrackActionsContextItem.Action(
                    title: strings.Music_Share,
                    iconName: "Music/ShareFilled",
                    action: { [weak controller] in
                        controller?.share(playlist: playlist, library: library)
                    }
                )
            ]), false),
            .separator,
            action(strings.Music_Edit, "Chat/Context Menu/Edit", false, { [weak controller] in
                controller?.editPlaylist(playlist, library: library)
            }),
            .separator,
            action(strings.Music_AddToPlaylist2, "Chat/Context Menu/AddCaption", false, { [weak controller] in
                controller?.addToPlaylist(tracks: library.tracks(of: playlist), excluding: playlist.id, library: library)
            }),
            action(strings.Music_PlayNext2, "Chat/Context Menu/MoveUp", false, { [weak controller] in
                controller?.enqueue(playlist: playlist, next: true, library: library)
            }),
            action(strings.Music_AddToQueue, "Chat/Context Menu/MoveDown", false, { [weak controller] in
                controller?.enqueue(playlist: playlist, next: false, library: library)
            }),
            .separator,
            action(strings.Music_Play, "Chat/Context Menu/Play", false, { [weak controller] in
                controller?.play(playlist: playlist, shuffled: false, library: library)
            }),
            action(strings.Music_Shuffle, "Music/Shuffle", false, { [weak controller] in
                controller?.play(playlist: playlist, shuffled: true, library: library)
            }),
            .separator,
            self.isOwnProfile ? action(strings.Music_RemoveFromProfile, "Music/RemoveFromProfile", true, { [weak controller] in
                controller?.setInProfile(playlist: playlist, isInProfile: false, library: library)
            }) : action(strings.Music_RemoveFromMusic, "Chat/Context Menu/Delete", true, { [weak controller] in
                controller?.confirmRemoval(playlist: playlist, library: library)
            })
        ]
        let contextController = makeContextController(presentationData: self.presentationData, source: .extracted(MusicTrackContextExtractedContentSource(contentNode: sourceNode)), items: .single(ContextController.Items(content: .list(items))), recognizer: nil, gesture: gesture)
        controller.presentInGlobalOverlay(contextController)
    }

    private func item(entry: MusicListEntry) -> ListViewItem {
        var header: ListViewItemHeader?
        if let letter = entry.letter {
            var actionTitle: String?
            var action: ((ASDisplayNode) -> Void)?
            if let category = self.searchCategory(header: letter), self.searchCategoriesWithMore.contains(category) {
                let strings = self.presentationData.strings
                actionTitle = self.expandedSearchCategories.contains(category) ? strings.ChatList_Search_ShowLess : strings.ChatList_Search_ShowMore
                action = { [weak self] _ in
                    self?.toggleSearchCategory(category)
                }
            }
            header = ChatListSearchItemHeader(type: .text(letter, AnyHashable(letter)), theme: self.presentationData.theme, strings: self.presentationData.strings, actionTitle: actionTitle, action: action)
        }
        switch entry.content {
        case let .tabSwitch(isOn):
            return self.tabSwitchItem(isOn: isOn)
        case .tabFooter:
            return self.tabFooterItem()
        case let .hubTiles(iconPlayTokens):
            return self.hubTilesItem(iconPlayTokens: iconPlayTokens)
        case .favoritePlaylistsTile:
            return self.favoritePlaylistsTileItem()
        case .playback:
            return self.playbackItem()
        case .addTracks:
            return self.addTracksItem()
        case .newPlaylist:
            return MusicAddTracksButtonItem(theme: self.presentationData.theme, title: self.presentationData.strings.Music_NewPlaylist2, sideInset: 16.0, topInset: 0.0, bottomInset: 16.0, sectionId: 1, action: { [weak self] in
                guard let self else {
                    return
                }
                self.controller?.createPlaylistFromChooser(library: self.library)
            })
        case let .emptyInfo(text):
            return ItemListTextItem(presentationData: ItemListPresentationData(self.presentationData), text: .plain(text), sectionId: 0, style: .blocks, additionalInsets: UIEdgeInsets(top: 16.0, left: 16.0, bottom: 0.0, right: 16.0))
        case let .playlistHeaderSpacer(height):
            return MusicPlaylistSpacerItem(height: height)
        case let .playlistInfo(text):
            return MusicPlaylistInfoItem(presentationData: ItemListPresentationData(self.presentationData), label: self.presentationData.strings.Music_Description2, text: text, sectionId: 4)
        case let .playlistActions(isEmpty, isFavorite):
            return self.playlistActionsItem(isEmpty: isEmpty, isFavorite: isFavorite)
        case let .track(track, isSelected, isFavorite, isPicked):
            return self.trackItem(track: track, isSelected: isSelected, isFavorite: isFavorite, isPicked: isPicked, header: header)
        case let .artist(artist):
            return self.nameRowItem(id: artist.name, name: artist.name, isMedium: true, header: header, action: { [weak self] in
                guard let self else {
                    return
                }
                if self.isScopedSearchActive {
                    self.library.noteSearched(artist: artist)
                }
                self.controller?.open(section: .songs(artist: artist.name), library: self.library)
            })
        case let .playlist(playlist, subtitle):
            let contextAction: ((ASDisplayNode, ContextGesture?) -> Void)? = self.picker == nil && self.playlistChooser == nil && !self.isForeignProfile ? { [weak self] node, gesture in
                guard let self, let playlist = self.library.playlist(id: playlist.id) else {
                    return
                }
                self.presentContextMenu(playlist: playlist, node: node, gesture: gesture)
            } : nil
            // In the attachment menu the checkmark's column picks the playlist for sending; the row still opens it.
            var selectionAction: (() -> Void)?
            var isSelected: Bool?
            if let selection = self.controller?.attachmentSelection, self.playlistChooser == nil {
                isSelected = selection.contains(playlistId: playlist.id)
                selectionAction = { [weak selection] in
                    selection?.toggle(playlistId: playlist.id)
                }
            }
            return self.nameRowItem(id: "\(playlist.id)", name: playlist.title, subtitle: subtitle, isFavorite: playlist.isFavorite, isLarge: true, cover: playlist.cover, header: header, isSelected: isSelected, selectionAction: selectionAction, contextAction: contextAction, action: { [weak self] in
                guard let self else {
                    return
                }
                if self.playlistChooser != nil {
                    self.controller?.choosePlaylist(playlist)
                    return
                }
                if self.isScopedSearchActive {
                    self.library.noteSearched(playlist: playlist)
                }
                self.controller?.open(section: .playlist(playlist.id), library: self.library)
            })
        }
    }

    private func updateList(allUpdated: Bool = false, scrollToTop: Bool = false, keepingTopOffset: CGFloat? = nil, animated: Bool = false) {
        guard self.validLayout != nil else {
            return
        }
        let entries = self.makeEntries()
        let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: self.entries, rightList: entries, allUpdated: allUpdated)
        self.entries = entries

        var scrollToItem: ListViewScrollToItem?
        if scrollToTop && !entries.isEmpty {
            scrollToItem = ListViewScrollToItem(index: 0, position: .top(-self.navigationScrollOffset), animated: false, curve: .Default(duration: nil), directionHint: .Up)
        } else if let keepingTopOffset, !entries.isEmpty {
            scrollToItem = ListViewScrollToItem(index: 0, position: .top(-keepingTopOffset), animated: false, curve: .Default(duration: nil), directionHint: .Up)
        }
        self.listNode.transaction(
            deleteIndices: deleteIndices.map { ListViewDeleteItem(index: $0, directionHint: nil) },
            insertIndicesAndItems: indicesAndItems.map { ListViewInsertItem(index: $0.0, previousIndex: $0.2, item: self.item(entry: $0.1), directionHint: nil) },
            updateIndicesAndItems: updateIndices.map { ListViewUpdateItem(index: $0.0, previousIndex: $0.2, item: self.item(entry: $0.1), directionHint: nil) },
            options: animated ? [.Synchronous, .LowLatency, .AnimateInsertion] : [.Synchronous, .LowLatency],
            scrollToItem: scrollToItem,
            updateOpaqueState: nil
        )
        self.updateIndex(transition: animated ? .animated(duration: 0.3, curve: .easeInOut) : .immediate)
        self.updateEmptyState(transition: animated ? .easeInOut(duration: 0.3) : .immediate)
    }

    /// The client's empty state (EmptyStateIndicatorComponent) centred between the bar and the bottom panels:
    /// on the hub choose the source chats or upload a track of one's own, on Playlists create one, on Favorites
    /// only what the screen is for.
    private func updateEmptyState(transition: ComponentTransition) {
        guard let emptyState = self.emptyState, let layout = self.validLayout, let navigationBarHeight = self.navigationBarView.view?.bounds.height else {
            if let emptyStateView = self.emptyStateView?.view {
                self.emptyStateView = nil
                transition.setAlpha(view: emptyStateView, alpha: 0.0, completion: { [weak emptyStateView] _ in
                    emptyStateView?.removeFromSuperview()
                })
            }
            return
        }
        let strings = self.presentationData.strings
        var emptyStateTransition = transition
        let emptyStateView: ComponentView<Empty>
        if let current = self.emptyStateView {
            emptyStateView = current
        } else {
            emptyStateView = ComponentView()
            self.emptyStateView = emptyStateView
            emptyStateTransition = .immediate
        }
        let title: String
        let text: String
        let actionTitle: String?
        switch emptyState {
        case .hub:
            title = strings.Music_EmptyTitle
            text = strings.Music_EmptyText
            actionTitle = strings.Music_ChooseChats
        case .playlists:
            title = strings.Music_NoPlaylistsTitle
            text = strings.Music_NoPlaylistsText
            actionTitle = strings.Music_CreatePlaylist
        case .favorites:
            title = strings.Music_NoFavoritesTitle
            text = strings.Music_NoFavoritesText
            actionTitle = nil
        }
        let bottomInset = layout.insets(options: []).bottom
        let size = CGSize(width: layout.size.width - layout.safeInsets.left - layout.safeInsets.right, height: max(0.0, layout.size.height - navigationBarHeight - bottomInset))
        let _ = emptyStateView.update(
            transition: emptyStateTransition,
            component: AnyComponent(EmptyStateIndicatorComponent(
                context: self.context,
                theme: self.presentationData.theme,
                fitToHeight: false,
                animationName: nil,
                title: title,
                text: text,
                actionTitle: actionTitle,
                action: { [weak self] in
                    guard let self else {
                        return
                    }
                    switch emptyState {
                    case .hub:
                        self.controller?.chooseSourceChats()
                    case .playlists:
                        self.controller?.createPlaylist(library: self.library, completion: nil)
                    case .favorites:
                        break
                    }
                },
                additionalActionTitle: emptyState == .hub ? strings.Music_UploadTrack : nil,
                additionalAction: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.controller?.addTrack(library: self.library)
                }
            )),
            environment: {},
            containerSize: size
        )
        if let view = emptyStateView.view {
            if view.superview == nil {
                self.view.insertSubview(view, aboveSubview: self.listNode.view)
                if !transition.animation.isImmediate {
                    view.alpha = 0.0
                }
            }
            emptyStateTransition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: layout.safeInsets.left, y: navigationBarHeight), size: size))
            transition.setAlpha(view: view, alpha: 1.0)
        }
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
        // In search only the Artists tab keeps its letters; the other tabs' headers name categories.
        let hasIndex = !self.isScopedSearchActive || self.searchScope == .artists
        for entry in self.entries where hasIndex {
            if let letter = entry.letter, !sections.contains(letter) {
                sections.append(letter)
            }
        }
        let insets = layout.insets(options: [.input])
        let frame = CGRect(x: layout.size.width - layout.safeInsets.right - 20.0, y: navigationBarHeight, width: 20.0, height: layout.size.height - navigationBarHeight - insets.bottom)
        transition.updateFrame(node: self.indexNode, frame: frame)
        self.indexNode.update(size: frame.size, color: self.presentationData.theme.list.itemAccentColor, sections: sections, transition: transition)
        self.indexNode.isUserInteractionEnabled = !sections.isEmpty
        // The index fades in and out with a sort by title or artist instead of popping.
        transition.updateAlpha(node: self.indexNode, alpha: sections.isEmpty ? 0.0 : 1.0)
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
            return strings.Music_Title
        case .dateAdded:
            return strings.Music_DateAdded
        case .artist:
            return strings.Music_Artist3
        case .lastPlayed:
            return strings.Music_LastPlayed
        case .dateUpdated:
            return strings.Music_DateUpdated
        case .playlistOrder:
            return strings.Music_PlaylistOrder
        }
    }

    private func sortOrderTitle() -> String {
        let strings = self.presentationData.strings
        switch self.sorting.key {
        case .title, .artist:
            return self.sorting.ascending ? strings.Music_AZ : strings.Music_ZA
        case .playlistOrder:
            return self.sorting.ascending ? strings.Music_AsAdded : strings.Music_Reversed
        case .dateAdded, .lastPlayed, .dateUpdated:
            return self.sorting.ascending ? strings.Music_OldestFirst : strings.Music_NewestFirst
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
            items.append(.action(ContextMenuActionItem(text: strings.Music_SelectTracks, icon: { theme in
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
                self.updateList(scrollToTop: true, animated: true)
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
            playlist.isInProfile ? action(strings.Music_RemoveFromProfile, "Chat/Context Menu/Remove", false, { [weak controller] in
                controller?.setInProfile(playlist: playlist, isInProfile: false, library: library)
            }) : action(strings.Music_AddToProfile, "Music/AddToProfile", false, { [weak controller] in
                controller?.setInProfile(playlist: playlist, isInProfile: true, library: library)
            }),
            .separator,
            action(strings.Music_Edit, "Chat/Context Menu/Edit", false, { [weak controller] in
                controller?.editPlaylist(playlist, library: library)
            })
        ]
        if hasTracks {
            // Sorting opens as a submenu, the way the client's menus step into a second level.
            items.append(.action(ContextMenuActionItem(text: strings.Music_Sort, icon: { theme in
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
            items.append(action(strings.Music_AddToPlaylist2, "Chat/Context Menu/AddCaption", false, { [weak controller] in
                controller?.addToPlaylist(tracks: library.tracks(of: playlist), excluding: playlist.id, library: library)
            }))
            items.append(action(strings.Music_PlayNext2, "Chat/Context Menu/MoveUp", false, { [weak controller] in
                controller?.enqueue(playlist: playlist, next: true, library: library)
            }))
            items.append(action(strings.Music_AddToQueue, "Chat/Context Menu/MoveDown", false, { [weak controller] in
                controller?.enqueue(playlist: playlist, next: false, library: library)
            }))
        }
        items.append(.separator)
        items.append(action(strings.Music_RemoveFromMusic, "Chat/Context Menu/Delete", true, { [weak controller] in
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
                self.updateList(animated: true)
            }))
        }
        return items
    }

    private func headerContent() -> ChatListHeaderComponent.Content {
        let strings = self.presentationData.strings

        let addButton = NavigationBarComponent.Button(
            id: "add",
            content: .icon(imageName: "Music/AddTrack"),
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
            title = artist ?? strings.Music_Tracks
            rightButtons = [addButton, sortButton]
        case .favorites:
            title = strings.Music_Favorites
            rightButtons = [sortButton]
        case .artists:
            title = strings.Music_Artists
            rightButtons = []
        case .playlists:
            title = self.playlistChooser != nil ? strings.Music_AddToPlaylist2 : strings.Music_Playlists
            rightButtons = [
                sortButton,
                NavigationBarComponent.Button(id: "create", content: .icon(imageName: "Chat List/AddIcon"), action: { [weak self] _ in
                    guard let self else {
                        return
                    }
                    self.controller?.createPlaylist(library: self.library, completion: nil)
                })
            ]
        case .profile:
            title = musicProfileLibraryTitle(strings: strings)
            rightButtons = []
        case .playlist:
            title = self.currentPlaylist?.title ?? strings.Music_Playlist
            rightButtons = [
                NavigationBarComponent.Button(id: "editPlaylist", content: .text(title: strings.Music_Edit2, isBold: false), action: { [weak self] _ in
                    guard let self, let playlist = self.currentPlaylist else {
                        return
                    }
                    self.controller?.editPlaylist(playlist, library: self.library)
                })
            ]
        }

        if self.controller?.attachmentSelection != nil {
            // In the attachment menu every list selects already.
            rightButtons.removeAll(where: { $0.id == AnyHashable("select") })
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
        } else if self.playlistChooser != nil {
            // Add to Playlist: New Playlist is the list's first row; the sheet closes with Cancel.
            rightButtons = [sortButton]
            leftButton = NavigationBarComponent.Button(
                id: "cancel",
                content: .text(title: strings.Common_Cancel, isBold: false),
                action: { [weak self] _ in
                    self?.controller?.closePlaylistChooser()
                }
            )
        } else if self.isSelecting {
            rightButtons = []
            leftButton = NavigationBarComponent.Button(
                id: "done",
                content: .text(title: strings.Common_Done, isBold: true),
                action: { [weak self] _ in
                    self?.setSelecting(false)
                }
            )
        } else if let close = self.controller?.attachmentClose {
            leftButton = NavigationBarComponent.Button(
                id: "close",
                content: .icon(imageName: "Navigation/Close"),
                action: { _ in
                    close()
                }
            )
        } else if self.controller?.mode == .tab {
            // Figma Music / Default 86:7448: the check icon from the Settings hub replaces Edit.
            leftButton = selectButton
        } else {
            backPressed = { [weak self] in
                self?.controller?.goBack()
            }
        }

        var titleComponent: AnyComponent<Empty>?
        if case .playlists(favoritesOnly: true) = self.section, self.picker == nil {
            // The section's title over the list it belongs to (Figma 239:16727), in the sizes of the collapsed playlist
            // header and the client's chat title: semibold 17 over regular 13, 1 pt apart.
            let listTheme = self.presentationData.theme.list
            titleComponent = AnyComponent(VStack([
                AnyComponentWithIdentity(id: "title", component: AnyComponent(MultilineTextComponent(
                    text: .plain(NSAttributedString(string: title, font: Font.semibold(17.0), textColor: listTheme.itemPrimaryTextColor)),
                    maximumNumberOfLines: 1
                ))),
                AnyComponentWithIdentity(id: "subtitle", component: AnyComponent(MultilineTextComponent(
                    text: .plain(NSAttributedString(string: strings.Music_Favorites, font: Font.regular(13.0), textColor: listTheme.itemSecondaryTextColor)),
                    maximumNumberOfLines: 1
                )))
            ], spacing: 1.0))
        }

        return ChatListHeaderComponent.Content(
            title: title,
            titleComponent: titleComponent,
            chatListTitle: nil,
            leftButton: leftButton,
            rightButtons: rightButtons,
            backPressed: backPressed
        )
    }

    /// The sheet's prompt line (iOS 27 Prompt): "Add to “Playlist”" above the bar's row.
    private var pickerPromptInset: CGFloat {
        return self.picker != nil ? MusicScreenNode.pickerPromptHeight : 0.0
    }

    private func updatePickerPrompt(layout: ContainerViewLayout) {
        guard let picker = self.picker else {
            return
        }
        let strings = self.presentationData.strings
        let theme = self.presentationData.theme
        if self.pickerPromptNode.supernode == nil {
            self.pickerPromptNode.maximumNumberOfLines = 1
            self.pickerPromptNode.truncationType = .end
        }
        // Above the bar's glass and edge effect, which are added later and would otherwise blur it.
        if self.pickerPromptNode.supernode == nil {
            self.addSubnode(self.pickerPromptNode)
        }
        self.view.bringSubviewToFront(self.pickerPromptNode.view)
        self.pickerPromptNode.attributedText = NSAttributedString(string: strings.Music_AddTo(picker.playlistTitle).string, font: Font.regular(12.0), textColor: theme.rootController.navigationBar.primaryTextColor)
        let size = self.pickerPromptNode.updateLayout(CGSize(width: layout.size.width - 120.0, height: 20.0))
        self.pickerPromptNode.frame = CGRect(origin: CGPoint(x: floor((layout.size.width - size.width) / 2.0), y: (layout.navigationBarStatusBarHeight ?? 0.0) + 12.0), size: size)
    }

    private func searchPlaceholder() -> String? {
        let strings = self.presentationData.strings
        switch self.section {
        case .hub:
            return nil
        case .songs:
            return strings.Music_SearchTracks
        case .favorites:
            return strings.Music_SearchFavorites
        case .artists:
            return strings.Music_SearchArtists
        case .playlists:
            return strings.Music_SearchPlaylists
        case .playlist:
            return strings.Music_SearchPlaylist
        case .profile:
            return strings.Music_SearchLibrary
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

        var tabs: AnyComponent<Empty>?
        if self.hasProfileTabs && self.playlistSearchQuery == nil {
            // Tracks and Playlists as the chat list's folder tabs, under the bar.
            let strings = self.presentationData.strings
            tabs = AnyComponent(HorizontalTabsComponent(
                context: self.context,
                theme: self.presentationData.theme,
                tabs: [
                    (MusicProfileTab.tracks, strings.Music_Tracks),
                    (MusicProfileTab.playlists, strings.Music_Playlists)
                ].map { item -> HorizontalTabsComponent.Tab in
                    let (tab, title) = item
                    return HorizontalTabsComponent.Tab(
                        id: AnyHashable(tab.rawValue),
                        content: .title(HorizontalTabsComponent.Tab.Title(text: title, entities: [], enableAnimations: false)),
                        badge: nil,
                        action: { [weak self] in
                            self?.selectProfileTab(tab)
                        }
                    )
                },
                selectedTab: AnyHashable(self.profileTab.rawValue),
                isEditing: false
            ))
        }

        return AnyComponent(HeaderPanelContainerComponent(
            theme: self.presentationData.theme,
            tabs: tabs,
            panels: panels
        ))
    }

    private func selectProfileTab(_ tab: MusicProfileTab) {
        guard self.profileTab != tab else {
            return
        }
        self.profileTab = tab
        self.updateList(scrollToTop: true, animated: true)
        self.controller?.requestLayout(transition: .animated(duration: 0.4, curve: .spring))
    }

    func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        let isFirstLayout = self.validLayout == nil
        self.validLayout = layout

        let componentTransition = ComponentTransition(transition)
        if self.isPlaylistScreen {
            self.playlistContainerLayoutUpdated(layout, isFirstLayout: isFirstLayout, transition: transition)
            return
        }
        self.updatePickerPrompt(layout: layout)
        let navigationBarSize = self.navigationBarView.update(
            transition: componentTransition,
            component: AnyComponent(ChatListNavigationBar(
                context: self.context,
                theme: self.presentationData.theme,
                strings: self.presentationData.strings,
                statusBarHeight: (layout.navigationBarStatusBarHeight ?? 0.0) + self.pickerPromptInset,
                leftInset: layout.safeInsets.left,
                rightInset: layout.safeInsets.right,
                trailingButtonsInset: layout.navigationBarTrailingButtonsInset,
                search: ChatListNavigationBar.Search(isEnabled: true, placeholder: self.searchPlaceholder()),
                activeSearch: self.playlistSearchQuery != nil ? ChatListNavigationBar.ActiveSearch(isExternal: false) : nil,
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
                // The bar's fade defaults to the chat list's white; Music lists sit on the pinned grey.
                edgeEffectColor: self.backgroundColor(theme: self.presentationData.theme),
                activateSearch: { [weak self] _ in
                    self?.setPlaylistSearchActive(true)
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
                if self.picker != nil, self.pickerPromptNode.supernode != nil {
                    self.view.bringSubviewToFront(self.pickerPromptNode.view)
                }
            }
            componentTransition.setFrame(view: navigationBarComponentView, frame: CGRect(origin: CGPoint(), size: navigationBarSize))
        }

        // While searching the bar takes the client's active-search state and its search bar grows out of the field (Figma Search, 251:22733).
        let isSearching = self.playlistSearchQuery != nil
        let removedSearchBar = self.updateSearchBar(layout: layout, navigationHeight: navigationBarSize.height, transition: componentTransition)

        var insets = layout.insets(options: [.input])
        insets.top = navigationBarSize.height
        if !isSearching && ((self.startsWithPlayback && self.picker == nil) || self.section == .hub) {
            // The first block's own top inset is for a list under a plain bar.
            insets.top -= 16.0
            if !self.displaysTabSwitch {
                // The first block keeps 16 pt from the player or the search field (Figma Music / Default, Songs / Default):
                // the bar ends 3 pt below the player, and the search field reaches 3 pt past the bar's end.
                insets.top += self.controller?.globalControlPanelsContextState?.mediaPlayback != nil ? 13.0 : 3.0
            }
        }
        if !isSearching && self.playlistChooser != nil {
            // New Playlist has no top inset of its own: like Play/Shuffle it keeps 16 pt from the player or the
            // search field (the bar ends 3 pt below the player; the field reaches 3 pt past the bar's end).
            insets.top += self.controller?.globalControlPanelsContextState?.mediaPlayback != nil ? 13.0 : 19.0
        }
        if !isSearching && self.hasProfileTabs {
            // The profile's tabs are the bar's lowest part (under them only the player, in the same glass, which ends
            // 3 pt above the bar's end): the first block keeps 16 pt from that glass, its own top inset.
            insets.top = navigationBarSize.height - 3.0
            if self.profileTab == .playlists && !self.profilePlaylists.isEmpty {
                // Playlist rows have no top inset of their own; Play/Shuffle and the empty text do.
                insets.top += 16.0
            }
        }
        insets.left = layout.safeInsets.left
        insets.right = layout.safeInsets.right
        if self.hasAlphabetSections && self.section == .artists {
            // Figma Artists / Main (99:10634): rows run under the 16 pt index, the arrow ends 4 pt before it (20 pt from the edge).
            insets.right += 8.0
        }
        if self.isSelecting && self.controller?.mode == .navigation {
            insets.bottom = self.selectionPanelBottomInset(layout: layout) + MusicScreenNode.selectionPanelHeight + 8.0
        }
        if let filtersFrame = self.updateSearchFilters(layout: layout, transition: transition) {
            // The last results stay clear of the scope tabs.
            insets.bottom = max(insets.bottom, layout.size.height - filtersFrame.minY + 8.0)
        }
        transition.updateFrame(node: self.listNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: layout.size, insets: insets, duration: duration, curve: curve), updateOpaqueState: nil)
        if isFirstLayout {
            self.updateList()
        }
        self.updateIndex(transition: transition)
        self.updateEmptyState(transition: componentTransition)
        self.updateSelectionPanel(layout: layout, transition: transition)

        self.applyNavigationScroll(transition: componentTransition)
        // The bar has its field back in place only now, so the search bar folds into where the field ends up.
        if let removedSearchBar {
            self.view.bringSubviewToFront(removedSearchBar.view)
            if !transition.isAnimated {
                removedSearchBar.view.removeFromSuperview()
            } else if let placeholderNode = (self.navigationBarView.view as? ChatListNavigationBar.View)?.searchContentNode?.placeholderNode {
                removedSearchBar.transitionOut(to: placeholderNode, transition: transition, completion: { [weak removedSearchBar] in
                    removedSearchBar?.view.removeFromSuperview()
                })
            } else {
                removedSearchBar.view.removeFromSuperview()
            }
        }
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
        } else if self.displaysPlaylistPlaybackPanel {
            // The last track clears the player by the same 8 pt as the selection toolbar.
            insets.bottom = max(insets.bottom, self.selectionPanelBottomInset(layout: layout) + MusicScreenNode.playlistPlaybackPanelHeight + 8.0)
        }
        transition.updateFrame(node: self.listNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], updateSizeAndInsets: ListViewUpdateSizeAndInsets(size: layout.size, insets: insets, duration: duration, curve: curve), updateOpaqueState: nil)
        if isFirstLayout {
            self.updateList()
        }
        self.updateSelectionPanel(layout: layout, transition: transition)
        self.updatePlaylistPlaybackPanel(layout: layout, transition: transition)
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
        // A sheet over a chat is away from the Dynamic Island: there the round avatar is not clipped into it but
        // scrolls on under the bar's blur and gradient, as content under any sheet's bar.
        let isSheet = self.controller?.navigationPresentation == .modal
        let headerHeight = MusicPlaylistHeaderView.height(width: layout.size.width, statusBarHeight: layout.statusBarHeight ?? 0.0, isExpanded: isExpanded)
        headerView.frame = CGRect(origin: CGPoint(), size: CGSize(width: layout.size.width, height: layout.size.height))
        // In the Music section the status is the track count alone; in the sheet from a chat it names the author first,
        // as a forwarded message does.
        let trackCountText = musicTrackCountString(self.presentationData.strings, self.library.tracks(of: playlist).count)
        var headerAuthor: MusicPlaylistHeaderView.Author?
        if isSheet, let peer = self.playlistOwnerPeer {
            let nameColor: UIColor
            switch peer.nameColor {
            case let .preset(color):
                nameColor = self.context.peerNameColors.get(color, dark: theme.overallDarkAppearance).main
            case let .collectible(color):
                nameColor = color.mainColor(dark: theme.overallDarkAppearance)
            default:
                nameColor = theme.list.itemAccentColor
            }
            headerAuthor = MusicPlaylistHeaderView.Author(context: self.context, peer: peer, name: self.playlistOwnerName, nameColor: nameColor, suffix: " • " + trackCountText)
        }
        headerView.update(theme: theme, title: playlist.title, subtitle: trackCountText, author: headerAuthor, cover: self.playlistCoverImage, coverMarkup: playlist.coverMarkup.flatMap { (self.context, $0) }, isExpanded: isExpanded, size: layout.size, statusBarHeight: layout.statusBarHeight ?? 0.0, hasDynamicIsland: layout.deviceMetrics.hasDynamicIsland && !isSheet, offset: offset, transition: headerTransition)

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
                    // As a sheet over a chat the playlist closes rather than goes back.
                    items: [GlassControlGroupComponent.Item(id: AnyHashable("back"), content: .icon(self.controller?.navigationPresentation == .modal ? "Navigation/Close" : "Navigation/Back"), action: { [weak self] in
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
        if !isActive {
            // The keyboard leaves together with the bar, as in the client's searches: resign before the layout drops the node.
            self.searchBarNode?.deactivate(clear: true)
            self.view.endEditing(true)
        }
        self.playlistSearchQuery = isActive ? "" : nil
        self.searchScope = self.defaultSearchScope
        self.expandedSearchCategories.removeAll()
        self.updateList(allUpdated: true, scrollToTop: true, animated: true)
        self.containerLayoutUpdated(layout, transition: .animated(duration: 0.4, curve: .spring))
        if isActive, let panelView = self.playlistSearchPanel?.view as? SearchInputPanelComponent.View {
            panelView.activateInput()
        }
    }

    /// How far below its open place the field starts: at the bar's own search field, or just under a playlist's bar.
    private func searchPanelRestingOffset(layout: ContainerViewLayout) -> CGFloat {
        if !self.isPlaylistScreen, let barView = self.navigationBarView.view {
            return max(0.0, barView.bounds.height - (layout.statusBarHeight ?? 0.0) - MusicScreenNode.playlistSearchPanelHeight - self.navigationScrollOffset)
        }
        return 16.0
    }

    /// The scope tabs' frame: the chat list search's filter bar metrics, 8 pt above the keyboard,
    /// or concentric with the screen corner when the keyboard is down.
    private func searchFiltersFrame(layout: ContainerViewLayout) -> CGRect {
        let bottomInset = layout.insets(options: [.input]).bottom
        var filtersInsets = UIEdgeInsets(top: 0.0, left: 12.0, bottom: bottomInset, right: 12.0)
        if filtersInsets.bottom == 84.0 {
            filtersInsets.bottom -= 6.0
        }
        if bottomInset <= 30.0 {
            filtersInsets = ContainerViewLayout.concentricInsets(bottomInset: bottomInset, innerDiameter: 40.0, sideInset: 32.0)
        } else if bottomInset <= 84.0 {
            filtersInsets.left = 20.0
            filtersInsets.right = filtersInsets.left
        } else {
            if let inputHeight = layout.inputHeight, filtersInsets.bottom == inputHeight {
                filtersInsets.bottom += 8.0
            }
            filtersInsets.bottom = max(8.0, filtersInsets.bottom)
        }
        let height: CGFloat = 40.0
        let minY = layout.size.height - filtersInsets.bottom - height
        let sideInsets = layout.sideInsets(forBandFrom: minY, to: minY + height)
        let left = sideInsets.left + filtersInsets.left
        let right = sideInsets.right + filtersInsets.right
        return CGRect(origin: CGPoint(x: left, y: minY), size: CGSize(width: layout.size.width - left - right, height: height))
    }

    /// Shows the scope tabs while a scoped search is open; returns their frame.
    @discardableResult
    private func updateSearchFilters(layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) -> CGRect? {
        guard self.isScopedSearchActive else {
            if let searchFiltersNode = self.searchFiltersNode {
                self.searchFiltersNode = nil
                if transition.isAnimated {
                    transition.updateAlpha(node: searchFiltersNode, alpha: 0.0, completion: { [weak searchFiltersNode] _ in
                        searchFiltersNode?.removeFromSupernode()
                    })
                } else {
                    searchFiltersNode.removeFromSupernode()
                }
            }
            return nil
        }
        let frame = self.searchFiltersFrame(layout: layout)
        let searchFiltersNode: ChatListSearchFiltersContainerNode
        var nodeTransition = transition
        if let current = self.searchFiltersNode {
            searchFiltersNode = current
        } else {
            nodeTransition = .immediate
            searchFiltersNode = ChatListSearchFiltersContainerNode()
            searchFiltersNode.customFilterPressed = { [weak self] id in
                guard let self, let scope = MusicSearchScope(rawValue: id) else {
                    return
                }
                self.selectSearchScope(scope)
            }
            self.searchFiltersNode = searchFiltersNode
            self.addSubnode(searchFiltersNode)
            searchFiltersNode.frame = frame
            if transition.isAnimated {
                searchFiltersNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
            }
        }
        nodeTransition.updateFrame(node: searchFiltersNode, frame: frame)
        self.updateSearchFiltersContent(size: frame.size, transition: nodeTransition)
        return frame
    }

    private func updateSearchFiltersContent(size: CGSize, transition: ContainedViewLayoutTransition) {
        guard let searchFiltersNode = self.searchFiltersNode else {
            return
        }
        let filters = MusicSearchScope.allCases.map { scope -> ChatListSearchFilterEntry in
            return .custom(id: scope.rawValue, title: self.searchScopeTitle(scope))
        }
        searchFiltersNode.update(size: size, sideInset: 0.0, filters: filters, displayGlobalPostsNewBadge: false, selectedFilter: .custom(self.searchScope.rawValue), transitionFraction: 0.0, presentationData: self.presentationData, transition: transition)
    }

    private func selectSearchScope(_ scope: MusicSearchScope) {
        guard self.searchScope != scope, let layout = self.validLayout else {
            return
        }
        self.searchScope = scope
        self.expandedSearchCategories.removeAll()
        if let searchBarNode = self.searchBarNode {
            let searchBarTheme = SearchBarNodeTheme(theme: self.presentationData.theme, hasSeparator: false)
            searchBarNode.placeholderString = NSAttributedString(string: self.searchScopePlaceholder(), font: Font.regular(17.0), textColor: searchBarTheme.placeholder)
        }
        self.updateSearchFiltersContent(size: self.searchFiltersFrame(layout: layout).size, transition: .animated(duration: 0.4, curve: .spring))
        self.updateList(scrollToTop: true)
    }

    /// Returns the search bar that has just closed; the caller folds it once the bar is laid out.
    private func updateSearchBar(layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ComponentTransition) -> SearchBarNode? {
        let placeholderNode = (self.navigationBarView.view as? ChatListNavigationBar.View)?.searchContentNode?.placeholderNode
        if self.playlistSearchQuery != nil {
            let searchBarNode: SearchBarNode
            var searchBarTransition = transition
            if let current = self.searchBarNode {
                searchBarNode = current
            } else {
                searchBarTransition = .immediate
                let theme = self.presentationData.theme
                let searchBarTheme = SearchBarNodeTheme(theme: theme, hasSeparator: false)
                searchBarNode = SearchBarNode(theme: searchBarTheme, presentationTheme: theme, strings: self.presentationData.strings, fieldStyle: .glass, displayBackground: false)
                searchBarNode.placeholderString = NSAttributedString(string: self.usesSearchScopes ? self.searchScopePlaceholder() : (self.searchPlaceholder() ?? self.presentationData.strings.Common_Search), font: Font.regular(17.0), textColor: searchBarTheme.placeholder)
                self.searchBarNode = searchBarNode
                searchBarNode.cancel = { [weak self] in
                    self?.setPlaylistSearchActive(false)
                }
                searchBarNode.textUpdated = { [weak self] query, _ in
                    guard let self, self.playlistSearchQuery != nil, self.playlistSearchQuery != query else {
                        return
                    }
                    self.playlistSearchQuery = query
                    self.updateList(scrollToTop: true, animated: true)
                }
                DispatchQueue.main.async { [weak self, weak searchBarNode] in
                    guard let self, let searchBarNode, self.searchBarNode === searchBarNode else {
                        return
                    }
                    searchBarNode.activate()
                }
            }
            let searchBarFrame = CGRect(origin: CGPoint(x: 0.0, y: navigationHeight - 54.0 + 2.0), size: CGSize(width: layout.size.width, height: 54.0))
            searchBarNode.updateLayout(boundingSize: searchBarFrame.size, leftInset: layout.safeInsets.left + 6.0, rightInset: layout.safeInsets.right, transition: searchBarTransition.containedViewLayoutTransition)
            searchBarTransition.setFrame(view: searchBarNode.view, frame: searchBarFrame)
            if searchBarNode.view.superview == nil {
                self.view.addSubview(searchBarNode.view)
                if case let .curve(duration, _) = transition.animation, let placeholderNode {
                    searchBarNode.animateIn(from: placeholderNode, duration: duration, timingFunction: kCAMediaTimingFunctionSpring)
                }
            }
        } else if let searchBarNode = self.searchBarNode {
            self.searchBarNode = nil
            return searchBarNode
        }
        return nil
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
                    placeholder: self.isPlaylistScreen ? strings.Music_SearchTracks : (self.searchPlaceholder() ?? strings.Music_Search),
                    hasEdgeEffect: false,
                    updated: { [weak self] query in
                        guard let self, self.playlistSearchQuery != nil, self.playlistSearchQuery != query else {
                            return
                        }
                        self.playlistSearchQuery = query
                        self.updateList(scrollToTop: true, animated: true)
                    },
                    cancel: { [weak self] in
                        self?.setPlaylistSearchActive(false)
                    }
                )),
                environment: {},
                containerSize: CGSize(width: layout.size.width, height: MusicScreenNode.playlistSearchPanelHeight)
            )
            if let panelView = panel.view {
                let panelFrame = CGRect(origin: CGPoint(x: 0.0, y: layout.statusBarHeight ?? 0.0), size: panelSize)
                if panelView.superview == nil {
                    self.view.addSubview(panelView)
                    panelView.alpha = 0.0
                    // The field rises from the bar's search field, as the chat list's search does.
                    panelView.frame = panelFrame.offsetBy(dx: 0.0, dy: self.searchPanelRestingOffset(layout: layout))
                }
                transition.setFrame(view: panelView, frame: panelFrame)
                transition.setAlpha(view: panelView, alpha: 1.0)
            }
        } else if let panel = self.playlistSearchPanel {
            self.playlistSearchPanel = nil
            if let panelView = panel.view {
                transition.setFrame(view: panelView, frame: panelView.frame.offsetBy(dx: 0.0, dy: self.searchPanelRestingOffset(layout: layout)))
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
        // As the profile's `containerLayoutUpdated(additive: true)`: the spacer changes at once, so the list's offset does
        // not move and the header plays one spring by itself; the rows catch up with the same spring, additively.
        let previousSpacerHeight = isExpanded ? 0.0 : MusicPlaylistHeaderView.height(width: layout.size.width, statusBarHeight: layout.statusBarHeight ?? 0.0, isExpanded: true) - MusicPlaylistHeaderView.height(width: layout.size.width, statusBarHeight: layout.statusBarHeight ?? 0.0, isExpanded: false)
        let spacerDelta = self.playlistHeaderSpacerHeight - previousSpacerHeight
        let transition: ContainedViewLayoutTransition = .animated(duration: 0.35, curve: .spring)
        // The list keeps its rows where they were when the spacer changes, which would move its offset by the spacer's
        // whole difference and flip the cover straight back: the offset is kept in the same transaction instead.
        var keepingTopOffset: CGFloat = 0.0
        if case let .known(value) = self.listNode.visibleContentOffset() {
            keepingTopOffset = value
        }
        self.isTogglingPlaylistHeader = true
        self.updateList(allUpdated: true, keepingTopOffset: keepingTopOffset, animated: false)
        self.isTogglingPlaylistHeader = false
        if case let .animated(duration, curve) = transition, spacerDelta != 0.0 {
            self.listNode.layer.animatePosition(from: CGPoint(x: 0.0, y: -spacerDelta), to: CGPoint(), duration: duration, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, additive: true)
        }
        self.playlistHeaderTransition = transition
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
        if self.playlistSearchQuery != nil {
            // An active search keeps the bar expanded, as the client's searches do.
            self.navigationScrollOffset = 0.0
        } else if case let .known(value) = self.listNode.visibleContentOffset() {
            self.navigationScrollOffset = max(0.0, min(value, ChatListNavigationBar.searchScrollHeight))
        }
        navigationBarComponentView.applyScroll(offset: self.navigationScrollOffset, allowAvatarsExpansion: false, forceUpdate: true, transition: transition)
    }

    /// The hub tiles' colours stand still while the list moves, so they add no work to the frames of a scroll.
    private func setHubTilesFlowPaused(_ paused: Bool) {
        self.listNode.forEachItemNode { itemNode in
            (itemNode as? MusicHubTilesItemNode)?.setFlowPaused(paused)
        }
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
