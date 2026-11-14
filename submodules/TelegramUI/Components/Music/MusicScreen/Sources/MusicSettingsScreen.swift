import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import ItemListPeerItem
import ItemListPeerActionItem
import PresentationDataUtils
import AccountContext
import UndoUI
import ListMessageItem
import PeerMessagesMediaPlaylist
import AttachmentUI

/// Settings ▸ Music: whether the section is in the tab bar, which chats its music comes from, and emptying it.
/// Built as the client's settings lists are (Archive, Data and Storage): an item list with glass rows.
private final class MusicSettingsArguments {
    let context: AccountContext
    let setTabShown: (Bool) -> Void
    let setAllChats: (Bool) -> Void
    let addChats: () -> Void
    let removeChat: (EnginePeer.Id) -> Void
    let setRevealedPeerId: (EnginePeer.Id?, EnginePeer.Id?) -> Void
    let removeAll: () -> Void
    let addProfileTracks: () -> Void
    let playProfileTrack: (MusicTrack) -> Void
    let removeProfileTrack: (MusicTrack) -> Void
    let openProfilePlaylist: (MusicPlaylist) -> Void
    let removeProfilePlaylist: (MusicPlaylist) -> Void

    init(context: AccountContext, setTabShown: @escaping (Bool) -> Void, setAllChats: @escaping (Bool) -> Void, addChats: @escaping () -> Void, removeChat: @escaping (EnginePeer.Id) -> Void, setRevealedPeerId: @escaping (EnginePeer.Id?, EnginePeer.Id?) -> Void, removeAll: @escaping () -> Void, addProfileTracks: @escaping () -> Void, playProfileTrack: @escaping (MusicTrack) -> Void, removeProfileTrack: @escaping (MusicTrack) -> Void, openProfilePlaylist: @escaping (MusicPlaylist) -> Void, removeProfilePlaylist: @escaping (MusicPlaylist) -> Void) {
        self.context = context
        self.addProfileTracks = addProfileTracks
        self.playProfileTrack = playProfileTrack
        self.removeProfileTrack = removeProfileTrack
        self.openProfilePlaylist = openProfilePlaylist
        self.removeProfilePlaylist = removeProfilePlaylist
        self.setTabShown = setTabShown
        self.setAllChats = setAllChats
        self.addChats = addChats
        self.removeChat = removeChat
        self.setRevealedPeerId = setRevealedPeerId
        self.removeAll = removeAll
    }
}

private enum MusicSettingsSection: Int32 {
    case tab
    case profileTracks
    case profilePlaylists
    case sources
    case removal
}

private enum MusicSettingsEntryId: Hashable {
    case index(Int32)
    case peer(EnginePeer.Id)
    case profileTrack(Int64)
    case profilePlaylist(Int)
}

/// The fake peer a playlist row is drawn with: its letter avatar, or its cover as the photo (as on the Music lists).
private func musicPlaylistRowPeer(_ playlist: MusicPlaylist) -> EnginePeer {
    return EnginePeer(TelegramGroup(id: EnginePeer.Id(namespace: Namespaces.Peer.CloudGroup, id: EnginePeer.Id.Id._internalFromInt64Value(Int64(playlist.id) + 1)), title: playlist.title, photo: playlist.cover.flatMap { [$0] } ?? [], participantCount: 0, role: .creator(rank: nil), membership: .Member, flags: [], defaultBannedRights: nil, migrationReference: nil, creationDate: 0, version: 0))
}

private enum MusicSettingsEntry: ItemListNodeEntry {
    case tabSwitch(Bool)
    case tabFooter
    case profileTracksHeader(hasItems: Bool)
    case addProfileTracks
    case profileTrack(index: Int, track: MusicTrack)
    case profilePlaylistsHeader
    case profilePlaylist(index: Int, playlist: MusicPlaylist, subtitle: String, isRevealed: Bool)
    case profileFooter(hasItems: Bool, afterPlaylists: Bool)
    case sourcesHeader
    case allChats(Bool)
    case chosenChats(Bool)
    case addChats
    case chat(index: Int, peer: EnginePeer, isRevealed: Bool)
    case sourcesFooter(allChats: Bool)
    case removeAll
    case removeAllFooter

    var section: ItemListSectionId {
        switch self {
        case .tabSwitch, .tabFooter:
            return MusicSettingsSection.tab.rawValue
        case .profileTracksHeader, .addProfileTracks, .profileTrack:
            return MusicSettingsSection.profileTracks.rawValue
        case let .profileFooter(_, afterPlaylists):
            // The footer belongs to the last block above it, so it sits at the usual footer inset.
            return (afterPlaylists ? MusicSettingsSection.profilePlaylists : MusicSettingsSection.profileTracks).rawValue
        case .profilePlaylistsHeader, .profilePlaylist:
            return MusicSettingsSection.profilePlaylists.rawValue
        case .sourcesHeader, .allChats, .chosenChats, .addChats, .chat, .sourcesFooter:
            return MusicSettingsSection.sources.rawValue
        case .removeAll, .removeAllFooter:
            return MusicSettingsSection.removal.rawValue
        }
    }

    var stableId: MusicSettingsEntryId {
        switch self {
        case .tabSwitch:
            return .index(0)
        case .tabFooter:
            return .index(1)
        case .profileTracksHeader:
            return .index(10)
        case .addProfileTracks:
            return .index(13)
        case let .profileTrack(_, track):
            return .profileTrack(track.file?.fileId.id ?? Int64(track.message.id.id))
        case .profilePlaylistsHeader:
            return .index(11)
        case let .profilePlaylist(_, playlist, _, _):
            return .profilePlaylist(playlist.id)
        case .profileFooter:
            return .index(12)
        case .sourcesHeader:
            return .index(2)
        case .allChats:
            return .index(3)
        case .chosenChats:
            return .index(4)
        case .addChats:
            return .index(5)
        case let .chat(_, peer, _):
            return .peer(peer.id)
        case .sourcesFooter:
            return .index(6)
        case .removeAll:
            return .index(7)
        case .removeAllFooter:
            return .index(8)
        }
    }

    private var sortIndex: Int {
        switch self {
        case .tabSwitch:
            return 0
        case .tabFooter:
            return 1
        case .profileTracksHeader:
            return 10
        case .addProfileTracks:
            return 11
        case let .profileTrack(index, _):
            return 20 + index
        case .profilePlaylistsHeader:
            return 30_000
        case let .profilePlaylist(index, _, _, _):
            return 30_001 + index
        case .profileFooter:
            return 59_999
        case .sourcesHeader:
            return 60_002
        case .allChats:
            return 60_003
        case .chosenChats:
            return 60_004
        case .addChats:
            return 60_005
        case let .chat(index, _, _):
            return 60_100 + index
        case .sourcesFooter:
            return 100_000
        case .removeAll:
            return 100_001
        case .removeAllFooter:
            return 100_002
        }
    }

    static func ==(lhs: MusicSettingsEntry, rhs: MusicSettingsEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.tabSwitch(a), .tabSwitch(b)), let (.allChats(a), .allChats(b)), let (.chosenChats(a), .chosenChats(b)):
            return a == b
        case let (.sourcesFooter(a), .sourcesFooter(b)), let (.profileTracksHeader(a), .profileTracksHeader(b)):
            return a == b
        case let (.profileFooter(a, c), .profileFooter(b, d)):
            return a == b && c == d
        case let (.profileTrack(lIndex, lTrack), .profileTrack(rIndex, rTrack)):
            return lIndex == rIndex && lTrack.message.id == rTrack.message.id && lTrack.message.stableVersion == rTrack.message.stableVersion && lTrack.title == rTrack.title && lTrack.artist == rTrack.artist
        case let (.profilePlaylist(lIndex, lPlaylist, lSubtitle, lRevealed), .profilePlaylist(rIndex, rPlaylist, rSubtitle, rRevealed)):
            return lIndex == rIndex && lPlaylist == rPlaylist && lSubtitle == rSubtitle && lRevealed == rRevealed
        case (.profilePlaylistsHeader, .profilePlaylistsHeader):
            return true
        case let (.chat(lIndex, lPeer, lRevealed), .chat(rIndex, rPeer, rRevealed)):
            return lIndex == rIndex && lPeer == rPeer && lRevealed == rRevealed
        case (.tabFooter, .tabFooter), (.sourcesHeader, .sourcesHeader), (.addChats, .addChats), (.addProfileTracks, .addProfileTracks), (.removeAll, .removeAll), (.removeAllFooter, .removeAllFooter):
            return true
        default:
            return false
        }
    }

    static func <(lhs: MusicSettingsEntry, rhs: MusicSettingsEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! MusicSettingsArguments
        let strings = presentationData.strings
        switch self {
        case let .tabSwitch(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: strings.Music_MusicTab, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setTabShown(value)
            })
        case .tabFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(strings.Music_ShowMusicInTabBar), sectionId: self.section)
        case let .profileTracksHeader(hasItems):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: hasItems ? strings.Music_TracksInProfileHeader : strings.Music_MusicInProfileHeader, sectionId: self.section)
        case .addProfileTracks:
            // As «Добавить чаты» below: the list's plus row opens the picker.
            return ItemListPeerActionItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesItemList.plusIconImage(presentationData.theme), title: strings.Music_AddTracks, alwaysPlain: false, sectionId: self.section, height: .peerList, editing: false, action: {
                arguments.addProfileTracks()
            })
        case let .profileTrack(_, track):
            let interaction = ListMessageItemInteraction(openMessage: { _, _ in
                arguments.playProfileTrack(track)
                return true
            }, openMessageContextMenu: { _, _, _, _, _ in
            }, toggleMediaPlayback: { _ in
                arguments.playProfileTrack(track)
            }, toggleMessagesSelection: { _, _ in
            }, openUrl: { _, _, _, _ in
            }, openInstantPage: { _, _ in
            }, longTap: { _, _ in
            }, getHiddenMedia: {
                return [:]
            })
            let theme = presentationData.theme
            let colors = theme.list.itemDisclosureActions.destructive
            var icon = ItemListRevealOptionIcon.none
            if let image = generateTintedImage(image: UIImage(bundleImageName: "Music/RemoveFromProfile"), color: colors.foregroundColor) {
                icon = .image(image: image)
            }
            let removeOption = ListMessageItemRevealOption(option: ItemListRevealOption(key: 0, title: strings.Music_Remove, icon: icon, color: colors.fillColor, iconColor: colors.foregroundColor, textColor: theme.list.itemSecondaryTextColor, isDestructive: true, displaysTitle: false), action: {
                arguments.removeProfileTrack(track)
            })
            let chatPresentationData = musicChatPresentationData(arguments.context.sharedContext.currentPresentationData.with { $0 })
            return ListMessageItem(presentationData: chatPresentationData, systemStyle: .glass, context: arguments.context, chatLocation: .peer(id: track.message.id.peerId), interaction: interaction, message: track.message, selection: .none, displayHeader: false, isGlobalSearchResult: !track.isSaved, isSavedMusic: track.isSaved, displayFileInfo: true, audioInfo: .performer, hidesAudioFileExtension: true, blockTopInset: 0.0, displayBackground: true, rightRevealOptions: [removeOption], displaysAudioCover: true, style: .blocks, sectionId: self.section)
        case .profilePlaylistsHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: strings.Music_PlaylistsInProfileHeader, sectionId: self.section)
        case let .profilePlaylist(_, playlist, subtitle, isRevealed):
            let peer = musicPlaylistRowPeer(playlist)
            return ItemListPeerItem(presentationData: presentationData, systemStyle: .glass, dateTimeFormat: PresentationDateTimeFormat(), nameDisplayOrder: .firstLast, context: arguments.context, peer: peer, height: .peerList, aliasHandling: .standard, presence: nil, text: .text(subtitle, .secondary), label: .none, editing: ItemListPeerItemEditing(editable: true, editing: false, revealed: isRevealed), revealOptions: ItemListPeerItemRevealOptions(options: [ItemListPeerItemRevealOption(type: .destructive, title: strings.Music_Remove, action: {
                arguments.removeProfilePlaylist(playlist)
            })]), switchValue: nil, enabled: true, selectable: true, sectionId: self.section, action: {
                arguments.openProfilePlaylist(playlist)
            }, setPeerIdWithRevealedOptions: { lhs, rhs in
                arguments.setRevealedPeerId(lhs, rhs)
            }, removePeer: { _ in
                arguments.removeProfilePlaylist(playlist)
            })
        case let .profileFooter(hasItems, _):
            let text = hasItems ? strings.Music_TheseTracksAndPlaylistsAppearInLibraryOf : strings.Music_TracksAndPlaylistsYouAddAppearHereAnd
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .sourcesHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: strings.Music_MusicFromChatsHeader, sectionId: self.section)
        case let .allChats(checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: strings.Music_AllChats, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.setAllChats(true)
            })
        case let .chosenChats(checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: strings.Music_SelectedChats, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.setAllChats(false)
            })
        case .addChats:
            return ItemListPeerActionItem(presentationData: presentationData, systemStyle: .glass, icon: PresentationResourcesItemList.plusIconImage(presentationData.theme), title: strings.Music_AddChats, alwaysPlain: false, sectionId: self.section, height: .peerList, editing: false, action: {
                arguments.addChats()
            })
        case let .chat(_, peer, isRevealed):
            return ItemListPeerItem(presentationData: presentationData, systemStyle: .glass, dateTimeFormat: PresentationDateTimeFormat(), nameDisplayOrder: .firstLast, context: arguments.context, peer: peer, height: .peerList, aliasHandling: .threatSelfAsSaved, presence: nil, text: .none, label: .none, editing: ItemListPeerItemEditing(editable: true, editing: false, revealed: isRevealed), revealOptions: ItemListPeerItemRevealOptions(options: [ItemListPeerItemRevealOption(type: .destructive, title: strings.Common_Delete, action: {
                arguments.removeChat(peer.id)
            })]), switchValue: nil, enabled: true, selectable: false, sectionId: self.section, action: nil, setPeerIdWithRevealedOptions: { lhs, rhs in
                arguments.setRevealedPeerId(lhs, rhs)
            }, removePeer: { id in
                arguments.removeChat(id)
            })
        case let .sourcesFooter(allChats):
            let text = allChats ? strings.Music_AudioFilesFromAllChatsAppearInMusic : strings.Music_OnlyAudioFilesFromSelectedChatsAppearIn
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .removeAll:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: strings.Music_DeleteAllMusic, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.removeAll()
            })
        case .removeAllFooter:
            return ItemListTextItem(presentationData: presentationData, text: .plain(strings.Music_TracksAndPlaylistsWillBeRemovedFromMusic), sectionId: self.section)
        }
    }
}

private struct MusicSettingsState: Equatable {
    var revealedPeerId: EnginePeer.Id?
}

private func musicSettingsEntries(strings: PresentationStrings, isTabShown: Bool, profile: (tracks: [MusicTrack], playlists: [(MusicPlaylist, String)]), sources: MusicSourceSettings, peers: [EnginePeer], state: MusicSettingsState) -> [MusicSettingsEntry] {
    var entries: [MusicSettingsEntry] = []
    entries.append(.tabSwitch(isTabShown))
    entries.append(.tabFooter)
    // What the profile shows (Library in the profile): played here, taken out with a swipe.
    let hasProfileItems = !profile.tracks.isEmpty || !profile.playlists.isEmpty
    entries.append(.profileTracksHeader(hasItems: !profile.tracks.isEmpty))
    entries.append(.addProfileTracks)
    for (index, track) in profile.tracks.enumerated() {
        entries.append(.profileTrack(index: index, track: track))
    }
    if !profile.playlists.isEmpty {
        entries.append(.profilePlaylistsHeader)
        for (index, item) in profile.playlists.enumerated() {
            let peerId = musicPlaylistRowPeer(item.0).id
            entries.append(.profilePlaylist(index: index, playlist: item.0, subtitle: item.1, isRevealed: state.revealedPeerId == peerId))
        }
    }
    entries.append(.profileFooter(hasItems: hasProfileItems, afterPlaylists: !profile.playlists.isEmpty))
    entries.append(.sourcesHeader)
    entries.append(.allChats(sources.allChats))
    entries.append(.chosenChats(!sources.allChats))
    if !sources.allChats {
        entries.append(.addChats)
        for (index, peer) in peers.enumerated() {
            entries.append(.chat(index: index, peer: peer, isRevealed: state.revealedPeerId == peer.id))
        }
    }
    entries.append(.sourcesFooter(allChats: sources.allChats))
    entries.append(.removeAll)
    entries.append(.removeAllFooter)
    return entries
}

public func musicSettingsController(context: AccountContext) -> ViewController {
    let statePromise = ValuePromise(MusicSettingsState(), ignoreRepeated: true)
    let stateValue = Atomic(value: MusicSettingsState())
    let updateState: ((MusicSettingsState) -> MusicSettingsState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    var currentSources = MusicSourceSettings.default
    let updateSources: ((inout MusicSourceSettings) -> Void) -> Void = { f in
        var sources = currentSources
        f(&sources)
        currentSources = sources
        setMusicSourceSettings(context: context, sources)
    }

    var presentImpl: ((ViewController) -> Void)?
    var pushImpl: ((ViewController) -> Void)?
    var presentToastImpl: ((String) -> Void)?
    var presentIconToastImpl: ((String, String) -> Void)?

    let arguments = MusicSettingsArguments(context: context, setTabShown: { value in
        setMusicTabIsShown(context: context, value)
    }, setAllChats: { value in
        updateSources { $0.allChats = value }
    }, addChats: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let strings = presentationData.strings
        let controller = context.sharedContext.makeContactMultiselectionController(ContactMultiselectionControllerParams(context: context, mode: .chatSelection(ContactMultiselectionControllerMode.ChatSelection(
            title: strings.Music_ChatsWithMusic,
            searchPlaceholder: strings.ChatListFilter_AddChatsSearchPlaceholder,
            selectedChats: Set(currentSources.chosenPeerIds),
            additionalCategories: nil,
            chatListFilters: nil
        )), filters: [], alwaysEnabled: true))
        controller.navigationPresentation = .modal
        let _ = (controller.result
        |> take(1)
        |> deliverOnMainQueue).startStandalone(next: { [weak controller] result in
            guard case let .result(peerIds, _) = result else {
                controller?.dismiss()
                return
            }
            var chosen: [EnginePeer.Id] = []
            for peerId in peerIds {
                if case let .peer(id) = peerId {
                    chosen.append(id)
                }
            }
            updateSources { sources in
                // Chats already listed keep their place; new ones go to the end.
                let kept = sources.chosenPeerIds.filter { chosen.contains($0) }
                let added = chosen.filter { !kept.contains($0) }
                sources.peerIds = (kept + added).map { $0.toInt64() }
            }
            controller?.dismiss()
        })
        pushImpl?(controller)
    }, removeChat: { peerId in
        updateState { state in
            var state = state
            state.revealedPeerId = nil
            return state
        }
        updateSources { sources in
            sources.peerIds.removeAll(where: { $0 == peerId.toInt64() })
        }
    }, setRevealedPeerId: { peerId, fromPeerId in
        updateState { state in
            var state = state
            if (peerId == nil && fromPeerId == state.revealedPeerId) || (peerId != nil && fromPeerId == nil) {
                state.revealedPeerId = peerId
            }
            return state
        }
    }, removeAll: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let strings = presentationData.strings
        let actionSheet = ActionSheetController(presentationData: presentationData)
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: strings.Music_AllTracksAndPlaylistsWillBeRemovedFrom),
                ActionSheetButtonItem(title: strings.Music_DeleteAllMusic, color: .destructive, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    MusicLibrary.shared(context: context).removeAll()
                    presentToastImpl?(strings.Music_MusicDeleted)
                })
            ]),
            ActionSheetItemGroup(items: [ActionSheetButtonItem(title: strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })])
        ])
        presentImpl?(actionSheet)
    }, addProfileTracks: {
        // The library in the attachment sheet, as tracks are attached to a message; the caption field and Send give way
        // to one accent button, «Добавить в профиль».
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let strings = presentationData.strings
        let attachmentController = AttachmentController(context: context, updatedPresentationData: nil, style: .glass, chatLocation: nil, buttons: [.standalone], initialButton: .standalone, fromMenu: false, hasTextInput: false)
        attachmentController.requestController = { _, present in
            let screen = MusicAttachmentScreen(context: context, addToProfile: { tracks, playlists in
                let library = MusicLibrary.shared(context: context)
                let newTracks = tracks.filter { !library.isSavedToProfile($0) }
                let newPlaylists = playlists.filter { !$0.isInProfile }
                for track in newTracks {
                    library.setSavedToProfile(track, true)
                }
                for playlist in newPlaylists {
                    library.setPlaylistInProfile(id: playlist.id, true)
                }
                let count = newTracks.count + newPlaylists.count
                let text: String
                if count == 0 {
                    text = strings.Music_AlreadyInYourProfile
                } else if newTracks.count == 1 && newPlaylists.isEmpty {
                    text = strings.MediaPlayer_SavedMusic_AddedToProfile
                } else if newPlaylists.count == 1 && newTracks.isEmpty {
                    text = strings.Music_PlaylistWasAddedToYourProfile
                } else {
                    text = strings.Music_AddedToYourProfile("\(count)").string
                }
                presentIconToastImpl?(text, "Peer Info/SavedMusic")
            })
            present(screen, screen.mediaPickerContext)
            return true
        }
        attachmentController.navigationPresentation = .flatModal
        attachmentController.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        pushImpl?(attachmentController)
    }, playProfileTrack: { track in
        let library = MusicLibrary.shared(context: context)
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        let location = library.playlistLocation(track: track, tracks: library.profileTracks, title: MusicPlayerSupport.libraryTitle(strings: strings), kind: .profile(context.account.peerId), source: { [weak library] in
            return library?.profileTracks
        })
        context.sharedContext.mediaManager.setPlaylist((context, PeerMessagesMediaPlaylist(context: context, location: location, chatLocationContextHolder: nil)), type: .music, control: .playback(.togglePlayPause))
    }, removeProfileTrack: { track in
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        MusicLibrary.shared(context: context).setSavedToProfile(track, false)
        presentIconToastImpl?(strings.Music_TrackWasRemovedFromYourProfile, "Peer Info/SavedMusic")
    }, openProfilePlaylist: { playlist in
        pushImpl?(MusicScreen(context: context, mode: .navigation, section: .playlist(playlist.id), library: MusicLibrary.shared(context: context)))
    }, removeProfilePlaylist: { playlist in
        updateState { state in
            var state = state
            state.revealedPeerId = nil
            return state
        }
        let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
        MusicLibrary.shared(context: context).setPlaylistInProfile(id: playlist.id, false)
        presentIconToastImpl?(strings.Music_PlaylistWasRemovedFromYourProfile, "Peer Info/SavedMusic")
    })

    let sources = musicSourceSettings(context: context)
    let peers: Signal<[EnginePeer], NoError> = sources
    |> map { $0.chosenPeerIds }
    |> distinctUntilChanged
    |> mapToSignal { peerIds -> Signal<[EnginePeer], NoError> in
        return context.engine.data.subscribe(EngineDataList(peerIds.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) }))
        |> map { peers in
            return peers.compactMap { $0 }
        }
    }

    // The profile's tracks and playlists, as the shared library has them, after every change of it.
    let profile = Signal<(tracks: [MusicTrack], playlists: [(MusicPlaylist, String)]), NoError> { subscriber in
        let library = MusicLibrary.shared(context: context)
        let put: () -> Void = {
            let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
            subscriber.putNext((library.profileTracks, library.profilePlaylists.map { ($0, musicPlaylistSubtitle(strings, playlist: $0, library: library)) }))
        }
        put()
        return library.updated.signal().start(next: { _ in
            put()
        })
    }
    |> runOn(Queue.mainQueue())

    let signal = combineLatest(queue: .mainQueue(),
        context.sharedContext.presentationData,
        musicTabIsShown(context: context),
        profile,
        sources,
        peers,
        statePromise.get()
    )
    |> map { presentationData, isTabShown, profile, sources, peers, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        currentSources = sources
        let strings = presentationData.strings
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(strings.Music_Music), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: musicSettingsEntries(strings: strings, isTabShown: isTabShown, profile: profile, sources: sources, peers: peers, state: state), style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    pushImpl = { [weak controller] c in
        controller?.push(c)
    }
    presentToastImpl = { [weak controller] text in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        controller?.present(UndoOverlayController(presentationData: presentationData, content: .succeed(text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in
            return false
        }), in: .current)
    }
    presentIconToastImpl = { [weak controller] text, iconName in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        guard let content = musicToastContent(text: text, iconName: iconName) else {
            return
        }
        controller?.present(UndoOverlayController(presentationData: presentationData, content: content, elevatedLayout: false, action: { _ in
            return true
        }), in: .current)
    }
    return controller
}
