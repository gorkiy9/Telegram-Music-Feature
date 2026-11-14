import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import ContextUI
import ChatListHeaderComponent
import GlobalControlPanelsContext
import LegacyMediaPickerUI
import UndoUI
import PromptUI
import PeerMessagesMediaPlaylist
import PresentationDataUtils
import ICloudResources

public func musicSectionTitle(strings: PresentationStrings) -> String {
    return strings.Music_Music
}

enum MusicSection: Equatable {
    case hub
    case songs(artist: String?)
    case artists
    /// `favoritesOnly`: the playlists marked as favorites, opened from the Favorites list.
    case playlists(favoritesOnly: Bool)
    case favorites
    case playlist(Int)
    /// The music a profile shows: its tracks and, for the account's own profile, the playlists put there.
    case profile(EnginePeer.Id)
}

/// The title of a profile's music: its row in the profile when nothing is there yet, and its screen.
public func musicProfileLibraryTitle(strings: PresentationStrings) -> String {
    return strings.Music_Library
}

private final class MusicTabBarContextReferenceContentSource: ContextReferenceContentSource {
    let keepInPlace: Bool = true
    let actionsHorizontalAlignment: ContextActionsHorizontalAlignment = .center

    private let sourceView: ContextExtractedContentContainingView

    init(sourceView: ContextExtractedContentContainingView) {
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView.contentView, contentAreaInScreenSpace: mainWindowScreenBounds, actionsPosition: .top)
    }
}

/// The sheet that picks the playlist for Add to Playlist: the Playlists list with New Playlist on top.
final class MusicPlaylistChooser {
    let excludedId: Int?
    let completion: (MusicPlaylist) -> Void

    init(excludedId: Int?, completion: @escaping (MusicPlaylist) -> Void) {
        self.excludedId = excludedId
        self.completion = completion
    }
}

/// The Music section: a tab of the root controller, and the same screen pushed from Settings.
/// Songs, Artists and Playlists are this screen pushed over it, on one shared library.
/// The header is the chat list's: its bar, search, tabs and media playback panel.
public final class MusicScreen: ViewController {
    public enum Mode {
        case tab
        case navigation
    }

    private let context: AccountContext
    let mode: Mode
    let section: MusicSection
    /// Set on the screens of the sheet that picks tracks for a playlist.
    let picker: MusicTrackPicker?
    /// Set on the sheet that picks a playlist to add tracks to.
    let playlistChooser: MusicPlaylistChooser?
    /// Set on the screens of the attachment menu's Music tab: a track tap selects it for sending, on every list.
    var attachmentSelection: MusicAttachmentSelection?
    /// Set on the root screen of the attachment menu's Music tab: its close button closes the menu.
    var attachmentClose: (() -> Void)?
    /// Another user's profile music: their saved-music list, as their profile loaded it.
    var profileSavedMusicContext: ProfileSavedMusicContext?
    /// The name of the user whose profile music this is, for the player's queue title.
    var profilePeerName: String?
    private var library: MusicLibrary?
    private var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?

    private let globalControlPanelsContext: GlobalControlPanelsContext
    private(set) var globalControlPanelsContextState: GlobalControlPanelsContext.State?
    private var globalControlPanelsContextStateDisposable: Disposable?

    override public var navigationBarTransitionSource: NavigationBarTransitionSource? {
        guard self.isNodeLoaded else {
            return nil
        }
        return self.musicNode.navigationBarView.view as? ChatListNavigationBar.View
    }

    private var musicNode: MusicScreenNode {
        return self.displayNode as! MusicScreenNode
    }

    public convenience init(context: AccountContext, mode: Mode) {
        self.init(context: context, mode: mode, section: .hub, library: nil)
        // The section's tab exists from launch: put the local test chat for forwarded tracks and playlists in the chat
        // list (concept only, nothing about it reaches the server).
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let _ = (context.engine.messages.ensureMusicTestChat(title: strings.Music_TestMusic)
        |> then(musicTestChatIncomingTracks(context: context))).start()
    }

    /// A playlist opened from its bubble in a chat: its own screen as a sheet over the chat.
    static func playlistSheet(context: AccountContext, library: MusicLibrary, playlistId: Int) -> MusicScreen {
        let controller = MusicScreen(context: context, mode: .navigation, section: .playlist(playlistId), library: library)
        controller.navigationPresentation = .modal
        controller._hasGlassStyle = true
        return controller
    }

    /// A profile's music, opened from its row in the profile. Another user's tracks come from `savedMusicContext`.
    public static func profileLibrary(context: AccountContext, peerId: EnginePeer.Id, peerName: String?, savedMusicContext: ProfileSavedMusicContext?) -> ViewController {
        let controller = MusicScreen(context: context, mode: .navigation, section: .profile(peerId), library: MusicLibrary.shared(context: context))
        if peerId != context.account.peerId && peerId != musicTestChatPeerId {
            controller.profileSavedMusicContext = savedMusicContext ?? ProfileSavedMusicContext(account: context.account, peerId: peerId)
        }
        controller.profilePeerName = peerName
        return controller
    }

    /// The sheet that adds tracks to a playlist: the hub, and the lists pushed from it, each row with an add control.
    static func trackPicker(context: AccountContext, library: MusicLibrary, picker: MusicTrackPicker) -> MusicScreen {
        let controller = MusicScreen(context: context, mode: .navigation, section: .hub, library: library, picker: picker)
        controller.navigationPresentation = .modal
        return controller
    }

    /// Add to Playlist: the section's Playlists as a sheet; a row adds the tracks there, New Playlist creates one first.
    static func playlistChooser(context: AccountContext, library: MusicLibrary, chooser: MusicPlaylistChooser) -> MusicScreen {
        let controller = MusicScreen(context: context, mode: .navigation, section: .playlists(favoritesOnly: false), library: library, playlistChooser: chooser)
        controller.navigationPresentation = .modal
        return controller
    }

    init(context: AccountContext, mode: Mode, section: MusicSection, library: MusicLibrary?, picker: MusicTrackPicker? = nil, playlistChooser: MusicPlaylistChooser? = nil) {
        self.context = context
        self.mode = mode
        self.section = section
        self.picker = picker
        self.playlistChooser = playlistChooser
        self.library = library
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.globalControlPanelsContext = GlobalControlPanelsContext(
            context: context,
            mediaPlayback: true,
            liveLocationMode: nil,
            groupCalls: nil,
            chatListNotices: false
        )

        super.init(navigationBarPresentationData: nil)

        if case .tab = mode {
            self.tabBarItemContextActionType = .always
            let icon = UIImage(bundleImageName: "Item List/Icons/Play")?.withRenderingMode(.alwaysTemplate)
            self.tabBarItem.image = icon
            self.tabBarItem.selectedImage = icon
            if !self.presentationData.reduceMotion {
                self.tabBarItem.animationName = "TabAudio"
                // Drawn for the attachment panel's 30 pt icons; the tab bar's slot is 48 pt.
                self.tabBarItem.animationScale = 30.0 / 48.0
                self.tabBarItem.animationOffset = CGPoint(x: 0.0, y: (48.0 - 30.0) * 0.5)
            }
        }
        if picker != nil || playlistChooser != nil {
            // The sheet is the iOS 27 one: 38 pt corners.
            self._hasGlassStyle = true
        }
        self.updateThemeAndStrings()

        self.scrollToTop = { [weak self] in
            guard let self, self.isNodeLoaded else {
                return
            }
            self.musicNode.scrollToTop()
        }

        self.presentationDataDisposable = (context.sharedContext.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            guard let self else {
                return
            }
            if presentationData.theme !== self.presentationData.theme || presentationData.strings !== self.presentationData.strings {
                self.presentationData = presentationData
                self.updateThemeAndStrings()
                if self.isNodeLoaded {
                    self.musicNode.updatePresentationData(presentationData)
                    self.requestLayout(transition: .immediate)
                }
            }
        })

        self.globalControlPanelsContextStateDisposable = (self.globalControlPanelsContext.state
        |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self else {
                return
            }
            // In the attachment menu the player is the menu's own panel above its tabs, as for the client's audio tab.
            self.globalControlPanelsContextState = self.attachmentSelection == nil ? state : nil
            self.requestLayout(transition: .animated(duration: 0.4, curve: .spring))
        })
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.presentationDataDisposable?.dispose()
        self.globalControlPanelsContextStateDisposable?.dispose()
    }

    private func updateThemeAndStrings() {
        var title = musicSectionTitle(strings: self.presentationData.strings)
        if case .profile = self.section {
            title = musicProfileLibraryTitle(strings: self.presentationData.strings)
        }
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.title = title
        if case .tab = self.mode {
            self.tabBarItem.title = title
        }
    }

    /// The header carries over from the section left in the tab bar: search stays visible.
    public func sectionOpened(from previous: ViewController?) {
        guard self.isNodeLoaded, let navigationBarView = previous?.navigationBarTransitionSource as? ChatListNavigationBar.View, let offset = navigationBarView.clippedScrollOffset, offset < ChatListNavigationBar.searchScrollHeight * 0.5 else {
            return
        }
        self.musicNode.revealSearch()
    }

    /// A playlist's cover keeps the status bar white while it is under it.
    func updateStatusBar(overCover: Bool) {
        self.statusBar.updateStatusBarStyle(overCover ? .White : self.presentationData.theme.rootController.statusBarStyle.style, animated: true)
    }

    func goBack() {
        let _ = (self.navigationController as? NavigationController)?.popViewController(animated: true)
    }

    func open(section: MusicSection, library: MusicLibrary) {
        self.isReturningFromSection = true
        let controller = MusicScreen(context: self.context, mode: .navigation, section: section, library: library, picker: self.picker)
        controller.attachmentSelection = self.attachmentSelection
        (self.navigationController as? NavigationController)?.pushViewController(controller)
    }

    /// Applies the picked tracks and closes the whole sheet.
    func finishPicking() {
        guard let picker = self.picker, let navigationController = self.navigationController as? NavigationController else {
            return
        }
        picker.commit()
        let controllers = navigationController.viewControllers.filter { controller in
            if let controller = controller as? MusicScreen, controller.picker === picker {
                return false
            }
            return true
        }
        navigationController.setViewControllers(controllers, animated: true)
    }

    /// Closes the playlist sheet together with anything opened from it.
    func closePlaylistChooser(including other: ViewController? = nil) {
        guard let navigationController = self.navigationController as? NavigationController else {
            return
        }
        navigationController.setViewControllers(navigationController.viewControllers.filter { $0 !== self && $0 !== other }, animated: true)
    }

    func choosePlaylist(_ playlist: MusicPlaylist) {
        guard let chooser = self.playlistChooser else {
            return
        }
        chooser.completion(playlist)
        self.closePlaylistChooser()
    }

    /// New Playlist from the sheet: the editor opens over it, and Done adds the tracks to the new playlist and closes both.
    func createPlaylistFromChooser(library: MusicLibrary) {
        guard let chooser = self.playlistChooser, let navigationController = self.navigationController as? NavigationController else {
            return
        }
        var editScreen: ViewController?
        let controller = musicPlaylistEditScreen(context: self.context, library: library, playlist: nil, completion: { [weak self] playlist in
            chooser.completion(playlist)
            self?.closePlaylistChooser(including: editScreen)
            editScreen = nil
        })
        editScreen = controller
        navigationController.pushViewController(controller)
    }

    private var rootNavigationController: NavigationController? {
        return (self.navigationController as? NavigationController) ?? (self.context.sharedContext.mainWindow?.viewController as? NavigationController)
    }

    /// `queueTitle` names the queue in the player sheet; by default it is the list the track was started from.
    func play(track: MusicTrack, tracks: [MusicTrack], library: MusicLibrary, queueTitle: String? = nil, queueKind: MusicPlayerQueueKind? = nil, source: (() -> [MusicTrack]?)? = nil) {
        let location = library.playlistLocation(track: track, tracks: tracks, title: queueTitle ?? self.queueTitle(library: library), kind: queueKind ?? self.queueKind, source: source)
        self.context.sharedContext.mediaManager.setPlaylist((self.context, PeerMessagesMediaPlaylist(context: self.context, location: location, chatLocationContextHolder: nil)), type: .music, control: .playback(.togglePlayPause))
    }

    /// The name and photo card, a description and tracks: a sheet like the one that creates a channel.
    func createPlaylist(library: MusicLibrary, completion: ((MusicPlaylist) -> Void)?) {
        self.rootNavigationController?.pushViewController(musicPlaylistEditScreen(context: self.context, library: library, playlist: nil, completion: { playlist in
            completion?(playlist)
        }))
    }

    func editPlaylist(_ playlist: MusicPlaylist, library: MusicLibrary) {
        if self.isNodeLoaded {
            self.musicNode.suspendPlaybackForPlaylistEditing()
        }
        self.rootNavigationController?.pushViewController(musicPlaylistEditScreen(context: self.context, library: library, playlist: playlist, completion: { _ in
        }))
    }

    /// The same sheet as from the playlist's editor, adding straight to the playlist.
    func addTracks(to playlist: MusicPlaylist, library: MusicLibrary) {
        let picker = MusicTrackPicker(playlistTitle: playlist.title, trackIds: playlist.trackIds, completion: { [weak library] trackIds in
            library?.updatePlaylist(id: playlist.id, { playlist in
                playlist.trackIds = trackIds
            })
        })
        self.rootNavigationController?.pushViewController(MusicScreen.trackPicker(context: self.context, library: library, picker: picker))
    }

    func setFavorite(playlist: MusicPlaylist, isFavorite: Bool, library: MusicLibrary) {
        library.updatePlaylist(id: playlist.id, { playlist in
            playlist.isFavorite = isFavorite
        })
        let strings = self.presentationData.strings
        self.presentToast(text: isFavorite ? strings.Music_PlaylistWasAddedToFavorites : strings.Music_PlaylistWasRemovedFromFavorites, iconName: isFavorite ? musicAnimatedFavoriteIconName : musicAnimatedUnfavoriteIconName)
    }

    func setInProfile(playlist: MusicPlaylist, isInProfile: Bool, library: MusicLibrary) {
        library.setPlaylistInProfile(id: playlist.id, isInProfile)
        let strings = self.presentationData.strings
        self.presentToast(text: isInProfile ? strings.Music_PlaylistWasAddedToYourProfile : strings.Music_PlaylistWasRemovedFromYourProfile, iconName: "Peer Info/SavedMusic")
    }

    func play(playlist: MusicPlaylist, shuffled: Bool, library: MusicLibrary) {
        var tracks = library.tracks(of: playlist)
        if shuffled {
            tracks.shuffle()
        }
        guard let first = tracks.first else {
            return
        }
        let playlistId = playlist.id
        self.play(track: first, tracks: tracks, library: library, queueTitle: musicPlaylistQueueTitle(strings: self.presentationData.strings, playlist: playlist), queueKind: .playlist(playlist.id), source: shuffled ? nil : { [weak library] in
            return library?.playlist(id: playlistId).flatMap { library?.tracks(of: $0) }
        })
    }

    /// With nothing from the section playing the playlist simply starts.
    func enqueue(playlist: MusicPlaylist, next: Bool, library: MusicLibrary) {
        let tracks = library.tracks(of: playlist)
        guard !tracks.isEmpty else {
            return
        }
        library.enqueue(tracks: tracks, next: next, completion: { [weak self, weak library] queued in
            guard let self, let library else {
                return
            }
            let strings = self.presentationData.strings
            if queued {
                self.presentToast(text: next ? strings.Music_PlaylistWillPlayNext : strings.Music_PlaylistWasAddedToQueue, iconName: next ? "Chat/Context Menu/MoveUp" : "Chat/Context Menu/MoveDown")
            } else {
                self.play(track: tracks[0], tracks: tracks, library: library, queueTitle: musicPlaylistQueueTitle(strings: strings, playlist: playlist), queueKind: .playlist(playlist.id))
            }
        })
    }

    /// The name of the queue a track started on this screen plays in, as the player sheet shows it.
    /// What the queue a track started on this screen plays: the player sheet's menu leads back to it.
    private var queueKind: MusicPlayerQueueKind {
        switch self.section {
        case let .songs(artist?):
            return .artist(artist)
        case let .playlist(id):
            return .playlist(id)
        case let .profile(peerId):
            return .profile(peerId)
        case .hub, .songs(nil), .artists, .playlists, .favorites:
            return .tracks
        }
    }

    private func queueTitle(library: MusicLibrary) -> String {
        let strings = self.presentationData.strings
        switch self.section {
        case let .songs(artist?):
            return strings.Music_Artist(artist).string
        case .favorites:
            return strings.Music_Favorites
        case let .playlist(id):
            if let playlist = library.playlist(id: id) {
                return musicPlaylistQueueTitle(strings: strings, playlist: playlist)
            }
            return musicOwnMusicQueueTitle(strings: strings)
        case let .profile(peerId):
            if peerId != self.context.account.peerId, let name = self.profilePeerName {
                return MusicPlayerSupport.userMusicTitle(strings: strings, name: name)
            }
            return MusicPlayerSupport.libraryTitle(strings: strings)
        case .hub, .songs(nil), .artists, .playlists:
            return musicOwnMusicQueueTitle(strings: strings)
        }
    }

    /// The test chat gets the playlist bubble; real chats get its tracks (see `musicSharePlaylistSubject`).
    func share(playlist: MusicPlaylist, library: MusicLibrary) {
        let tracks = library.tracks(of: playlist)
        guard !tracks.isEmpty else {
            return
        }
        self.present(self.context.sharedContext.makeShareScreen(context: self.context, params: ShareControllerParams(subject: musicSharePlaylistSubject(context: self.context, playlist: playlist, tracks: tracks), completed: { [weak self] peerIds in
            self?.presentForwardedToast(peerIds: peerIds)
        }, hidesSenderNames: true)), in: .window(.root))
    }

    /// The client's success toast (animated checkmark) naming the chats the playlist went to.
    private func presentForwardedToast(peerIds: [EnginePeer.Id]) {
        guard !peerIds.isEmpty else {
            return
        }
        let context = self.context
        let _ = (context.engine.data.get(EngineDataList(peerIds.map(TelegramEngine.EngineData.Item.Peer.Peer.init)))
        |> deliverOnMainQueue).startStandalone(next: { [weak self] peerList in
            guard let self else {
                return
            }
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let strings = presentationData.strings
            func name(_ peer: EnginePeer) -> String {
                let title = peer.id == context.account.peerId ? strings.DialogList_SavedMessages : peer.displayTitle(strings: strings, displayOrder: presentationData.nameDisplayOrder)
                return "**\(title.replacingOccurrences(of: "**", with: ""))**"
            }
            let peers = peerList.compactMap { $0 }
            let target: String
            if peers.count == 1 {
                target = name(peers[0])
            } else if peers.count == 2 {
                target = strings.Music_TwoChats("\(name(peers[0]))", "\(name(peers[1]))").string
            } else if let first = peers.first {
                target = strings.Music_ChatAndOthers("\(name(first))", "\(peers.count - 1)").string
            } else {
                return
            }
            let text = strings.Music_ForwardedTo(target).string
            self.present(UndoOverlayController(presentationData: presentationData, content: .succeed(text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, animateInAsReplacement: true, action: { _ in
                return false
            }), in: .current)
        })
    }

    func confirmRemoval(playlist: MusicPlaylist, library: MusicLibrary, completion: (() -> Void)? = nil) {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let strings = presentationData.strings
        let actionSheet = ActionSheetController(presentationData: presentationData)
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: strings.Music_TracksStayInYourMusic),
                ActionSheetButtonItem(title: strings.Music_DeletePlaylist, color: .destructive, action: { [weak actionSheet, weak library] in
                    actionSheet?.dismissAnimated()
                    library?.removePlaylist(id: playlist.id)
                    completion?()
                })
            ]),
            ActionSheetItemGroup(items: [ActionSheetButtonItem(title: strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })])
        ])
        self.present(actionSheet, in: .window(.root))
    }

    /// The menu also opens on a tab that is not selected, and every section lives under this one.
    private func selectTab() -> NavigationController? {
        guard let navigationController = self.context.sharedContext.mainWindow?.viewController as? NavigationController else {
            return nil
        }
        if let tabBarController = navigationController.viewControllers.first as? TabBarController, let index = tabBarController.controllers.firstIndex(where: { $0 === self }) {
            tabBarController.selectedIndex = index
        }
        return navigationController
    }

    private func openFromMenu(section: MusicSection, library: MusicLibrary) {
        self.selectTab()?.pushViewController(MusicScreen(context: self.context, mode: .navigation, section: section, library: library))
    }

    private func tabMenuItems(library: MusicLibrary) -> [ContextMenuItem] {
        let strings = self.presentationData.strings
        let action: (String, String, @escaping () -> Void) -> ContextMenuItem = { title, iconName, action in
            return .action(ContextMenuActionItem(text: title, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: iconName), color: theme.contextMenu.primaryColor)
            }, action: { _, f in
                f(.dismissWithoutContent)
                action()
            }))
        }

        return [
            action(strings.Music_AddTrack, "Chat/Context Menu/AddMusic", { [weak self, weak library] in
                guard let self, let library else {
                    return
                }
                let _ = self.selectTab()
                self.addTrack(library: library)
            }),
            action(strings.Music_NewPlaylist, "Music/NoteList", { [weak self, weak library] in
                guard let self, let library else {
                    return
                }
                self.createPlaylist(library: library, completion: { [weak self, weak library] playlist in
                    guard let self, let library else {
                        return
                    }
                    self.openFromMenu(section: .playlist(playlist.id), library: library)
                })
            }),
            .separator,
            action(strings.Music_Tracks, "Music/Note", { [weak self, weak library] in
                guard let self, let library else {
                    return
                }
                self.openFromMenu(section: .songs(artist: nil), library: library)
            }),
            action(strings.Music_Artists, "Music/Microphone", { [weak self, weak library] in
                guard let self, let library else {
                    return
                }
                self.openFromMenu(section: .artists, library: library)
            }),
            action(strings.Music_Playlists, "Music/Playlists", { [weak self, weak library] in
                guard let self, let library else {
                    return
                }
                self.openFromMenu(section: .playlists(favoritesOnly: false), library: library)
            }),
            .separator,
            action(strings.Music_Play, "Chat/Context Menu/Play", { [weak self, weak library] in
                guard let self, let library else {
                    return
                }
                self.playAll(library: library, shuffled: false)
            }),
            action(strings.Music_Shuffle, "Music/Shuffle", { [weak self, weak library] in
                guard let self, let library else {
                    return
                }
                self.playAll(library: library, shuffled: true)
            })
        ]
    }

    /// All tracks in the hub's order, newest first, or in a random one.
    private func playAll(library: MusicLibrary, shuffled: Bool) {
        var tracks = library.tracks(source: .all, sorting: MusicSorting(key: .dateAdded, ascending: false))
        if shuffled {
            tracks.shuffle()
        }
        guard let first = tracks.first else {
            return
        }
        self.play(track: first, tracks: tracks, library: library, queueTitle: musicOwnMusicQueueTitle(strings: self.presentationData.strings), queueKind: .tracks, source: shuffled ? nil : { [weak library] in
            return library?.tracks(source: .all, sorting: MusicSorting(key: .dateAdded, ascending: false))
        })
    }

    override public func tabBarItemContextAction(sourceView: ContextExtractedContentContainingView, gesture: ContextGesture) {
        let items = ContextController.Items(content: .list(self.tabMenuItems(library: self.currentLibrary())))
        let controller = makeContextController(context: self.context, presentationData: self.presentationData, source: .reference(MusicTabBarContextReferenceContentSource(sourceView: sourceView)), items: .single(items), recognizer: nil, gesture: gesture)
        self.context.sharedContext.mainWindow?.presentInGlobalOverlay(controller)
    }

    override public func toolbarActionSelected(action: ToolbarActionOption) {
        guard self.isNodeLoaded else {
            return
        }
        switch action {
        case .left:
            self.musicNode.deleteSelectedTracks()
        case .right:
            self.musicNode.forwardSelectedTracks()
        case .middle:
            break
        }
    }

    func presentFavoriteToast(isFavorite: Bool) {
        let toast = musicFavoriteToast(strings: self.presentationData.strings, isFavorite: isFavorite)
        self.presentToast(text: toast.text, iconName: toast.iconName)
    }

    func presentRemovedFromMusicToast(count: Int) {
        let toast = musicLibraryToast(strings: self.presentationData.strings, isInMusic: false, count: count)
        self.presentToast(text: toast.text, iconName: toast.iconName)
    }

    func presentToast(text: String, iconName: String) {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        guard let content = musicToastContent(text: text, iconName: iconName) else {
            return
        }
        self.present(UndoOverlayController(presentationData: presentationData, content: content, action: { _ in
            return true
        }), in: .current)
    }

    /// With nothing from the section playing there is no queue to join, so the track simply starts.
    func enqueue(track: MusicTrack, next: Bool, library: MusicLibrary) {
        library.enqueue(tracks: [track], next: next, completion: { [weak self, weak library] queued in
            guard let self, let library else {
                return
            }
            let strings = self.presentationData.strings
            if queued {
                self.presentToast(text: next ? strings.Music_TrackWillPlayNext : strings.Music_TrackWasAddedToQueue, iconName: next ? "Chat/Context Menu/MoveUp" : "Chat/Context Menu/MoveDown")
            } else {
                self.play(track: track, tracks: [track], library: library)
            }
        })
    }

    /// Playlists are local stand-ins: the choice is kept with the playlist in memory.
    func addToPlaylist(track: MusicTrack, library: MusicLibrary) {
        self.addToPlaylist(tracks: [track], excluding: nil, library: library)
    }

    func addToPlaylist(tracks: [MusicTrack], excluding excludedId: Int?, library: MusicLibrary) {
        presentMusicAddToPlaylistSheet(context: self.context, library: library, tracks: tracks, excluding: excludedId, push: { [weak self] controller in
            self?.rootNavigationController?.pushViewController(controller)
        }, toast: { [weak self] text in
            self?.presentToast(text: text, iconName: "Chat/Context Menu/AddCaption")
        })
    }

    func setSavedToProfile(track: MusicTrack, isSaved: Bool, library: MusicLibrary) {
        library.setSavedToProfile(track, isSaved)
        let strings = self.presentationData.strings
        self.presentToast(text: isSaved ? strings.MediaPlayer_SavedMusic_AddedToProfile : strings.Music_TrackWasRemovedFromYourProfile, iconName: "Peer Info/SavedMusic")
    }

    /// A chat's track is forwarded as its message; a saved one has no message to forward, so its file is sent.
    func share(track: MusicTrack) {
        let subject: ShareControllerSubject
        if track.isSaved, let file = track.file {
            subject = .media(.standalone(media: file), nil)
        } else {
            subject = .messages([track.message])
        }
        self.present(self.context.sharedContext.makeShareScreen(context: self.context, params: ShareControllerParams(subject: subject, hidesSenderNames: true)), in: .window(.root))
    }

    /// Selected tracks are sent like tracks attached in a chat (see `musicShareTracksSubject`).
    func share(tracks: [MusicTrack], completion: @escaping () -> Void) {
        self.present(self.context.sharedContext.makeShareScreen(context: self.context, params: ShareControllerParams(subject: musicShareTracksSubject(context: self.context, tracks: tracks), completed: { [weak self] peerIds in
            self?.presentForwardedToast(peerIds: peerIds)
            completion()
        })), in: .window(.root))
    }

    func confirmRemoval(tracks: [MusicTrack], library: MusicLibrary, completion: @escaping () -> Void) {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let strings = presentationData.strings
        let actionSheet = ActionSheetController(presentationData: presentationData)
        let title = tracks.count == 1 ? strings.Music_DeleteTrack : strings.Music_DeleteTracks("\(tracks.count)").string
        var items: [ActionSheetItem] = []
        if tracks.contains(where: \.isSaved) {
            items.append(ActionSheetTextItem(title: strings.Music_TracksStayInYourProfileAndInChats))
        } else {
            items.append(ActionSheetTextItem(title: strings.Music_FilesStayInChats))
        }
        items.append(ActionSheetButtonItem(title: title, color: .destructive, action: { [weak self, weak actionSheet, weak library] in
            actionSheet?.dismissAnimated()
            library?.remove(tracks: tracks)
            completion()
            self?.presentRemovedFromMusicToast(count: tracks.count)
        }))
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [ActionSheetButtonItem(title: strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })])
        ])
        self.present(actionSheet, in: .window(.root))
    }

    /// Picks an audio file and opens the new track screen with its tags; Done uploads it to the profile.
    func addTrack(library: MusicLibrary) {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        self.present(legacyICloudFilePicker(theme: presentationData.theme, mode: .default, documentTypes: ["public.mp3", "public.mpeg-4-audio", "public.aac-audio", "org.xiph.flac"], completion: { [weak self, weak library] urls in
            guard let url = urls.first, let library else {
                return
            }
            let _ = (library.prepareTrack(url: url)
            |> take(1)).start(next: { [weak self, weak library] file in
                guard let self, let library else {
                    return
                }
                guard let file else {
                    self.presentAddedToast(success: false)
                    return
                }
                self.push(musicTrackEditScreen(context: self.context, library: library, mode: .new(file), completion: { [weak self] success in
                    self?.presentAddedToast(success: success)
                }))
            })
        }), in: .window(.root))
    }

    /// Opens the track screen for a track of the library; the change is kept on this device.
    func editTrack(_ track: MusicTrack, library: MusicLibrary) {
        self.push(musicTrackEditScreen(context: self.context, library: library, mode: .edit(track), completion: { _ in
        }))
    }

    private func presentAddedToast(success: Bool) {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let strings = presentationData.strings
        self.present(UndoOverlayController(
            presentationData: presentationData,
            content: .universalImage(
                image: generateTintedImage(image: UIImage(bundleImageName: "Peer Info/SavedMusic"), color: .white)!,
                size: nil,
                title: nil,
                text: success ? strings.MediaPlayer_SavedMusic_AddedToProfile : strings.Login_UnknownError,
                customUndoText: nil,
                timeout: 3.0
            ),
            action: { _ in
                return true
            }
        ), in: .current)
    }

    private func currentLibrary() -> MusicLibrary {
        if let library = self.library {
            return library
        }
        let library = MusicLibrary.shared(context: self.context)
        self.library = library
        return library
    }

    override public func loadDisplayNode() {
        self.displayNode = MusicScreenNode(context: self.context, controller: self, presentationData: self.presentationData, library: self.currentLibrary())
        self.displayNodeDidLoad()
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.musicNode.refresh()
    }

    /// Set while a pushed section is on top, so coming back from it does not replay the hub icons.
    private var isReturningFromSection = false

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if self.isReturningFromSection {
            self.isReturningFromSection = false
        } else {
            self.musicNode.playHubIcons()
        }
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.musicNode.containerLayoutUpdated(layout, transition: transition)
    }
}

/// Audio files copied into the app's Documents/MusicTestChat folder arrive in the test chat as messages from it, once each.
/// They are local only, so the Music section (built from server search) never sees them.
private func musicTestChatIncomingTracks(context: AccountContext) -> Signal<Never, NoError> {
    guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
        return .complete()
    }
    let folder = documents.appendingPathComponent("MusicTestChat", isDirectory: true)
    guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
        return .complete()
    }
    let audioUrls = urls.filter { ["mp3", "m4a", "flac"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    if audioUrls.isEmpty {
        return .complete()
    }
    return combineLatest(audioUrls.map { url -> Signal<(Int32, TelegramMediaFile)?, NoError> in
        return iCloudFileDescription(url)
        |> take(1)
        |> map { item -> (Int32, TelegramMediaFile)? in
            guard let item else {
                return nil
            }
            // A stable id per file name keeps a file from arriving twice.
            var hash: UInt32 = 2166136261
            for byte in item.fileName.utf8 {
                hash = (hash ^ UInt32(byte)) &* 16777619
            }
            let messageId = Int32(1_000_000 + hash % 1_000_000)
            var previewRepresentations: [TelegramMediaImageRepresentation] = []
            if item.audioMetadata?.hasAudioArtwork == true {
                previewRepresentations.append(TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 320, height: 320), resource: ICloudFileResource(urlData: item.urlData, thumbnail: true), progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false))
            }
            var attributes: [TelegramMediaFileAttribute] = [.FileName(fileName: item.fileName)]
            if let audioMetadata = item.audioMetadata {
                attributes.append(.Audio(isVoice: false, duration: audioMetadata.duration, title: audioMetadata.title, performer: audioMetadata.performer, waveform: nil))
            }
            let mimeType = guessMimeTypeByFileExtension((item.fileName as NSString).pathExtension)
            let file = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: Int64(messageId)), partialReference: nil, resource: ICloudFileResource(urlData: item.urlData, thumbnail: false), previewRepresentations: previewRepresentations, videoThumbnails: [], immediateThumbnailData: nil, mimeType: mimeType, size: Int64(item.fileSize), attributes: attributes, alternativeRepresentations: [])
            return (messageId, file)
        }
    })
    |> take(1)
    |> mapToSignal { items -> Signal<Never, NoError> in
        return context.engine.messages.addMusicTestChatIncomingFiles(items.compactMap { $0.map { (messageId: $0.0, file: $0.1) } })
    }
}
