import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import AccountContext
import TelegramCore
import TelegramPresentationData
import PeerMessagesMediaPlaylist

/// Show All of a group of tracks in a chat: every track of the group in a sheet, as the Music section's rows.
/// A row plays the group from that track.
final class MusicTrackGroupSheet: ViewController {
    private let context: AccountContext
    private let messages: [EngineRawMessage]
    private var presentationData: PresentationData

    private var sheetNode: MusicTrackGroupSheetNode {
        return self.displayNode as! MusicTrackGroupSheetNode
    }

    init(context: AccountContext, messages: [EngineRawMessage]) {
        self.context = context
        self.messages = messages
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }

        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))

        self.navigationPresentation = .modal
        self._hasGlassStyle = true
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.title = musicTrackCountString(self.presentationData.strings, messages.count)
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Close, style: .plain, target: self, action: #selector(self.closePressed))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func closePressed() {
        self.dismiss()
    }

    override func loadDisplayNode() {
        self.displayNode = MusicTrackGroupSheetNode(context: self.context, presentationData: self.presentationData, messages: self.messages, play: { [weak self] message in
            self?.play(message: message)
        })
        self.displayNodeDidLoad()
    }

    private func play(message: EngineRawMessage) {
        let tracks = self.messages.map { MusicTrack(message: $0, isSaved: false) }
        guard let track = tracks.first(where: { $0.message.id == message.id }) else {
            return
        }
        let library = MusicLibrary.shared(context: self.context)
        let location = library.playlistLocation(track: track, tracks: tracks, title: self.title ?? "", kind: .chat(message.id.peerId))
        self.context.sharedContext.mediaManager.setPlaylist((self.context, PeerMessagesMediaPlaylist(context: self.context, location: location, chatLocationContextHolder: nil)), type: .music, control: .playback(.togglePlayPause))
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.sheetNode.containerLayoutUpdated(layout, navigationHeight: self.navigationLayout(layout: layout).navigationFrame.maxY, transition: transition)
    }
}

private final class MusicTrackGroupSheetNode: ASDisplayNode {
    private let listNode: MusicPlayerQueueListNode
    private let messages: [EngineRawMessage]

    init(context: AccountContext, presentationData: PresentationData, messages: [EngineRawMessage], play: @escaping (EngineRawMessage) -> Void) {
        self.messages = messages
        self.listNode = MusicPlayerQueueListNode(context: context, presentationData: presentationData)

        super.init()

        // The fill of the Music section's lists.
        self.backgroundColor = presentationData.theme.chatList.pinnedItemBackgroundColor
        self.addSubnode(self.listNode)
        self.listNode.openMessage = { message in
            play(message)
        }
    }

    private var hasItems = false

    func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
        transition.updateFrame(node: self.listNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        var insets = layout.insets(options: [])
        insets.top = navigationHeight
        self.listNode.updateLayout(size: layout.size, insets: insets, transition: transition)
        // Rows go in only once the list has a size: laid out at zero width, a track row computes an invalid frame.
        if !self.hasItems && layout.size.width > 0.0 {
            self.hasItems = true
            self.listNode.update(messages: self.messages, favoriteFileIds: Set(), currentId: nil, isPaused: true, canReorder: false, animated: false)
        }
    }
}

extension MusicPlayerSupport {
    /// Show All of a group of tracks in a chat bubble.
    public static func openTrackGroup(context: AccountContext, messages: [EngineRawMessage]) {
        guard !messages.isEmpty, let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController else {
            return
        }
        navigationController.pushViewController(MusicTrackGroupSheet(context: context, messages: messages))
    }
}

extension MusicPlayerSupport {
    /// Add to Music from a chat (message menu, selection panel): every music file of the messages goes into Music,
    /// on this device; the profile is not touched.
    /// Files already in Music are skipped, and the toast counts only the added ones.
    public static func addToMusic(context: AccountContext, messages: [EngineRawMessage]) {
        let library = MusicLibrary.shared(context: context)
        var seenFileIds = Set<Int64>()
        let files = messages.compactMap(chatMusicFile).filter { file in
            let fileId = file.fileId.id
            return library.track(fileId: fileId) == nil && seenFileIds.insert(fileId).inserted
        }
        if files.isEmpty {
            return
        }
        for file in files {
            library.addToMusic(file: file)
        }
        let toast = musicLibraryToast(strings: context.sharedContext.currentPresentationData.with { $0 }.strings, isInMusic: true, count: files.count)
        musicPlayerToast(context: context, text: toast.text, iconName: toast.iconName)
    }
}

extension MusicPlayerSupport {
    /// The files in Music, for the marks on tracks in chats.
    public static func libraryFileIds(context: AccountContext) -> Signal<Set<Int64>, NoError> {
        return MusicLibrary.shared(context: context).fileIdsSignal
    }

    /// Whether the file is in Music; safe off the main queue (a chat bubble's layout).
    public static func libraryContainsFile(context: AccountContext, fileId: Int64) -> Bool {
        return MusicLibrary.containsFile(accountId: context.account.id, fileId: fileId)
    }

    /// Whether the file is saved to the account's profile. Main queue only.
    public static func isSavedToProfile(context: AccountContext, fileId: Int64) -> Bool {
        let library = MusicLibrary.shared(context: context)
        if let track = library.track(fileId: fileId) {
            return library.isSavedToProfile(track)
        }
        return library.savedFileIds?.contains(fileId) ?? false
    }

    /// Add to Profile for a chat's track (shared media of a chat): the profile only, Music is not touched.
    public static func addToProfile(context: AccountContext, message: EngineRawMessage) {
        guard chatMusicFile(message) != nil else {
            return
        }
        let library = MusicLibrary.shared(context: context)
        library.setSavedToProfile(MusicTrack(message: message, isSaved: false), true)
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        musicPlayerToast(context: context, text: strings.MediaPlayer_SavedMusic_AddedToProfile, iconName: "Peer Info/SavedMusic")
    }
}

private func chatMusicFile(_ message: EngineRawMessage) -> TelegramMediaFile? {
    for media in message.media {
        if let file = media as? TelegramMediaFile, file.isMusic {
            return file
        }
    }
    return nil
}
