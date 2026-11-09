import Foundation
import UIKit
import Display
import AsyncDisplayKit
import ComponentFlow
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import AccountContext
import DirectionalPanGesture
import ChatPresentationInterfaceState
import ChatControllerInteraction
import ContextUI
import UndoUI
import ChatHistoryEntry
import MultilineTextComponent
import GlassControls
import PhotoResources
import InstantPageUI
import MusicScreen

final class OverlayAudioPlayerControllerNode: ViewControllerTracingNode, ASGestureRecognizerDelegate {
    let ready = Promise<Bool>()
    
    private let context: AccountContext
    
    private let source: ChatHistoryListSource
    private let chatLocation: ChatLocation
    private var presentationData: PresentationData
    private let type: MediaManagerPlayerType
    private let requestDismiss: () -> Void
    private let requestShare: (ShareControllerSubject) -> Void
    private let requestSearchByArtist: (String) -> Void
    private let requestAdd: () -> Void
    private let playlistLocation: SharedMediaPlaylistLocation?
    private let isGlobalSearch: Bool
    
    private let controllerInteraction: ChatControllerInteraction
    
    private var currentIsReversed: Bool
    
    private let dimNode: ASDisplayNode
    private let containerContainingNode: ASDisplayNode
    private let contentNode: ASDisplayNode
    private let controlsNode: OverlayAudioPlayerControlsNode
    private let historyBackgroundNode: ASDisplayNode
    private let historyBackgroundContentNode: ASDisplayNode
    private let historyFrameNode: SparseNode
    private let historyFrameLeftOverlayNode: ASDisplayNode
    private let historyFrameRightOverlayNode: ASDisplayNode
    private let historyFrameTopOverlayClipNode: ASDisplayNode
    private let historyFrameTopOverlayNode: ASDisplayNode
    private let historyFrameTopMaskNode: ASImageNode
    private let collapseNode: HighlightableButtonNode
    private let headerButtons = ComponentView<Empty>()
    private let title = ComponentView<Empty>()
    
    private var floatingHeaderOffset: CGFloat?
    private var historyContentOffset: CGFloat = 0.0
    private var hasAnyHistoryMessages: Bool?
    private var historyNode: ChatHistoryListNodeImpl
    private var replacementHistoryNode: ChatHistoryListNodeImpl?
    private var replacementHistoryNodeFloatingOffset: CGFloat?
    
    private var currentAlbumArt: (FileMediaReference, SharedMediaPlaybackAlbumArt)?
    private let albumArtBackground: UIVisualEffectView
    private let albumArtNode = TransformImageNode()
    
    private var saveMediaDisposable: MetaDisposable?
    
    private var validLayout: ContainerViewLayout?
    private var containerUsesCornerRadii = false
    
    private var presentationDataDisposable: Disposable?
    private let replacementHistoryNodeReadyDisposable = MetaDisposable()
    
    private let getParentController: () -> ViewController?
        
    private var dataDisposable: Disposable?
    private var savedIdsPromise = Promise<Set<Int64>?>()
    private var savedIds: Set<Int64>?
    private var peer: EnginePeer?
    
    private var copyProtectionEnabled = false
    
    /// The Music section's compact sheet; the queue header opens the full player with the track list.
    private var isCompact = false
    private var favoriteFileIds = Set<Int64>()
    private var libraryState: MusicPlayerLibraryState?
    private var libraryQueue: MusicPlayerQueueInfo?
    private var sourceCount: Int?
    private var sourceChatPeer: EnginePeer?
    private let compactDataDisposable = MetaDisposable()
    
    /// The queue sheet (Figma Player / Queue List 301:17254), opened from the compact sheet's header: a toolbar with
    /// Reverse, the queue's name and its menu over the tracks still to play, the compact card at the bottom.
    private var isQueueOpen = false
    private let queueSheetNode = ASDisplayNode()
    private let queueSheetShadowView = UIView()
    private let queueGrabberNode = ASImageNode()
    private let queueReverseButton = HighlightableButtonNode()
    private let queueTitleButton = HighlightTrackingButtonNode()
    private let queueSubtitleNode = ImmediateTextNode()
    private let queueLabelNode = ImmediateTextNode()
    private let queueBadgeNode = ASDisplayNode()
    private let queueBadgeTextNode = ImmediateTextNode()
    private let queueMoreButton = HighlightableButtonNode()
    private let queueMoreReferenceNode = ContextReferenceContentNode()
    private var queueListNode: MusicPlayerQueueListNode?
    private let queueMessagesDisposable = MetaDisposable()
    /// The queue in play order, as far as it is known.
    private var queueMessages: [EngineRawMessage] = []
    /// The queue is the Music section's own: it can be reordered and its tracks play without replacing it.
    private var queueIsLibrary = false
    /// «Транслировать в профиль» has no API behind it: the choice is kept for the player's lifetime only.
    private var isBroadcastingToProfile = false
    private var queueSheetOpeningFrame: CGRect?
    /// The sheet is folding back into the compact one's header; the card keeps its place meanwhile.
    private var isQueueClosing = false
    /// The open sheet dragged down by the finger: its top moves, the card stays.
    private var queueDragOffset: CGFloat = 0.0
    /// A swipe up on the compact sheet pulls the queue sheet out of its header; the card stays.
    private var isQueueInteractivelyOpening = false
    private var queueInteractiveBaseFrame: CGRect?
    private var queueOpenFrame: CGRect?
    private var queueCloseToken = 0
    private static let queueToolbarHeight: CGFloat = 86.0
    /// The client's sheet spring, shared by the sheet, the card and their outlines so they move as one.
    private static let queueSheetTransition: ContainedViewLayoutTransition = .animated(duration: 0.42, curve: .spring)
    /// The card's top corners: the sheet reaches this far under the card, so nothing of it shows past the card.
    private static let queueCardOverlap: CGFloat = 38.0
        
    init(
        context: AccountContext,
        chatLocation: ChatLocation,
        type: MediaManagerPlayerType,
        initialMessageId: EngineMessage.Id,
        initialOrder: MusicPlaybackSettingsOrder,
        playlistLocation: SharedMediaPlaylistLocation?,
        requestDismiss: @escaping () -> Void,
        requestShare: @escaping (ShareControllerSubject) -> Void,
        requestSearchByArtist: @escaping (String) -> Void,
        requestAdd: @escaping () -> Void,
        getParentController: @escaping () -> ViewController?
    ) {
        self.context = context
        self.chatLocation = chatLocation
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.type = type
        self.requestDismiss = requestDismiss
        self.requestShare = requestShare
        self.requestSearchByArtist = requestSearchByArtist
        self.requestAdd = requestAdd
        self.playlistLocation = playlistLocation
        self.getParentController = getParentController
        
        if let playlistLocation = playlistLocation as? PeerMessagesPlaylistLocation, case let .custom(messages, canReorder, at, loadMore, _) = playlistLocation.effectiveLocation(context: context) {
            // Preserved as-is: every existing `.custom` location reaching here is saved music
            // (`.savedMusic` is rewritten into `.custom` by effectiveLocation). The rich-message
            // branch below passes false, because its rows are not saved music.
            let isSavedMusic = true
            self.source = .custom(messages: messages, messageId: at, quote: nil, isSavedMusic: isSavedMusic, canReorder: canReorder, richMessageId: nil, loadMore: loadMore)
            self.isGlobalSearch = false
        } else if let instantPageLocation = playlistLocation as? InstantPagePlaylistLocation, let richMessageId = instantPageLocation.messageId, !instantPageLocation.tracks.isEmpty {
            // A rich message holds several audio files but is ONE message, so the default
            // music-tagged history list renders it as a single row. Build the queue from the
            // playing playlist's own tracks instead: one synthesized row per track, whose Local
            // id IS the InstantPageMedia.index, so a row maps back to a playlist item exactly.
            //
            // These messages are DISPLAY-ONLY. Playback stays on InstantPageMediaPlaylist, which
            // carries a real messageReference and so revalidates file references; a synthesized
            // Local message could not.
            var queueMessages: [EngineRawMessage] = []
            for track in instantPageLocation.tracks {
                let syntheticId = Int32(clamping: track.index)
                queueMessages.append(EngineRawMessage(stableId: UInt32(clamping: track.index), stableVersion: 0, id: EngineMessage.Id(peerId: richMessageId.peerId, namespace: Namespaces.Message.Local, id: syntheticId), globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 0, flags: [], tags: [.music], globalTags: [], localTags: [], customTags: [], forwardInfo: nil, author: nil, text: "", attributes: [], media: [track.file], peers: EngineSimpleDictionary(), associatedMessages: EngineSimpleDictionary(), associatedMessageIds: [], associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:]))
            }
            // Pass document order as-is. ChatHistoryListNode's `.custom` handling reverses the
            // array and the list then renders bottom-up, and the two together land on document
            // order on screen — pre-reversing here displayed the tracks backwards.
            //
            // This only affects DISPLAY. Next/Previous are driven by InstantPageMediaPlaylist
            // walking its own items, never by these rows, so the two cannot disagree.
            // Note the inversion is deliberately applied here rather than in the shared `.custom`
            // handling, which saved music also uses and which is correct for it today.
            self.source = .custom(messages: .single((queueMessages, Int32(queueMessages.count), false)), messageId: initialMessageId, quote: nil, isSavedMusic: false, canReorder: false, richMessageId: richMessageId, loadMore: nil)
            self.isGlobalSearch = false
        } else {
            self.source = .default
            self.isGlobalSearch = false
        }
        
        if case .regular = initialOrder {
            self.currentIsReversed = false
        } else {
            self.currentIsReversed = true
        }
        
        var openMessageImpl: ((EngineMessage.Id) -> Bool)?
        var openMessageContextMenuImpl: ((EngineRawMessage, ASDisplayNode, CGRect, Any?) -> Void)?
        self.controllerInteraction = ChatControllerInteraction(openMessage: { message, _ in
            if let openMessageImpl = openMessageImpl {
                return openMessageImpl(message.id)
            } else {
                return false
            }
        }, openPeer: { _, _, _, _ in
        }, openPeerMention: { _, _ in
        }, openMessageContextMenu: { message, _, node, rect, gesture, _ in
            openMessageContextMenuImpl?(message, node, rect, gesture)
        }, openMessageReactionContextMenu: { _, _, _, _ in
        }, updateMessageReaction: { _, _, _, _ in
        }, activateMessagePinch: { _ in
        }, openMessageContextActions: { _, _, _, _ in
        }, navigateToMessage: { _, _, _ in
        }, navigateToMessageStandalone: { _ in
        }, navigateToThreadMessage: { _, _, _ in
        }, tapMessage: nil, clickThroughMessage: { _, _ in
        }, toggleMessagesSelection: { _, _ in
        }, sendCurrentMessage: { _, _ in
        }, sendMessage: { _, _ in
        }, sendSticker: { _, _, _, _, _, _, _, _, _ in
            return false
        }, sendEmoji: { _, _, _ in
        }, sendGif: { _, _, _, _, _ in
            return false
        }, sendBotContextResultAsGif: { _, _, _, _, _, _ in
            return false
        }, editGif: { _, _ in
        }, requestMessageActionCallback: { _, _, _, _, _ in
        }, requestMessageActionUrlAuth: { _, _ in
        }, activateSwitchInline: { _, _, _ in
        }, openUrl: { _ in
        }, openExternalInstantPage: { _ in
        }, shareCurrentLocation: { _ in
        }, shareAccountContact: { _ in
        }, sendBotCommand: { _, _ in
        }, openInstantPage: { _, _ in
        }, openWallpaper: { _ in
        }, openTheme: {_ in 
        }, openHashtag: { _, _ in
        }, updateInputState: { _ in
        }, updateInputMode: { _ in
        }, updatePresentationState: { _ in
        }, openMessageShareMenu: { _ in
        }, presentController: { _, _ in
        }, presentControllerInCurrent: { _, _ in
        }, navigationController: {
            return nil
        }, chatControllerNode: {
            return nil
        }, presentGlobalOverlayController: { _, _ in
        }, callPeer: { _, _ in
        }, openConferenceCall: { _ in
        }, longTap: { _, _ in
        }, todoItemLongTap: { _, _ in
        }, pollOptionLongTap: { _, _ in
        }, openCheckoutOrReceipt: { _, _ in
        }, openSearch: {
        }, setupReply: { _ in
        }, canSetupReply: { _ in
            return .none
        }, canSendMessages: {
            return false
        }, navigateToFirstDateMessage: { _, _ in
        }, requestRedeliveryOfFailedMessages: { _ in
        }, addContact: { _ in   
        }, rateCall: { _, _, _ in
        }, requestSelectMessagePollOptions: { _, _ in
        }, requestAddMessagePollOption: { _, _, _, _, _ in
        }, requestOpenMessagePollResults: { _, _ in
        }, openAppStorePage: {
        }, displayMessageTooltip: { _, _, _, _, _ in
        }, seekToTimecode: { _, _, _ in    
        }, scheduleCurrentMessage: { _ in
        }, sendScheduledMessagesNow: { _ in
        }, editScheduledMessagesTime: { _ in
        }, performTextSelectionAction: { _, _, _, _, _ in
        }, displayImportedMessageTooltip: { _ in
        }, displaySwipeToReplyHint: {
        }, dismissReplyMarkupMessage: { _ in
        }, openMessagePollResults: { _, _ in
        }, openPollCreation: { _, _ in
        }, openPollMedia: { _, _ in
        }, displayPollSolution: { _, _ in
        }, displayPsa: { _, _ in
        }, displayDiceTooltip: { _ in
        }, animateDiceSuccess: { _, _ in
        }, displayPremiumStickerTooltip: { _, _ in
        }, displayEmojiPackTooltip: { _, _ in
        }, openPeerContextMenu: { _, _, _, _, _ in
        }, openMessageReplies: { _, _, _ in
        }, openReplyThreadOriginalMessage: { _ in
        }, openMessageStats: { _ in
        }, editMessageMedia: { _, _ in
        }, copyText: { _ in
        }, displayUndo: { _ in
        }, isAnimatingMessage: { _ in
            return false
        }, getMessageTransitionNode: {
            return nil
        }, updateChoosingSticker: { _ in
        }, commitEmojiInteraction: { _, _, _, _ in
        }, openLargeEmojiInfo: { _, _, _ in
        }, openJoinLink: { _ in
        }, openWebView: { _, _, _, _, _ in
        }, activateAdAction: { _, _, _, _ in
        }, adContextAction: { _, _, _ in
        }, removeAd: { _ in
        }, openRequestedPeerSelection: { _, _, _, _ in
        }, saveMediaToFiles: { _ in
        }, openNoAdsDemo: {
        }, openAdsInfo: {
        }, displayGiveawayParticipationStatus: { _ in
        }, openPremiumStatusInfo: { _, _, _, _ in
        }, openRecommendedChannelContextMenu: { _, _, _ in
        }, openGroupBoostInfo: { _, _ in
        }, openStickerEditor: {
        }, openAgeRestrictedMessageMedia: { _, _ in
        }, playMessageEffect: { _ in
        }, editMessageFactCheck: { _ in
        }, sendGift: { _ in
        }, openUniqueGift: { _ in
        }, openMessageFeeException: {
        }, requestMessageUpdate: { _, _, _ in
        }, cancelInteractiveKeyboardGestures: {
        }, dismissTextInput: {
        }, scrollToMessageId: { _, _ in
        }, scrollToMessageIdWithAnchor: { _, _ in
        }, navigateToStory: { _, _ in
        }, attemptedNavigationToPrivateQuote: { _ in
        }, forceUpdateWarpContents: {
        }, playShakeAnimation: {
        }, displayQuickShare: { _, _ ,_ in
        }, updateChatLocationThread: { _, _ in
        }, requestToggleTodoMessageItem: { _, _, _ in
        }, displayTodoToggleUnavailable: { _ in
        }, openStarsPurchase: { _ in
        }, openRankInfo: { _, _, _ in
        }, openSetPeerAvatar: {
        }, displayPollRestrictedToast: { _ in
        }, automaticMediaDownloadSettings: MediaAutoDownloadSettings.defaultSettings, pollActionState: ChatInterfacePollActionState(), stickerSettings: ChatInterfaceStickerSettings(), presentationContext: ChatPresentationContext(context: context, backgroundNode: nil))
        
        self.dimNode = ASDisplayNode()
        self.dimNode.backgroundColor = UIColor(white: 0.0, alpha: 0.5)
        
        self.containerContainingNode = ASDisplayNode()
        self.containerContainingNode.clipsToBounds = true
        
        self.contentNode = ASDisplayNode()
        
        self.controlsNode = OverlayAudioPlayerControlsNode(account: context.account, engine: context.engine, accountManager: context.sharedContext.accountManager, presentationData: self.presentationData, status: context.sharedContext.mediaManager.musicMediaPlayerState, chatLocation: self.chatLocation, source: self.source, lottieSettings: context.lottieRenderingSettings)
        self.controlsNode.getParentController = getParentController
        
        self.historyBackgroundNode = ASDisplayNode()
        self.historyBackgroundNode.isLayerBacked = true
        
        self.historyBackgroundContentNode = ASDisplayNode()
        self.historyBackgroundContentNode.isLayerBacked = true
        self.historyBackgroundContentNode.backgroundColor = self.presentationData.theme.list.itemModalBlocksBackgroundColor
        
        self.historyBackgroundNode.addSubnode(self.historyBackgroundContentNode)
        
        self.historyFrameNode = SparseNode()
        self.historyFrameLeftOverlayNode = ASDisplayNode()
        self.historyFrameLeftOverlayNode.backgroundColor = self.presentationData.theme.list.modalBlocksBackgroundColor
        
        self.historyFrameRightOverlayNode = ASDisplayNode()
        self.historyFrameRightOverlayNode.backgroundColor = self.presentationData.theme.list.modalBlocksBackgroundColor
        
        self.historyFrameTopOverlayClipNode = ASDisplayNode()
        self.historyFrameTopOverlayClipNode.clipsToBounds = true
        
        self.historyFrameTopOverlayNode = ASDisplayNode()
        self.historyFrameTopOverlayNode.cornerRadius = 38.0
        self.historyFrameTopOverlayNode.clipsToBounds = true
        self.historyFrameTopOverlayNode.backgroundColor = self.presentationData.theme.list.modalBlocksBackgroundColor
        self.historyFrameTopOverlayNode.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        
        self.historyFrameTopMaskNode = ASImageNode()
        self.historyFrameTopMaskNode.displaysAsynchronously = false
        self.historyFrameTopMaskNode.image = generateCornersImage(theme: self.presentationData.theme)
        self.historyFrameTopMaskNode.isUserInteractionEnabled = false
        
        let tagMask: EngineMessage.Tags
        switch type {
            case .music:
                tagMask = .music
            case .voice:
                tagMask = .voiceOrInstantVideo
            case .file:
                tagMask = .file
        }
                
        let chatLocationContextHolder = Atomic<ChatLocationContextHolder?>(value: nil)
        self.historyNode = ChatHistoryListNodeImpl(
            context: context,
            updatedPresentationData: (context.sharedContext.currentPresentationData.with({ $0 }), context.sharedContext.presentationData),
            systemStyle: .glass,
            chatLocation: chatLocation,
            chatLocationContextHolder: chatLocationContextHolder,
            adMessagesContext: nil,
            tag: .tag(tagMask),
            source: self.source,
            subject: .message(id: .id(initialMessageId), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil, setupReply: false),
            controllerInteraction: self.controllerInteraction,
            selectedMessages: .single(nil),
            mode: .list(reversed: self.currentIsReversed, reverseGroups: !self.currentIsReversed, displayHeaders: .none, hintLinks: false, isGlobalSearch: self.isGlobalSearch, isMusicPlaylist: true),
            isChatPreview: false,
            messageTransitionNode: { return nil
            }
        )
        self.historyNode.clipsToBounds = true
        
        self.collapseNode = HighlightableButtonNode()
        self.collapseNode.displaysAsynchronously = false
        self.collapseNode.setImage(generateCollapseIcon(theme: self.presentationData.theme), for: [])
        
        self.albumArtBackground = UIVisualEffectView()
        self.albumArtBackground.contentView.addSubview(self.albumArtNode.view)
        self.albumArtNode.isUserInteractionEnabled = false
        
        super.init()
        
        self.backgroundColor = nil
        self.isOpaque = false
        
        self.historyNode.preloadPages = true
        self.historyNode.stackFromBottom = true
        self.historyNode.areContentAnimationsEnabled = true
        self.historyNode.contentPositionChanged = { [weak self] offset in
            self?.updateHistoryContentOffset(offset, transition: .immediate)
        }
        self.historyNode.updateFloatingHeaderOffset = { [weak self] offset, transition in
            if let strongSelf = self {
                strongSelf.updateFloatingHeaderOffset(offset: offset, transition: transition)
            }
        }
        
        self.historyNode.endedInteractiveDragging = { [weak self] _ in
            guard let self else {
                return
            }
            switch self.historyNode.visibleContentOffset() {
            case let .known(value):
                if let playlistLocation = self.playlistLocation as? PeerMessagesPlaylistLocation, case let .savedMusic(_, _, canReorder) = playlistLocation, canReorder {
                    
                } else {
                    if value <= -10.0 {
                        self.requestDismiss()
                    }
                }
            default:
                break
            }
        }
        
        self.controlsNode.updateIsExpanded = { [weak self] in
            if let strongSelf = self, let validLayout = strongSelf.validLayout {
                strongSelf.containerLayoutUpdated(validLayout, transition: .animated(duration: 0.5, curve: .spring))
            }
        }
        
        self.controlsNode.requestAlbumArtDisplay = { [weak self] fileReferenceAndAlbumArt in
            guard let self, let layout = self.validLayout else {
                return
            }
            self.currentAlbumArt = fileReferenceAndAlbumArt
            
            if let (fileReference, albumArt) = fileReferenceAndAlbumArt {
                self.albumArtNode.setSignal(playerAlbumArt(engine: self.context.engine, fileReference: fileReference, albumArt: albumArt, thumbnail: false))
            }
            
            self.containerLayoutUpdated(layout, transition: .animated(duration: 0.25, curve: .easeInOut))
        }
        
        self.controlsNode.requestCollapse = { [weak self] in
            self?.requestDismiss()
        }
        
        self.controlsNode.requestShare = { [weak self] subject in
            self?.requestShare(subject)
        }
        
        self.controlsNode.requestSearchByArtist = { [weak self] artist in
            self?.requestSearchByArtist(artist)
        }
        
        self.controlsNode.requestLayout = { [weak self] transition in
            if let self, let validLayout = self.validLayout {
                self.containerLayoutUpdated(validLayout, transition: transition)
            }
        }
        
        self.controlsNode.updateOrder = { [weak self] order in
            self?.queueOrderChanged(order)
            if let strongSelf = self {
                let reversed: Bool
                if case .regular = order {
                    reversed = false
                } else {
                    reversed = true
                }
                if reversed != strongSelf.currentIsReversed {
                    strongSelf.currentIsReversed = reversed
                    if let itemId = strongSelf.controlsNode.currentItemId as? PeerMessagesMediaPlaylistItemId {
                        strongSelf.transitionToUpdatedHistoryNode(atMessage: itemId.messageId)
                    }
                }
            }
        }
        
        self.controlsNode.control = { [weak self] action in
            if let strongSelf = self {
                strongSelf.context.sharedContext.mediaManager.playlistControl(action, type: strongSelf.type)
            }
        }
        
        self.controlsNode.requestSaveToProfile = { [weak self] file in
            if let self {
                self.addToSavedMusic(file: file)
            }
        }
        
        self.controlsNode.requestRemoveFromProfile = { [weak self] file in
            if let self {
                self.removeFromSavedMusic(file: file)
            }
        }
        
        self.addSubnode(self.dimNode)
        self.addSubnode(self.containerContainingNode)
        self.containerContainingNode.addSubnode(self.contentNode)
        self.contentNode.addSubnode(self.historyBackgroundNode)
        self.contentNode.addSubnode(self.historyNode)
        self.contentNode.addSubnode(self.historyFrameNode)
        self.contentNode.addSubnode(self.controlsNode)
        
        self.historyFrameNode.addSubnode(self.historyFrameLeftOverlayNode)
        self.historyFrameNode.addSubnode(self.historyFrameRightOverlayNode)
        self.historyFrameNode.addSubnode(self.historyFrameTopOverlayClipNode)
        self.historyFrameTopOverlayClipNode.addSubnode(self.historyFrameTopOverlayNode)
        self.historyFrameNode.addSubnode(self.historyFrameTopMaskNode)
        self.historyFrameNode.addSubnode(self.collapseNode)
        
        self.historyNode.beganInteractiveDragging = { [weak self] _ in
            self?.controlsNode.collapse()
        }
        
        openMessageImpl = { [weak self] id in
            if let strongSelf = self, let instantPageLocation = strongSelf.playlistLocation as? InstantPagePlaylistLocation, instantPageLocation.messageId != nil, id.namespace == Namespaces.Message.Local {
                // Re-seed the SAME playlist at the tapped track. Letting openChatMessage build a
                // PeerMessagesMediaPlaylist over these rows would be wrong twice: they are
                // synthesized Local messages whose MessageReference cannot revalidate a stale file
                // reference, and replacing the playlist would desync the bubble's own play/pause.
                strongSelf.playInstantPageTrack(atMediaIndex: Int(id.id), location: instantPageLocation)
                return false
            }
            if let strongSelf = self, strongSelf.isNodeLoaded, let message = strongSelf.historyNode.messageInCurrentHistoryView(id)?._asMessage() {
                var playlistLocation: PeerMessagesPlaylistLocation?
                if let location = strongSelf.playlistLocation as? PeerMessagesPlaylistLocation {
                    if case let .custom(messages, canReorder, _, loadMore, hidePanel) = location {
                        playlistLocation = .custom(messages: messages, canReorder: canReorder, at: id, loadMore: loadMore, hidePanel: hidePanel)
                    } else if case let .savedMusic(context, _, canReorder) = location {
                        playlistLocation = .savedMusic(context: context, at: id.id, canReorder: canReorder)
                    }
                }
                return strongSelf.context.sharedContext.openChatMessage(OpenChatMessageParams(context: strongSelf.context, chatLocation: nil, chatFilterTag: nil, chatLocationContextHolder: nil, message: message, standalone: false, reverseMessageGalleryOrder: false, navigationController: nil, dismissInput: { }, present: { _, _, _ in }, transitionNode: { _, _, _ in return nil }, addToTransitionSurface: { _ in }, openUrl: { _ in }, openPeer: { _, _ in }, callPeer: { _, _ in }, openConferenceCall: { _ in
                }, enqueueMessage: { _ in }, sendSticker: nil, sendEmoji: nil, setupTemporaryHiddenMedia: { _, _, _ in }, chatAvatarHiddenMedia: { _, _ in }, playlistLocation: playlistLocation))
            }
            return false
        }
        
        openMessageContextMenuImpl = { [weak self] message, node, rect, gesture in
            guard let self else {
                return
            }
            self.openMessageContextMenu(message: message, node: node, frame: rect, gesture: gesture as? ContextGesture)
        }
        
        self.presentationDataDisposable = context.sharedContext.presentationData.startStrict(next: { [weak self] presentationData in
            if let strongSelf = self {
                if strongSelf.presentationData.theme !== presentationData.theme || strongSelf.presentationData.strings !== presentationData.strings {
                    strongSelf.updatePresentationData(presentationData)
                }
            }
        })
        
        let copyProtectionEnabled: Signal<Bool, NoError>
        if case let .peer(peerId) = self.chatLocation {
            if let playlistLocation = self.playlistLocation as? PeerMessagesPlaylistLocation, case .savedMusic = playlistLocation {
                copyProtectionEnabled = .single(false)
            } else if peerId.namespace == Namespaces.Peer.CloudUser {
                copyProtectionEnabled = context.engine.data.subscribe(
                    TelegramEngine.EngineData.Item.Peer.CopyProtectionEnabled(id: peerId),
                    TelegramEngine.EngineData.Item.Peer.MyCopyProtectionEnabled(id: peerId)
                ) |> map { copyProtectionEnabled, myCopyProtectionEnabled in
                    return copyProtectionEnabled || myCopyProtectionEnabled
                }
            } else {
                copyProtectionEnabled = context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.CopyProtectionEnabled(id: peerId))
            }
        } else {
            copyProtectionEnabled = .single(false)
        }
        
        let peer: Signal<EnginePeer?, NoError>
        if let playlistLocation = self.playlistLocation as? PeerMessagesPlaylistLocation, case let .savedMusic(savedMusicContext, _, _) = playlistLocation {
            peer = context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: savedMusicContext.peerId))
        } else {
            peer = .single(nil)
        }
        
        self.dataDisposable = combineLatest(
            queue: Queue.mainQueue(),
            context.engine.peers.savedMusicIds(),
            copyProtectionEnabled,
            peer
        ).start(next: { [weak self] savedIds, copyProtectionEnabled, peer in
            guard let self else {
                return
            }
            let isFirstTime = self.savedIds == nil
            self.savedIds = savedIds
            self.savedIdsPromise.set(.single(savedIds))
            self.copyProtectionEnabled = copyProtectionEnabled
            self.controlsNode.forceCopyProtected.set(copyProtectionEnabled)
            self.peer = peer
            
            let transition: ContainedViewLayoutTransition = isFirstTime ? .immediate : .animated(duration: 0.5, curve: .spring)
            if let validLayout = self.validLayout {
                self.containerLayoutUpdated(validLayout, transition: transition)
            }
        })
        
        self.ready.set(
            combineLatest(
                self.historyNode.historyState.get()
                |> take(1),
                self.savedIdsPromise.get()
                |> filter {
                    $0 != nil
                }
                |> take(1)
            )
            |> map { _, _ -> Bool in
                return true
            }
        )
        
        self.setupReordering()
        
        if isMusicSectionEnabled, case .music = type {
            self.setupCompactSheet(playlistLocation: playlistLocation)
            // The player's first state can arrive before the sheet is set up, so its order is checked here as well.
            self.resetLegacyReversedOrder(self.controlsNode.currentOrder ?? initialOrder)
        }
        
        self.albumArtBackground.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.albumArtTapped(_:))))
    }
    
    deinit {
        self.presentationDataDisposable?.dispose()
        self.replacementHistoryNodeReadyDisposable.dispose()
        self.dataDisposable?.dispose()
        self.saveMediaDisposable?.dispose()
        self.compactDataDisposable.dispose()
        self.queueMessagesDisposable.dispose()
    }
    
    override func didLoad() {
        super.didLoad()
        
        self.dimNode.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.dimTapGesture(_:))))
        
        let panRecognizer = DirectionalPanGestureRecognizer(target: self, action: #selector(self.panGesture(_:)))
        panRecognizer.delegate = self.wrappedGestureRecognizerDelegate
        panRecognizer.delaysTouchesBegan = false
        panRecognizer.cancelsTouchesInView = true
        panRecognizer.shouldBegin = { [weak self] point in
            guard let self else {
                return false
            }
            if self.historyFrameTopOverlayNode.bounds.contains(self.view.convert(point, to: self.historyFrameTopOverlayNode.view)) {
                return true
            }
            if self.controlsNode.bounds.contains(self.view.convert(point, to: self.controlsNode.view)) {
                return true
            }
            if self.isQueueOpen {
                // The toolbar drags the sheet down; the list scrolls.
                let sheetPoint = self.view.convert(point, to: self.queueSheetNode.view)
                if sheetPoint.y >= 0.0 && sheetPoint.y < 86.0 {
                    return true
                }
            }
            return false
        }
        self.view.addGestureRecognizer(panRecognizer)
    }
    
    /// Rebuilds the rich message's playlist re-anchored on `mediaIndex`, exactly as tapping the
    /// track inside the bubble does. `InstantPageMedia`'s url/caption/credit are not read by
    /// `InstantPageMediaPlaylistItem` — playbackData and displayData both derive entirely from the
    /// file's own attributes — so reconstructing them as nil is lossless here.
    private func playInstantPageTrack(atMediaIndex mediaIndex: Int, location: InstantPagePlaylistLocation) {
        guard let webPage = location.webPage, let messageId = location.messageId else {
            return
        }
        var items: [InstantPageMedia] = []
        var initialItemIndex = 0
        for track in location.tracks {
            if track.index == mediaIndex {
                initialItemIndex = items.count
            }
            items.append(InstantPageMedia(index: track.index, media: .file(track.file), url: nil, caption: nil, credit: nil))
        }
        guard !items.isEmpty else {
            return
        }
        var isVoice = false
        if case let .file(file) = items[initialItemIndex].media {
            isVoice = file.isVoice
        }
        // The playlist id must stay `.richMessage(messageId:)`: the bubble's own play/pause and
        // scrubber are bound to it via filteredPlaylistState(playlistId:itemId:).
        let playlist = InstantPageMediaPlaylist(
            playlistId: .richMessage(messageId: messageId),
            webPage: webPage,
            messageReference: location.messageReference,
            items: items,
            initialItemIndex: initialItemIndex
        )
        self.context.sharedContext.mediaManager.setPlaylist(
            (self.context, playlist),
            type: isVoice ? .voice : .music,
            control: .playback(.play)
        )
    }

    private func setupReordering() {
        guard let playlistLocation = self.playlistLocation as? PeerMessagesPlaylistLocation, case let .savedMusic(savedMusicContext, _, canReorder) = playlistLocation, canReorder else {
            return
        }
        let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: savedMusicContext.peerId))
        |> deliverOnMainQueue).start(next: { [weak self] peer in
            guard let self, let peer = peer.flatMap({ PeerReference($0) }) else {
                return
            }

            self.historyNode.reorderItem = { fromIndex, toIndex, transactionOpaqueState -> Signal<Bool, NoError> in
                guard let filteredEntries = (transactionOpaqueState as? ChatHistoryTransactionOpaqueState)?.historyView.filteredEntries, !filteredEntries.isEmpty else {
                    return .single(false)
                }
                
                func mapIndex(_ uiIndex: Int) -> Int {
                    return filteredEntries.count - 1 - uiIndex
                }

                let mappedFromIndex = mapIndex(fromIndex)
                guard filteredEntries.indices.contains(mappedFromIndex), case let .MessageEntry(fromMessage, _, _, _, _, _) = filteredEntries[mappedFromIndex], let fromFile = fromMessage.media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile else {
                    return .single(false)
                }

                var afterFile: TelegramMediaFile?
                if toIndex > 0 {
                    let afterMappedIndex = mapIndex(toIndex - 1)
                    if filteredEntries.indices.contains(afterMappedIndex), case let .MessageEntry(afterMessage, _, _, _, _, _) = filteredEntries[afterMappedIndex], let file = afterMessage.media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile {
                        afterFile = file
                    }
                } else {
                    afterFile = nil
                }
                
                let _ = savedMusicContext.addMusic(
                    file: .savedMusic(peer: peer, media: fromFile),
                    afterFile: afterFile.flatMap { .savedMusic(peer: peer, media: $0) }
                ).start()

                return .single(true)
            }
        })
        self.historyNode.autoScrollWhenReordering = false
        self.historyNode.didEndScrollingWithOverscroll = { [weak self] in
            guard let self else {
                return
            }
            self.requestDismiss()
        }
    }

    
    func updatePresentationData(_ presentationData: PresentationData) {
        let themeUpdated = self.presentationData.theme !== presentationData.theme || self.presentationData.strings !== presentationData.strings
        self.presentationData = presentationData
        if self.isCompact {
            self.updateQueueColors(listUpdated: themeUpdated)
        }
        
        self.historyBackgroundContentNode.backgroundColor = self.hasAnyHistoryMessages == true ? self.presentationData.theme.list.itemModalBlocksBackgroundColor : self.presentationData.theme.list.modalPlainBackgroundColor
        self.historyFrameLeftOverlayNode.backgroundColor = self.hasAnyHistoryMessages == true ? self.presentationData.theme.list.modalBlocksBackgroundColor : self.presentationData.theme.list.modalPlainBackgroundColor
        self.historyFrameRightOverlayNode.backgroundColor = self.hasAnyHistoryMessages == true ? self.presentationData.theme.list.modalBlocksBackgroundColor : self.presentationData.theme.list.modalPlainBackgroundColor
        self.historyFrameTopOverlayNode.backgroundColor = self.hasAnyHistoryMessages == true ? self.presentationData.theme.list.modalBlocksBackgroundColor : self.presentationData.theme.list.modalPlainBackgroundColor
        self.historyFrameTopMaskNode.image = generateCornersImage(theme: self.presentationData.theme)
        
        self.collapseNode.setImage(generateCollapseIcon(theme: self.presentationData.theme), for: [])
        
        self.controlsNode.updatePresentationData(self.presentationData)
    }
    
    private func dismissAllTooltips() {
        guard let controller = self.getParentController() else {
            return
        }
        controller.window?.forEachController({ controller in
            if let controller = controller as? UndoOverlayController {
                controller.dismissWithCommitAction()
            }
        })
        controller.forEachController({ controller in
            if let controller = controller as? UndoOverlayController {
                controller.dismissWithCommitAction()
            }
            return true
        })
    }
    
    func forwardToSavedMessages(file: FileMediaReference) {
        self.dismissAllTooltips()
        
        let _ = self.context.engine.messages.enqueueOutgoingMessage(to: self.context.account.peerId, replyTo: nil, content: .file(file)).start()
        
        let controller = UndoOverlayController(
            presentationData: self.presentationData,
            content: .forward(savedMessages: true, text: self.presentationData.strings.MediaPlayer_AudioForwardedToSavedMesagesTooltip),
            action: { _ in
                return true
            }
        )
        self.getParentController()?.present(controller, in: .current)
    }
    
    private func updateMusicSaved(file: FileMediaReference, isSaved: Bool) {
        if let playlistLocation = self.playlistLocation as? PeerMessagesPlaylistLocation, case let .savedMusic(savedMusicContext, _, _) = playlistLocation, savedMusicContext.peerId == self.context.account.peerId {
            if isSaved {
                let _ = savedMusicContext.addMusic(file: file).start()
            } else {
                let _ = savedMusicContext.removeMusic(file: file).start()
            }
        } else {
            if isSaved {
                let _ = self.context.engine.peers.addSavedMusic(file: file).start()
            } else {
                let _ = self.context.engine.peers.removeSavedMusic(file: file).start()
            }
        }
    }
    
    func addToSavedMusic(file: FileMediaReference) {
        self.dismissAllTooltips()
        
        var actionText: String? = self.presentationData.strings.MediaPlayer_SavedMusic_AddedToProfile_View
        if let itemId = self.controlsNode.currentItemId as? PeerMessagesMediaPlaylistItemId, itemId.messageId.namespace == Namespaces.Message.Local && itemId.messageId.peerId == self.context.account.peerId {
            actionText = nil
        }
        
        let controller = UndoOverlayController(
            presentationData: self.presentationData,
            content: .universalImage(
                image: generateTintedImage(image: UIImage(bundleImageName: "Peer Info/SavedMusic"), color: .white)!,
                size: nil,
                title: nil,
                text: self.presentationData.strings.MediaPlayer_SavedMusic_AddedToProfile,
                customUndoText: actionText,
                timeout: 3.0
            ),
            action: { [weak self] action in
                if let self, case .undo = action {
                    let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.context.account.peerId))
                    |> deliverOnMainQueue).start(next: { [weak self] peer in
                        guard let self, let peer else {
                            return
                        }
                        if let controller = self.context.sharedContext.makePeerInfoController(
                            context: self.context,
                            updatedPresentationData: nil,
                            peer: peer,
                            mode: .myProfile,
                            avatarInitiallyExpanded: false,
                            fromChat: false,
                            requestsContext: nil
                        ) {
                            if let navigationController = (self.getParentController() as? OverlayAudioPlayerControllerImpl)?.parentNavigationController {
                                self.requestDismiss()
                                navigationController.pushViewController(controller)
                            }
                        }
                    })
                }
                return true
            }
        )
        self.getParentController()?.present(controller, in: .current)
        
        self.updateMusicSaved(file: file, isSaved: true)
    }
    
    func removeFromSavedMusic(file: FileMediaReference) {
        self.dismissAllTooltips()
                        
        let controller = UndoOverlayController(
            presentationData: self.presentationData,
            content: .universalImage(
                image: generateTintedImage(image: UIImage(bundleImageName: "Peer Info/SavedMusic"), color: .white)!,
                size: nil,
                title: nil,
                text: self.presentationData.strings.MediaPlayer_SavedMusic_RemovedFromProfile,
                customUndoText: nil,
                timeout: 3.0
            ),
            action: { _ in
                return true
            }
        )
        
        if let itemId = self.controlsNode.currentItemId as? PeerMessagesMediaPlaylistItemId, itemId.messageId.namespace == Namespaces.Message.Local && itemId.messageId.peerId == self.context.account.peerId, self.historyNode.originalHistoryView?.entries.count == 1 {
            if let navigationController = (self.getParentController() as? OverlayAudioPlayerControllerImpl)?.parentNavigationController {
                self.requestDismiss()
                navigationController.presentOverlay(controller: controller)
                
                self.context.sharedContext.mediaManager.setPlaylist(nil, type: self.type, control: .playback(.pause))
            }
        } else {
            self.getParentController()?.present(controller, in: .current)
        }
        
        self.updateMusicSaved(file: file, isSaved: false)
    }
    
    // MARK: Compact sheet
    
    private func setupCompactSheet(playlistLocation: SharedMediaPlaylistLocation?) {
        let context = self.context
        self.isCompact = true
        self.controlsNode.isCompact = true
        for node in [self.historyNode, self.historyBackgroundNode, self.historyFrameNode] as [ASDisplayNode] {
            node.alpha = 0.0
            node.isUserInteractionEnabled = false
        }
        
        self.controlsNode.requestOpenQueue = { [weak self] in
            self?.openQueue()
        }
        self.controlsNode.currentItemChanged = { [weak self] in
            guard let self, self.isQueueOpen || self.isQueueInteractivelyOpening else {
                return
            }
            self.reloadQueueMessages()
        }
        self.controlsNode.pausedChanged = { [weak self] in
            guard let self, self.isQueueOpen || self.isQueueInteractivelyOpening else {
                return
            }
            self.updateQueueList(order: self.controlsNode.currentOrder ?? .regular, animated: true)
        }
        self.setupQueueSheet()
        self.controlsNode.requestToggleSaved = { [weak self] in
            self?.toggleInMusic()
        }
        self.controlsNode.requestToggleFavorite = { [weak self] in
            guard let self, let fileId = self.controlsNode.currentFileReference?.media.fileId.id else {
                return
            }
            let isFavorite = !self.favoriteFileIds.contains(fileId)
            if isFavorite {
                self.favoriteFileIds.insert(fileId)
            } else {
                self.favoriteFileIds.remove(fileId)
            }
            MusicPlayerSupport.setFavorite(context: self.context, fileId: fileId, isFavorite: isFavorite)
            if let layout = self.validLayout {
                self.containerLayoutUpdated(layout, transition: .immediate)
            }
        }
        self.controlsNode.requestAddToPlaylist = { [weak self] in
            guard let self, let fileId = self.controlsNode.currentFileReference?.media.fileId.id else {
                return
            }
            let messageId = (self.controlsNode.currentItemId as? PeerMessagesMediaPlaylistItemId)?.messageId
            MusicPlayerSupport.addToPlaylist(context: self.context, fileId: fileId, messageId: messageId, present: { [weak self] controller in
                (self?.getParentController() as? OverlayAudioPlayerControllerImpl)?.present(controller, in: .window(.root))
            }, dismissPlayer: { [weak self] in
                self?.requestDismiss()
            })
        }
        self.controlsNode.requestMoreMenu = { [weak self] referenceNode in
            self?.openCompactMoreMenu(referenceNode: referenceNode)
        }
        
        // The queue's size and source when the Music section did not start it.
        var sourceCount: Signal<Int?, NoError> = .single(nil)
        var sourceChatPeer: Signal<EnginePeer?, NoError> = .single(nil)
        if let playlistLocation = playlistLocation as? PeerMessagesPlaylistLocation, case let .custom(messages, _, _, _, _) = playlistLocation.effectiveLocation(context: context) {
            sourceCount = messages
            |> map { messages, totalCount, _ -> Int? in
                return max(Int(totalCount), messages.count)
            }
        } else if let instantPageLocation = playlistLocation as? InstantPagePlaylistLocation, !instantPageLocation.tracks.isEmpty {
            sourceCount = .single(instantPageLocation.tracks.count)
        } else if case let .peer(peerId) = self.chatLocation {
            sourceCount = context.engine.data.subscribe(TelegramEngine.EngineData.Item.Messages.MessageCount(peerId: peerId, threadId: nil, tag: .music))
            sourceChatPeer = context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        }
        
        self.compactDataDisposable.set(combineLatest(
            queue: Queue.mainQueue(),
            MusicPlayerSupport.queueInfo(context: context),
            MusicPlayerSupport.libraryState(context: context),
            sourceCount,
            sourceChatPeer
        ).start(next: { [weak self] libraryQueue, libraryState, sourceCount, sourceChatPeer in
            guard let self else {
                return
            }
            self.libraryQueue = libraryQueue
            self.libraryState = libraryState
            self.favoriteFileIds = libraryState.favoriteFileIds
            self.sourceCount = sourceCount
            self.sourceChatPeer = sourceChatPeer
            if self.isQueueOpen {
                let isLibrary = libraryQueue.flatMap { queue in self.currentQueueMessageId.flatMap { queue.messageIds.contains($0) } } ?? false
                if isLibrary && !self.queueIsLibrary {
                    self.reloadQueueMessages()
                } else {
                    self.updateQueueList(order: self.controlsNode.currentOrder ?? .regular, animated: false)
                }
                self.updateQueueReverseButton()
            }
            if let layout = self.validLayout {
                self.containerLayoutUpdated(layout, transition: .immediate)
            }
        }))
    }
    
    /// Whether the playing file is in Music: the profile's saved tracks, the audio of every chat and the files added
    /// to Music, less the files taken out of it. A track started in the Music section is in it. Adding and taking
    /// out never touch the profile. Nil for a copy-protected file that is not in Music: it cannot be kept.
    private var isInMusic: Bool? {
        guard let fileId = self.controlsNode.currentFileReference?.media.fileId.id else {
            return nil
        }
        let state = self.libraryState
        if state?.removedFileIds.contains(fileId) == true {
            return self.copyProtectionEnabled ? nil : false
        }
        if let libraryQueue = self.libraryQueue, let itemId = self.controlsNode.currentItemId as? PeerMessagesMediaPlaylistItemId, libraryQueue.messageIds.contains(itemId.messageId) {
            return true
        }
        if state?.trackFileIds.contains(fileId) == true || self.savedIds?.contains(fileId) == true || self.isChatFile {
            return true
        }
        return self.copyProtectionEnabled ? nil : false
    }
    
    /// The playing file is a chat's message, so it is in Music unless it was taken out.
    private var isChatFile: Bool {
        guard let itemId = self.controlsNode.currentItemId as? PeerMessagesMediaPlaylistItemId else {
            return false
        }
        return itemId.messageId.namespace == Namespaces.Message.Cloud
    }
    
    private func toggleInMusic() {
        guard let file = self.controlsNode.currentFileReference, let isInMusic = self.isInMusic else {
            return
        }
        if isInMusic {
            MusicPlayerSupport.removeFromMusic(context: self.context, fileId: file.media.fileId.id)
        } else {
            MusicPlayerSupport.addToMusic(context: self.context, file: file.media)
        }
    }
    
    /// The track count and the list the queue comes from (Figma: «Ваш «Playlist Title»», «Ваша музыка», «Диалог с username»…).
    private func compactQueueInfo() -> (count: Int?, title: String?) {
        let strings = self.presentationData.strings
        if let libraryQueue = self.libraryQueue, let itemId = self.controlsNode.currentItemId as? PeerMessagesMediaPlaylistItemId, libraryQueue.messageIds.contains(itemId.messageId) {
            return (libraryQueue.messageIds.count, libraryQueue.title)
        }
        var title: String?
        if let playlistLocation = self.playlistLocation as? PeerMessagesPlaylistLocation, case .savedMusic = playlistLocation {
            if let peer = self.peer {
                title = peer.id == self.context.account.peerId ? MusicPlayerSupport.ownMusicTitle(strings: strings) : MusicPlayerSupport.userMusicTitle(strings: strings, name: peer.compactDisplayTitle)
            }
        } else if let peer = self.sourceChatPeer {
            if case .user = peer {
                if peer.id == self.context.account.peerId {
                    title = strings.DialogList_SavedMessages
                } else {
                    title = MusicPlayerSupport.chatTitle(strings: strings, name: peer.compactDisplayTitle)
                }
            } else {
                title = peer.displayTitle(strings: strings, displayOrder: self.presentationData.nameDisplayOrder)
            }
        }
        return (self.sourceCount, title)
    }
    
    // MARK: Queue sheet
    
    private func setupQueueSheet() {
        let presentationData = self.presentationData
        self.queueSheetNode.isHidden = true
        self.queueSheetNode.clipsToBounds = true
        self.queueSheetNode.cornerRadius = 38.0
        self.queueSheetNode.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        self.queueSheetNode.layer.cornerCurve = .continuous
        self.queueSheetShadowView.isHidden = true
        self.queueSheetShadowView.isUserInteractionEnabled = false
        self.queueSheetShadowView.layer.shadowColor = UIColor.black.cgColor
        self.queueSheetShadowView.layer.shadowOpacity = 0.18
        self.queueSheetShadowView.layer.shadowRadius = 20.0
        self.queueSheetShadowView.layer.shadowOffset = CGSize(width: 0.0, height: 8.0)
        
        self.queueGrabberNode.displaysAsynchronously = false
        self.queueGrabberNode.isUserInteractionEnabled = false
        for node in [self.queueSubtitleNode, self.queueLabelNode, self.queueBadgeTextNode] {
            node.displaysAsynchronously = false
            node.isUserInteractionEnabled = false
        }
        self.queueSubtitleNode.maximumNumberOfLines = 1
        self.queueSubtitleNode.truncationType = .end
        self.queueBadgeNode.isUserInteractionEnabled = false
        self.queueBadgeNode.addSubnode(self.queueBadgeTextNode)
        self.queueTitleButton.addSubnode(self.queueSubtitleNode)
        self.queueTitleButton.addSubnode(self.queueLabelNode)
        self.queueTitleButton.addSubnode(self.queueBadgeNode)
        self.queueMoreReferenceNode.isUserInteractionEnabled = false
        self.queueMoreButton.addSubnode(self.queueMoreReferenceNode)
        
        let listNode = MusicPlayerQueueListNode(context: self.context, presentationData: presentationData)
        listNode.clipsToBounds = true
        self.queueListNode = listNode
        
        self.queueSheetNode.addSubnode(listNode)
        self.queueSheetNode.addSubnode(self.queueGrabberNode)
        self.queueSheetNode.addSubnode(self.queueReverseButton)
        self.queueSheetNode.addSubnode(self.queueTitleButton)
        self.queueSheetNode.addSubnode(self.queueMoreButton)
        self.contentNode.insertSubnode(self.queueSheetNode, belowSubnode: self.controlsNode)
        self.contentNode.view.insertSubview(self.queueSheetShadowView, belowSubview: self.queueSheetNode.view)
        
        self.queueTitleButton.highligthedChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            for node in [self.queueSubtitleNode, self.queueLabelNode, self.queueBadgeNode] as [ASDisplayNode] {
                if highlighted {
                    node.layer.removeAnimation(forKey: "opacity")
                    node.alpha = 0.4
                } else {
                    node.alpha = 1.0
                    node.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                }
            }
        }
        self.queueTitleButton.addTarget(self, action: #selector(self.queueTitlePressed), forControlEvents: .touchUpInside)
        self.queueReverseButton.addTarget(self, action: #selector(self.queueReversePressed), forControlEvents: .touchUpInside)
        self.queueMoreButton.addTarget(self, action: #selector(self.queueMorePressed), forControlEvents: .touchUpInside)
        
        listNode.openMessage = { [weak self] message in
            self?.playQueueMessage(message)
        }
        listNode.openContextMenu = { [weak self] message, node, gesture in
            self?.openMessageContextMenu(message: message, node: node, frame: node.bounds, gesture: gesture)
        }
        listNode.moveMessage = { [weak self] messageId, toIndex in
            self?.moveQueueMessage(messageId: messageId, toDisplayedIndex: toIndex)
        }
        
        self.updateQueueColors()
    }
    
    private func updateQueueColors(listUpdated: Bool = false) {
        let theme = self.presentationData.theme
        // Figma color/bg/plain: the Music section's own background, light or dark.
        self.queueSheetNode.backgroundColor = theme.chatList.pinnedItemBackgroundColor
        self.queueGrabberNode.image = generateStretchableFilledCircleImage(diameter: 6.0, color: theme.list.controlSecondaryColor)
        self.queueBadgeNode.backgroundColor = theme.list.itemPrimaryTextColor.withMultipliedAlpha(0.08)
        // Figma Toolbar: both buttons in the section colour, Reverse in the accent while it is on.
        self.updateQueueReverseButton()
        // The sheet's three dots (Music/More), drawn on Reverse's 30 pt canvas so the two glyphs match in size.
        let moreImage = generateTintedImage(image: UIImage(bundleImageName: "Music/More"), color: theme.list.itemSecondaryTextColor).flatMap { image in
            return generateImage(CGSize(width: 30.0, height: 30.0), contextGenerator: { size, context in
                context.clear(CGRect(origin: CGPoint(), size: size))
                if let cgImage = image.cgImage {
                    context.draw(cgImage, in: CGRect(origin: CGPoint(), size: size))
                }
            })
        }
        self.queueMoreButton.setImage(moreImage, for: [])
        if listUpdated {
            self.queueListNode?.updatePresentationData(self.presentationData)
        }
    }
    
    /// Figma Toolbar: grabber 16, then a 70 pt row — Reverse and the menu 40 pt at 16 from the edges, the queue's
    /// source and «Очередь» with the count centred between them, as in the compact sheet's header.
    private func updateQueueSheetLayout(size: CGSize, layoutList: Bool, transition: ContainedViewLayoutTransition, listTransition: ContainedViewLayoutTransition? = nil) {
        let theme = self.presentationData.theme
        let strings = self.presentationData.strings
        let width = size.width
        
        transition.updateFrame(node: self.queueGrabberNode, frame: CGRect(x: floor((width - 36.0) / 2.0), y: 5.0, width: 36.0, height: 6.0))
        transition.updateFrame(node: self.queueReverseButton, frame: CGRect(x: 16.0, y: 16.0 + 11.0, width: 40.0, height: 40.0))
        let moreFrame = CGRect(x: width - 16.0 - 40.0, y: 16.0 + 11.0, width: 40.0, height: 40.0)
        transition.updateFrame(node: self.queueMoreButton, frame: moreFrame)
        self.queueMoreReferenceNode.frame = CGRect(origin: CGPoint(), size: moreFrame.size)
        
        let queueInfo = self.compactQueueInfo()
        let titleWidth = width - (16.0 + 40.0 + 8.0) * 2.0
        self.queueSubtitleNode.attributedText = NSAttributedString(string: queueInfo.title ?? "", font: Font.regular(13.0), textColor: theme.list.sectionHeaderTextColor)
        let subtitleSize = self.queueSubtitleNode.updateLayout(CGSize(width: titleWidth, height: 100.0))
        self.queueLabelNode.attributedText = NSAttributedString(string: MusicPlayerSupport.queueLabel(strings: strings), font: Font.medium(16.0), textColor: theme.list.itemPrimaryTextColor)
        let labelSize = self.queueLabelNode.updateLayout(CGSize(width: titleWidth, height: 100.0))
        var badgeSize = CGSize()
        if let count = queueInfo.count {
            self.queueBadgeTextNode.attributedText = NSAttributedString(string: presentationStringsFormattedNumber(Int32(clamping: count), self.presentationData.dateTimeFormat.groupingSeparator), font: Font.medium(12.0), textColor: theme.list.itemPrimaryTextColor)
            let badgeTextSize = self.queueBadgeTextNode.updateLayout(CGSize(width: 100.0, height: 100.0))
            badgeSize = CGSize(width: max(20.0, badgeTextSize.width + 8.0), height: 20.0)
            self.queueBadgeTextNode.frame = CGRect(origin: CGPoint(x: floor((badgeSize.width - badgeTextSize.width) / 2.0), y: floor((badgeSize.height - badgeTextSize.height) / 2.0)), size: badgeTextSize)
            self.queueBadgeNode.isHidden = false
        } else {
            self.queueBadgeNode.isHidden = true
        }
        self.queueBadgeNode.cornerRadius = badgeSize.height / 2.0
        
        let titleFrame = CGRect(x: 16.0 + 40.0 + 8.0, y: 16.0, width: titleWidth, height: 70.0)
        transition.updateFrame(node: self.queueTitleButton, frame: titleFrame)
        // Inside the title the lines move along with it: set at once, they jumped sideways while the sheet's width
        // animated between the compact and the full one.
        transition.updateFrame(node: self.queueSubtitleNode, frame: CGRect(origin: CGPoint(x: floor((titleWidth - subtitleSize.width) / 2.0), y: 8.0 + floor((18.0 - subtitleSize.height) / 2.0)), size: subtitleSize))
        let rowWidth = labelSize.width + (badgeSize.width > 0.0 ? 8.0 + badgeSize.width : 0.0)
        let rowX = floor((titleWidth - rowWidth) / 2.0)
        let rowCenterY: CGFloat = 8.0 + 18.0 + 8.0 + 10.0
        transition.updateFrame(node: self.queueLabelNode, frame: CGRect(origin: CGPoint(x: rowX, y: floor(rowCenterY - labelSize.height / 2.0)), size: labelSize))
        transition.updateFrame(node: self.queueBadgeNode, frame: CGRect(origin: CGPoint(x: rowX + labelSize.width + 8.0, y: rowCenterY - badgeSize.height / 2.0), size: badgeSize))
        
        // The list ends under the card's top corners: its last rows scroll out from behind them.
        let toolbarHeight = OverlayAudioPlayerControllerNode.queueToolbarHeight
        let listFrame = CGRect(x: 0.0, y: toolbarHeight, width: width, height: max(0.0, size.height - toolbarHeight))
        if layoutList, let listNode = self.queueListNode {
            let listTransition = listTransition ?? transition
            listTransition.updateFrame(node: listNode, frame: listFrame)
            listNode.updateLayout(size: listFrame.size, insets: UIEdgeInsets(top: 0.0, left: 0.0, bottom: OverlayAudioPlayerControllerNode.queueCardOverlap + 8.0, right: 0.0), transition: listTransition)
        }
    }
    
    /// The compact sheet's header opens the queue: the sheet rises to the status bar with the list over the card.
    private func openQueue() {
        guard self.isCompact, !self.isQueueOpen, let layout = self.validLayout else {
            return
        }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let openingFrame: CGRect
        if self.isQueueClosing || self.isQueueInteractivelyOpening {
            // Reopened while folding: the sheet goes on from where it is on screen, the card from where it is.
            openingFrame = self.queueSheetNode.layer.presentation()?.frame ?? self.queueSheetNode.frame
        } else {
            // The sheet takes over the compact header in place — the same grabber and title at the same spot — and
            // the card stays where it is: one layout without animation swaps them, so nothing on screen moves.
            let fromFrame = self.controlsNode.frame
            openingFrame = CGRect(x: fromFrame.minX, y: fromFrame.minY, width: fromFrame.width, height: OverlayAudioPlayerControllerNode.queueToolbarHeight + OverlayAudioPlayerControllerNode.queueCardOverlap)
            self.controlsNode.showsQueueHeader = false
            self.queueSheetNode.isHidden = false
            self.queueSheetShadowView.isHidden = false
            self.queueSheetNode.frame = openingFrame
            self.queueSheetShadowView.frame = openingFrame
            self.updateQueueColors()
            self.updateQueueSheetLayout(size: openingFrame.size, layoutList: false, transition: .immediate)
            self.containerLayoutUpdated(layout, transition: .immediate)
        }
        let wasLoading = self.isQueueInteractivelyOpening
        self.isQueueOpen = true
        self.isQueueClosing = false
        self.isQueueInteractivelyOpening = false
        self.queueInteractiveBaseFrame = nil
        self.queueDragOffset = 0.0
        self.queueCloseToken += 1
        
        self.queueSheetOpeningFrame = openingFrame
        // One spring for the sheet, the card and their outlines (Reduce Motion: a crossfade in place).
        let transition: ContainedViewLayoutTransition = reduceMotion ? .immediate : OverlayAudioPlayerControllerNode.queueSheetTransition
        self.containerLayoutUpdated(layout, transition: transition)
        if reduceMotion {
            self.queueSheetNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
        }
        if wasLoading {
            // The drag already brought the list in.
            for node in [self.queueReverseButton, self.queueMoreButton, self.queueListNode].compactMap({ $0 }) as [ASDisplayNode] {
                let from = node.alpha
                node.alpha = 1.0
                node.layer.animateAlpha(from: from, to: 1.0, duration: 0.2)
            }
            return
        }
        self.reloadQueueMessages()
        for node in [self.queueReverseButton, self.queueMoreButton, self.queueListNode].compactMap({ $0 }) as [ASDisplayNode] {
            node.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
        }
    }
    
    /// The queue's title folds the sheet back.
    private func closeQueue() {
        guard self.isQueueOpen || self.isQueueInteractivelyOpening, let layout = self.validLayout else {
            return
        }
        self.isQueueInteractivelyOpening = false
        self.queueInteractiveBaseFrame = nil
        self.queueDragOffset = 0.0
        // The sheet folds into the compact header's place and hands it back there; the card goes to its compact
        // place below it without a header of its own until then.
        self.isQueueOpen = false
        self.isQueueClosing = true
        self.queueCloseToken += 1
        let token = self.queueCloseToken
        self.queueMessagesDisposable.set(nil)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let transition: ContainedViewLayoutTransition = reduceMotion ? .immediate : OverlayAudioPlayerControllerNode.queueSheetTransition
        self.containerLayoutUpdated(layout, transition: transition)
        let duration: Double
        if case let .animated(value, _) = transition {
            duration = value
        } else {
            duration = 0.25
            self.queueSheetNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: duration, removeOnCompletion: false)
        }
        // Other layouts can run meanwhile (the player's state), so the hand-over waits for the animation's own end.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: { [weak self] in
            guard let self, self.queueCloseToken == token else {
                return
            }
            self.finishClosingQueue()
        })
        for node in [self.queueReverseButton, self.queueMoreButton, self.queueListNode].compactMap({ $0 }) as [ASDisplayNode] {
            node.alpha = 0.0
            node.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2)
        }
    }
    
    private static func rubberBand(_ distance: CGFloat, limit: CGFloat) -> CGFloat {
        return limit * (1.0 - 1.0 / (distance * 0.55 / limit + 1.0))
    }
    
    private func setQueueSheetFrame(_ frame: CGRect) {
        self.queueSheetNode.layer.removeAllAnimations()
        self.queueSheetShadowView.layer.removeAllAnimations()
        self.queueSheetNode.frame = frame
        self.queueSheetShadowView.frame = frame
        OverlayAudioPlayerControlsNode.updateAnimatedPath(layer: self.queueSheetShadowView.layer, keyPath: "shadowPath", path: UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: frame.size), byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 38.0, height: 38.0)).cgPath, transition: .immediate)
    }
    
    /// The open sheet follows the finger down; above its place it gives a little.
    private func updateQueueDrag(translation: CGFloat) {
        guard let openFrame = self.queueOpenFrame else {
            return
        }
        let offset = translation >= 0.0 ? translation : -OverlayAudioPlayerControllerNode.rubberBand(-translation, limit: 40.0)
        self.queueDragOffset = max(0.0, offset)
        let maxOffset = max(0.0, openFrame.height - OverlayAudioPlayerControllerNode.queueToolbarHeight - OverlayAudioPlayerControllerNode.queueCardOverlap)
        let clamped = min(offset, maxOffset)
        self.setQueueSheetFrame(CGRect(x: openFrame.minX, y: openFrame.minY + clamped, width: openFrame.width, height: openFrame.height - clamped))
    }
    
    /// A swipe up on the compact sheet: the queue sheet takes over its header in place and rises with the finger.
    private func beginInteractiveQueueOpening() {
        guard self.isCompact, !self.isQueueOpen, !self.isQueueClosing, let layout = self.validLayout else {
            return
        }
        let fromFrame = self.controlsNode.frame
        let baseFrame = CGRect(x: fromFrame.minX, y: fromFrame.minY, width: fromFrame.width, height: OverlayAudioPlayerControllerNode.queueToolbarHeight + OverlayAudioPlayerControllerNode.queueCardOverlap)
        self.isQueueInteractivelyOpening = true
        self.queueInteractiveBaseFrame = baseFrame
        self.controlsNode.showsQueueHeader = false
        self.queueSheetNode.isHidden = false
        self.queueSheetShadowView.isHidden = false
        self.updateQueueColors()
        self.setQueueSheetFrame(baseFrame)
        let queueTop = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top)
        // The list is laid out at the height it will have and revealed as the sheet grows.
        self.updateQueueSheetLayout(size: CGSize(width: baseFrame.width, height: max(baseFrame.height, baseFrame.maxY - queueTop)), layoutList: true, transition: .immediate)
        for node in [self.queueReverseButton, self.queueMoreButton, self.queueListNode].compactMap({ $0 }) as [ASDisplayNode] {
            node.alpha = 0.0
        }
        self.containerLayoutUpdated(layout, transition: .immediate)
        self.reloadQueueMessages()
    }
    
    private func updateInteractiveQueueOpening(distance: CGFloat) {
        guard let baseFrame = self.queueInteractiveBaseFrame, let layout = self.validLayout else {
            return
        }
        let queueTop = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top)
        let maxDistance = max(0.0, baseFrame.minY - queueTop)
        let distance = max(0.0, distance)
        let rise = distance <= maxDistance ? distance : maxDistance + OverlayAudioPlayerControllerNode.rubberBand(distance - maxDistance, limit: 30.0)
        self.setQueueSheetFrame(CGRect(x: baseFrame.minX, y: baseFrame.minY - rise, width: baseFrame.width, height: baseFrame.height + rise))
        let alpha = min(1.0, rise / 120.0)
        for node in [self.queueReverseButton, self.queueMoreButton, self.queueListNode].compactMap({ $0 }) as [ASDisplayNode] {
            node.alpha = alpha
        }
    }
    
    private func finishClosingQueue() {
        guard self.isQueueClosing, let layout = self.validLayout else {
            return
        }
        self.isQueueClosing = false
        self.queueSheetNode.layer.removeAnimation(forKey: "opacity")
        self.queueMessages = []
        self.queueSheetNode.isHidden = true
        self.queueSheetShadowView.isHidden = true
        for node in [self.queueReverseButton, self.queueMoreButton, self.queueListNode].compactMap({ $0 }) as [ASDisplayNode] {
            node.alpha = 1.0
        }
        self.controlsNode.showsQueueHeader = true
        self.containerLayoutUpdated(layout, transition: .immediate)
    }
    
    @objc private func queueTitlePressed() {
        self.closeQueue()
    }
    
    /// Reverse is on while the section's queue is turned over. Shuffle is the player's order setting, so the two
    /// work independently.
    private var isQueueReversed: Bool {
        if self.queueIsLibrary, let libraryQueue = self.libraryQueue {
            return libraryQueue.isReversed
        }
        return self.controlsNode.currentOrder == .reversed
    }
    
    private func updateQueueReverseButton() {
        let theme = self.presentationData.theme
        self.queueReverseButton.setImage(generateTintedImage(image: UIImage(bundleImageName: "GlobalMusicPlayer/OrderReverse"), color: self.isQueueReversed ? theme.list.itemAccentColor : theme.list.itemSecondaryTextColor), for: [])
    }
    
    /// A rich message's tracks only play through their own playlist: Reverse and dragging use the order setting there.
    private var queueIsInstantPage: Bool {
        if let instantPageLocation = self.playlistLocation as? InstantPagePlaylistLocation, instantPageLocation.messageId != nil {
            return !self.queueIsLibrary
        }
        return false
    }
    
    /// Figma «в обратном порядке»: the queue is turned over, so the tracks before the playing one come next.
    /// It does not touch Shuffle. A queue from a chat or a profile becomes the section's own first.
    @objc private func queueReversePressed() {
        if self.queueIsInstantPage {
            let order = self.controlsNode.currentOrder ?? .regular
            let nextOrder: MusicPlaybackSettingsOrder = order == .reversed ? .regular : .reversed
            let _ = updateMusicPlaybackSettingsInteractively(accountManager: self.context.sharedContext.accountManager, {
                return $0.withUpdatedOrder(nextOrder)
            }).startStandalone()
            self.context.sharedContext.mediaManager.playlistControl(.setOrder(nextOrder), type: self.type)
            return
        }
        // The legacy reversed order would turn the queue back: it is the full player's, not the sheet's.
        if self.controlsNode.currentOrder == .reversed {
            let _ = updateMusicPlaybackSettingsInteractively(accountManager: self.context.sharedContext.accountManager, {
                return $0.withUpdatedOrder(.regular)
            }).startStandalone()
            self.context.sharedContext.mediaManager.playlistControl(.setOrder(.regular), type: self.type)
        }
        if !self.queueIsLibrary {
            guard self.adoptQueue() else {
                return
            }
            MusicPlayerSupport.setQueueReversed(context: self.context, true)
            return
        }
        MusicPlayerSupport.setQueueReversed(context: self.context, !(self.libraryQueue?.isReversed ?? false))
    }
    
    /// Takes the queue over as the section's own; false while its tracks are still loading.
    private func adoptQueue() -> Bool {
        guard let currentId = self.currentQueueMessageId, self.queueMessages.contains(where: { $0.id == currentId }) else {
            return false
        }
        let kind: MusicPlayerQueueKind
        switch self.queueSource {
        case let .chat(peer):
            kind = .chat(peer.id)
        case let .profile(peer):
            kind = .profile(peer.id)
        case let .ownPlaylist(id):
            kind = .playlist(id)
        case let .artist(name):
            kind = .artist(name)
        case .tracks:
            kind = .tracks
        }
        MusicPlayerSupport.adoptQueue(context: self.context, messages: self.queueMessages, currentId: currentId, title: self.compactQueueInfo().title ?? "", kind: kind, timestamp: self.controlsNode.currentPosition)
        self.queueIsLibrary = true
        self.subscribeToQueue(MusicPlayerSupport.queueMessages(context: self.context))
        return true
    }
    
    @objc private func queueMorePressed() {
        self.openQueueMenu()
    }
    
    private func queueOrderChanged(_ order: MusicPlaybackSettingsOrder) {
        guard self.isCompact else {
            return
        }
        self.resetLegacyReversedOrder(order)
        self.updateQueueReverseButton()
        if self.isQueueOpen {
            self.updateQueueList(order: order, animated: true)
        }
    }
    
    /// The sheet turns the queue over itself; the full player's reversed order would hide «На очереди» from the first
    /// track and play the queue backwards behind Reverse's back. A rich message's queue keeps it: Reverse uses it there.
    private func resetLegacyReversedOrder(_ order: MusicPlaybackSettingsOrder) {
        guard order == .reversed, !self.queueIsInstantPage else {
            return
        }
        let _ = updateMusicPlaybackSettingsInteractively(accountManager: self.context.sharedContext.accountManager, {
            return $0.withUpdatedOrder(.regular)
        }).startStandalone()
        self.context.sharedContext.mediaManager.playlistControl(.setOrder(.regular), type: self.type)
    }
    
    private var currentQueueMessageId: EngineMessage.Id? {
        return (self.controlsNode.currentItemId as? PeerMessagesMediaPlaylistItemId)?.messageId
    }
    
    /// The queue's tracks in play order: the section's own queue, the list the player was given, or the chat's audio.
    private func reloadQueueMessages() {
        let context = self.context
        let signal: Signal<[EngineRawMessage], NoError>
        if let libraryQueue = self.libraryQueue, let messageId = self.currentQueueMessageId, libraryQueue.messageIds.contains(messageId) {
            self.queueIsLibrary = true
            signal = MusicPlayerSupport.queueMessages(context: context)
        } else {
            self.queueIsLibrary = false
            if case let .custom(messages, _, _, _, _, _, _) = self.source {
                signal = messages
                |> map { messages, _, _ -> [EngineRawMessage] in
                    return messages
                }
            } else if case let .peer(peerId) = self.chatLocation {
                // Newest first, which is the chat's play order: Next goes to the earlier track.
                func page(state: SearchMessagesState?, loaded: [EngineRawMessage]) -> Signal<[EngineRawMessage], NoError> {
                    return context.engine.messages.searchMessages(location: .peer(peerId: peerId, fromId: nil, tags: .music, reactions: nil, threadId: nil, minDate: nil, maxDate: nil), query: "", state: state)
                    |> take(1)
                    |> mapToSignal { result, state -> Signal<[EngineRawMessage], NoError> in
                        let messages = loaded + result.messages
                        if result.completed || result.messages.isEmpty || messages.count >= 1000 {
                            return .single(messages)
                        }
                        return .single(messages)
                        |> then(page(state: state, loaded: messages))
                    }
                }
                signal = page(state: nil, loaded: [])
            } else {
                signal = .single([])
            }
        }
        self.subscribeToQueue(signal)
    }
    
    private func subscribeToQueue(_ signal: Signal<[EngineRawMessage], NoError>) {
        self.queueMessagesDisposable.set((signal
        |> deliverOnMainQueue).startStrict(next: { [weak self] messages in
            guard let self else {
                return
            }
            let isFirst = self.queueMessages.isEmpty
            self.queueMessages = messages
            self.updateQueueList(order: self.controlsNode.currentOrder ?? .regular, animated: !isFirst)
        }))
    }
    
    /// The queue in play order: what played before the current track, the track, then what comes. Shuffle has no
    /// order to show, so the list keeps the queue's own.
    private func playOrderQueueMessages(order: MusicPlaybackSettingsOrder) -> [EngineRawMessage] {
        return order == .reversed ? self.queueMessages.reversed() : self.queueMessages
    }
    
    private func updateQueueList(order: MusicPlaybackSettingsOrder, animated: Bool) {
        guard let listNode = self.queueListNode else {
            return
        }
        // Any queue but a rich message's can be reordered (a chat's or a profile's becomes the section's own on the
        // first drag); a shuffled one has no order to change.
        let canReorder = !self.queueIsInstantPage && order == .regular && self.currentQueueMessageId != nil
        listNode.update(messages: self.playOrderQueueMessages(order: order), favoriteFileIds: self.favoriteFileIds, currentId: self.currentQueueMessageId, isPaused: self.controlsNode.currentIsPaused ?? false, canReorder: canReorder, animated: animated)
    }
    
    private func moveQueueMessage(messageId: EngineMessage.Id, toDisplayedIndex: Int) {
        if !self.queueIsLibrary {
            guard self.adoptQueue() else {
                return
            }
        }
        // The list shows the whole queue in its order, so its index is the queue's.
        MusicPlayerSupport.moveInQueue(context: self.context, messageId: messageId, toIndex: toDisplayedIndex)
    }
    
    /// A row plays its track in the same queue.
    private func playQueueMessage(_ message: EngineRawMessage) {
        if self.queueIsLibrary {
            MusicPlayerSupport.playInQueue(context: self.context, messageId: message.id)
            return
        }
        if let instantPageLocation = self.playlistLocation as? InstantPagePlaylistLocation, instantPageLocation.messageId != nil, message.id.namespace == Namespaces.Message.Local {
            self.playInstantPageTrack(atMediaIndex: Int(message.id.id), location: instantPageLocation)
            return
        }
        var playlistLocation: PeerMessagesPlaylistLocation?
        if let location = self.playlistLocation as? PeerMessagesPlaylistLocation {
            if case let .custom(messages, canReorder, _, loadMore, hidePanel) = location {
                playlistLocation = .custom(messages: messages, canReorder: canReorder, at: message.id, loadMore: loadMore, hidePanel: hidePanel)
            } else if case let .savedMusic(context, _, canReorder) = location {
                playlistLocation = .savedMusic(context: context, at: message.id.id, canReorder: canReorder)
            }
        }
        let _ = self.context.sharedContext.openChatMessage(OpenChatMessageParams(context: self.context, chatLocation: nil, chatFilterTag: nil, chatLocationContextHolder: nil, message: message, standalone: false, reverseMessageGalleryOrder: false, navigationController: nil, dismissInput: { }, present: { _, _, _ in }, transitionNode: { _, _, _ in return nil }, addToTransitionSurface: { _ in }, openUrl: { _ in }, openPeer: { _, _ in }, callPeer: { _, _ in }, openConferenceCall: { _ in
        }, enqueueMessage: { _ in }, sendSticker: nil, sendEmoji: nil, setupTemporaryHiddenMedia: { _, _, _ in }, chatAvatarHiddenMedia: { _, _ in }, playlistLocation: playlistLocation))
    }
    
    private enum QueueSource {
        /// Library tracks that make no list of their own, or a list with nowhere to lead.
        case tracks
        case ownPlaylist(Int)
        case artist(String)
        case chat(EnginePeer)
        /// A profile's music: someone's own list of tracks.
        case profile(EnginePeer)
    }
    
    private var queueSource: QueueSource {
        if self.queueIsLibrary, let libraryQueue = self.libraryQueue {
            switch libraryQueue.kind {
            case .tracks:
                return .tracks
            case let .playlist(id):
                return MusicPlayerSupport.playlistExists(context: self.context, id: id) ? .ownPlaylist(id) : .tracks
            case let .artist(name):
                return .artist(name)
            case let .chat(peerId):
                if let peer = self.sourceChatPeer, peer.id == peerId {
                    return .chat(peer)
                }
                return .tracks
            case let .profile(peerId):
                if let peer = self.peer, peer.id == peerId {
                    return .profile(peer)
                }
                return .tracks
            }
        }
        if let playlistLocation = self.playlistLocation as? PeerMessagesPlaylistLocation, case .savedMusic = playlistLocation, let peer = self.peer {
            return .profile(peer)
        }
        if let peer = self.sourceChatPeer {
            return .chat(peer)
        }
        return .tracks
    }
    
    /// Figma Player / Queue List Menu: Broadcast and Share, then the list actions, then the way back to the queue's
    /// source. A playlist of the library is already one, so it offers no new playlist.
    private func openQueueMenu() {
        guard let controller = self.getParentController() else {
            return
        }
        let context = self.context
        let presentationData = self.presentationData
        let strings = presentationData.strings
        let icon: (String) -> (PresentationTheme) -> UIImage? = { name in
            return { theme in
                return generateTintedImage(image: UIImage(bundleImageName: name), color: theme.contextMenu.primaryColor)
            }
        }
        let source = self.queueSource
        let messages = self.queueMessages
        
        var items: [ContextMenuItem] = []
        let isBroadcasting = self.isBroadcastingToProfile
        items.append(.action(ContextMenuActionItem(text: isBroadcasting ? musicString(strings, ru: "Остановить трансляцию", en: "Stop Broadcasting") : musicString(strings, ru: "Транслировать в профиль", en: "Broadcast to Profile"), icon: icon("Chat/Context Menu/VoiceChat"), action: { [weak self] _, f in
            f(.default)
            guard let self else {
                return
            }
            self.isBroadcastingToProfile = !isBroadcasting
            MusicPlayerSupport.toast(context: context, text: isBroadcasting ? musicString(strings, ru: "Трансляция в профиль остановлена", en: "Broadcasting stopped") : musicString(strings, ru: "Музыка транслируется в профиль", en: "Your music is shown in your profile"), iconName: "Chat/Context Menu/VoiceChat")
        })))
        if !self.copyProtectionEnabled && !messages.isEmpty {
            items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuShare, icon: icon("Chat/Context Menu/Share"), action: { [weak self] _, f in
                f(.default)
                self?.shareQueue()
            })))
        }
        
        var listItems: [ContextMenuItem] = []
        var offersNewPlaylist = true
        if case .ownPlaylist = source {
            offersNewPlaylist = false
        }
        if offersNewPlaylist && !messages.isEmpty {
            listItems.append(.action(ContextMenuActionItem(text: musicString(strings, ru: "Создать плейлист", en: "New Playlist"), icon: icon("Music/NoteList"), action: { [weak self] _, f in
                f(.dismissWithoutContent)
                MusicPlayerSupport.createPlaylist(context: context, messages: messages, dismissPlayer: {
                    self?.requestDismiss()
                })
            })))
            listItems.append(.action(ContextMenuActionItem(text: musicString(strings, ru: "Добавить в плейлист", en: "Add to Playlist"), icon: icon("Chat/Context Menu/AddCaption"), action: { [weak self] _, f in
                f(.default)
                MusicPlayerSupport.addToPlaylist(context: context, messages: messages, present: { [weak self] controller in
                    (self?.getParentController() as? OverlayAudioPlayerControllerImpl)?.present(controller, in: .window(.root))
                }, dismissPlayer: {
                    self?.requestDismiss()
                })
            })))
        }
        if !listItems.isEmpty {
            items.append(.separator)
            items.append(contentsOf: listItems)
        }
        
        let peerName: (EnginePeer) -> String = { peer in
            if peer.id == context.account.peerId {
                return musicString(strings, ru: "Ваш профиль", en: "Your Profile")
            }
            if let addressName = peer.addressName, !addressName.isEmpty {
                return "@\(addressName)"
            }
            return peer.compactDisplayTitle
        }
        var goToItem: ContextMenuItem?
        switch source {
        case .tracks:
            break
        case let .ownPlaylist(id):
            goToItem = .action(ContextMenuActionItem(text: musicString(strings, ru: "Перейти к плейлисту", en: "Go to Playlist"), textLayout: .secondLineWithValue(MusicPlayerSupport.libraryTitle(strings: strings)), icon: icon("Music/Playlists"), action: { [weak self] _, f in
                f(.dismissWithoutContent)
                self?.requestDismiss()
                MusicPlayerSupport.openPlaylist(context: context, id: id)
            }))
        case let .artist(name):
            goToItem = .action(ContextMenuActionItem(text: musicString(strings, ru: "Перейти к артисту", en: "Go to Artist"), textLayout: .secondLineWithValue(name), icon: icon("Music/Microphone"), action: { [weak self] _, f in
                f(.dismissWithoutContent)
                self?.requestDismiss()
                MusicPlayerSupport.openArtist(context: context, name: name)
            }))
        case let .chat(peer):
            goToItem = .action(ContextMenuActionItem(text: musicString(strings, ru: "Перейти к диалогу", en: "Go to Chat"), textLayout: .secondLineWithValue(peerName(peer)), icon: icon("Chat/Context Menu/GoToMessage"), action: { [weak self] _, f in
                f(.dismissWithoutContent)
                self?.requestDismiss()
                context.sharedContext.navigateToChat(accountId: context.account.id, peerId: peer.id, messageId: nil)
            }))
        case let .profile(peer):
            goToItem = .action(ContextMenuActionItem(text: musicString(strings, ru: "Перейти к плейлисту", en: "Go to Playlist"), textLayout: .secondLineWithValue(peerName(peer)), icon: icon("Music/Playlists"), action: { [weak self] _, f in
                f(.dismissWithoutContent)
                self?.requestDismiss()
                guard let infoController = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer, mode: .generic, avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil), let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController else {
                    return
                }
                navigationController.pushViewController(infoController)
            }))
        }
        if let goToItem {
            items.append(.separator)
            items.append(goToItem)
        }
        
        let contextController = makeContextController(presentationData: presentationData, source: .reference(OverlayAudioPlayerReferenceContentSource(sourceNode: self.queueMoreReferenceNode)), items: .single(ContextController.Items(content: .list(items))), gesture: nil)
        controller.presentInGlobalOverlay(contextController)
    }
    
    /// Chat tracks are forwarded as their messages; a list of profile tracks, which have none, sends its first file.
    private func shareQueue() {
        let messages = self.queueMessages
        let chatMessages = messages.filter { $0.id.namespace == Namespaces.Message.Cloud }
        if !chatMessages.isEmpty {
            self.requestShare(.messages(Array(chatMessages.prefix(100))))
        } else if let file = messages.first?.media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile {
            self.requestShare(.media(.standalone(media: file), nil))
        }
    }
    
    private func openCompactMoreMenu(referenceNode: ContextReferenceContentNode) {
        guard let controller = self.getParentController(), let fileReference = self.controlsNode.currentFileReference else {
            return
        }
        let context = self.context
        let presentationData = self.presentationData
        let strings = presentationData.strings
        let messageId = (self.controlsNode.currentItemId as? PeerMessagesMediaPlaylistItemId)?.messageId
        let icon: (String) -> (PresentationTheme) -> UIImage? = { name in
            return { theme in
                return generateTintedImage(image: UIImage(bundleImageName: name), color: theme.contextMenu.primaryColor)
            }
        }
        
        var items: [ContextMenuItem] = []
        if !self.copyProtectionEnabled {
            items.append(.action(ContextMenuActionItem(text: strings.Conversation_ContextMenuShare, icon: icon("Chat/Context Menu/Share"), action: { [weak self] _, f in
                f(.default)
                self?.controlsNode.sharePressed()
            })))
            items.append(.action(ContextMenuActionItem(text: strings.MediaPlayer_ContextMenu_SaveToFiles, icon: icon("Chat/Context Menu/Save"), action: { [weak self] _, f in
                f(.default)
                guard let self else {
                    return
                }
                let disposable: MetaDisposable
                if let current = self.saveMediaDisposable {
                    disposable = current
                } else {
                    disposable = MetaDisposable()
                    self.saveMediaDisposable = disposable
                }
                disposable.set(saveMediaToFiles(context: context, fileReference: fileReference, present: { [weak self] c, a in
                    if let self, let controller = self.getParentController() as? OverlayAudioPlayerControllerImpl {
                        controller.present(c, in: .window(.root), with: a)
                    }
                }))
            })))
        }
        if let messageId, messageId.namespace == Namespaces.Message.Cloud {
            items.append(.action(ContextMenuActionItem(text: strings.MediaPlayer_ContextMenu_ShowInChat, icon: icon("Chat/Context Menu/GoToMessage"), action: { [weak self] _, f in
                f(.dismissWithoutContent)
                context.sharedContext.navigateToChat(accountId: context.account.id, peerId: messageId.peerId, messageId: messageId)
                self?.requestDismiss()
            })))
        }
        // Adding to the profile moved here from the sheet: its button now adds to Music.
        if let isSaved = self.isSaved {
            items.insert(.action(ContextMenuActionItem(text: isSaved ? musicString(strings, ru: "Убрать из профиля", en: "Remove from Profile") : musicString(strings, ru: "Добавить в профиль", en: "Add to Profile"), icon: icon(isSaved ? "Music/RemoveFromProfile" : "Peer Info/SaveMusic"), action: { [weak self] _, f in
                f(.default)
                guard let self else {
                    return
                }
                if isSaved {
                    self.removeFromSavedMusic(file: fileReference)
                } else {
                    self.addToSavedMusic(file: fileReference)
                }
            })), at: 0)
        }
        var artist: String?
        for attribute in fileReference.media.attributes {
            if case let .Audio(_, _, _, performer, _) = attribute, let performer, !performer.isEmpty {
                artist = performer
            }
        }
        if let artist {
            if !items.isEmpty {
                items.append(.separator)
            }
            items.append(.action(ContextMenuActionItem(text: musicString(strings, ru: "Искать по артисту", en: "Search Artist"), textLayout: .secondLineWithValue(artist), icon: icon("Chat/Context Menu/Search"), action: { [weak self] _, f in
                f(.default)
                self?.requestSearchByArtist(artist)
            })))
        }
        guard !items.isEmpty else {
            return
        }
        let contextController = makeContextController(presentationData: presentationData, source: .reference(OverlayAudioPlayerReferenceContentSource(sourceNode: referenceNode)), items: .single(ContextController.Items(content: .list(items))), gesture: nil)
        controller.presentInGlobalOverlay(contextController)
    }
    
    private var isSaved: Bool? {
        if self .copyProtectionEnabled {
            return nil
        }
        if case let .peer(peerId) = self.chatLocation, peerId.namespace == Namespaces.Peer.SecretChat {
            return nil
        }
        guard let fileReference = self.controlsNode.currentFileReference else {
            return nil
        }
        return self.savedIds?.contains(fileReference.media.fileId.id)
    }
    
    private func updateHistoryContentOffset(_ offset: ListViewVisibleContentOffset, transition: ContainedViewLayoutTransition) {
        switch offset {
        case let .known(value):
            self.historyContentOffset = value
        case .none:
            self.historyContentOffset = 0.0
        case .unknown:
            break
        }
        
        self.updateContainerContainingNodeTransform(transition: transition)
    }
    
    private func updateContainerContainingNodeTransform(transition: ContainedViewLayoutTransition) {
        guard let layout = self.validLayout else {
            return
        }
        
        if case .regular = layout.metrics.widthClass {
            transition.updateTransform(layer: self.containerContainingNode.layer, transform: CATransform3DIdentity)
            transition.updateCornerRadius(node: self.containerContainingNode, cornerRadius: 0.0)
            return
        }
        if self.isCompact {
            // The compact sheet floats 6 pt from the screen edges on its own; the screen does not shrink behind it.
            transition.updateTransform(layer: self.containerContainingNode.layer, transform: CATransform3DIdentity)
            transition.updateCornerRadius(node: self.containerContainingNode, cornerRadius: 0.0)
            return
        }
        
        let expandDistance = self.effectiveHeaderHeight
        let topOffsetFraction = max(0.0, min(1.0, self.historyContentOffset / expandDistance))
        
        let minScale: CGFloat = (layout.size.width - 6.0 * 2.0) / layout.size.width
        let minScaledTranslation: CGFloat = (layout.size.height - layout.size.height * minScale) * 0.5 - 6.0
        
        let scale = minScale * (1.0 - topOffsetFraction) + topOffsetFraction
        let scaledTranslation = minScaledTranslation * (1.0 - topOffsetFraction)
        
        var containerTransform = CATransform3DIdentity
        containerTransform = CATransform3DTranslate(containerTransform, 0.0, scaledTranslation, 0.0)
        containerTransform = CATransform3DScale(containerTransform, scale, scale, scale)
        
        transition.updateTransform(layer: self.containerContainingNode.layer, transform: containerTransform)
        
        let containerCornerRadius = max(22.0, layout.deviceMetrics.screenCornerRadius)
        let screenCornerRadii = layout.screenCornerRadii
        if !screenCornerRadii.isUniform, CALayer.cornerRadiiSupported {
            // iPhone Duo's cover screen: the container fills the screen, so each corner follows its own screen corner
            // (8pt on the hinge side, 59pt outside) rather than one radius.
            self.containerUsesCornerRadii = true
            self.containerContainingNode.layer.setCornerRadii(screenCornerRadii)
        } else {
            if self.containerUsesCornerRadii {
                self.containerUsesCornerRadii = false
                self.containerContainingNode.layer.setCornerRadii(CornerRadii(uniform: containerCornerRadius))
            }
            transition.updateCornerRadius(node: self.containerContainingNode, cornerRadius: containerCornerRadius)
        }
    }
    
    private var effectiveHeaderHeight: CGFloat {
        var headerHeight: CGFloat = 38.0
        if let playlistLocation = self.playlistLocation as? PeerMessagesPlaylistLocation, case .savedMusic = playlistLocation {
            headerHeight = 78.0
        }
        return headerHeight
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        self.validLayout = layout
                
        transition.updateFrame(node: self.dimNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        transition.updateFrameAsPositionAndBounds(node: self.containerContainingNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        transition.updateFrame(node: self.contentNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        
        // The bottom controls panel spans iPhone Duo's side strip; it keeps clear only of a corner block at the bottom.
        // Equal insets keep the controls across the full width, as before.
        let controlsBottomInsets = layout.bottomEdgeSideInsets()
        let controlsLeftInset: CGFloat = layout.safeInsets.left != layout.safeInsets.right ? controlsBottomInsets.left : 0.0
        let controlsRightInset: CGFloat = layout.safeInsets.left != layout.safeInsets.right ? controlsBottomInsets.right : 0.0
        let controlsHeight: CGFloat
        let controlsFrame: CGRect
        if self.isCompact {
            // Figma Player Sheet: 6 pt from the screen edges, bottom corners concentric with the screen's.
            // The queue sheet spans the screen: its card sits at the bottom edge (Figma Player / Queue List).
            let sheetInset: CGFloat = self.isQueueOpen ? 0.0 : 6.0
            let sheetWidth = layout.size.width - controlsBottomInsets.left - controlsBottomInsets.right - sheetInset * 2.0
            self.controlsNode.compactBottomCornerRadius = layout.deviceMetrics.screenCornerRadius - sheetInset
            let fileId = self.controlsNode.currentFileReference?.media.fileId.id
            self.controlsNode.compactPanelState = OverlayAudioPlayerControlsNode.CompactPanelState(isInMusic: self.isInMusic, isFavorite: fileId.flatMap { self.favoriteFileIds.contains($0) } ?? false)
            let queueInfo = self.compactQueueInfo()
            self.controlsNode.queueCount = queueInfo.count
            self.controlsNode.queueTitle = queueInfo.title
            controlsHeight = self.controlsNode.updateLayout(width: sheetWidth, leftInset: 0.0, rightInset: 0.0, bottomInset: layout.intrinsicInsets.bottom, maxHeight: layout.size.height, savedMusic: nil, transition: transition)
            controlsFrame = CGRect(origin: CGPoint(x: controlsBottomInsets.left + sheetInset, y: layout.size.height - sheetInset - controlsHeight), size: CGSize(width: sheetWidth, height: controlsHeight))
            if self.isQueueClosing {
                let headerFrame = CGRect(x: controlsFrame.minX, y: controlsFrame.minY - OverlayAudioPlayerControllerNode.queueToolbarHeight, width: controlsFrame.width, height: OverlayAudioPlayerControllerNode.queueToolbarHeight + OverlayAudioPlayerControllerNode.queueCardOverlap)
                transition.updateFrame(node: self.queueSheetNode, frame: headerFrame, beginWithCurrentState: true)
                transition.updateFrame(view: self.queueSheetShadowView, frame: headerFrame, beginWithCurrentState: true)
                OverlayAudioPlayerControlsNode.updateAnimatedPath(layer: self.queueSheetShadowView.layer, keyPath: "shadowPath", path: UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: headerFrame.size), byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 38.0, height: 38.0)).cgPath, transition: transition)
                self.updateQueueSheetLayout(size: headerFrame.size, layoutList: false, transition: transition)
            }
            if self.isQueueOpen {
                let queueTop = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top)
                let openHeight = max(0.0, controlsFrame.minY + OverlayAudioPlayerControllerNode.queueCardOverlap - queueTop)
                self.queueOpenFrame = CGRect(x: controlsFrame.minX, y: queueTop, width: controlsFrame.width, height: openHeight)
                // A drag moves the sheet's top only; the card under it stays.
                let dragOffset = min(self.queueDragOffset, max(0.0, openHeight - OverlayAudioPlayerControllerNode.queueToolbarHeight - OverlayAudioPlayerControllerNode.queueCardOverlap))
                let queueFrame = CGRect(x: controlsFrame.minX, y: queueTop + dragOffset, width: controlsFrame.width, height: openHeight - dragOffset)
                var contentTransition = transition
                if let openingFrame = self.queueSheetOpeningFrame {
                    // The sheet grows out of the compact one; its content is laid out at its final size at once.
                    self.queueSheetOpeningFrame = nil
                    self.queueSheetNode.frame = openingFrame
                    self.queueSheetShadowView.frame = openingFrame
                    contentTransition = .immediate
                }
                transition.updateFrame(node: self.queueSheetNode, frame: queueFrame, beginWithCurrentState: true)
                transition.updateFrame(view: self.queueSheetShadowView, frame: queueFrame, beginWithCurrentState: true)
                OverlayAudioPlayerControlsNode.updateAnimatedPath(layer: self.queueSheetShadowView.layer, keyPath: "shadowPath", path: UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: queueFrame.size), byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 38.0, height: 38.0)).cgPath, transition: transition)
                // The toolbar moves with the sheet's edges; the list is laid out at its final size at once and revealed.
                self.updateQueueSheetLayout(size: queueFrame.size, layoutList: true, transition: transition, listTransition: contentTransition)
            }
        } else {
            controlsHeight = self.controlsNode.updateLayout(width: layout.size.width, leftInset: controlsLeftInset, rightInset: controlsRightInset, bottomInset: layout.intrinsicInsets.bottom, maxHeight: layout.size.height, savedMusic: self.isSaved, transition: transition)
            controlsFrame = CGRect(origin: CGPoint(x: 0.0, y: layout.size.height - controlsHeight), size: CGSize(width: layout.size.width, height: controlsHeight))
        }
        let controlsTransition = self.controlsNode.frame.width > 0.0 ? transition : .immediate
        // From what is on screen: the sheet can be turned back mid-flight.
        controlsTransition.updateFrame(node: self.controlsNode, frame: controlsFrame, beginWithCurrentState: self.isCompact)

        let layoutTopInset: CGFloat = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top)
        // The playlist keeps 16pt clear of a side strip (iPhone Duo), so its rows and header stay out of the strip and of
        // the status corner above it when the sheet rises to the top; 16pt on each side otherwise.
        let listSideMargins = layout.listSideMargins(base: 16.0)
        var insets = UIEdgeInsets()
        insets.left = listSideMargins.left
        insets.right = listSideMargins.right
        insets.bottom = 0.0
                        
        let headerHeight = self.effectiveHeaderHeight

        let listTopInset = layoutTopInset + headerHeight
        let listNodeSize = CGSize(width: layout.size.width, height: layout.size.height - listTopInset - controlsHeight)
        
        insets.top = max(0.0, listNodeSize.height - floor(62.0 * 3.5))
        
        var itemOffsetInsets = insets
        if let playlistLocation = self.playlistLocation as? PeerMessagesPlaylistLocation, case let .savedMusic(_, _, canReorder) = playlistLocation, canReorder {
            itemOffsetInsets.top = 0.0
            itemOffsetInsets.bottom = 0.0
            insets = itemOffsetInsets
        }
        transition.updateFrame(node: self.historyNode, frame: CGRect(origin: CGPoint(x: 0.0, y: listTopInset), size: listNodeSize))
        
        let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
        let updateSizeAndInsets = ListViewUpdateSizeAndInsets(size: listNodeSize, insets: insets, itemOffsetInsets: itemOffsetInsets, duration: duration, curve: curve)
        self.historyNode.updateLayout(transition: transition, updateSizeAndInsets: updateSizeAndInsets)
        if let replacementHistoryNode = self.replacementHistoryNode {
            transition.updateFrame(node: replacementHistoryNode, frame: CGRect(origin: CGPoint(x: 0.0, y: listTopInset), size: listNodeSize))
            let updateSizeAndInsets = ListViewUpdateSizeAndInsets(size: listNodeSize, insets: insets, itemOffsetInsets: itemOffsetInsets, duration: 0.0, curve: .Default(duration: nil))
            replacementHistoryNode.updateLayout(transition: transition, updateSizeAndInsets: updateSizeAndInsets)
        }
        
        if let playlistLocation = self.playlistLocation as? PeerMessagesPlaylistLocation, case .savedMusic = playlistLocation {
            let leftControlItems: [GlassControlGroupComponent.Item] = [
                GlassControlGroupComponent.Item(
                    id: AnyHashable("close"),
                    content: .icon("Navigation/Close"),
                    action: { [weak self] in
                        guard let self else {
                            return
                        }
                        self.requestDismiss()
                    }
                )
            ]
            var rightControlItems: [GlassControlGroupComponent.Item] = []
            if let playlistLocation = self.playlistLocation as? PeerMessagesPlaylistLocation, case let .savedMusic(savedMusicContext, _, _) = playlistLocation, savedMusicContext.peerId == self.context.account.peerId {
                rightControlItems.append(
                    GlassControlGroupComponent.Item(
                        id: AnyHashable("add"),
                        content: .icon("Navigation/Add"),
                        action: { [weak self] in
                            guard let self else {
                                return
                            }
                            self.requestAdd()
                        }
                    )
                )
            }
            
            let headerInset: CGFloat = 16.0
            let headerButtonsSize = self.headerButtons.update(
                transition: ComponentTransition(transition),
                component: AnyComponent(
                    GlassControlPanelComponent(
                        theme: self.presentationData.theme,
                        leftItem: GlassControlPanelComponent.Item(
                            items: leftControlItems,
                            background: .panel
                        ),
                        centralItem: nil,
                        rightItem: rightControlItems.isEmpty ? nil : GlassControlPanelComponent.Item(
                            items: rightControlItems,
                            background: .panel
                        ),
                        centerAlignmentIfPossible: true,
                        isDark: self.presentationData.theme.overallDarkAppearance
                    )
                ),
                environment: {},
                containerSize: CGSize(width: layout.size.width - listSideMargins.left - listSideMargins.right, height: 44.0)
            )
            if let headerButtonsView = self.headerButtons.view {
                if headerButtonsView.superview == nil {
                    self.historyFrameNode.view.addSubview(headerButtonsView)
                }
                headerButtonsView.frame = CGRect(origin: CGPoint(x: listSideMargins.left, y: headerInset), size: headerButtonsSize)
            }
            
            let titleString: String
            if let peer = self.peer {
                if peer.id == self.context.account.peerId {
                    titleString = self.presentationData.strings.MediaPlayer_PlaylistYourTitle
                } else {
                    titleString = self.presentationData.strings.MediaPlayer_PlaylistTitle(peer.compactDisplayTitle).string
                }
            } else {
                titleString = ""
            }
            
            // Centred between the header's buttons, in the band the header keeps to.
            let titleAvailableWidth = layout.size.width - listSideMargins.left - listSideMargins.right - 54.0 * 2.0
            let titleSize = self.title.update(
                transition: ComponentTransition(transition),
                component: AnyComponent(
                    MultilineTextComponent(text: .plain(NSAttributedString(string: titleString, font: Font.semibold(17.0), textColor: self.presentationData.theme.list.itemPrimaryTextColor)))
                ),
                environment: {},
                containerSize: CGSize(width: titleAvailableWidth, height: headerHeight)
            )
            if let titleView = self.title.view {
                if titleView.superview == nil {
                    self.historyFrameNode.view.addSubview(titleView)
                }
                titleView.frame = CGRect(origin: CGPoint(x: listSideMargins.left + 54.0 + floor((titleAvailableWidth - titleSize.width) / 2.0), y: 29.0), size: titleSize)
            }
        }
        
        transition.updateFrame(node: self.collapseNode, frame: CGRect(origin: CGPoint(x: 0.0, y: -7.0), size: CGSize(width: layout.size.width, height: 30.0)))
        
        self.updateHistoryContentOffset(self.historyNode.visibleContentOffset(), transition: transition)
        
        self.albumArtBackground.frame = CGRect(origin: .zero, size: layout.size)
        
        if let _ = self.currentAlbumArt {
            var animateIn = false
            if self.albumArtBackground.superview == nil {
                self.view.addSubview(self.albumArtBackground)
                animateIn = true
            }
            // iPhone Duo: beside a side strip the cover keeps to the band between the side insets (in folded portrait it
            // reached 31pt into the strip and the status corner). Elsewhere the insets are equal and the band is the
            // whole width, as before.
            let albumArtBandInsets: (left: CGFloat, right: CGFloat) = layout.safeInsets.left != layout.safeInsets.right ? (layout.safeInsets.left, layout.safeInsets.right) : (0.0, 0.0)
            let albumArtBandWidth = layout.size.width - albumArtBandInsets.left - albumArtBandInsets.right
            let albumArtSide = min(360.0, albumArtBandWidth - 32.0)
            let albumArtSize = CGSize(width: albumArtSide, height: albumArtSide)
            self.albumArtNode.frame = CGRect(origin: CGPoint(x: albumArtBandInsets.left + floorToScreenPixels((albumArtBandWidth - albumArtSize.width) / 2.0), y: floorToScreenPixels((layout.size.height - albumArtSize.height) / 2.0)), size: albumArtSize)
            
            let makeLargeAlbumArtLayout = self.albumArtNode.asyncLayout()
            let applyLargeAlbumArt = makeLargeAlbumArtLayout(TransformImageArguments(corners: ImageCorners(radius: 4.0), imageSize: albumArtSize, boundingSize: albumArtSize, intrinsicInsets: UIEdgeInsets()))
            applyLargeAlbumArt()
            
            if animateIn {
                self.controlsNode.albumArtNode.alpha = 0.0
                
                let sourceFrame = self.controlsNode.albumArtNode.view.convert(self.controlsNode.albumArtNode.bounds, to: self.albumArtBackground.contentView)
                ContainedViewLayoutTransition.animated(duration: 0.4, curve: .spring).animateFrame(node: self.albumArtNode, from: sourceFrame)
                UIView.animate(withDuration: 0.2, animations: {
                    self.albumArtBackground.effect = UIBlurEffect(style: self.presentationData.theme.overallDarkAppearance ? .dark : .light)
                })
            }
        } else {
            self.controlsNode.albumArtNode.alpha = 1.0
            
            if self.albumArtBackground.superview != nil {
                let fadeTransition = ComponentTransition(transition)
                fadeTransition.setBlur(layer: self.albumArtNode.layer, radius: 10.0)
                fadeTransition.setAlpha(layer: self.albumArtNode.layer, alpha: 0.0)
                
                UIView.animate(withDuration: 0.2, animations: {
                    self.albumArtBackground.effect = nil
                }, completion: { _ in
                    self.albumArtBackground.removeFromSuperview()
                    ComponentTransition.immediate.setBlur(layer: self.albumArtNode.layer, radius: 0.0)
                    ComponentTransition.immediate.setAlpha(layer: self.albumArtNode.layer, alpha: 1.0)
                })
            }
        }
        
        var layout = layout
        layout.intrinsicInsets.bottom = layout.size.height - controlsFrame.minY + (self.historyNode.hasAnyMessages || self.isCompact ? 0.0 : 8.0)
        self.getParentController()?.presentationContext.containerLayoutUpdated(layout, transition: transition)
    }
    
    func animateIn() {
        self.layer.animateBoundsOriginYAdditive(from: -self.bounds.size.height, to: 0.0, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring)
        self.dimNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
        self.dimNode.layer.animatePosition(from: CGPoint(x: 0.0, y: -self.bounds.size.height), to: CGPoint(), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: true, additive: true)
    }
    
    func animateOut(completion: (() -> Void)?) {
        self.dismissAllTooltips()
        
        self.layer.animateBoundsOriginYAdditive(from: self.bounds.origin.y, to: -self.bounds.size.height, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, completion: { _ in
            completion?()
        })
        self.dimNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
        self.dimNode.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: -self.bounds.size.height), duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, additive: true)
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if !self.bounds.contains(point) {
            return nil
        }
        if self.albumArtBackground.superview == nil && self.isCompact {
            if !self.controlsNode.frame.contains(point) && !(self.isQueueOpen && self.queueSheetNode.frame.contains(point)) {
                return self.dimNode.view
            }
            return result
        }
        if self.albumArtBackground.superview == nil &&  point.y < self.historyFrameNode.frame.minY {
            return self.dimNode.view
        }
        return result
    }
    
    @objc func dimTapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            self.requestDismiss()
        }
    }
    
    @objc func albumArtTapped(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state, let layout = self.validLayout {
            self.currentAlbumArt = nil
            self.containerLayoutUpdated(layout, transition: .animated(duration: 0.3, curve: .easeInOut))
        }
    }
            
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let recognizer = gestureRecognizer as? UIPanGestureRecognizer {
            let location = recognizer.location(in: self.view)
            if let view = super.hitTest(location, with: nil) {
                if let gestureRecognizers = view.gestureRecognizers, view != self.view {
                    for gestureRecognizer in gestureRecognizers {
                        if let panGestureRecognizer = gestureRecognizer as? UIPanGestureRecognizer, gestureRecognizer.isEnabled {
                            if panGestureRecognizer.state != .began {
                                panGestureRecognizer.isEnabled = false
                                panGestureRecognizer.isEnabled = true
                            }
                        }
                    }
                }
            }
        }
        return true
    }
    
    @objc func panGesture(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
            case .began:
                self.dismissAllTooltips()
            case .changed:
                let translation = recognizer.translation(in: self.contentNode.view)
                if self.isCompact {
                    if self.isQueueOpen {
                        // The sheet follows the finger; the card stays.
                        self.updateQueueDrag(translation: translation.y)
                        return
                    }
                    if self.isQueueInteractivelyOpening || (translation.y < 0.0 && !self.isQueueClosing) {
                        if !self.isQueueInteractivelyOpening {
                            self.beginInteractiveQueueOpening()
                        }
                        self.updateInteractiveQueueOpening(distance: -translation.y)
                        return
                    }
                }
                var bounds = self.contentNode.bounds
                bounds.origin.y = -translation.y
                bounds.origin.y = min(0.0, bounds.origin.y)
                if bounds.origin.y < 0.0 {
                    //let delta = -bounds.origin.y
                    //bounds.origin.y = -((1.0 - (1.0 / (((delta) * 0.55 / (50.0)) + 1.0))) * 50.0)
                }
                
                self.contentNode.bounds = bounds
            case .ended:
                let translation = recognizer.translation(in: self.contentNode.view)
                var bounds = self.contentNode.bounds
                bounds.origin.y = -translation.y
                if bounds.origin.y < 0.0 {
                    //let delta = -bounds.origin.y
                    //bounds.origin.y = -((1.0 - (1.0 / (((delta) * 0.55 / (50.0)) + 1.0))) * 50.0)
                }
                
                let velocity = recognizer.velocity(in: self.contentNode.view)
                
                if self.isCompact {
                    // The queue sheet opens with a swipe up and folds back with a swipe down, either way from where
                    // the finger left it; down on the compact sheet closes the player.
                    if self.isQueueOpen {
                        if translation.y > 80.0 || velocity.y > 300.0 {
                            self.closeQueue()
                        } else if let layout = self.validLayout {
                            self.queueDragOffset = 0.0
                            self.containerLayoutUpdated(layout, transition: OverlayAudioPlayerControllerNode.queueSheetTransition)
                        }
                        return
                    }
                    if self.isQueueInteractivelyOpening {
                        if translation.y < -80.0 || velocity.y < -300.0 {
                            self.openQueue()
                        } else {
                            self.closeQueue()
                        }
                        return
                    }
                }
                
                if (bounds.minY < -60.0 || velocity.y > 300.0) {
                    self.requestDismiss()
                } else {
                    let previousBounds = self.bounds
                    var bounds = self.bounds
                    bounds.origin.y = 0.0
                    self.contentNode.bounds = bounds
                    self.contentNode.layer.animateBounds(from: previousBounds, to: self.contentNode.bounds, duration: 0.3, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue)
                }
            case .cancelled:
                if self.isCompact && self.isQueueOpen, let layout = self.validLayout {
                    self.queueDragOffset = 0.0
                    self.containerLayoutUpdated(layout, transition: OverlayAudioPlayerControllerNode.queueSheetTransition)
                    return
                }
                if self.isQueueInteractivelyOpening {
                    self.closeQueue()
                    return
                }
                let previousBounds = self.contentNode.bounds
                var bounds = self.contentNode.bounds
                bounds.origin.y = 0.0
                self.contentNode.bounds = bounds
                self.contentNode.layer.animateBounds(from: previousBounds, to: self.contentNode.bounds, duration: 0.3, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue)
            default:
                break
        }
    }
    
    private func updateFloatingHeaderOffset(offset: CGFloat, transition: ContainedViewLayoutTransition) {
        guard let layout = self.validLayout else {
            return
        }
        self.floatingHeaderOffset = offset
        let previousHasAnyHistoryMessages = self.hasAnyHistoryMessages
        self.hasAnyHistoryMessages = self.historyNode.hasAnyMessages
        self.controlsNode.hasPlainBackground = !self.historyNode.hasAnyMessages
        
        // The playlist's side margins (wider beside iPhone Duo's side strip), which the list insets match.
        let listSideMargins = layout.listSideMargins(base: 16.0)
        let headerHeight: CGFloat = self.effectiveHeaderHeight

        let layoutTopInset: CGFloat = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top)

        let rawControlsOffset = offset + layoutTopInset
        var backgroundOffset = max(layoutTopInset, rawControlsOffset)
        if !self.historyNode.hasAnyMessages {
            backgroundOffset += 25.0
        }
        
        let backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: backgroundOffset + headerHeight), size: CGSize(width: layout.size.width, height: layout.size.height))
        
        let frameFrame = CGRect(origin: CGPoint(x: 0.0, y: backgroundOffset), size: CGSize(width: layout.size.width, height: layout.size.height))
        let topOverlayFrame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: layout.size.width, height: headerHeight))
        let leftOverlayFrame = CGRect(origin: CGPoint(x: 0.0, y: topOverlayFrame.maxY - 1.0), size: CGSize(width: listSideMargins.left, height: layout.size.height))
        let rightOverlayFrame = CGRect(origin: CGPoint(x: layout.size.width - listSideMargins.right, y: topOverlayFrame.maxY - 1.0), size: CGSize(width: listSideMargins.right, height: layout.size.height))
        
        transition.updateFrame(node: self.historyFrameNode, frame: frameFrame)
        self.historyFrameTopOverlayClipNode.frame = topOverlayFrame
        self.historyFrameTopOverlayNode.frame = CGRect(origin: .zero, size: CGSize(width: topOverlayFrame.width, height: 78.0))
        self.historyFrameLeftOverlayNode.frame = leftOverlayFrame
        self.historyFrameRightOverlayNode.frame = rightOverlayFrame
        if let image = self.historyFrameTopMaskNode.image {
            self.historyFrameTopMaskNode.frame = CGRect(origin: CGPoint(x: listSideMargins.left, y: topOverlayFrame.maxY - 1.0), size: CGSize(width: layout.size.width - listSideMargins.left - listSideMargins.right, height: image.size.height))
        }
        self.historyFrameTopMaskNode.isHidden = self.controlsNode.hasPlainBackground
        
        let previousBackgroundFrame = self.historyBackgroundNode.frame
        if !backgroundFrame.equalTo(previousBackgroundFrame) {
            self.historyBackgroundNode.frame = backgroundFrame
            self.historyBackgroundContentNode.frame = CGRect(origin: CGPoint(), size: backgroundFrame.size)
            
            let positionDelta = CGPoint(x: backgroundFrame.minX - previousBackgroundFrame.minX, y: backgroundFrame.minY - previousBackgroundFrame.minY)
            
            transition.animateOffsetAdditive(node: self.historyBackgroundNode, offset: positionDelta.y)
        }
        
        if self.hasAnyHistoryMessages != previousHasAnyHistoryMessages {
            self.updatePresentationData(self.presentationData)
        }
    }
    
    private func transitionToUpdatedHistoryNode(atMessage messageId: EngineMessage.Id) {
        let tagMask: EngineMessage.Tags
        switch self.type {
            case .music:
                tagMask = .music
            case .voice:
                tagMask = .voiceOrInstantVideo
            case .file:
                tagMask = .file
        }
        
        let chatLocationContextHolder = Atomic<ChatLocationContextHolder?>(value: nil)
        let historyNode = ChatHistoryListNodeImpl(
            context: self.context,
            updatedPresentationData: (self.context.sharedContext.currentPresentationData.with({ $0 }), self.context.sharedContext.presentationData),
            systemStyle: .glass,
            chatLocation: self.chatLocation,
            chatLocationContextHolder: chatLocationContextHolder,
            adMessagesContext: nil,
            tag: .tag(tagMask),
            source: self.source,
            subject: .message(id: .id(messageId), highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil, setupReply: false),
            controllerInteraction: self.controllerInteraction,
            selectedMessages: .single(nil),
            mode: .list(reversed: self.currentIsReversed, reverseGroups: !self.currentIsReversed, displayHeaders: .none, hintLinks: false, isGlobalSearch: self.isGlobalSearch, isMusicPlaylist: true),
            isChatPreview: false,
            messageTransitionNode: { return nil
            }
        )
        historyNode.clipsToBounds = true
        historyNode.preloadPages = true
        historyNode.stackFromBottom = true
        historyNode.areContentAnimationsEnabled = true
        historyNode.updateFloatingHeaderOffset = { [weak self] offset, _ in
            self?.replacementHistoryNodeFloatingOffset = offset
        }
        self.replacementHistoryNodeFloatingOffset = nil
        self.replacementHistoryNode = historyNode
        if let layout = self.validLayout {
            let layoutTopInset: CGFloat = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top)
            let controlsHeight = self.controlsNode.frame.height

            // The same side margins as the current list (wider beside iPhone Duo's side strip).
            let listSideMargins = layout.listSideMargins(base: 16.0)
            var insets = UIEdgeInsets()
            insets.left = listSideMargins.left
            insets.right = listSideMargins.right
            insets.bottom = 0.0

            let headerHeight = self.effectiveHeaderHeight
            let listTopInset = layoutTopInset + headerHeight
            let listNodeSize = CGSize(width: layout.size.width, height: layout.size.height - listTopInset - controlsHeight)
            
            insets.top = max(0.0, listNodeSize.height - floor(62.0 * 3.5))
            
            var itemOffsetInsets = insets
            if let playlistLocation = self.playlistLocation as? PeerMessagesPlaylistLocation, case let .savedMusic(_, _, canReorder) = playlistLocation, canReorder {
                itemOffsetInsets.top = 0.0
                itemOffsetInsets.bottom = 0.0
                insets = itemOffsetInsets
            }

            historyNode.frame = CGRect(origin: CGPoint(x: 0.0, y: listTopInset), size: listNodeSize)

            let updateSizeAndInsets = ListViewUpdateSizeAndInsets(size: listNodeSize, insets: insets, itemOffsetInsets: itemOffsetInsets, duration: 0.0, curve: .Default(duration: nil))
            historyNode.updateLayout(transition: .immediate, updateSizeAndInsets: updateSizeAndInsets)
        }
        self.replacementHistoryNodeReadyDisposable.set((historyNode.historyState.get() |> take(1) |> deliverOnMainQueue).startStrict(next: { [weak self] _ in
            if let strongSelf = self {
                strongSelf.replaceWithReadyUpdatedHistoryNode()
            }
        }))
    }
    
    private func replaceWithReadyUpdatedHistoryNode() {
        if let replacementHistoryNode = self.replacementHistoryNode {
            self.replacementHistoryNode = nil
            
            let previousHistoryNode = self.historyNode
            previousHistoryNode.disconnect()
            self.contentNode.insertSubnode(replacementHistoryNode, belowSubnode: self.historyNode)
            self.historyNode = replacementHistoryNode
            self.setupReordering()
            self.updateHistoryContentOffset(replacementHistoryNode.visibleContentOffset(), transition: .immediate)
            
            if let offset = self.replacementHistoryNodeFloatingOffset, let previousOffset = self.floatingHeaderOffset {
                let offsetDelta = offset - previousOffset
                 
                let previousBackgroundNode = ASDisplayNode()
                previousBackgroundNode.isLayerBacked = true
                previousBackgroundNode.backgroundColor = self.historyBackgroundContentNode.backgroundColor
                self.contentNode.insertSubnode(previousBackgroundNode, belowSubnode: previousHistoryNode)
                previousBackgroundNode.frame = self.historyBackgroundNode.frame
                
                self.updateFloatingHeaderOffset(offset: offset, transition: .animated(duration: 0.4, curve: .spring))
                previousHistoryNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak previousHistoryNode] _ in
                    previousHistoryNode?.removeFromSupernode()
                })
                previousHistoryNode.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: offsetDelta), duration: 0.4, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: true, additive: true)
                previousBackgroundNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak previousBackgroundNode] _ in
                    previousBackgroundNode?.removeFromSupernode()
                })
                self.historyNode.layer.animatePosition(from: CGPoint(x: 0.0, y: -offsetDelta), to: CGPoint(), duration: 0.4, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: true, additive: true)
            } else {
                previousHistoryNode.removeFromSupernode()
            }
            
            self.historyNode.updateFloatingHeaderOffset = { [weak self] offset, transition in
                if let strongSelf = self {
                    strongSelf.updateFloatingHeaderOffset(offset: offset, transition: transition)
                }
            }
            self.historyNode.contentPositionChanged = { [weak self] offset in
                self?.updateHistoryContentOffset(offset, transition: .immediate)
            }
            
            self.historyNode.endedInteractiveDragging = { [weak self] _ in
                guard let strongSelf = self else {
                    return
                }
                switch strongSelf.historyNode.visibleContentOffset() {
                case let .known(value):
                    if let playlistLocation = strongSelf.playlistLocation as? PeerMessagesPlaylistLocation, case let .savedMusic(_, _, canReorder) = playlistLocation, canReorder {

                    } else {
                        if value <= -10.0 {
                            strongSelf.requestDismiss()
                        }
                    }
                default:
                    break
                }
            }
            
            self.historyNode.beganInteractiveDragging = { [weak self] _ in
                self?.controlsNode.collapse()
            }
            
            if let layout = self.validLayout {
                let layoutTopInset: CGFloat = max(layout.statusBarHeight ?? 0.0, layout.safeInsets.top)
                let controlsHeight = self.controlsNode.frame.height

                // The same side margins as the replaced list (wider beside iPhone Duo's side strip).
                let listSideMargins = layout.listSideMargins(base: 16.0)
                var insets = UIEdgeInsets()
                insets.left = listSideMargins.left
                insets.right = listSideMargins.right
                insets.bottom = 0.0

                let headerHeight = self.effectiveHeaderHeight
                let listTopInset = layoutTopInset + headerHeight
                let listNodeSize = CGSize(width: layout.size.width, height: layout.size.height - listTopInset - controlsHeight)
                
                insets.top = max(0.0, listNodeSize.height - floor(62.0 * 3.5))
                
                var itemOffsetInsets = insets
                if let playlistLocation = self.playlistLocation as? PeerMessagesPlaylistLocation, case let .savedMusic(_, _, canReorder) = playlistLocation, canReorder {
                    itemOffsetInsets.top = 0.0
                    itemOffsetInsets.bottom = 0.0
                    insets = itemOffsetInsets
                }
                
                self.historyNode.frame = CGRect(origin: CGPoint(x: 0.0, y: listTopInset), size: listNodeSize)
                
                let updateSizeAndInsets = ListViewUpdateSizeAndInsets(size: listNodeSize, insets: insets, itemOffsetInsets: itemOffsetInsets, duration: 0.0, curve: .Default(duration: nil))
                self.historyNode.updateLayout(transition: .immediate, updateSizeAndInsets: updateSizeAndInsets)
                
                self.historyNode.recursivelyEnsureDisplaySynchronously(true)
            }
            
            self.replacementHistoryNodeFloatingOffset = nil
            self.updateHistoryContentOffset(self.historyNode.visibleContentOffset(), transition: .immediate)
        }
    }
    
    private func openMessageContextMenu(message: EngineRawMessage, node: ASDisplayNode, frame: CGRect, recognizer: TapLongTapOrDoubleTapGestureRecognizer? = nil, gesture: ContextGesture? = nil, location: CGPoint? = nil) {
        guard let node = node as? ContextExtractedContentContainingNode, let peer = message.peers[message.id.peerId].flatMap({ PeerReference($0) }), let file = message.effectiveMedia.first(where: { $0 is TelegramMediaFile}) as? TelegramMediaFile else {
            return
        }
        let context = self.context
        let presentationData = self.presentationData
        let source: ContextContentSource = .extracted(OverlayAudioPlayerContextExtractedContentSource(contentNode: node))
        let fileReference: FileMediaReference = message.id.namespace == Namespaces.Message.Local ? .savedMusic(peer: peer, media: file) : .message(message: MessageReference(message), media: file)
        
        let canSaveToProfile = !(self.savedIds?.contains(file.fileId.id) == true)
        let canSaveToSavedMessages = message.id.peerId != self.context.account.peerId || message.id.namespace == Namespaces.Message.Local
        
        let _ = (context.sharedContext.chatAvailableMessageActions(engine: context.engine, accountPeerId: context.account.peerId, messageIds: [message.id], keepUpdated: false)
        |> deliverOnMainQueue).startStandalone(next: { [weak self] actions in
            guard let self else {
                return
            }
            
            var items: [ContextMenuItem] = []
            if canSaveToProfile || canSaveToSavedMessages {
                items.append(
                    .action(ContextMenuActionItem(text: presentationData.strings.MediaPlayer_ContextMenu_SaveTo, icon: { theme in return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/DownloadTone"), color: theme.contextMenu.primaryColor) }, action: { [weak self] c, _ in
                        if let self {
                            var subActions: [ContextMenuItem] = []
                            subActions.append(
                                .action(ContextMenuActionItem(text: presentationData.strings.Common_Back, icon: { theme in return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.contextMenu.primaryColor) }, iconPosition: .left, action: { c, _ in
                                    c?.popItems()
                                }))
                            )
                            subActions.append(.separator)
                            
                            if canSaveToProfile {
                                subActions.append(
                                    .action(ContextMenuActionItem(text: presentationData.strings.MediaPlayer_ContextMenu_SaveTo_Profile, icon: { theme in return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/User"), color: theme.contextMenu.primaryColor) }, action: { [weak self] _, f in
                                        f(.default)
                                        
                                        if let self {
                                            self.addToSavedMusic(file: fileReference)
                                        }
                                    }))
                                )
                            }
                            
                            if canSaveToSavedMessages {
                                subActions.append(
                                    .action(ContextMenuActionItem(text: presentationData.strings.MediaPlayer_ContextMenu_SaveTo_SavedMessages, icon: { theme in return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Fave"), color: theme.contextMenu.primaryColor) }, action: { [weak self] _, f in
                                        f(.default)
                                        
                                        if let self {
                                            self.forwardToSavedMessages(file: fileReference)
                                        }
                                    }))
                                )
                            }
                            
                            subActions.append(
                                .action(ContextMenuActionItem(text: presentationData.strings.MediaPlayer_ContextMenu_SaveTo_Files, icon: { theme in return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Save"), color: theme.contextMenu.primaryColor) }, action: { [weak self] _, f in
                                    f(.default)
                                    
                                    if let self {
                                        let disposable: MetaDisposable
                                        if let current = self.saveMediaDisposable {
                                            disposable = current
                                        } else {
                                            disposable = MetaDisposable()
                                            self.saveMediaDisposable = disposable
                                        }
                                        disposable.set(
                                            saveMediaToFiles(context: context, fileReference: fileReference, present: { [weak self] c, a in
                                                if let self, let controller = (self.getParentController() as? OverlayAudioPlayerControllerImpl) {
                                                    controller.present(c, in: .window(.root), with: a)
                                                }
                                            })
                                        )
                                    }
                                }))
                            )
                            
                            let noAction: ((ContextMenuActionItem.Action) -> Void)? = nil
                            subActions.append(
                                .action(ContextMenuActionItem(text: presentationData.strings.MediaPlayer_ContextMenu_SaveTo_Info, textLayout: .multiline, textFont: .small, icon: { _ in return nil }, action: noAction))
                            )

                            c?.pushItems(items: .single(ContextController.Items(content: .list(subActions))))
                        }
                    }))
                )
            } else {
                items.append(.action(ContextMenuActionItem(text: presentationData.strings.MediaPlayer_ContextMenu_SaveToFiles, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Save"), color: theme.actionSheet.primaryTextColor)
                }, action: { [weak self] _, f in
                    f(.default)
                    
                    if let self {
                        let disposable: MetaDisposable
                        if let current = self.saveMediaDisposable {
                            disposable = current
                        } else {
                            disposable = MetaDisposable()
                            self.saveMediaDisposable = disposable
                        }
                        disposable.set(
                            saveMediaToFiles(context: context, fileReference: fileReference, present: { [weak self] c, a in
                                if let self, let controller = (self.getParentController() as? OverlayAudioPlayerControllerImpl) {
                                    controller.present(c, in: .window(.root), with: a)
                                }
                            })
                        )
                    }
                })))
            }
            
            var addedSeparator = false
            
            if message.id.namespace == Namespaces.Message.Cloud {
                if !addedSeparator {
                    items.append(.separator)
                    addedSeparator = true
                }
                items.append(
                    .action(ContextMenuActionItem(text: presentationData.strings.MediaPlayer_ContextMenu_ShowInChat, icon: { theme in return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/GoToMessage"), color: theme.contextMenu.primaryColor) }, action: { [weak self] _, f in
                        f(.dismissWithoutContent)
                        
                        guard let self else {
                            return
                        }
                        context.sharedContext.navigateToChat(accountId: context.account.id, peerId: message.id.peerId, messageId: message.id)
                        self.requestDismiss()
                    }))
                )
            }
            
            var canDelete = false
            if case .custom = self.source {
                if self.savedIds?.contains(file.fileId.id) == true {
                    canDelete = true
                }
            } else if let peer = message.peers[message.id.peerId] {
                if peer is TelegramUser || peer is TelegramSecretChat {
                    canDelete = true
                } else if let _ = peer as? TelegramGroup {
                    canDelete = true
                } else if let channel = peer as? TelegramChannel {
                    if message.flags.contains(.Incoming) {
                        canDelete = channel.hasPermission(.deleteAllMessages)
                    } else {
                        canDelete = true
                    }
                } else {
                    canDelete = false
                }
            } else {
                canDelete = false
            }
            
            if canDelete {
                if !addedSeparator {
                    items.append(.separator)
                    addedSeparator = true
                }
                var actionTitle = presentationData.strings.MediaPlayer_ContextMenu_Delete
                if case .custom = self.source {
                    actionTitle = presentationData.strings.MediaPlayer_ContextMenu_Remove
                }
                items.append(
                    .action(ContextMenuActionItem(text: actionTitle, textColor: .destructive, icon: { theme in return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.contextMenu.destructiveColor) }, action: { [weak self] c, f in
                        guard let self else {
                            return
                        }
                        if message.id.namespace == Namespaces.Message.Local {
                            f(.default)
                            self.removeFromSavedMusic(file: fileReference)
                        } else {
                            c?.setItems(context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: message.id.peerId))
                            |> map { peer -> ContextController.Items in
                                var items: [ContextMenuItem] = []
                                let messageIds = [message.id]
                                
                                if let peer {
                                    var personalPeerName: String?
                                    var isChannel = false
                                    if case let .user(user) = peer {
                                        personalPeerName = EnginePeer(user).compactDisplayTitle
                                    } else if case let .channel(channel) = peer, case .broadcast = channel.info {
                                        isChannel = true
                                    }
                                    
                                    if actions.options.contains(.deleteGlobally) {
                                        let globalTitle: String
                                        if isChannel {
                                            globalTitle = presentationData.strings.Conversation_DeleteMessagesForEveryone
                                        } else if let personalPeerName = personalPeerName {
                                            globalTitle = presentationData.strings.Conversation_DeleteMessagesFor(personalPeerName).string
                                        } else {
                                            globalTitle = presentationData.strings.Conversation_DeleteMessagesForEveryone
                                        }
                                        items.append(.action(ContextMenuActionItem(text: globalTitle, textColor: .destructive, icon: { _ in nil }, action: { c, f in
                                            c?.dismiss(completion: {
                                                let _ = context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: .forEveryone).startStandalone()
                                            })
                                        })))
                                    }
                                    
                                    if actions.options.contains(.deleteLocally) {
                                        var localOptionText = presentationData.strings.Conversation_DeleteMessagesForMe
                                        if context.account.peerId == message.id.peerId {
                                            if messageIds.count == 1 {
                                                localOptionText = presentationData.strings.Conversation_Moderate_Delete
                                            } else {
                                                localOptionText = presentationData.strings.Conversation_DeleteManyMessages
                                            }
                                        }
                                        items.append(.action(ContextMenuActionItem(text: localOptionText, textColor: .destructive, icon: { _ in nil }, action: { c, f in
                                            c?.dismiss(completion: {
                                                let _ = context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: .forLocalPeer).startStandalone()
                                            })
                                        })))
                                    }
                                }
                                
                                return ContextController.Items(content: .list(items))
                            }, minHeight: nil, animated: true)
                        }
                    }))
                )
            }
            
            guard !items.isEmpty else {
                return
            }
            
            let contextController = makeContextController(presentationData: presentationData, source: source, items: .single(ContextController.Items(content: .list(items))), recognizer: recognizer, gesture: gesture)
            self.getParentController()?.presentInGlobalOverlay(contextController)
        })
    }
}

private final class OverlayAudioPlayerContextExtractedContentSource: ContextExtractedContentSource {
    let keepInPlace: Bool = false
    let ignoreContentTouches: Bool = false
    let blurBackground: Bool = true
    let additionalInsets = UIEdgeInsets(top: 0.0, left: 0.0, bottom: 80.0, right: 0.0)
    
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

private func generateCollapseIcon(theme: PresentationTheme) -> UIImage? {
    return generateImage(CGSize(width: 36.0, height: 6.0), rotatedContext: { size, context in
        let bounds = CGRect(origin: CGPoint(), size: size)
        context.clear(bounds)
        
        let path = UIBezierPath(roundedRect: bounds, cornerRadius: 3.0)
        context.setFillColor(theme.list.controlSecondaryColor.cgColor)
        context.addPath(path.cgPath)
        context.fillPath()
    })
}

private func generateCornersImage(theme: PresentationTheme) -> UIImage? {
    return generateImage(CGSize(width: 56.0, height: 56.0), rotatedContext: { (size, context) in
        let bounds = CGRect(origin: CGPoint(), size: size)
        context.setFillColor(theme.list.modalBlocksBackgroundColor.cgColor)
        context.fill(bounds)
        
        context.setBlendMode(.clear)
        
        var corners: UIRectCorner = []
        corners.insert(.topLeft)
        corners.insert(.topRight)
        
        let cornerRadius: CGFloat = 26.0
        let path = UIBezierPath(roundedRect: bounds.offsetBy(dx: 0.0, dy: 1.0), byRoundingCorners: corners, cornerRadii: CGSize(width: cornerRadius, height: cornerRadius))
        context.addPath(path.cgPath)
        context.fillPath()
    })?.stretchableImage(withLeftCapWidth: 28, topCapHeight: 28)
}
