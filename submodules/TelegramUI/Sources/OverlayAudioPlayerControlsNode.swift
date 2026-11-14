import Foundation
import LottieSettings
import UIKit
import AsyncDisplayKit
import Display
import ComponentFlow
import TelegramCore
import SwiftSignalKit
import TelegramPresentationData
import UniversalMediaPlayer
import TelegramUIPreferences
import AccountContext
import PhotoResources
import AppBundle
import ManagedAnimationNode
import RangeSet
import TelegramBaseController
import ContextUI
import SliderContextItem
import UndoUI
import MarqueeComponent
import MultilineTextComponent
import BundleIconComponent
import ButtonComponent
import Markdown
import TextFormat
import MusicScreen

private func normalizeValue(_ value: CGFloat) -> CGFloat {
    return round(value * 10.0) / 10.0
}

private func generateBackground(theme: PresentationTheme) -> UIImage? {
    return generateImage(CGSize(width: 20.0, height: 18.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setShadow(offset: CGSize(width: 0.0, height: -4.0), blur: 30.0, color: UIColor(white: 0.0, alpha: 0.2).cgColor)
        context.setFillColor(theme.list.modalPlainBackgroundColor.cgColor)
        context.fill(CGRect(origin: CGPoint(x: 0.0, y: 8.0), size: CGSize(width: 20.0, height: 20.0)))
    })?.stretchableImage(withLeftCapWidth: 10, topCapHeight: 18)
}

private func generatePlainBackground(theme: PresentationTheme) -> UIImage? {
    return generateImage(CGSize(width: 20.0, height: 18.0 + 25.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setFillColor(theme.list.modalPlainBackgroundColor.cgColor)
        context.fill(CGRect(origin: CGPoint(x: 0.0, y: 8.0 + 25.0), size: CGSize(width: 20.0, height: 20.0)))
    })?.stretchableImage(withLeftCapWidth: 10, topCapHeight: 18 + 25)
}


private func optionsRateImage(rate: String, color: UIColor = .white) -> UIImage? {
    let isLarge = "".isEmpty
    return generateImage(isLarge ? CGSize(width: 30.0, height: 30.0) : CGSize(width: 24.0, height: 24.0), rotatedContext: { size, context in
        UIGraphicsPushContext(context)

        context.clear(CGRect(origin: CGPoint(), size: size))

        if let image = generateTintedImage(image: UIImage(bundleImageName: isLarge ? "Chat/Context Menu/Playspeed30" : "Chat/Context Menu/Playspeed24"), color: color) {
            image.draw(at: CGPoint(x: 0.0, y: 0.0))
        }

        let string = NSMutableAttributedString(string: rate, font: Font.with(size: isLarge ? 11.0 : 10.0, design: .round, weight: .semibold), textColor: color)

        var offset = CGPoint(x: 1.0, y: 0.0)
        if rate.count >= 3 {
            if rate == "0.5x" {
                string.addAttribute(.kern, value: -0.8 as NSNumber, range: NSRange(string.string.startIndex ..< string.string.endIndex, in: string.string))
                offset.x += -0.5
            } else {
                string.addAttribute(.kern, value: -0.5 as NSNumber, range: NSRange(string.string.startIndex ..< string.string.endIndex, in: string.string))
                offset.x += -0.3
            }
        } else {
            offset.x += -0.3
        }

        if !isLarge {
            offset.x *= 0.5
            offset.y *= 0.5
        }

        let boundingRect = string.boundingRect(with: size, options: [], context: nil)
        string.draw(at: CGPoint(x: offset.x + floor((size.width - boundingRect.width) / 2.0), y: offset.y + floor((size.height - boundingRect.height) / 2.0)))

        UIGraphicsPopContext()
    })
}

private let digitsSet = CharacterSet(charactersIn: "0123456789")
private func timestampLabelWidthForDuration(_ timestamp: Double) -> CGFloat {
    let text: String
    if timestamp > 0 {
        let timestamp = Int32(timestamp)
        let hours = timestamp / (60 * 60)
        let minutes = timestamp % (60 * 60) / 60
        let seconds = timestamp % 60
        if hours != 0 {
            text = String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            text = String(format: "%d:%02d", minutes, seconds)
        }
    } else {
        text = "-:--"
    }
    
    let convertedString = text.components(separatedBy: digitsSet).joined(separator: "8")
    let string = NSAttributedString(string: convertedString, font: Font.regular(13.0), textColor: .black)
    let size = string.boundingRect(with: CGSize(width: 200.0, height: 100.0), options: NSStringDrawingOptions.usesLineFragmentOrigin, context: nil).size
    return size.width
}

private let titleFont = Font.semibold(17.0)
private let descriptionFont = Font.regular(15.0)

private func stringsForDisplayData(_ data: SharedMediaPlaybackDisplayData?, presentationData: PresentationData) -> (NSAttributedString?, NSAttributedString?, Bool, NSAttributedString?) {
    var titleString: NSAttributedString?
    var descriptionString: NSAttributedString?
    var hasArtist = false
    var captionString: NSAttributedString?
    
    if let data = data {
        let titleText: String
        let subtitleText: String
        switch data {
            case let .music(title, performer, _, _, caption):
                titleText = title ?? presentationData.strings.MediaPlayer_UnknownTrack
                subtitleText = performer ?? presentationData.strings.MediaPlayer_UnknownArtist
                hasArtist = performer != nil
                captionString = caption
            case .voice, .instantVideo:
                titleText = ""
                subtitleText = ""
        }
        
        titleString = NSAttributedString(string: titleText, font: titleFont, textColor: presentationData.theme.list.itemPrimaryTextColor)
        descriptionString = NSAttributedString(string: subtitleText, font: descriptionFont, textColor: presentationData.theme.list.itemSecondaryTextColor)
    }
    
    return (titleString, descriptionString, hasArtist, captionString)
}

final class OverlayAudioPlayerControlsNode: ASDisplayNode {
    private let accountManager: AccountManager<TelegramAccountManagerTypes>
    private let account: Account
    private let engine: TelegramEngine
    private var presentationData: PresentationData
    private let chatLocation: ChatLocation
    private let source: ChatHistoryListSource
    
    private let backgroundNode: ASImageNode
    
    let albumArtNode: TransformImageNode
    private let titleNode: TextNode
    private let title: ComponentView<Empty>
    private let descriptionNode: TextNode
    private let shareNode: HighlightableButtonNode
    private let artistButton: HighlightTrackingButtonNode
    
    private var profileAudio: ComponentView<Empty>?
    
    private let scrubberNode: MediaPlayerScrubbingNode
    private let leftDurationLabel: MediaPlayerTimeTextNode
    private let rightDurationLabel: MediaPlayerTimeTextNode
    private let infoNode: ASTextNode
    
    private let backwardButton: IconButtonNode
    private let forwardButton: IconButtonNode
    
    private var seekTimer: SwiftSignalKit.Timer?
    private var seekRate: AudioPlaybackRate = .x2
    private var previousRate: AudioPlaybackRate?
    
    private(set) var currentIsPaused: Bool?
    private let playPauseButton: IconButtonNode
    private let playPauseIconNode: PlayPauseIconNode
    
    private(set) var currentOrder: MusicPlaybackSettingsOrder?
    /// The compact sheet's Shuffle, when its owner handles it: Shuffle then mixes the queue instead of the order setting.
    var requestShuffle: (() -> Void)?
    /// Lights the compact Shuffle while the queue itself is shuffled; nil follows the order setting.
    var isQueueShuffled: Bool? {
        didSet {
            if self.isQueueShuffled != oldValue, let order = self.currentOrder {
                self.updateOrderButton(order)
            }
        }
    }
    private let orderButton: IconButtonNode
    
    private var currentLooping: MusicPlaybackSettingsLooping?
    private let loopingButton: IconButtonNode
    
    private var currentRate: AudioPlaybackRate?
    private let rateButton: AudioRateButton
    
    let separatorNode: ASDisplayNode
    
    var hasPlainBackground = false {
        didSet {
            self.backgroundNode.image = self.hasPlainBackground ? generatePlainBackground(theme: self.presentationData.theme) : generateBackground(theme: self.presentationData.theme)
        }
    }
        
    var isExpanded = false
    var updateIsExpanded: (() -> Void)?
    var requestAlbumArtDisplay: (((FileMediaReference, SharedMediaPlaybackAlbumArt)?) -> Void)?
    
    var requestCollapse: (() -> Void)?
    var requestShare: ((ShareControllerSubject) -> Void)?
    var requestSearchByArtist: ((String) -> Void)?
    var requestSaveToProfile: ((FileMediaReference) -> Void)?
    var requestRemoveFromProfile: ((FileMediaReference) -> Void)?
    var requestLayout: ((ContainedViewLayoutTransition) -> Void)?
    
    var updateOrder: ((MusicPlaybackSettingsOrder) -> Void)?
    var control: ((SharedMediaPlayerControlAction) -> Void)?
    
    var getParentController: () -> ViewController? = { return nil }
    
    let forceCopyProtected = ValuePromise<Bool>(false)
    
    private(set) var currentItemId: SharedMediaPlaylistItemId?
    private var displayData: SharedMediaPlaybackDisplayData?
    private var currentAlbumArtInitialized = false
    private var currentAlbumArt: SharedMediaPlaybackAlbumArt?
    private(set) var currentFileReference: FileMediaReference?
    private var statusDisposable: Disposable?
    private var chapterDisposable: Disposable?
    
    private var previousCaption: NSAttributedString?
    private var currentChapters: [MediaPlayerScrubbingChapter] = []
    private var chaptersPromise = ValuePromise<[MediaPlayerScrubbingChapter]>([])
    private var currentChapter: MediaPlayerScrubbingChapter?
    
    private let hapticFeedback = HapticFeedback()
    
    private var leftDurationLabelPushed = false
    private var rightDurationLabelPushed = false
    private var infoNodePushed = false
    
    private var currentDuration: Double = 0.0
    private(set) var currentPosition: Double = 0.0
    
    private var validLayout: (width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, bottomInset: CGFloat, maxHeight: CGFloat, savedMusic: Bool?)?
    private var hasCompletedLayout = false
    
    // MARK: Compact sheet
    
    /// The Music section's player sheet (Figma Player 277:14091): the queue header over a card with the playing
    /// track, its progress, the playback buttons and the panel that adds the track to Music, Favorites or a playlist.
    /// Off, the node lays out as the full player under the queue list.
    var isCompact = false {
        didSet {
            if self.isCompact != oldValue {
                self.updateStyleVisibility()
                self.updateScrubberContent()
            }
        }
    }
    /// The sheet keeps 6 pt from the screen edges, so its bottom corners follow the screen's, 6 pt smaller.
    var compactBottomCornerRadius: CGFloat = 38.0
    var queueCount: Int?
    var queueTitle: String?
    /// Off while the queue sheet is open: its toolbar names the queue, and the card sits at the screen's bottom.
    var showsQueueHeader = true {
        didSet {
            if self.showsQueueHeader != oldValue {
                self.updateStyleVisibility()
            }
        }
    }
    private var compactEffectiveHeaderHeight: CGFloat {
        return self.showsQueueHeader ? OverlayAudioPlayerControlsNode.compactHeaderHeight : 0.0
    }
    struct CompactPanelState: Equatable {
        /// Nil when the track is not in Music and cannot be added (copy protection, secret chats).
        var isInMusic: Bool?
        var isFavorite: Bool
    }
    var compactPanelState = CompactPanelState(isInMusic: nil, isFavorite: false)
    
    var requestOpenQueue: (() -> Void)?
    /// The playing track changed: the queue sheet's list follows it.
    var currentItemChanged: (() -> Void)?
    /// Play or pause: the queue's playing cover follows it.
    var pausedChanged: (() -> Void)?
    var requestToggleSaved: (() -> Void)?
    var requestToggleFavorite: (() -> Void)?
    var requestAddToPlaylist: (() -> Void)?
    var requestMoreMenu: ((ContextReferenceContentNode) -> Void)?
    
    private static let compactHeaderHeight: CGFloat = 86.0
    private static let compactCardHeight: CGFloat = 314.0
    private static let compactTopCornerRadius: CGFloat = 38.0
    
    private let compactShadowView = UIView()
    private let compactSheetView = UIView()
    private let compactSheetMask = CAShapeLayer()
    private let compactCardShadowView = UIView()
    private let compactCardView = UIView()
    private let compactGrabberNode = ASImageNode()
    private let queueTitleNode = ImmediateTextNode()
    private let queueBadgeNode = ASDisplayNode()
    private let queueBadgeTextNode = ImmediateTextNode()
    private let queueSubtitleNode = ImmediateTextNode()
    private let queueButton = HighlightTrackingButtonNode()
    private let moreButton = HighlightableButtonNode()
    private let moreReferenceNode = ContextReferenceContentNode()
    private let panelButtons: [ComponentView<Empty>] = [ComponentView<Empty>(), ComponentView<Empty>(), ComponentView<Empty>()]
    private var panelContentIds: [AnyHashable?] = [nil, nil, nil]
    /// A tapped toggle bounces the icon its tap brings in, once the new state has been laid out.
    private var pendingPanelBounce: Int?
    
    init(account: Account, engine: TelegramEngine, accountManager: AccountManager<TelegramAccountManagerTypes>, presentationData: PresentationData, status: Signal<(Account, SharedMediaPlayerItemPlaybackStateOrLoading, MediaManagerPlayerType)?, NoError>, chatLocation: ChatLocation, source: ChatHistoryListSource, lottieSettings: LottieRenderingSettings) {
        self.accountManager = accountManager
        self.account = account
        self.engine = engine
        self.presentationData = presentationData
        self.chatLocation = chatLocation
        self.source = source
        
        self.backgroundNode = ASImageNode()
        self.backgroundNode.isLayerBacked = true
        self.backgroundNode.displayWithoutProcessing = true
        self.backgroundNode.displaysAsynchronously = false
        self.backgroundNode.image = generateBackground(theme: presentationData.theme)
                
        self.albumArtNode = TransformImageNode()
        
        self.titleNode = TextNode()
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.displaysAsynchronously = false
        
        self.title = ComponentView<Empty>()
                
        self.descriptionNode = TextNode()
        self.descriptionNode.isUserInteractionEnabled = false
        self.descriptionNode.displaysAsynchronously = false
        
        self.artistButton = HighlightTrackingButtonNode()
        
        self.shareNode = HighlightableButtonNode()
        self.shareNode.setImage(generateTintedImage(image: UIImage(bundleImageName: "GlobalMusicPlayer/Share"), color: presentationData.theme.list.itemPrimaryTextColor), for: [])
        
        self.scrubberNode = MediaPlayerScrubbingNode(content: .standard(lineHeight: 7.0, lineCap: .round, scrubberHandle: .none, backgroundColor: presentationData.theme.list.controlSecondaryColor.withMultipliedAlpha(0.5), foregroundColor: presentationData.theme.list.itemPrimaryTextColor, bufferingColor: presentationData.theme.list.itemPrimaryTextColor.withAlphaComponent(0.4), chapters: []))
        self.leftDurationLabel = MediaPlayerTimeTextNode(textColor: presentationData.theme.list.itemSecondaryTextColor, textFont: Font.medium(12.0))
        self.leftDurationLabel.displaysAsynchronously = false
        self.leftDurationLabel.keepPreviousValueOnEmptyState = true
        self.rightDurationLabel = MediaPlayerTimeTextNode(textColor: presentationData.theme.list.itemSecondaryTextColor, textFont: Font.medium(12.0))
        self.rightDurationLabel.displaysAsynchronously = false
        self.rightDurationLabel.mode = .reversed
        self.rightDurationLabel.alignment = .right
        self.rightDurationLabel.keepPreviousValueOnEmptyState = true
        
        self.infoNode = ASTextNode()
        self.infoNode.maximumNumberOfLines = 1
        self.infoNode.isUserInteractionEnabled = false
        self.infoNode.displaysAsynchronously = false
        
        self.rateButton = AudioRateButton()
        self.rateButton.hitTestSlop = UIEdgeInsets(top: -8.0, left: -4.0, bottom: -8.0, right: -4.0)
        self.rateButton.displaysAsynchronously = false
        
        self.backwardButton = IconButtonNode()
        self.backwardButton.displaysAsynchronously = false
        
        self.forwardButton = IconButtonNode()
        self.forwardButton.displaysAsynchronously = false
        
        self.orderButton = IconButtonNode()
        self.orderButton.displaysAsynchronously = false
        
        self.loopingButton = IconButtonNode()
        self.loopingButton.displaysAsynchronously = false
        
        self.playPauseButton = IconButtonNode()
        self.playPauseButton.displaysAsynchronously = false
        
        self.playPauseIconNode = PlayPauseIconNode(lottieSettings: lottieSettings)
        
        self.backwardButton.icon = generateTintedImage(image: UIImage(bundleImageName: "GlobalMusicPlayer/Previous"), color: presentationData.theme.list.itemPrimaryTextColor)
        self.forwardButton.icon = generateTintedImage(image: UIImage(bundleImageName: "GlobalMusicPlayer/Next"), color: presentationData.theme.list.itemPrimaryTextColor)
        
        self.separatorNode = ASDisplayNode()
        self.separatorNode.isLayerBacked = true
        self.separatorNode.backgroundColor = presentationData.theme.list.itemPlainSeparatorColor
        
        super.init()
        
        self.addSubnode(self.backgroundNode)
                
        self.addSubnode(self.albumArtNode)
        //self.addSubnode(self.titleNode)
        self.addSubnode(self.descriptionNode)
        self.addSubnode(self.artistButton)
        self.addSubnode(self.shareNode)
        
        self.addSubnode(self.leftDurationLabel)
        self.addSubnode(self.rightDurationLabel)
        self.addSubnode(self.infoNode)
        self.addSubnode(self.scrubberNode)
        
        self.addSubnode(self.orderButton)
        self.addSubnode(self.loopingButton)
        self.addSubnode(self.backwardButton)
        self.addSubnode(self.forwardButton)
        self.addSubnode(self.playPauseButton)
        self.playPauseButton.addSubnode(self.playPauseIconNode)
        self.addSubnode(self.rateButton)
        
        //self.addSubnode(self.separatorNode)
        
        self.compactGrabberNode.displaysAsynchronously = false
        self.compactGrabberNode.isUserInteractionEnabled = false
        self.queueTitleNode.displaysAsynchronously = false
        self.queueBadgeTextNode.displaysAsynchronously = false
        self.queueSubtitleNode.displaysAsynchronously = false
        for node in [self.queueTitleNode, self.queueBadgeNode, self.queueBadgeTextNode, self.queueSubtitleNode] as [ASDisplayNode] {
            node.isUserInteractionEnabled = false
        }
        self.queueBadgeNode.addSubnode(self.queueBadgeTextNode)
        self.queueButton.addSubnode(self.queueTitleNode)
        self.queueButton.addSubnode(self.queueBadgeNode)
        self.queueButton.addSubnode(self.queueSubtitleNode)
        self.addSubnode(self.compactGrabberNode)
        self.addSubnode(self.queueButton)
        self.moreButton.addSubnode(self.moreReferenceNode)
        self.moreReferenceNode.isUserInteractionEnabled = false
        self.addSubnode(self.moreButton)
        
        self.compactSheetView.layer.mask = self.compactSheetMask
        self.compactShadowView.layer.shadowColor = UIColor.black.cgColor
        self.compactShadowView.layer.shadowOpacity = 0.18
        self.compactShadowView.layer.shadowRadius = 20.0
        self.compactShadowView.layer.shadowOffset = CGSize(width: 0.0, height: 8.0)
        self.compactCardShadowView.layer.shadowColor = UIColor.black.cgColor
        self.compactCardShadowView.layer.shadowOpacity = 0.08
        self.compactCardShadowView.layer.shadowRadius = 8.0
        self.compactCardShadowView.layer.shadowOffset = CGSize(width: 0.0, height: -4.0)
        self.compactCardView.layer.cornerRadius = OverlayAudioPlayerControlsNode.compactTopCornerRadius
        self.compactCardView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        self.compactCardView.layer.cornerCurve = .continuous
        self.compactSheetView.addSubview(self.compactCardShadowView)
        self.compactSheetView.addSubview(self.compactCardView)
        self.updateCompactColors()
        self.updateStyleVisibility()
        
        let accountId = account.id
        let delayedStatus = status
        |> mapToSignal { value -> Signal<(Account, SharedMediaPlayerItemPlaybackStateOrLoading, MediaManagerPlayerType)?, NoError> in
            guard let value = value, value.0.id == accountId else {
                return .single(nil)
            }
            switch value.1 {
                case .state:
                    return .single(value)
                case .loading:
                    return .single(value)
                    |> delay(0.1, queue: .mainQueue())
            }
        }
        
        let mappedStatus = combineLatest(delayedStatus, self.scrubberNode.scrubbingTimestamp) |> map { value, scrubbingTimestamp -> MediaPlayerStatus in
            if let (_, valueOrLoading, _) = value, case let .state(value) = valueOrLoading {
                return MediaPlayerStatus(generationTimestamp: scrubbingTimestamp != nil ? 0 : value.status.generationTimestamp, duration: value.status.duration, dimensions: value.status.dimensions, timestamp: scrubbingTimestamp ?? value.status.timestamp, baseRate: value.status.baseRate, seekId: value.status.seekId, status: value.status.status, soundEnabled: value.status.soundEnabled)
            } else {
                return MediaPlayerStatus(generationTimestamp: 0.0, duration: 0.0, dimensions: CGSize(), timestamp: 0.0, baseRate: 1.0, seekId: 0, status: .paused, soundEnabled: true)
            }
        }
        self.scrubberNode.status = mappedStatus
        self.leftDurationLabel.status = mappedStatus
        self.rightDurationLabel.status = mappedStatus
                
        self.statusDisposable = combineLatest(
            queue: Queue.mainQueue(),
            delayedStatus,
            self.forceCopyProtected.get()
        ).startStrict(next: { [weak self] value, forceCopyProtected in
            guard let strongSelf = self else {
                return
            }
            var itemUpdated = false
            var valueItemId: SharedMediaPlaylistItemId?
            if let (_, value, _) = value, case let .state(state) = value {
                valueItemId = state.item.id
            }
            if !areSharedMediaPlaylistItemIdsEqual(valueItemId, strongSelf.currentItemId) {
                strongSelf.currentItemId = valueItemId
                strongSelf.scrubberNode.ignoreSeekId = nil
                itemUpdated = true
            }
            
            var rateButtonIsHidden = true
            var displayData: SharedMediaPlaybackDisplayData?
            if let (_, valueOrLoading, _) = value, case let .state(value) = valueOrLoading {
                var isPaused: Bool
                switch value.status.status {
                    case .playing:
                        isPaused = false
                    case .paused:
                        isPaused = true
                    case let .buffering(_, whilePlaying, _, _):
                        isPaused = !whilePlaying
                }
                if strongSelf.wasPlaying {
                    isPaused = false
                }
                
                let isFirstTime = strongSelf.currentIsPaused == nil
                if strongSelf.currentIsPaused != isPaused {
                    strongSelf.currentIsPaused = isPaused
                    strongSelf.pausedChanged?()
                    
                    strongSelf.updatePlayPauseButton(paused: isPaused, animated: !isFirstTime)
                }
                
                strongSelf.playPauseButton.isEnabled = true
                strongSelf.backwardButton.isEnabled = true
                strongSelf.forwardButton.isEnabled = true
                
                displayData = value.item.displayData
                
                if value.order != strongSelf.currentOrder {
                    strongSelf.updateOrder?(value.order)
                    strongSelf.currentOrder = value.order
                    strongSelf.updateOrderButton(value.order)
                }
                if value.looping != strongSelf.currentLooping {
                    strongSelf.currentLooping = value.looping
                    strongSelf.updateLoopButton(value.looping)
                }
                
                let baseRate = AudioPlaybackRate(value.status.baseRate )
                if baseRate != strongSelf.currentRate {
                    strongSelf.currentRate = baseRate
                    strongSelf.updateRateButton(baseRate)
                }
                
                if let displayData = displayData, case let .music(_, _, _, long, _) = displayData, long {
                    strongSelf.scrubberNode.enableFineScrubbing = true
                    rateButtonIsHidden = false
                } else {
                    strongSelf.scrubberNode.enableFineScrubbing = false
                    rateButtonIsHidden = true
                }
                
                let duration = value.status.duration
                if duration != strongSelf.currentDuration && !duration.isZero {
                    strongSelf.currentDuration = duration
                    strongSelf.requestLayout(transition: .immediate)
                }
                
                strongSelf.rateButton.isHidden = rateButtonIsHidden
                
                strongSelf.currentPosition = value.status.timestamp
            } else {
                strongSelf.playPauseButton.isEnabled = false
                strongSelf.backwardButton.isEnabled = false
                strongSelf.forwardButton.isEnabled = false
                strongSelf.rateButton.isHidden = true
                displayData = nil
            }
            
            if strongSelf.displayData != displayData {
                strongSelf.displayData = displayData
                          
                if let (_, valueOrLoading, _) = value, case let .state(value) = valueOrLoading, let source = value.item.playbackData?.source {
                    switch source {
                        case let .telegramFile(fileReference, _, _):
                            strongSelf.currentFileReference = fileReference
                            if let size = fileReference.media.size {
                                strongSelf.scrubberNode.bufferingStatus = strongSelf.engine.resources.resourceRangesStatus(resource: EngineMediaResource(fileReference.media.resource))
                                |> map { ranges -> (RangeSet<Int64>, Int64) in
                                    return (ranges, size)
                                }
                            } else {
                                strongSelf.scrubberNode.bufferingStatus = nil
                            }
                    }
                } else {
                    strongSelf.scrubberNode.bufferingStatus = nil
                }
                strongSelf.updateLabels(transition: .immediate)
            }
            
            if let (_, valueOrLoading, _) = value, case let .state(value) = valueOrLoading, let source = value.item.playbackData?.source {
                switch source {
                case let .telegramFile(_, isCopyProtected, _):
                    strongSelf.shareNode.isHidden = isCopyProtected || forceCopyProtected || strongSelf.isCompact
                }
            }
            
            if itemUpdated {
                strongSelf.requestLayout?(.animated(duration: 0.2, curve: .easeInOut))
                strongSelf.currentItemChanged?()
            }
        })
                
        self.chapterDisposable = combineLatest(queue: Queue.mainQueue(), mappedStatus, self.chaptersPromise.get())
        .startStrict(next: { [weak self] status, chapters in
            if let strongSelf = self, status.duration > 1.0, chapters.count > 0 {
                let previousChapter = strongSelf.currentChapter
                var currentChapter: MediaPlayerScrubbingChapter?
                for chapter in chapters {
                    if chapter.start > status.timestamp {
                        break
                    } else {
                        currentChapter = chapter
                    }
                }
                
                if let chapter = currentChapter, chapter != previousChapter {
                    strongSelf.currentChapter = chapter
                    
                    if strongSelf.scrubberNode.isScrubbing {
                        strongSelf.hapticFeedback.impact(.light)
                    }
                    
                    if let previousChapter = previousChapter, !strongSelf.infoNode.alpha.isZero {
                        if let snapshotView = strongSelf.infoNode.view.snapshotView(afterScreenUpdates: false) {
                            snapshotView.frame = strongSelf.infoNode.frame
                            strongSelf.infoNode.view.superview?.addSubview(snapshotView)
                            
                            let offset: CGFloat = 30.0
                            let snapshotTargetPosition: CGPoint
                            let nodeStartPosition: CGPoint
                            if previousChapter.start < chapter.start {
                                snapshotTargetPosition = CGPoint(x: -offset, y: 0.0)
                                nodeStartPosition = CGPoint(x: offset, y: 0.0)
                            } else {
                                snapshotTargetPosition = CGPoint(x: offset, y: 0.0)
                                nodeStartPosition = CGPoint(x: -offset, y: 0.0)
                            }
                            snapshotView.layer.animatePosition(from: CGPoint(), to: snapshotTargetPosition, duration: 0.2, removeOnCompletion: false, additive: true)
                            snapshotView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak snapshotView] _ in
                                snapshotView?.removeFromSuperview()
                            })
                            strongSelf.infoNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                            strongSelf.infoNode.layer.animatePosition(from: nodeStartPosition, to: CGPoint(), duration: 0.2, additive: true)
                        }
                    }
                    strongSelf.infoNode.attributedText = NSAttributedString(string: chapter.title, font: Font.regular(13.0), textColor: strongSelf.presentationData.theme.list.itemSecondaryTextColor)
                    strongSelf.requestLayout(transition: .immediate)
                }
            }
        })
        
        self.scrubberNode.seek = { [weak self] value in
            self?.control?(.seek(value))
        }
        
        self.shareNode.addTarget(self, action: #selector(self.sharePressed), forControlEvents: .touchUpInside)
        self.orderButton.addTarget(self, action: #selector(self.orderPressed), forControlEvents: .touchUpInside)
        self.loopingButton.addTarget(self, action: #selector(self.loopingPressed), forControlEvents: .touchUpInside)
        self.backwardButton.addTarget(self, action: #selector(self.backwardPressed), forControlEvents: .touchUpInside)
        self.forwardButton.addTarget(self, action: #selector(self.forwardPressed), forControlEvents: .touchUpInside)
        self.playPauseButton.addTarget(self, action: #selector(self.playPausePressed), forControlEvents: .touchUpInside)
        self.rateButton.addTarget(self, action: #selector(self.rateButtonPressed), forControlEvents: .touchUpInside)
        self.artistButton.addTarget(self, action: #selector(self.artistPressed), forControlEvents: .touchUpInside)
        self.queueButton.addTarget(self, action: #selector(self.queuePressed), forControlEvents: .touchUpInside)
        self.moreButton.addTarget(self, action: #selector(self.morePressed), forControlEvents: .touchUpInside)
        
        self.queueButton.highligthedChanged = { [weak self] highlighted in
            guard let self else {
                return
            }
            for node in [self.queueTitleNode, self.queueBadgeNode, self.queueSubtitleNode] as [ASDisplayNode] {
                if highlighted {
                    node.layer.removeAnimation(forKey: "opacity")
                    node.alpha = 0.4
                } else {
                    node.alpha = 1.0
                    node.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                }
            }
        }
        
        self.artistButton.highligthedChanged = { [weak self] highlighted in
            if let strongSelf = self {
                if highlighted {
                    strongSelf.descriptionNode.layer.removeAnimation(forKey: "opacity")
                    strongSelf.descriptionNode.alpha = 0.4
                } else {
                    strongSelf.descriptionNode.alpha = 1.0
                    strongSelf.descriptionNode.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                }
            }
        }
        
        self.rateButton.contextAction = { [weak self] sourceNode, gesture in
            self?.openRateMenu(sourceNode: sourceNode, gesture: gesture)
        }
        
        self.playPauseButton.circleColor = presentationData.theme.list.controlSecondaryColor.withAlphaComponent(0.35)
        self.backwardButton.circleColor = presentationData.theme.list.controlSecondaryColor.withAlphaComponent(0.35)
        self.forwardButton.circleColor = presentationData.theme.list.controlSecondaryColor.withAlphaComponent(0.35)
    }
    
    deinit {
        self.statusDisposable?.dispose()
        self.chapterDisposable?.dispose()
    }
    
    override func didLoad() {
        super.didLoad()
        
        self.view.insertSubview(self.compactSheetView, at: 0)
        self.view.insertSubview(self.compactShadowView, at: 0)
        
        self.albumArtNode.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.albumArtTap(_:))))
        
        let backwardLongPressGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(self.seekBackwardLongPress(_:)))
        backwardLongPressGestureRecognizer.minimumPressDuration = 0.3
        self.backwardButton.view.addGestureRecognizer(backwardLongPressGestureRecognizer)
        
        let forwardLongPressGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(self.seekForwardLongPress(_:)))
        forwardLongPressGestureRecognizer.minimumPressDuration = 0.3
        self.forwardButton.view.addGestureRecognizer(forwardLongPressGestureRecognizer)
    }
    
    private var wasPlaying = false
    @objc private func seekBackwardLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
        switch gestureRecognizer.state {
            case .began:
                self.wasPlaying = !(self.currentIsPaused ?? true)
                self.backwardButton.isPressing = true
                self.previousRate = self.currentRate
                self.control?(.playback(.pause))
                
                var time: Double = 0.0
                let seekTimer = SwiftSignalKit.Timer(timeout: 0.1, repeat: true, completion: { [weak self] in
                    if let strongSelf = self {
                        var delta: Double = 0.8
                        if time >= 4.0 {
                            delta = 3.2
                        } else if time >= 2.0 {
                            delta = 1.6
                        }
                        time += 0.1
                        
                        let newPosition = strongSelf.currentPosition - delta
                        strongSelf.currentPosition = newPosition
                        strongSelf.control?(.seek(newPosition))
                    }
                }, queue: Queue.mainQueue())
                self.seekTimer = seekTimer
                seekTimer.start()
            case .ended, .cancelled:
                self.backwardButton.isPressing = false
                self.seekTimer?.invalidate()
                self.seekTimer = nil
                if self.wasPlaying {
                    self.control?(.playback(.play))
                }
                self.previousRate = nil
            default:
                break
        }
    }
    
    @objc private func seekForwardLongPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
        switch gestureRecognizer.state {
            case .began:
                self.wasPlaying = !(self.currentIsPaused ?? true)
                self.forwardButton.isPressing = true
                self.previousRate = self.currentRate
                self.seekRate = .x4
                self.control?(.playback(.play))
                self.control?(.setBaseRate(self.seekRate))
                let seekTimer = SwiftSignalKit.Timer(timeout: 2.0, repeat: true, completion: { [weak self] in
                    if let strongSelf = self {
                        if strongSelf.seekRate == .x4 {
                            strongSelf.seekRate = .x8
                        } else if strongSelf.seekRate == .x8 {
                            strongSelf.seekRate = .x16
                        }
                        strongSelf.control?(.setBaseRate(strongSelf.seekRate))
                        if strongSelf.seekRate == .x16 {
                            strongSelf.seekTimer?.invalidate()
                            strongSelf.seekTimer = nil
                        }
                    }
                }, queue: Queue.mainQueue())
                self.seekTimer = seekTimer
                seekTimer.start()
            case .ended, .cancelled:
                self.forwardButton.isPressing = false
                self.control?(.setBaseRate(self.previousRate ?? .x1))
                self.seekTimer?.invalidate()
                self.seekTimer = nil
                if !self.wasPlaying {
                    self.control?(.playback(.pause))
                }
                self.previousRate = nil
            default:
                break
        }
    }
    
    func updatePresentationData(_ presentationData: PresentationData) {
        guard self.presentationData.theme !== presentationData.theme else {
            return
        }
        self.presentationData = presentationData
        
        self.playPauseButton.circleColor = presentationData.theme.list.controlSecondaryColor.withAlphaComponent(0.35)
        self.backwardButton.circleColor = presentationData.theme.list.controlSecondaryColor.withAlphaComponent(0.35)
        self.forwardButton.circleColor = presentationData.theme.list.controlSecondaryColor.withAlphaComponent(0.35)
        
        self.backgroundNode.image = self.hasPlainBackground ? generatePlainBackground(theme: presentationData.theme) : generateBackground(theme: presentationData.theme)
        self.shareNode.setImage(generateTintedImage(image: UIImage(bundleImageName: "GlobalMusicPlayer/Share"), color: presentationData.theme.list.itemPrimaryTextColor), for: [])
        self.scrubberNode.updateColors(backgroundColor: presentationData.theme.list.controlSecondaryColor.withMultipliedAlpha(0.5), foregroundColor: presentationData.theme.list.itemPrimaryTextColor)
        self.leftDurationLabel.textColor = presentationData.theme.list.itemSecondaryTextColor
        self.rightDurationLabel.textColor = presentationData.theme.list.itemSecondaryTextColor
        self.backwardButton.icon = generateTintedImage(image: UIImage(bundleImageName: "GlobalMusicPlayer/Previous"), color: presentationData.theme.list.itemPrimaryTextColor)
        self.forwardButton.icon = generateTintedImage(image: UIImage(bundleImageName: "GlobalMusicPlayer/Next"), color: presentationData.theme.list.itemPrimaryTextColor)
        if let isPaused = self.currentIsPaused {
            self.updatePlayPauseButton(paused: isPaused, animated: false)
        }
        if let order = self.currentOrder {
            self.updateOrderButton(order)
        }
        if let looping = self.currentLooping {
            self.updateLoopButton(looping)
        }
        if let rate = self.currentRate {
            self.updateRateButton(rate)
        }
        self.separatorNode.backgroundColor = presentationData.theme.list.itemPlainSeparatorColor
        self.updateCompactColors()
        self.updateScrubberContent()
        
        self.updateLabels(transition: .immediate)
        self.requestLayout(transition: .immediate)
    }
    
    private func updateLabels(transition: ContainedViewLayoutTransition) {
        guard let (width, leftInset, rightInset, _, _, _) = self.validLayout else {
            return
        }
        
        let sideInset: CGFloat = 20.0
        
        let infoLabelsLeftInset: CGFloat = 53.0
        let infoLabelsRightInset: CGFloat = 32.0
        
        var infoVerticalOrigin: CGFloat = 21.0
        var infoLabelsX: CGFloat = leftInset + sideInset + infoLabelsLeftInset
        var infoLabelsWidth: CGFloat = width - sideInset * 2.0 - leftInset - rightInset - infoLabelsLeftInset - infoLabelsRightInset
        if self.isCompact {
            // Figma Player Row: 48 pt cover at 16, the text 8 pt after it, the more button 40 pt at 16 from the right.
            infoVerticalOrigin = self.compactEffectiveHeaderHeight + 19.0
            infoLabelsX = 72.0
            infoLabelsWidth = width - infoLabelsX - 16.0 - 40.0 - 8.0
        }
        
        let (titleString, descriptionString, hasArtist, caption) = stringsForDisplayData(self.displayData, presentationData: self.presentationData)
        
        if self.previousCaption?.string != caption?.string {
            self.previousCaption = caption
            let chapters = caption.flatMap { parseMediaPlayerChapters($0) } ?? []
            self.chaptersPromise.set(chapters)
            self.currentChapters = chapters
            self.updateScrubberContent()
        }
        
        self.artistButton.isUserInteractionEnabled = hasArtist
        
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: titleString, backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: infoLabelsWidth, height: CGFloat.greatestFiniteMagnitude), alignment: .left, lineSpacing: 0.0, cutout: nil, insets: UIEdgeInsets()))
        
        let titleSize = self.title.update(
            transition: .immediate,
            component: AnyComponent(
                MarqueeComponent(attributedText: titleString ?? NSAttributedString())
            ),
            environment: {},
            containerSize: CGSize(width: infoLabelsWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        if let titleView = self.title.view {
            if titleView.superview == nil {
                self.view.addSubview(titleView)
            }
            transition.updateFrame(view: titleView, frame: CGRect(origin: CGPoint(x: self.isExpanded ? floor((width - titleSize.width) / 2.0) : infoLabelsX, y: infoVerticalOrigin), size: titleSize))
        }
        
        let makeDescriptionLayout = TextNode.asyncLayout(self.descriptionNode)
        let (descriptionLayout, descriptionApply) = makeDescriptionLayout(TextNodeLayoutArguments(attributedString: descriptionString, backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: infoLabelsWidth, height: CGFloat.greatestFiniteMagnitude), alignment: .left, lineSpacing: 0.0, cutout: nil, insets: UIEdgeInsets()))
        
        transition.updateFrame(node: self.titleNode, frame: CGRect(origin: CGPoint(x: self.isExpanded ? floor((width - titleLayout.size.width) / 2.0) : infoLabelsX, y: infoVerticalOrigin + 1.0), size: titleLayout.size))
        let _ = titleApply()
        
        let descriptionFrame = CGRect(origin: CGPoint(x: self.isExpanded ? floor((width - descriptionLayout.size.width) / 2.0) : infoLabelsX, y: infoVerticalOrigin + 24.0), size: descriptionLayout.size)
        transition.updateFrame(node: self.descriptionNode, frame: descriptionFrame)
        let _ = descriptionApply()
        
        self.artistButton.frame = descriptionFrame.insetBy(dx: -8.0, dy: -8.0)
        
        var albumArt: SharedMediaPlaybackAlbumArt?
        if let displayData = self.displayData {
            switch displayData {
                case let .music(_, _, value, _, _):
                    albumArt = value
                default:
                    break
            }
        }
        if self.currentAlbumArt != albumArt || !self.currentAlbumArtInitialized {
            self.currentAlbumArtInitialized = true
            self.currentAlbumArt = albumArt
            self.albumArtNode.setSignal(playerAlbumArt(engine: self.engine, fileReference: self.currentFileReference, albumArt: albumArt, thumbnail: true))
            self.requestAlbumArtDisplay?(nil)
        }
    }
    
    private func updatePlayPauseButton(paused: Bool, animated: Bool) {
        self.playPauseIconNode.customColor = self.presentationData.theme.list.itemPrimaryTextColor
        if paused {
            self.playPauseIconNode.enqueueState(.play, animated: animated)
        } else {
            self.playPauseIconNode.enqueueState(.pause, animated: animated)
        }
    }
    
    private func updateOrderButton(_ order: MusicPlaybackSettingsOrder) {
        if self.isCompact {
            // The sheet's left button is Shuffle only: accent while the order is random.
            let isActive = order == .random || self.isQueueShuffled == true
            self.orderButton.icon = generateTintedImage(image: UIImage(bundleImageName: "GlobalMusicPlayer/OrderRandom"), color: isActive ? self.presentationData.theme.list.itemAccentColor : self.presentationData.theme.list.itemSecondaryTextColor)
            return
        }
        switch order {
            case .regular:
                self.orderButton.icon = generateTintedImage(image: UIImage(bundleImageName: "GlobalMusicPlayer/OrderReverse"), color: self.presentationData.theme.list.itemSecondaryTextColor)
            case .reversed:
                self.orderButton.icon = generateTintedImage(image: UIImage(bundleImageName: "GlobalMusicPlayer/OrderReverse"), color: self.presentationData.theme.list.itemAccentColor)
            case .random:
                self.orderButton.icon = generateTintedImage(image: UIImage(bundleImageName: "GlobalMusicPlayer/OrderRandom"), color: self.presentationData.theme.list.itemAccentColor)
        }
    }
    
    private func updateLoopButton(_ looping: MusicPlaybackSettingsLooping) {
        let baseColor = self.presentationData.theme.list.itemSecondaryTextColor
        switch looping {
            case .none:
                self.loopingButton.icon = generateTintedImage(image: UIImage(bundleImageName: "GlobalMusicPlayer/Repeat"), color: baseColor)
            case .item:
                self.loopingButton.icon = generateTintedImage(image: UIImage(bundleImageName: "GlobalMusicPlayer/RepeatOne"), color: self.presentationData.theme.list.itemAccentColor)
            case .all:
                self.loopingButton.icon = generateTintedImage(image: UIImage(bundleImageName: "GlobalMusicPlayer/Repeat"), color: self.presentationData.theme.list.itemAccentColor)
        }
    }
    
    private func updateRateButton(_ playbackBaseRate: AudioPlaybackRate) {
        let rate = self.previousRate ?? playbackBaseRate
        
        self.rateButton.setContent(.image(optionsRateImage(rate: rate.stringValue.uppercased(), color: self.presentationData.theme.list.itemSecondaryTextColor)))
    }
    
    static let basePanelHeight: CGFloat = 190.0
    
    static func heightForLayout(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, bottomInset: CGFloat, maxHeight: CGFloat, isExpanded: Bool, savedMusic: Bool?) -> CGFloat {
        var panelHeight: CGFloat = OverlayAudioPlayerControlsNode.basePanelHeight
        if isExpanded {
            let sideInset: CGFloat = 20.0
            panelHeight += width - leftInset - rightInset - sideInset * 2.0 + 24.0
        }
        var height = min(panelHeight, maxHeight)
        if let _ = savedMusic {
            height += 52.0
            let buttonInsets = ContainerViewLayout.concentricInsets(bottomInset: bottomInset, innerDiameter: 52.0, sideInset: 30.0)
            height += buttonInsets.bottom
        } else {
            height += 8.0
        }
        return height
    }
    
    func requestLayout(transition: ContainedViewLayoutTransition) {
        guard let layout = self.validLayout else {
            return
        }
        let _ = self.updateLayout(width: layout.width, leftInset: layout.leftInset, rightInset: layout.rightInset, bottomInset: layout.bottomInset, maxHeight: layout.maxHeight, savedMusic: layout.savedMusic, transition: transition)
    }
    
    func updateLayout(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, bottomInset: CGFloat, maxHeight: CGFloat, savedMusic: Bool?, transition: ContainedViewLayoutTransition) -> CGFloat {
        let previousWidth = self.validLayout?.width
        self.validLayout = (width, leftInset, rightInset, bottomInset, maxHeight, savedMusic)
    
        var transition = transition
        if !self.hasCompletedLayout || previousWidth == nil || previousWidth?.isZero == true {
            transition = .immediate
        }
        
        if self.isCompact {
            let height = self.updateCompactLayout(width: width, transition: transition)
            self.hasCompletedLayout = true
            return height
        }
        
        let finalPanelHeight = OverlayAudioPlayerControlsNode.heightForLayout(width: width, leftInset: leftInset, rightInset: rightInset, bottomInset: bottomInset, maxHeight: maxHeight, isExpanded: self.isExpanded, savedMusic: savedMusic)
        let panelHeight = OverlayAudioPlayerControlsNode.heightForLayout(width: width, leftInset: leftInset, rightInset: rightInset, bottomInset: bottomInset, maxHeight: maxHeight, isExpanded: self.isExpanded, savedMusic: nil)
        
        transition.updateFrame(node: self.separatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: panelHeight), size: CGSize(width: width, height: UIScreenPixel)))
                
        let sideInset: CGFloat = 16.0
        let sideButtonsInset: CGFloat = sideInset + 60.0
        
        let infoVerticalOrigin: CGFloat = 21.0
        
        self.updateLabels(transition: transition)
        
        transition.updateFrame(node: self.shareNode, frame: CGRect(origin: CGPoint(x: width - rightInset - sideInset - 34.0, y: infoVerticalOrigin), size: CGSize(width: 42.0, height: 42.0)))
        
        let albumArtSize = CGSize(width: 46.0, height: 46.0)
        let makeAlbumArtLayout = self.albumArtNode.asyncLayout()
        let applyAlbumArt = makeAlbumArtLayout(TransformImageArguments(corners: ImageCorners(radius: 10.0), imageSize: albumArtSize, boundingSize: albumArtSize, intrinsicInsets: UIEdgeInsets()))
        applyAlbumArt()
        let albumArtFrame = CGRect(origin: CGPoint(x: leftInset + sideInset, y: infoVerticalOrigin - 3.0), size: albumArtSize)
        transition.updateFrame(node: self.albumArtNode, frame: albumArtFrame)
        
        let scrubberVerticalOrigin: CGFloat = infoVerticalOrigin + 58.0
        let scrubberInset: CGFloat = 9.0
        
        // The scrubber, the info label and the centre buttons keep to the band between the side insets (iPhone Duo's
        // side strip), like the duration labels and the side buttons.
        transition.updateFrame(node: self.scrubberNode, frame: CGRect(origin: CGPoint(x: leftInset + sideInset + scrubberInset, y: scrubberVerticalOrigin - 8.0), size: CGSize(width: width - leftInset - rightInset - (sideInset + scrubberInset) * 2.0, height: 10.0 + 8.0 * 2.0)))
        
        let leftLabelVerticalOffset: CGFloat = self.leftDurationLabelPushed ? 6.0 : 0.0
        transition.updateFrame(node: self.leftDurationLabel, frame: CGRect(origin: CGPoint(x: leftInset + sideInset + scrubberInset, y: scrubberVerticalOrigin + 19.0 + leftLabelVerticalOffset), size: CGSize(width: 100.0, height: 20.0)))
        
        let rightLabelVerticalOffset: CGFloat = self.rightDurationLabelPushed ? 6.0 : 0.0
        transition.updateFrame(node: self.rightDurationLabel, frame: CGRect(origin: CGPoint(x: width - sideInset - rightInset - 100.0 - scrubberInset, y: scrubberVerticalOrigin + 19.0 + rightLabelVerticalOffset), size: CGSize(width: 100.0, height: 20.0)))
        
        let infoLabelVerticalOffset: CGFloat = self.infoNodePushed ? 6.0 : 0.0
                
        let infoSize = self.infoNode.measure(CGSize(width: width - leftInset - rightInset - 60.0 * 2.0 - 100.0, height: 100.0))
        self.infoNode.bounds = CGRect(origin: CGPoint(), size: infoSize)
        transition.updatePosition(node: self.infoNode, position: CGPoint(x: leftInset + (width - leftInset - rightInset) / 2.0, y: scrubberVerticalOrigin + 14.0 + infoLabelVerticalOffset + infoSize.height / 2.0))
        
        
        let rateRightOffset = timestampLabelWidthForDuration(self.currentDuration)
        transition.updateFrame(node: self.rateButton, frame: CGRect(origin: CGPoint(x: width - sideInset - rightInset - rateRightOffset - 38.0, y: scrubberVerticalOrigin + 10.0 + rightLabelVerticalOffset - 6.0 + UIScreenPixel), size: CGSize(width: 24.0, height: 44.0)))
        
        transition.updateFrame(node: self.backgroundNode, frame: CGRect(origin: CGPoint(x: 0.0, y: -8.0), size: CGSize(width: width, height: finalPanelHeight + 8.0)))
        
        let buttonSize = CGSize(width: 64.0, height: 64.0)
        let buttonsWidth = min(width - leftInset - rightInset - sideButtonsInset * 2.0, 320.0)
        let buttonsRect = CGRect(origin: CGPoint(x: leftInset + floor((width - leftInset - rightInset - buttonsWidth) / 2.0), y: scrubberVerticalOrigin + 34.0), size: CGSize(width: buttonsWidth, height: buttonSize.height))
        
        transition.updateFrame(node: self.orderButton, frame: CGRect(origin: CGPoint(x: leftInset + sideInset - 12.0, y: buttonsRect.minY), size: buttonSize))
        transition.updateFrame(node: self.loopingButton, frame: CGRect(origin: CGPoint(x: width - rightInset - sideInset - buttonSize.width + 12.0, y: buttonsRect.minY), size: buttonSize))
        
        transition.updateFrame(node: self.backwardButton, frame: CGRect(origin: buttonsRect.origin, size: buttonSize))
        transition.updateFrame(node: self.forwardButton, frame: CGRect(origin: CGPoint(x: buttonsRect.maxX - buttonSize.width, y: buttonsRect.minY), size: buttonSize))
        
        let playPauseFrame = CGRect(origin: CGPoint(x: buttonsRect.minX + floor((buttonsRect.width - buttonSize.width) / 2.0), y: buttonsRect.minY), size: buttonSize)
        transition.updateFrame(node: self.playPauseButton, frame: playPauseFrame)
        transition.updateFrame(node: self.playPauseIconNode, frame: CGRect(origin: CGPoint(x: -6.0, y: -6.0), size: CGSize(width: 76.0, height: 76.0)))
                                 
        if let savedMusic {
            var profileAudioTransition = transition
            if self.profileAudio == nil {
                profileAudioTransition = .immediate
            }
            let profileAudio: ComponentView<Empty> = self.profileAudio ?? {
                let componentView = ComponentView<Empty>()
                self.profileAudio = componentView
                return componentView
            }()
                        
            let profileAudioButtonContent: AnyComponentWithIdentity<Empty>
            var buttonBackgroundColor = self.presentationData.theme.list.itemCheckColors.fillColor
            if savedMusic {
                profileAudioButtonContent =  AnyComponentWithIdentity(id: "removeFromProfile", component: AnyComponent(
                    MultilineTextComponent(text: .plain(NSAttributedString(string: self.presentationData.strings.MediaPlayer_SavedMusic_RemoveFromProfileShort, font: Font.semibold(17.0), textColor: self.presentationData.theme.list.itemPrimaryTextColor)))
                ))
                buttonBackgroundColor = self.presentationData.theme.list.controlSecondaryColor.withMultipliedAlpha(0.5)
            } else {
                profileAudioButtonContent = AnyComponentWithIdentity(id: "addToProfile", component: AnyComponent(
                    HStack([
                        AnyComponentWithIdentity(id: "icon", component: AnyComponent(
                            BundleIconComponent(name: "Peer Info/SaveMusic", tintColor: self.presentationData.theme.list.itemCheckColors.foregroundColor)
                        )),
                        AnyComponentWithIdentity(id: "label", component: AnyComponent(
                            MultilineTextComponent(text: .plain(NSAttributedString(string: self.presentationData.strings.MediaPlayer_SavedMusic_AddToProfile, font: Font.semibold(17.0), textColor: self.presentationData.theme.list.itemCheckColors.foregroundColor)))
                        ))
                    ], spacing: 8.0)
                ))
            }
            
            let buttonInsets = ContainerViewLayout.concentricInsets(bottomInset: bottomInset, innerDiameter: 52.0, sideInset: 30.0)
            let profileAudioSize = profileAudio.update(
                transition: ComponentTransition(profileAudioTransition),
                component: AnyComponent(ButtonComponent(
                    background: ButtonComponent.Background(
                        style: .glass,
                        color: buttonBackgroundColor,
                        foreground: self.presentationData.theme.list.itemCheckColors.foregroundColor,
                        pressedColor: buttonBackgroundColor
                    ),
                    content: profileAudioButtonContent,
                    action: { [weak self] in
                        guard let self, let file = self.currentFileReference else {
                            return
                        }
                        if savedMusic {
                            self.requestRemoveFromProfile?(file)
                        } else {
                            self.requestSaveToProfile?(file)
                        }
                    }
                )),
                environment: {},
                containerSize: CGSize(width: width - leftInset - rightInset - buttonInsets.left - buttonInsets.right, height: 52.0)
            )
            let profileAudioOrigin: CGFloat = finalPanelHeight - profileAudioSize.height - buttonInsets.bottom
            // In the band between the side insets (the bottom-edge insets beside iPhone Duo's strip: clear of a bottom corner block).
            let profileAudioFrame = CGRect(origin: CGPoint(x: leftInset + floor((width - leftInset - rightInset - profileAudioSize.width) / 2.0), y: profileAudioOrigin), size: profileAudioSize)
            if let profileAudioView = profileAudio.view {
                if profileAudioView.superview == nil {
                    self.view.addSubview(profileAudioView)
                }
                profileAudioTransition.updateFrame(view: profileAudioView, frame: profileAudioFrame)
            }
        } else if let profileAudio = self.profileAudio {
            self.profileAudio = nil
            if let profileAudioView = profileAudio.view {
                profileAudioView.removeFromSuperview()
            }
        }
        
        self.hasCompletedLayout = true
        return finalPanelHeight
    }
    
    // MARK: Compact sheet layout
    
    private func updateScrubberContent() {
        let theme = self.presentationData.theme
        // Figma Track Progress: an 8 pt track; the full player keeps its 7 pt one.
        self.scrubberNode.updateContent(.standard(lineHeight: self.isCompact ? 8.0 : 7.0, lineCap: .round, scrubberHandle: .none, backgroundColor: theme.list.controlSecondaryColor.withMultipliedAlpha(0.5), foregroundColor: theme.list.itemPrimaryTextColor, bufferingColor: theme.list.itemPrimaryTextColor.withAlphaComponent(0.4), chapters: self.currentChapters))
    }
    
    private func updateCompactColors() {
        let theme = self.presentationData.theme
        // Figma color/bg/plain: the Music section's own background.
        self.compactSheetView.backgroundColor = theme.chatList.pinnedItemBackgroundColor
        self.compactCardView.backgroundColor = theme.list.itemModalBlocksBackgroundColor
        self.compactCardShadowView.backgroundColor = .clear
        self.compactGrabberNode.image = generateStretchableFilledCircleImage(diameter: 6.0, color: theme.list.controlSecondaryColor)
        self.queueBadgeNode.backgroundColor = theme.list.itemPrimaryTextColor.withMultipliedAlpha(0.08)
        self.moreButton.setImage(generateTintedImage(image: UIImage(bundleImageName: "Music/More"), color: theme.list.itemPrimaryTextColor), for: [])
    }
    
    private func updateStyleVisibility() {
        let isCompact = self.isCompact
        // One shadow under the mini player whatever the header does: its outline follows the sheet, so it only moves.
        self.compactShadowView.isHidden = !isCompact
        self.compactSheetView.isHidden = !isCompact
        self.compactGrabberNode.isHidden = !isCompact || !self.showsQueueHeader
        self.queueButton.isHidden = !isCompact || !self.showsQueueHeader
        self.moreButton.isHidden = !isCompact
        for button in self.panelButtons {
            button.view?.isHidden = !isCompact
        }
        self.backgroundNode.isHidden = isCompact
        if isCompact {
            // Share moves to the more menu; adding to the profile is the panel's first button.
            self.shareNode.isHidden = true
            if let profileAudioView = self.profileAudio?.view {
                profileAudioView.removeFromSuperview()
            }
            self.profileAudio = nil
        }
        if let order = self.currentOrder {
            self.updateOrderButton(order)
        }
    }
    
    /// The sheet's outline with iOS's continuous corners (the system's squircle, Figma's iOS corner smoothing): two
    /// continuous rounded halves, one with the top radius and one with the bottom one, filled as their union. Always
    /// the same elements, so the outline animates between sizes.
    private func compactSheetPath(size: CGSize, topRadius: CGFloat, bottomRadius: CGFloat) -> UIBezierPath {
        let half = floor(size.height / 2.0)
        let path = UIBezierPath(roundedRect: CGRect(x: 0.0, y: 0.0, width: size.width, height: half + 1.0), byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: topRadius, height: topRadius))
        path.append(UIBezierPath(roundedRect: CGRect(x: 0.0, y: half, width: size.width, height: size.height - half), byRoundingCorners: [.bottomLeft, .bottomRight], cornerRadii: CGSize(width: bottomRadius, height: bottomRadius)))
        return path
    }
    
    /// Figma Player Sheet 275:2027: grabber 16, queue header 70, then the card: row 80, progress 44, buttons 84,
    /// panel 24 + 50 and 32 below it.
    private func updateCompactLayout(width: CGFloat, transition: ContainedViewLayoutTransition) -> CGFloat {
        let theme = self.presentationData.theme
        let strings = self.presentationData.strings
        let headerHeight = self.compactEffectiveHeaderHeight
        let height = headerHeight + OverlayAudioPlayerControlsNode.compactCardHeight
        let size = CGSize(width: width, height: height)
        let bounds = CGRect(origin: CGPoint(), size: size)
        
        let topRadius = OverlayAudioPlayerControlsNode.compactTopCornerRadius
        let sheetPath = self.compactSheetPath(size: size, topRadius: topRadius, bottomRadius: max(topRadius, self.compactBottomCornerRadius))
        transition.updateFrame(view: self.compactShadowView, frame: bounds)
        transition.updateFrame(view: self.compactSheetView, frame: bounds)
        // The outline moves with the frame: a path set at once while the frame animates made the card jump at the
        // corners as the sheet left the screen edges.
        self.compactSheetMask.frame = bounds
        OverlayAudioPlayerControlsNode.updateAnimatedPath(layer: self.compactSheetMask, keyPath: "path", path: sheetPath.cgPath, transition: transition)
        OverlayAudioPlayerControlsNode.updateAnimatedPath(layer: self.compactShadowView.layer, keyPath: "shadowPath", path: sheetPath.cgPath, transition: transition)
        
        let cardFrame = CGRect(x: 0.0, y: headerHeight, width: width, height: height - headerHeight + topRadius)
        transition.updateFrame(view: self.compactCardView, frame: cardFrame)
        transition.updateFrame(view: self.compactCardShadowView, frame: cardFrame)
        OverlayAudioPlayerControlsNode.updateAnimatedPath(layer: self.compactCardShadowView.layer, keyPath: "shadowPath", path: UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: cardFrame.size), byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: topRadius, height: topRadius)).cgPath, transition: transition)
        
        // The player's own grabber, 36 × 6 in the controlSecondary colour.
        transition.updateFrame(node: self.compactGrabberNode, frame: CGRect(x: floor((width - 36.0) / 2.0), y: 5.0, width: 36.0, height: 6.0))
        
        // Queue header: the queue's source, "Очередь" with the track count under it.
        self.queueTitleNode.attributedText = NSAttributedString(string: MusicPlayerSupport.queueLabel(strings: strings), font: Font.medium(16.0), textColor: theme.list.itemPrimaryTextColor)
        let queueTitleSize = self.queueTitleNode.updateLayout(CGSize(width: width - 80.0, height: 100.0))
        var badgeSize = CGSize()
        if let queueCount = self.queueCount {
            self.queueBadgeTextNode.attributedText = NSAttributedString(string: presentationStringsFormattedNumber(Int32(clamping: queueCount), self.presentationData.dateTimeFormat.groupingSeparator), font: Font.medium(12.0), textColor: theme.list.itemPrimaryTextColor)
            let badgeTextSize = self.queueBadgeTextNode.updateLayout(CGSize(width: 100.0, height: 100.0))
            badgeSize = CGSize(width: max(20.0, badgeTextSize.width + 8.0), height: 20.0)
            self.queueBadgeTextNode.frame = CGRect(origin: CGPoint(x: floor((badgeSize.width - badgeTextSize.width) / 2.0), y: floor((badgeSize.height - badgeTextSize.height) / 2.0)), size: badgeTextSize)
            self.queueBadgeNode.isHidden = false
        } else {
            self.queueBadgeNode.isHidden = true
        }
        self.queueBadgeNode.cornerRadius = badgeSize.height / 2.0
        let queueRowWidth = queueTitleSize.width + (badgeSize.width > 0.0 ? 8.0 + badgeSize.width : 0.0)
        // Figma Songs List 277:3982: the queue's source on top, «Очередь» with the count 8 pt under it.
        let queueRowCenterY: CGFloat = 16.0 + 8.0 + 18.0 + 8.0 + 10.0
        let queueRowX = floor((width - queueRowWidth) / 2.0)
        transition.updateFrame(node: self.queueTitleNode, frame: CGRect(origin: CGPoint(x: queueRowX, y: floor(queueRowCenterY - queueTitleSize.height / 2.0)), size: queueTitleSize))
        transition.updateFrame(node: self.queueBadgeNode, frame: CGRect(origin: CGPoint(x: queueRowX + queueTitleSize.width + 8.0, y: queueRowCenterY - badgeSize.height / 2.0), size: badgeSize))
        
        self.queueSubtitleNode.attributedText = NSAttributedString(string: self.queueTitle ?? "", font: Font.regular(13.0), textColor: theme.list.sectionHeaderTextColor)
        self.queueSubtitleNode.truncationType = .end
        self.queueSubtitleNode.maximumNumberOfLines = 1
        let queueSubtitleSize = self.queueSubtitleNode.updateLayout(CGSize(width: width - 40.0, height: 100.0))
        transition.updateFrame(node: self.queueSubtitleNode, frame: CGRect(origin: CGPoint(x: floor((width - queueSubtitleSize.width) / 2.0), y: 16.0 + 8.0 + floor((18.0 - queueSubtitleSize.height) / 2.0)), size: queueSubtitleSize))
        transition.updateFrame(node: self.queueButton, frame: CGRect(x: 0.0, y: 0.0, width: width, height: headerHeight))
        
        // Player Row.
        self.updateLabels(transition: transition)
        let albumArtSize = CGSize(width: 48.0, height: 48.0)
        let applyAlbumArt = self.albumArtNode.asyncLayout()(TransformImageArguments(corners: ImageCorners(radius: albumArtSize.width / 2.0), imageSize: albumArtSize, boundingSize: albumArtSize, intrinsicInsets: UIEdgeInsets()))
        applyAlbumArt()
        transition.updateFrame(node: self.albumArtNode, frame: CGRect(origin: CGPoint(x: 16.0, y: headerHeight + 16.0), size: albumArtSize))
        let moreFrame = CGRect(x: width - 16.0 - 40.0, y: headerHeight + 20.0, width: 40.0, height: 40.0)
        transition.updateFrame(node: self.moreButton, frame: moreFrame)
        self.moreReferenceNode.frame = CGRect(origin: CGPoint(), size: moreFrame.size)
        
        // Track Progress: the track 8 pt below the row, the times 12 pt under it.
        let progressSideInset: CGFloat = 20.0
        let trackY = headerHeight + 80.0 + 8.0
        transition.updateFrame(node: self.scrubberNode, frame: CGRect(x: progressSideInset, y: trackY + 4.0 - 13.0, width: width - progressSideInset * 2.0, height: 26.0))
        let timeY = trackY + 8.0 + 12.0 - 2.0
        transition.updateFrame(node: self.leftDurationLabel, frame: CGRect(x: progressSideInset, y: timeY, width: 100.0, height: 20.0))
        transition.updateFrame(node: self.rightDurationLabel, frame: CGRect(x: width - progressSideInset - 100.0, y: timeY, width: 100.0, height: 20.0))
        let infoSize = self.infoNode.measure(CGSize(width: width - 60.0 * 2.0 - 100.0, height: 100.0))
        self.infoNode.bounds = CGRect(origin: CGPoint(), size: infoSize)
        transition.updatePosition(node: self.infoNode, position: CGPoint(x: width / 2.0, y: timeY + 10.0))
        let rateRightOffset = timestampLabelWidthForDuration(self.currentDuration)
        transition.updateFrame(node: self.rateButton, frame: CGRect(x: width - progressSideInset - rateRightOffset - 30.0, y: timeY - 12.0, width: 24.0, height: 44.0))
        
        // Track Controls: shuffle and repeat 32 pt from the edges, previous and next 83.5 pt from play.
        let buttonSize = CGSize(width: 64.0, height: 64.0)
        let controlsCenterY = headerHeight + 124.0 + 42.0
        let buttonFrame: (CGFloat) -> CGRect = { centerX in
            return CGRect(x: floor(centerX - buttonSize.width / 2.0), y: floor(controlsCenterY - buttonSize.height / 2.0), width: buttonSize.width, height: buttonSize.height)
        }
        transition.updateFrame(node: self.orderButton, frame: buttonFrame(32.0))
        transition.updateFrame(node: self.loopingButton, frame: buttonFrame(width - 32.0))
        transition.updateFrame(node: self.backwardButton, frame: buttonFrame(width / 2.0 - 83.5))
        transition.updateFrame(node: self.forwardButton, frame: buttonFrame(width / 2.0 + 83.5))
        transition.updateFrame(node: self.playPauseButton, frame: buttonFrame(width / 2.0))
        transition.updateFrame(node: self.playPauseIconNode, frame: CGRect(origin: CGPoint(x: -6.0, y: -6.0), size: CGSize(width: 76.0, height: 76.0)))
        
        // Track Menu: Add to Music, Favorites, Add to Playlist.
        let panelSideInset: CGFloat = 20.0
        let panelSpacing: CGFloat = 8.0
        let panelHeight: CGFloat = 50.0
        let panelY = headerHeight + 208.0 + 24.0
        let panelButtonWidth = floor((width - panelSideInset * 2.0 - panelSpacing * 2.0) / 3.0)
        let state = self.compactPanelState
        let accent = theme.list.itemAccentColor
        let foreground = theme.list.itemPrimaryTextColor
        // The section's glass buttons: near-clear glass, tinted with the accent while the track is added.
        let plainGlass = theme.overallDarkAppearance ? UIColor(white: 0.0, alpha: 0.01) : UIColor(white: 1.0, alpha: 0.01)
        let activeGlass = accent.withMultipliedAlpha(0.1)
        // Icons drawn for the player: the same 30 pt canvas, glyph size and 2 pt stroke as shuffle and repeat.
        let panelItems: [(icon: String, isActive: Bool, isEnabled: Bool, action: () -> Void)] = [
            (state.isInMusic == true ? "Music/PlayerCheck" : "Music/PlayerAdd", state.isInMusic == true, state.isInMusic != nil, { [weak self] in
                self?.requestToggleSaved?()
            }),
            (state.isFavorite ? "Music/PlayerStarSlash" : "Music/PlayerStar", state.isFavorite, true, { [weak self] in
                self?.requestToggleFavorite?()
            }),
            ("Music/PlayerAddToPlaylist", false, true, { [weak self] in
                self?.requestAddToPlaylist?()
            })
        ]
        for (index, item) in panelItems.enumerated() {
            let color = item.isActive ? accent : foreground
            let glass = item.isActive ? activeGlass : plainGlass
            let buttonSize = CGSize(width: index == panelItems.count - 1 ? width - panelSideInset * 2.0 - (panelButtonWidth + panelSpacing) * 2.0 : panelButtonWidth, height: panelHeight)
            let contentId = AnyHashable("\(item.icon) \(item.isActive)")
            let contentChanged = self.panelContentIds[index] != nil && self.panelContentIds[index] != contentId
            self.panelContentIds[index] = contentId
            let isToggle = index != panelItems.count - 1
            let _ = self.panelButtons[index].update(
                transition: .immediate,
                component: AnyComponent(ButtonComponent(
                    background: ButtonComponent.Background(style: .actualGlass, color: glass, foreground: color, pressedColor: glass, cornerRadius: panelHeight * 0.5),
                    content: AnyComponentWithIdentity(id: contentId, component: AnyComponent(BundleIconComponent(name: item.icon, tintColor: color))),
                    isEnabled: item.isEnabled,
                    action: { [weak self] in
                        self?.panelButtonTapped(index: index, isToggle: isToggle)
                        item.action()
                    }
                )),
                environment: {},
                containerSize: buttonSize
            )
            if let view = self.panelButtons[index].view {
                if view.superview == nil {
                    self.view.addSubview(view)
                }
                view.isHidden = false
                transition.updateFrame(view: view, frame: CGRect(origin: CGPoint(x: panelSideInset + CGFloat(index) * (panelButtonWidth + panelSpacing), y: panelY), size: buttonSize))
                if contentChanged && self.pendingPanelBounce == index {
                    self.pendingPanelBounce = nil
                    MusicButtonIconAnimation.bounce(in: view)
                }
            }
        }
        
        return height
    }
    
    /// Sets a layer's path (a mask's or a shadow's) along the transition, starting from what is on screen, so a change
    /// that interrupts a running one picks it up mid-flight.
    static func updateAnimatedPath(layer: CALayer, keyPath: String, path: CGPath, transition: ContainedViewLayoutTransition) {
        let read: (CALayer?) -> CGPath? = { layer in
            if keyPath == "path" {
                return (layer as? CAShapeLayer)?.path
            } else {
                return layer?.shadowPath
            }
        }
        let currentPath = read(layer)
        if let currentPath, currentPath == path {
            return
        }
        var fromPath = currentPath
        if layer.animation(forKey: keyPath) != nil, let presentationPath = read(layer.presentation()) {
            fromPath = presentationPath
        }
        layer.removeAnimation(forKey: keyPath)
        if keyPath == "path" {
            (layer as? CAShapeLayer)?.path = path
        } else {
            layer.shadowPath = path
        }
        if case let .animated(duration, curve) = transition, let fromPath {
            layer.animate(from: fromPath, to: path, keyPath: keyPath, timingFunction: curve.timingFunction, duration: duration, mediaTimingFunction: curve.mediaTimingFunction)
        }
    }
    
    private func panelButtonTapped(index: Int, isToggle: Bool) {
        guard isToggle else {
            MusicButtonIconAnimation.bounce(in: self.panelButtons[index].view)
            return
        }
        // The new icon arrives with the library's next state; a tap that changes nothing bounces the current one.
        self.pendingPanelBounce = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: { [weak self] in
            guard let self, self.pendingPanelBounce == index else {
                return
            }
            self.pendingPanelBounce = nil
            MusicButtonIconAnimation.bounce(in: self.panelButtons[index].view)
        })
    }

    @objc private func queuePressed() {
        self.requestOpenQueue?()
    }
    
    @objc private func morePressed() {
        self.requestMoreMenu?(self.moreReferenceNode)
    }
    
    func collapse() {
        if self.isExpanded {
            self.isExpanded = false
            self.updateIsExpanded?()
        }
    }
    
    @objc func collapsePressed() {
        self.requestCollapse?()
    }
    
    @objc func sharePressed() {
        if let itemId = self.currentItemId as? PeerMessagesMediaPlaylistItemId {
            if itemId.messageId.namespace == Namespaces.Message.Cloud {
                let _ = (self.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: itemId.messageId))
                |> deliverOnMainQueue).startStandalone(next: { [weak self] message in
                    guard let message else {
                        return
                    }
                    self?.requestShare?(.messages([message._asMessage()]))
                })
            } else if let fileReference = self.currentFileReference {
                self.requestShare?(.media(fileReference.abstract, nil))
            }
        }
    }
    
    @objc func orderPressed() {
        if self.isCompact, let requestShuffle = self.requestShuffle {
            requestShuffle()
            return
        }
        if let order = self.currentOrder {
            var nextOrder: MusicPlaybackSettingsOrder
            switch order {
                case .regular:
                    nextOrder = .reversed
                case .reversed:
                    nextOrder = .random
                case .random:
                    nextOrder = .regular
            }
            if self.isCompact {
                nextOrder = order == .random ? .regular : .random
            }
            let _ = updateMusicPlaybackSettingsInteractively(accountManager: self.accountManager, {
                return $0.withUpdatedOrder(nextOrder)
            }).startStandalone()
            self.control?(.setOrder(nextOrder))
        }
    }
    
    @objc func loopingPressed() {
        if let looping = self.currentLooping {
            let nextLooping: MusicPlaybackSettingsLooping
            switch looping {
                case .none:
                    nextLooping = .item
                case .item:
                    nextLooping = .all
                case .all:
                    nextLooping = .none
            }
            let _ = updateMusicPlaybackSettingsInteractively(accountManager: self.accountManager, {
                return $0.withUpdatedLooping(nextLooping)
            }).startStandalone()
            self.control?(.setLooping(nextLooping))
        }
    }
    
    @objc func backwardPressed() {
        self.control?(.previous)
    }
    
    @objc func forwardPressed() {
        self.control?(.next)
    }
    
    @objc func playPausePressed() {
        self.control?(.playback(.togglePlayPause))
    }
    
    @objc func rateButtonPressed() {
        var nextRate: AudioPlaybackRate
        if let rate = self.currentRate {
            switch rate {
            case .x0_5, .x2:
                nextRate = .x1
            case .x1:
                nextRate = .x1_5
            case .x1_5:
                nextRate = .x2
            default:
                if rate.doubleValue < 0.5 {
                    nextRate = .x0_5
                } else if rate.doubleValue < 1.0 {
                    nextRate = .x1
                } else if rate.doubleValue < 1.5 {
                    nextRate = .x1_5
                } else if rate.doubleValue < 2.0 {
                    nextRate = .x2
                } else {
                    nextRate = .x1
                }
            }
        } else {
            nextRate = .x1_5
        }
        self.control?(.setBaseRate(nextRate))
    }
    
    private func speedList(strings: PresentationStrings) -> [(String, String, AudioPlaybackRate)] {
        let speedList: [(String, String, AudioPlaybackRate)] = [
            ("0.5x", "0.5x", .x0_5),
            (strings.PlaybackSpeed_Normal, "1x", .x1),
            ("1.5x", "1.5x", .x1_5),
            ("2x", "2x", .x2)
        ]
        return speedList
    }
    
    private func contextMenuSpeedItems(scheduleTooltip: @escaping (MediaNavigationAccessoryPanel.ChangeType?) -> Void) -> Signal<ContextController.Items, NoError> {
        var presetItems: [ContextMenuItem] = []
                
        let previousRate = self.currentRate
        let previousValue = self.currentRate?.doubleValue ?? 1.0
        let sliderValuePromise = ValuePromise<Double?>(nil)
        let sliderItem: ContextMenuItem = .custom(SliderContextItem(minValue: 0.2, maxValue: 2.5, value: previousValue, valueChanged: { [weak self] newValue, finished in
            let newValue = normalizeValue(newValue)
            self?.control?(.setBaseRate(AudioPlaybackRate(newValue)))
            sliderValuePromise.set(newValue)
            if finished {
                scheduleTooltip(.sliderCommit(previousValue, newValue))
            }
        }), true)
 
        let theme = self.presentationData.theme
        for (text, _, rate) in self.speedList(strings: self.presentationData.strings) {
            let isSelected = self.currentRate == rate
            presetItems.append(.action(ContextMenuActionItem(text: text, icon: { _ in return nil }, iconSource: ContextMenuActionItemIconSource(size: CGSize(width: 24.0, height: 24.0), signal: sliderValuePromise.get()
            |> map { value in
                if isSelected && value == nil {
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Check"), color: theme.contextMenu.primaryColor)
                } else {
                    return UIImage()
                }
            }), action: { [weak self] _, f in
                scheduleTooltip(nil)
                f(.default)
                
                self?.control?(.setBaseRate(rate))
                if let previousRate, previousRate.isPreset {
                    self?.presentAudioRateTooltip(baseRate: rate, changeType: .preset)
                } else {
                    self?.presentAudioRateTooltip(baseRate: rate, changeType: .sliderCommit(previousValue, rate.doubleValue))
                }
            })))
        }

        return .single(ContextController.Items(content: .twoLists(presetItems, [sliderItem])))
    }
    
    private func openRateMenu(sourceNode: ASDisplayNode, gesture: ContextGesture?) {
        guard let controller = self.getParentController() else {
            return
        }
        var scheduledTooltip: MediaNavigationAccessoryPanel.ChangeType?
        let items = self.contextMenuSpeedItems(scheduleTooltip: { change in
            scheduledTooltip = change
        })
        
        let contextController = makeContextController(presentationData: self.presentationData, source: .reference(HeaderContextReferenceContentSource(controller: controller, sourceNode: self.rateButton.referenceNode, shouldBeDismissed: .single(false))), items: items, gesture: gesture)
        contextController.dismissed = { [weak self] in
            if let scheduledTooltip, let self, let rate = self.currentRate {
                self.presentAudioRateTooltip(baseRate: rate, changeType: scheduledTooltip)
            }
        }
        controller.presentInGlobalOverlay(contextController)
    }
    
    private func presentAudioRateTooltip(baseRate: AudioPlaybackRate, changeType: MediaNavigationAccessoryPanel.ChangeType) {
        guard let controller = self.getParentController() else {
            return
        }
        
        let presentationData = self.presentationData
        let text: String?
        let rate: CGFloat?
        if case let .sliderCommit(previousValue, newValue) = changeType {
            let value = String(format: "%0.1f", baseRate.doubleValue)
            if baseRate == .x1 {
                text = presentationData.strings.Conversation_AudioRateTooltipNormal
            } else {
                text = presentationData.strings.Conversation_AudioRateTooltipCustom(value).string
            }
            if newValue > previousValue {
                rate = .infinity
            } else if newValue < previousValue {
                rate = -.infinity
            } else {
                rate = nil
            }
        } else if baseRate == .x1 {
            text = presentationData.strings.Conversation_AudioRateTooltipNormal
            rate = 1.0
        } else if baseRate == .x1_5 {
            text = presentationData.strings.Conversation_AudioRateTooltip15X
            rate = 1.5
        } else if baseRate == .x2 {
            text = presentationData.strings.Conversation_AudioRateTooltipSpeedUp
            rate = 2.0
        } else {
            text = nil
            rate = nil
        }
        var showTooltip = true
        if case .sliderChange = changeType {
            showTooltip = false
        }
        if let rate, let text, showTooltip {
            controller.presentInGlobalOverlay(
                UndoOverlayController(
                    presentationData: presentationData,
                    content: .audioRate(
                        rate: rate,
                        text: text
                    ),
                    elevatedLayout: false,
                    animateInAsReplacement: false,
                    action: { action in
                        return true
                    }
                )
            )
        }
    }
    
    @objc func albumArtTap(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            if let supernode = self.supernode {
                let bounds = supernode.bounds
                if bounds.width > bounds.height {
                    return
                }
            }
            if let currentFileReference = self.currentFileReference, let currentAlbumArt = self.currentAlbumArt {
                self.requestAlbumArtDisplay?((currentFileReference, currentAlbumArt))
            }
        }
    }
    
    @objc func artistPressed() {
        let (_, descriptionString, _, _) = stringsForDisplayData(self.displayData, presentationData: self.presentationData)
        if let artist = descriptionString?.string {
            self.requestSearchByArtist?(artist)
        }
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if result == self.view {
            return nil
        }
        return result
    }
}

private enum PlayPauseIconNodeState: Equatable {
    case play
    case pause
}

private final class PlayPauseIconNode: ManagedAnimationNode {
    private let duration: Double = 0.35
    private var iconState: PlayPauseIconNodeState = .pause
    
    init(lottieSettings: LottieRenderingSettings) {
        super.init(size: CGSize(width: 76.0, height: 76.0), lottieSettings: lottieSettings)
        
        self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 41, endFrame: 41), duration: 0.01))
    }
    
    func enqueueState(_ state: PlayPauseIconNodeState, animated: Bool) {
        guard self.iconState != state else {
            return
        }
        
        let previousState = self.iconState
        self.iconState = state
        
        switch previousState {
            case .pause:
                switch state {
                    case .play:
                        if animated {
                            self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 41, endFrame: 83), duration: self.duration))
                        } else {
                            self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 0, endFrame: 0), duration: 0.01))
                        }
                    case .pause:
                        break
                }
            case .play:
                switch state {
                    case .pause:
                        if animated {
                            self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 0, endFrame: 41), duration: self.duration))
                        } else {
                            self.trackTo(item: ManagedAnimationItem(source: .local("anim_playpause"), frames: .range(startFrame: 41, endFrame: 41), duration: 0.01))
                        }
                    case .play:
                        break
                }
        }
    }
}

private final class HeaderContextReferenceContentSource: ContextReferenceContentSource {
    private let controller: ViewController
    private let sourceNode: ContextReferenceContentNode

    var shouldBeDismissed: Signal<Bool, NoError>
    
    init(controller: ViewController, sourceNode: ContextReferenceContentNode, shouldBeDismissed: Signal<Bool, NoError>) {
        self.controller = controller
        self.sourceNode = sourceNode
        self.shouldBeDismissed = shouldBeDismissed
    }
    
    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceNode.view, contentAreaInScreenSpace: mainWindowScreenBounds)
    }
}

/// The sheet's more button: the menu opens from it.
final class OverlayAudioPlayerReferenceContentSource: ContextReferenceContentSource {
    private let sourceNode: ContextReferenceContentNode
    
    init(sourceNode: ContextReferenceContentNode) {
        self.sourceNode = sourceNode
    }
    
    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceNode.view, contentAreaInScreenSpace: mainWindowScreenBounds)
    }
}
