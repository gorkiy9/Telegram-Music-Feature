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

/// Local flag of the Music section: turns off both the tab and the Settings row.
public let isMusicSectionEnabled = true

/// The section's strings are not in the language packs yet.
func musicString(_ strings: PresentationStrings, ru: String, en: String) -> String {
    return strings.primaryComponent.languageCode.hasPrefix("ru") ? ru : en
}

public func musicSectionTitle(strings: PresentationStrings) -> String {
    return musicString(strings, ru: "Музыка", en: "Music")
}

enum MusicSection: Equatable {
    case hub
    case songs(artist: String?)
    case artists
    case playlists
    case favorites
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
    }

    init(context: AccountContext, mode: Mode, section: MusicSection, library: MusicLibrary?) {
        self.context = context
        self.mode = mode
        self.section = section
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
            self.globalControlPanelsContextState = state
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
        let title = musicSectionTitle(strings: self.presentationData.strings)
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

    func goBack() {
        let _ = (self.navigationController as? NavigationController)?.popViewController(animated: true)
    }

    func open(section: MusicSection, library: MusicLibrary) {
        (self.navigationController as? NavigationController)?.pushViewController(MusicScreen(context: self.context, mode: .navigation, section: section, library: library))
    }

    func play(track: MusicTrack, tracks: [MusicTrack], library: MusicLibrary) {
        let location = library.playlistLocation(track: track, tracks: tracks)
        self.context.sharedContext.mediaManager.setPlaylist((self.context, PeerMessagesMediaPlaylist(context: self.context, location: location, chatLocationContextHolder: nil)), type: .music, control: .playback(.togglePlayPause))
    }

    func createPlaylist(library: MusicLibrary, completion: ((MusicPlaylist) -> Void)?) {
        let strings = self.presentationData.strings
        self.present(promptController(
            context: self.context,
            text: musicString(strings, ru: "Новый плейлист", en: "New Playlist"),
            value: nil,
            placeholder: musicString(strings, ru: "Название", en: "Title"),
            characterLimit: 64,
            apply: { [weak library] value in
                guard let title = value?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                    return
                }
                if let playlist = library?.createPlaylist(title: title) {
                    completion?(playlist)
                }
            }
        ), in: .window(.root))
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
            action(musicString(strings, ru: "Добавить трек", en: "Add Track"), "Chat/Context Menu/AddMusic", { [weak self, weak library] in
                guard let self, let library else {
                    return
                }
                let _ = self.selectTab()
                self.addTrack(library: library)
            }),
            action(musicString(strings, ru: "Создать плейлист", en: "New Playlist"), "Music/NoteList", { [weak self, weak library] in
                guard let self, let library else {
                    return
                }
                self.createPlaylist(library: library, completion: { [weak self, weak library] _ in
                    guard let self, let library else {
                        return
                    }
                    self.openFromMenu(section: .playlists, library: library)
                })
            }),
            .separator,
            action(musicString(strings, ru: "Треки", en: "Tracks"), "Music/Note", { [weak self, weak library] in
                guard let self, let library else {
                    return
                }
                self.openFromMenu(section: .songs(artist: nil), library: library)
            }),
            action(musicString(strings, ru: "Артисты", en: "Artists"), "Music/Microphone", { [weak self, weak library] in
                guard let self, let library else {
                    return
                }
                self.openFromMenu(section: .artists, library: library)
            }),
            action(musicString(strings, ru: "Плейлисты", en: "Playlists"), "Music/Playlists", { [weak self, weak library] in
                guard let self, let library else {
                    return
                }
                self.openFromMenu(section: .playlists, library: library)
            }),
            .separator,
            action(musicString(strings, ru: "Воспроизвести", en: "Play"), "Chat/Context Menu/Play", { [weak self, weak library] in
                guard let self, let library else {
                    return
                }
                self.playAll(library: library, shuffled: false)
            }),
            action(musicString(strings, ru: "Перемешать", en: "Shuffle"), "Music/Shuffle", { [weak self, weak library] in
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
        self.play(track: first, tracks: tracks, library: library)
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
            self.musicNode.toggleSelectAll()
        case .right:
            self.musicNode.deleteSelectedTracks()
        case .middle:
            break
        }
    }

    private func presentToast(text: String, iconName: String) {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        guard let image = generateTintedImage(image: UIImage(bundleImageName: iconName), color: .white) else {
            return
        }
        self.present(UndoOverlayController(presentationData: presentationData, content: .universalImage(image: image, size: nil, title: nil, text: text, customUndoText: nil, timeout: 3.0), action: { _ in
            return true
        }), in: .current)
    }

    /// With nothing from the section playing there is no queue to join, so the track simply starts.
    func enqueue(track: MusicTrack, next: Bool, library: MusicLibrary) {
        library.enqueue(track: track, next: next, completion: { [weak self, weak library] queued in
            guard let self, let library else {
                return
            }
            let strings = self.presentationData.strings
            if queued {
                self.presentToast(text: next ? musicString(strings, ru: "Трек будет следующим", en: "The track will play next") : musicString(strings, ru: "Трек добавлен в очередь", en: "The track was added to the queue"), iconName: next ? "Chat/Context Menu/MoveUp" : "Chat/Context Menu/MoveDown")
            } else {
                self.play(track: track, tracks: [track], library: library)
            }
        })
    }

    /// Playlists are local stand-ins: the choice is kept with the playlist in memory.
    func addToPlaylist(track: MusicTrack, library: MusicLibrary) {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let strings = presentationData.strings
        let actionSheet = ActionSheetController(presentationData: presentationData)
        let added: (MusicPlaylist) -> Void = { [weak self, weak library] playlist in
            library?.add(track: track, to: playlist)
            self?.presentToast(text: musicString(strings, ru: "Трек добавлен в «\(playlist.title)»", en: "The track was added to “\(playlist.title)”"), iconName: "Chat/Context Menu/AddCaption")
        }
        var items: [ActionSheetItem] = [ActionSheetTextItem(title: musicString(strings, ru: "Добавить в плейлист", en: "Add to Playlist"))]
        for playlist in library.playlists {
            items.append(ActionSheetButtonItem(title: playlist.title, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                added(playlist)
            }))
        }
        items.append(ActionSheetButtonItem(title: musicString(strings, ru: "Новый плейлист", en: "New Playlist"), action: { [weak self, weak actionSheet, weak library] in
            actionSheet?.dismissAnimated()
            guard let self, let library else {
                return
            }
            self.createPlaylist(library: library, completion: { playlist in
                added(playlist)
            })
        }))
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [ActionSheetButtonItem(title: strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })])
        ])
        self.present(actionSheet, in: .window(.root))
    }

    func setSavedToProfile(track: MusicTrack, isSaved: Bool, library: MusicLibrary) {
        library.setSavedToProfile(track, isSaved)
        let strings = self.presentationData.strings
        self.presentToast(text: isSaved ? strings.MediaPlayer_SavedMusic_AddedToProfile : musicString(strings, ru: "Трек убран из профиля", en: "The track was removed from your profile"), iconName: "Peer Info/SavedMusic")
    }

    /// A chat's track is forwarded as its message; a saved one has no message to forward, so its file is sent.
    func share(track: MusicTrack) {
        let subject: ShareControllerSubject
        if track.isSaved, let file = track.file {
            subject = .media(.standalone(media: file), nil)
        } else {
            subject = .messages([track.message])
        }
        self.present(self.context.sharedContext.makeShareScreen(context: self.context, params: ShareControllerParams(subject: subject)), in: .window(.root))
    }

    func confirmRemoval(tracks: [MusicTrack], library: MusicLibrary, completion: @escaping () -> Void) {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let strings = presentationData.strings
        let actionSheet = ActionSheetController(presentationData: presentationData)
        let title = tracks.count == 1 ? musicString(strings, ru: "Удалить трек", en: "Delete Track") : musicString(strings, ru: "Удалить треки: \(tracks.count)", en: "Delete \(tracks.count) Tracks")
        var items: [ActionSheetItem] = []
        if tracks.contains(where: \.isSaved) {
            items.append(ActionSheetTextItem(title: musicString(strings, ru: "Треки из профиля будут убраны из него. Файлы из чатов останутся в чатах.", en: "Tracks from your profile will be removed from it. Files from chats stay in the chats.")))
        } else {
            items.append(ActionSheetTextItem(title: musicString(strings, ru: "Файлы останутся в чатах.", en: "The files stay in the chats.")))
        }
        items.append(ActionSheetButtonItem(title: title, color: .destructive, action: { [weak actionSheet, weak library] in
            actionSheet?.dismissAnimated()
            library?.remove(tracks: tracks)
            completion()
        }))
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: items),
            ActionSheetItemGroup(items: [ActionSheetButtonItem(title: strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })])
        ])
        self.present(actionSheet, in: .window(.root))
    }

    func addTrack(library: MusicLibrary) {
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        self.present(legacyICloudFilePicker(theme: presentationData.theme, mode: .default, documentTypes: ["public.mp3", "public.mpeg-4-audio", "public.aac-audio", "org.xiph.flac"], completion: { [weak self, weak library] urls in
            guard let url = urls.first else {
                return
            }
            library?.addTrack(url: url, completion: { [weak self] success in
                guard let self else {
                    return
                }
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
            })
        }), in: .window(.root))
    }

    private func currentLibrary() -> MusicLibrary {
        if let library = self.library {
            return library
        }
        let library = MusicLibrary(context: self.context, playlistTitle: musicString(self.presentationData.strings, ru: "Плейлист", en: "Playlist"))
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

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.musicNode.containerLayoutUpdated(layout, transition: transition)
    }
}
