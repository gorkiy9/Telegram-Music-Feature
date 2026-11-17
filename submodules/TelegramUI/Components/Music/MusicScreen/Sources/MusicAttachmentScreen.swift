import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import AttachmentUI
import ChatSendMessageActionUI

/// The tracks and playlists picked in the attachment menu's Music tab, in the order they were picked, shared by all
/// its lists.
final class MusicAttachmentSelection {
    private(set) var tracks: [MusicTrack] = []
    private(set) var playlistIds: [Int] = []
    let updated = ValuePipe<Void>()
    let count = ValuePromise<Int>(0, ignoreRepeated: true)

    func contains(_ track: MusicTrack) -> Bool {
        return self.tracks.contains(where: { $0.message.id == track.message.id })
    }

    func toggle(_ track: MusicTrack) {
        if let index = self.tracks.firstIndex(where: { $0.message.id == track.message.id }) {
            self.tracks.remove(at: index)
        } else {
            self.tracks.append(track)
        }
        self.didUpdate()
    }

    /// A row reports a tap with the value it asks for, sometimes twice: setting it makes the second report a no-op.
    func set(_ track: MusicTrack, isSelected: Bool) {
        if self.contains(track) != isSelected {
            self.toggle(track)
        }
    }

    func contains(playlistId: Int) -> Bool {
        return self.playlistIds.contains(playlistId)
    }

    func toggle(playlistId: Int) {
        if let index = self.playlistIds.firstIndex(of: playlistId) {
            self.playlistIds.remove(at: index)
        } else {
            self.playlistIds.append(playlistId)
        }
        self.didUpdate()
    }

    func clear() {
        self.tracks.removeAll()
        self.playlistIds.removeAll()
        self.didUpdate()
    }

    private func didUpdate() {
        self.count.set(self.tracks.count + self.playlistIds.count)
        self.updated.putNext(Void())
    }
}

/// The Music tab of the attachment menu: the section's library (hub, Tracks, Artists, Playlists) in the menu's sheet.
/// A track tap selects it; with something selected the menu's tabs give way to the caption field and Send, as in the
/// gallery and files. The lists push inside the sheet on their own navigation stack, as in the section.
public final class MusicAttachmentScreen: ViewController, AttachmentContainable {
    public var requestAttachmentMenuExpansion: () -> Void = {}
    public var updateNavigationStack: (@escaping ([AttachmentContainable]) -> ([AttachmentContainable], AttachmentMediaPickerContext?)) -> Void = { _ in }
    public var parentController: () -> ViewController? = {
        return nil
    }
    public var updateTabBarAlpha: (CGFloat, ContainedViewLayoutTransition) -> Void = { _, _ in }
    public var updateTabBarVisibility: (Bool, ContainedViewLayoutTransition) -> Void = { _, _ in }
    public var cancelPanGesture: () -> Void = {}
    public var isContainerPanning: () -> Bool = { return false }
    public var isContainerExpanded: () -> Bool = { return false }
    public var isMinimized: Bool = false

    public var mediaPickerContext: AttachmentMediaPickerContext? {
        return MusicAttachmentPickerContext(controller: self)
    }

    fileprivate let context: AccountContext
    let selection = MusicAttachmentSelection()
    fileprivate var caption: NSAttributedString?
    private let peerId: EnginePeer.Id
    private let send: ([[AnyMediaReference]], Bool, NSAttributedString?) -> Void
    /// Set when the library is picked for the profile (Settings ▸ Music): instead of the caption field and Send the
    /// sheet shows one accent button, «Добавить в профиль».
    fileprivate var addToProfile: (([MusicTrack], [MusicPlaylist]) -> Void)?

    private let navigation: NavigationController
    private let screen: MusicScreen

    private var currentLayout: ContainerViewLayout?
    private var isAppearing = false

    /// `send` gets the groups to send in order, each a group of messages of its own: the picked tracks first (a chat's
    /// track as its message, a saved one as the profile's file), then every picked playlist apart. It also gets whether
    /// to send silently and the caption, which goes under the first group.
    public init(context: AccountContext, peerId: EnginePeer.Id, send: @escaping ([[AnyMediaReference]], Bool, NSAttributedString?) -> Void) {
        self.context = context
        self.peerId = peerId
        self.send = send
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let navigationTheme = NavigationControllerTheme(presentationTheme: presentationData.theme)
        self.navigation = NavigationController(mode: .single, theme: NavigationControllerTheme(statusBar: navigationTheme.statusBar, navigationBar: navigationTheme.navigationBar, emptyAreaColor: .clear, separatorColor: navigationTheme.separatorColor, opaqueBackgroundColor: navigationTheme.opaqueBackgroundColor))
        self.navigation.isOpaqueWhenInOverlay = false
        self.screen = MusicScreen(context: context, mode: .navigation, section: .hub, library: nil)

        super.init(navigationBarPresentationData: nil)

        self.statusBar.statusBarStyle = .Ignore
        self.navigationPresentation = .default
        self.screen.navigationPresentation = .default
        self.screen.attachmentSelection = self.selection
        self.screen.attachmentClose = { [weak self] in
            self?.dismiss(animated: true)
        }
        self.navigation.setViewControllers([self.screen], animated: false)
    }

    /// The same library sheet, picking tracks and playlists to put in the profile. `completion` gets what was picked;
    /// the sheet closes itself.
    convenience init(context: AccountContext, addToProfile completion: @escaping ([MusicTrack], [MusicPlaylist]) -> Void) {
        self.init(context: context, peerId: context.account.peerId, send: { _, _, _ in })
        self.addToProfile = completion
    }

    required public init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public var ready: Promise<Bool> {
        return self.screen.ready
    }

    override public func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNodeDidLoad()
        self.navigation.setIgnoreAppearanceMethodInvocations(true)
        self.displayNode.view.addSubview(self.navigation.view)
        self.navigation.setIgnoreAppearanceMethodInvocations(false)
    }

    /// The sheet starts expanded: the hub and its lists are full-height screens.
    public func prepareForReuse() {
        self.requestAttachmentMenuExpansion()
    }

    public func resetForReuse() {
        self.selection.clear()
        self.caption = nil
        if self.navigation.viewControllers.count > 1 {
            self.navigation.setViewControllers([self.screen], animated: false)
        }
    }

    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.currentLayout = layout
        guard self.isAppearing else {
            return
        }
        transition.updateFrame(view: self.navigation.view, frame: CGRect(origin: .zero, size: layout.size))
        self.navigation.containerLayoutUpdated(layout, transition: transition)
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !self.isAppearing {
            self.isAppearing = true
            if let layout = self.currentLayout {
                self.navigation.view.frame = CGRect(origin: .zero, size: layout.size)
                self.navigation.containerLayoutUpdated(layout, transition: .immediate)
            }
        }
        self.navigation.viewWillAppear(animated)
        self.requestAttachmentMenuExpansion()
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.navigation.viewDidAppear(animated)
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.navigation.viewWillDisappear(animated)
    }

    fileprivate func addSelectedToProfile() {
        guard let addToProfile = self.addToProfile else {
            return
        }
        let library = MusicLibrary.shared(context: self.context)
        let tracks = self.selection.tracks
        let playlists = self.selection.playlistIds.compactMap { library.playlist(id: $0) }
        guard !tracks.isEmpty || !playlists.isEmpty else {
            return
        }
        addToProfile(tracks, playlists)
        self.dismiss(animated: true)
    }

    fileprivate func sendSelected(silently: Bool) {
        let tracks = self.selection.tracks
        let library = MusicLibrary.shared(context: self.context)
        let playlists = self.selection.playlistIds.compactMap { library.playlist(id: $0) }
        guard !tracks.isEmpty || !playlists.isEmpty else {
            return
        }
        let caption = self.caption
        let send = self.send
        let peerId = self.peerId
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.context.account.peerId))
        |> deliverOnMainQueue).start(next: { [weak self] accountPeer in
            let peerReference = accountPeer.flatMap { PeerReference($0._asPeer()) }
            let mediaReference: (MusicTrack) -> AnyMediaReference? = { track in
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
            var groups: [[AnyMediaReference]] = []
            let trackGroup = tracks.compactMap(mediaReference)
            if !trackGroup.isEmpty {
                groups.append(trackGroup)
            }
            // A playlist goes as a message of its own: in the test chat its bubble, elsewhere its tracks as one group
            // (the API has no playlists, as with Share).
            let ownerName = accountPeer?.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
            for playlist in playlists {
                let playlistTracks = library.tracks(of: playlist)
                if musicSendsPlaylistBubble(to: peerId) {
                    let webpage = musicSharedPlaylistWebpage(playlist: playlist, files: playlistTracks.compactMap(\.file), ownerName: ownerName)
                    groups.append([.standalone(media: webpage)])
                } else {
                    let group = playlistTracks.compactMap(mediaReference)
                    if !group.isEmpty {
                        groups.append(group)
                    }
                }
            }
            if !groups.isEmpty {
                send(groups, silently, caption)
            }
            self?.dismiss(animated: true)
        })
    }

    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.navigation.viewDidDisappear(animated)
    }
}

private final class MusicAttachmentPickerContext: AttachmentMediaPickerContext {
    private weak var controller: MusicAttachmentScreen?

    init(controller: MusicAttachmentScreen) {
        self.controller = controller
    }

    private var isAddingToProfile: Bool {
        return self.controller?.addToProfile != nil
    }

    /// For the profile the selection does not turn the panel into the caption field: the main button takes its place.
    var selectionCount: Signal<Int, NoError> {
        if self.isAddingToProfile {
            return .single(0)
        }
        return self.controller?.selection.count.get() ?? .single(0)
    }

    var caption: Signal<NSAttributedString?, NoError> {
        return .single(self.controller?.caption)
    }

    var hasCaption: Bool {
        return !self.isAddingToProfile
    }

    func setCaption(_ caption: NSAttributedString) {
        self.controller?.caption = caption
    }

    func send(mode: AttachmentMediaPickerSendMode, attachmentMode: AttachmentMediaPickerAttachmentMode, parameters: ChatSendMessageActionSheetController.SendParameters?) {
        self.controller?.sendSelected(silently: mode == .silently)
    }

    func schedule(parameters: ChatSendMessageActionSheetController.SendParameters?) {
    }

    /// «Добавить в профиль» in the accent colour with the client's filled Add to Profile icon (profile with a note, as on the player); it shows once something is
    /// picked. From two picks on, the count sits at the button's trailing edge and the title moves left for it.
    var mainButtonState: Signal<AttachmentMainButtonState?, NoError> {
        guard let controller = self.controller, controller.addToProfile != nil else {
            return .single(nil)
        }
        return combineLatest(controller.selection.count.get(), controller.context.sharedContext.presentationData)
        |> map { count, presentationData -> AttachmentMainButtonState? in
            let colors = presentationData.theme.list.itemCheckColors
            return AttachmentMainButtonState(text: presentationData.strings.Music_AddToProfile, badge: count > 1 ? "\(count)" : nil, font: .bold, background: .color(colors.fillColor), textColor: colors.foregroundColor, isVisible: count > 0, progress: .none, isEnabled: count > 0, hasShimmer: false, iconName: "Peer Info/SaveMusic", badgeAlignment: .trailing)
        }
    }

    func mainButtonAction() {
        self.controller?.addSelectedToProfile()
    }
}
