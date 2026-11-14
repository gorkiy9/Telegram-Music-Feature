import Foundation
import LottieSettings
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import PhotoResources
import MusicAlbumArtResources
import ComponentFlow
import EdgeEffect
import ChatMessageDateAndStatusNode
import ChatMessageBubbleContentNode
import ChatMessageItemCommon
import ChatMessageAttachedContentButtonNode
import ChatControllerInteraction
import ListMessageItem
import UniversalMediaPlayer

/// Music section concept: the link preview type a playlist shared into a chat travels as.
public let chatMessageMusicPlaylistWebpageType = "telegram_music_playlist"

public func chatMessageMusicPlaylist(_ media: [EngineRawMedia]) -> (TelegramMediaWebpageLoadedContent, TelegramMediaWebpage, TelegramMediaWebpageMusicPlaylistAttribute)? {
    for media in media {
        if let webpage = media as? TelegramMediaWebpage, case let .Loaded(content) = webpage.content, content.type == chatMessageMusicPlaylistWebpageType {
            for attribute in content.attributes {
                if case let .musicPlaylist(playlist) = attribute {
                    return (content, webpage, playlist)
                }
            }
        }
    }
    return nil
}

private let previewTrackCount = 5

private func trackCountString(_ strings: PresentationStrings, _ count: Int) -> String {
    return strings.Music_TrackCount(Int32(clamping: count))
}

private func durationString(_ duration: Int) -> String {
    return String(format: "%d:%02d", duration / 60, duration % 60)
}

private struct TrackInfo {
    let file: TelegramMediaFile
    let title: String
    let performer: String?
    let duration: Int?
}

private func trackInfo(_ file: TelegramMediaFile) -> TrackInfo {
    var title: String?
    var performer: String?
    var duration: Int?
    for attribute in file.attributes {
        if case let .Audio(_, durationValue, titleValue, performerValue, _) = attribute {
            title = titleValue
            performer = performerValue
            duration = durationValue
            break
        }
    }
    var resolvedTitle = title ?? file.fileName ?? ""
    if title == nil, let dot = resolvedTitle.lastIndex(of: "."), dot != resolvedTitle.startIndex {
        resolvedTitle = String(resolvedTitle[..<dot])
    }
    let resolvedPerformer = performer?.trimmingCharacters(in: .whitespacesAndNewlines)
    return TrackInfo(file: file, title: resolvedTitle, performer: resolvedPerformer?.isEmpty == false ? resolvedPerformer : nil, duration: duration)
}

/// A track row of the bubble: the Music row's round cover, title and artist in the chat's file colours, duration.
private final class TrackRowNode: ASDisplayNode {
    let coverNode = TransformImageNode()
    let titleNode = TextNode()
    let performerNode = TextNode()
    let durationNode = TextNode()
    var fileId: Int64?
    /// The Music rows' Playing Now wave over the cover while this track is the one the player is on.
    private var playingIndicatorNode: ListMessagePlayingIndicatorNode?

    override init() {
        super.init()
        self.addSubnode(self.coverNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.performerNode)
        self.addSubnode(self.durationNode)
    }

    func updatePlayingIndicator(_ state: ListMessageItemPlayingIndicator?, animated: Bool) {
        if let state {
            let indicatorNode: ListMessagePlayingIndicatorNode
            if let current = self.playingIndicatorNode {
                indicatorNode = current
            } else {
                indicatorNode = ListMessagePlayingIndicatorNode()
                self.playingIndicatorNode = indicatorNode
                self.insertSubnode(indicatorNode, aboveSubnode: self.coverNode)
                if animated {
                    indicatorNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                }
            }
            indicatorNode.frame = self.coverNode.frame
            indicatorNode.update(size: self.coverNode.frame.size, state: state)
        } else if let indicatorNode = self.playingIndicatorNode {
            self.playingIndicatorNode = nil
            if animated {
                indicatorNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak indicatorNode] _ in
                    indicatorNode?.removeFromSupernode()
                })
            } else {
                indicatorNode.removeFromSupernode()
            }
        }
    }
}

/// Draws the cover aspect-filled into the bubble's media corners, or the playlist screen's placeholder without one.
private func coverDrawing(image: UIImage?, placeholderColor: UIColor, placeholderIcon: UIImage?) -> (TransformImageArguments) -> DrawingContext? {
    return { arguments in
        guard let context = DrawingContext(size: arguments.drawingSize, clear: true) else {
            return nil
        }
        let rect = arguments.drawingRect
        context.withFlippedContext { c in
            if let image, let cgImage = image.cgImage, image.size.width > 0.0, image.size.height > 0.0 {
                let scale = max(rect.width / image.size.width, rect.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                c.draw(cgImage, in: CGRect(origin: CGPoint(x: rect.midX - size.width / 2.0, y: rect.midY - size.height / 2.0), size: size))
            } else {
                c.setFillColor(placeholderColor.cgColor)
                c.fill(rect)
                if let placeholderIcon, let cgImage = placeholderIcon.cgImage {
                    let iconSize = CGSize(width: 64.0, height: 64.0)
                    c.draw(cgImage, in: CGRect(origin: CGPoint(x: rect.midX - iconSize.width / 2.0, y: rect.midY - iconSize.height / 2.0), size: iconSize))
                }
            }
        }
        addCorners(context, arguments: arguments)
        return context
    }
}

/// A playlist shared into a chat (Figma Chat Playlist Cover 334:9791): the cover across the bubble like a photo, its
/// lower half under the client's edge effect (blur and a darkening gradient) carrying the name, owner, track count
/// and the playlist menu; then the first five tracks and Show All when there are more. The cover and Show All open
/// the playlist's sheet.
public class ChatMessageMusicPlaylistBubbleContentNode: ChatMessageBubbleContentNode {
    private let coverNode: TransformImageNode
    private let shadeContainerView: UIView
    private let shadeView: EdgeEffectView
    private let titleNode: TextNode
    private let subtitleNode: TextNode
    private let moreButtonNode: HighlightableButtonNode
    private var trackNodes: [TrackRowNode] = []
    private let separatorNode: ASDisplayNode
    private let showAllButtonNode: ChatMessageAttachedContentButtonNode
    private let dateAndStatusNode: ChatMessageDateAndStatusNode

    private var playlistId: Int64?
    private var coverKey: String?
    private var playingDisposable: Disposable?
    private var playingTrack: (fileId: Int64, isPaused: Bool)?

    required public init(lottieSettings: LottieRenderingSettings) {
        self.coverNode = TransformImageNode()
        self.shadeContainerView = UIView()
        self.shadeContainerView.isUserInteractionEnabled = false
        self.shadeContainerView.clipsToBounds = true
        self.shadeView = EdgeEffectView()
        self.shadeView.isUserInteractionEnabled = false
        self.shadeContainerView.addSubview(self.shadeView)
        self.titleNode = TextNode()
        self.subtitleNode = TextNode()
        self.moreButtonNode = HighlightableButtonNode()
        self.separatorNode = ASDisplayNode()
        self.showAllButtonNode = ChatMessageAttachedContentButtonNode()
        self.dateAndStatusNode = ChatMessageDateAndStatusNode()

        super.init(lottieSettings: lottieSettings)

        self.addSubnode(self.coverNode)
        self.addSubnode(self.titleNode)
        self.addSubnode(self.subtitleNode)
        self.addSubnode(self.moreButtonNode)
        for _ in 0 ..< previewTrackCount {
            let trackNode = TrackRowNode()
            self.trackNodes.append(trackNode)
            self.addSubnode(trackNode)
        }
        self.addSubnode(self.separatorNode)
        self.addSubnode(self.showAllButtonNode)

        self.moreButtonNode.addTarget(self, action: #selector(self.morePressed), forControlEvents: .touchUpInside)
        self.showAllButtonNode.addTarget(self, action: #selector(self.showAllPressed), forControlEvents: .touchUpInside)

        self.dateAndStatusNode.reactionSelected = { [weak self] _, value, sourceView in
            guard let self, let item = self.item else {
                return
            }
            item.controllerInteraction.updateMessageReaction(item.topMessage, .reaction(value), false, sourceView)
        }
        self.dateAndStatusNode.openReactionPreview = { [weak self] gesture, sourceView, value in
            guard let self, let item = self.item else {
                gesture?.cancel()
                return
            }
            item.controllerInteraction.openMessageReactionContextMenu(item.topMessage, sourceView, gesture, value)
        }
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.playingDisposable?.dispose()
    }

    /// Follows the music player like the Music section's lists: by file, paused while buffering a paused track.
    private func subscribeToPlayerIfNeeded(context: AccountContext) {
        guard self.playingDisposable == nil else {
            return
        }
        self.playingDisposable = (context.sharedContext.mediaManager.musicMediaPlayerState
        |> map { state -> (Int64, Bool)? in
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
            self.updatePlayingIndicators(animated: true)
        })
    }

    private func updatePlayingIndicators(animated: Bool) {
        for trackNode in self.trackNodes {
            var state: ListMessageItemPlayingIndicator?
            if !trackNode.isHidden, let fileId = trackNode.fileId, let playingTrack = self.playingTrack, playingTrack.fileId == fileId {
                state = playingTrack.isPaused ? .paused : .playing
            }
            trackNode.updatePlayingIndicator(state, animated: animated)
        }
    }

    override public func didLoad() {
        super.didLoad()

        // The shade lies over the cover and under the row's text and menu.
        self.view.insertSubview(self.shadeContainerView, aboveSubview: self.coverNode.view)

        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.contentTap(_:)))
        self.view.addGestureRecognizer(tapRecognizer)
    }

    override public func accessibilityActivate() -> Bool {
        self.perform(.open)
        return true
    }

    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, CGSize?, CGFloat, (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        let statusLayout = self.dateAndStatusNode.asyncLayout()
        let makeCoverLayout = self.coverNode.asyncLayout()
        let makeTitleLayout = TextNode.asyncLayout(self.titleNode)
        let makeSubtitleLayout = TextNode.asyncLayout(self.subtitleNode)
        let makeShowAllButtonLayout = ChatMessageAttachedContentButtonNode.asyncLayout(self.showAllButtonNode)
        let trackLayouts = self.trackNodes.map { node in
            return (TextNode.asyncLayout(node.titleNode), TextNode.asyncLayout(node.performerNode), TextNode.asyncLayout(node.durationNode), node.coverNode.asyncLayout())
        }
        let previousTrackFileIds = self.trackNodes.map(\.fileId)

        return { [weak self] item, layoutConstants, _, _, _, _ in
            let playlistData = chatMessageMusicPlaylist(item.message.media)

            var incoming = item.message.effectivelyIncoming(item.context.account.peerId)
            if let subject = item.associatedData.subject, case let .messageOptions(_, _, info) = subject, case .forward = info {
                incoming = false
            }
            let theme = item.presentationData.theme.theme
            let messageTheme = incoming ? theme.chat.message.incoming : theme.chat.message.outgoing
            let strings = item.presentationData.strings
            let fontSize = item.presentationData.fontSize.baseDisplaySize

            // The row over the cover: Figma's 16 semibold and 15 regular, white over the shade like the playlist
            // screen's expanded header. Tracks keep the fonts of the chat's audio bubble.
            let titleFont = Font.semibold(floor(fontSize * 16.0 / 17.0))
            let subtitleFont = Font.regular(floor(fontSize * 15.0 / 17.0))
            let trackTitleFont = Font.regular(floor(fontSize * 16.0 / 17.0))
            let trackPerformerFont = Font.regular(floor(fontSize * 13.0 / 17.0))
            let durationFont = Font.with(size: floor(fontSize * 13.0 / 17.0), design: .regular, weight: .regular, traits: [.monospacedNumbers])

            let files = playlistData?.2.files ?? []
            let tracks = files.map(trackInfo)
            let previewTracks = Array(tracks.prefix(previewTrackCount))
            let showsAll = tracks.count > previewTrackCount

            let titleString = NSAttributedString(string: playlistData?.0.title ?? "", font: titleFont, textColor: .white)
            var subtitleComponents: [String] = []
            if let author = playlistData?.0.author, !author.isEmpty {
                subtitleComponents.append(author)
            }
            subtitleComponents.append(trackCountString(strings, tracks.count))
            let subtitleString = NSAttributedString(string: subtitleComponents.joined(separator: " • "), font: subtitleFont, textColor: UIColor(white: 1.0, alpha: 0.6))

            // Media on top, as a photo with a caption: the author's name goes above it.
            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: true, headerSpacing: 5.0, hidesBackground: .never, forceFullCorners: false, forceAlignment: .none)

            // A photo's insets from the bubble's edge, as the media bubble takes them: on a plain colour wallpaper
            // 1 pt or the bubble's stroke, so the cover never covers the bubble's outline.
            let imageInsets: UIEdgeInsets
            if case .color = item.presentationData.theme.wallpaper {
                let colors = messageTheme.bubble.withoutWallpaper
                if colors.fill[0] == colors.stroke || colors.stroke.alpha.isZero {
                    imageInsets = UIEdgeInsets(top: 1.0, left: 1.0, bottom: 1.0, right: 1.0)
                } else {
                    imageInsets = layoutConstants.bubble.strokeInsets
                }
            } else {
                imageInsets = layoutConstants.image.bubbleInsets
            }

            return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, { [weak self] constrainedSize, position in
                let sideInset = layoutConstants.text.bubbleInsets.right
                let contentWidth = min(constrainedSize.width, 300.0)

                var edited = false
                if item.attributes.updatingMedia != nil {
                    edited = true
                }
                var viewCount: Int?
                var dateReactionsAndPeers = mergedMessageReactionsAndPeers(accountPeerId: item.context.account.peerId, accountPeer: item.associatedData.accountPeer, message: item.message)
                if item.message.isRestricted(platform: "ios", contentSettings: item.context.currentContentSettings.with { $0 }) {
                    dateReactionsAndPeers = ([], [])
                }
                for attribute in item.message.attributes {
                    if let attribute = attribute as? EditedMessageAttribute {
                        edited = !attribute.isHidden
                    } else if let attribute = attribute as? ViewCountMessageAttribute {
                        viewCount = attribute.count
                    }
                }

                let dateText = stringForMessageTimestampStatus(context: item.context, message: EngineMessage(item.message), dateTimeFormat: item.presentationData.dateTimeFormat, nameDisplayOrder: item.presentationData.nameDisplayOrder, strings: strings, associatedData: item.associatedData)

                let statusType: ChatMessageDateAndStatusType?
                if case .customChatContents = item.associatedData.subject {
                    statusType = nil
                } else if item.message.timestamp == 0 {
                    statusType = nil
                } else {
                    switch position {
                    case .linear(_, .None), .linear(_, .Neighbour(true, _, _)):
                        if incoming {
                            statusType = .BubbleIncoming
                        } else {
                            if item.message.flags.contains(.Failed) {
                                statusType = .BubbleOutgoing(.Failed)
                            } else if (item.message.flags.isSending && !item.message.isSentOrAcknowledged) || item.attributes.updatingMedia != nil {
                                statusType = .BubbleOutgoing(.Sending)
                            } else {
                                statusType = .BubbleOutgoing(.Sent(read: item.read))
                            }
                        }
                    default:
                        statusType = nil
                    }
                }

                var statusSuggestedWidthAndContinue: (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation) -> Void))?
                let messageEffect = item.message.messageEffect(availableMessageEffects: item.associatedData.availableMessageEffects)
                if let statusType {
                    statusSuggestedWidthAndContinue = statusLayout(ChatMessageDateAndStatusNode.Arguments(
                        context: item.context,
                        presentationData: item.presentationData,
                        edited: edited,
                        impressionCount: viewCount,
                        dateText: dateText,
                        type: statusType,
                        layoutInput: .trailingContent(contentWidth: 1000.0, reactionSettings: shouldDisplayInlineDateReactions(message: EngineMessage(item.message), isPremium: item.associatedData.isPremium, forceInline: item.associatedData.forceInlineReactions) ? ChatMessageDateAndStatusNode.TrailingReactionSettings(displayInline: true, preferAdditionalInset: false) : nil),
                        constrainedSize: CGSize(width: contentWidth - sideInset * 2.0, height: .greatestFiniteMagnitude),
                        availableReactions: item.associatedData.availableReactions,
                        savedMessageTags: item.associatedData.savedMessageTags,
                        reactions: dateReactionsAndPeers.reactions,
                        reactionPeers: dateReactionsAndPeers.peers,
                        displayAllReactionPeers: item.message.id.peerId.namespace == Namespaces.Peer.CloudUser,
                        areReactionsTags: item.topMessage.areReactionsTags(accountPeerId: item.context.account.peerId),
                        areStarReactionsEnabled: item.associatedData.areStarReactionsEnabled,
                        messageEffect: messageEffect,
                        replyCount: 0,
                        starsCount: nil,
                        isPinned: false,
                        hasAutoremove: item.message.isSelfExpiring,
                        canViewReactionList: canViewMessageReactionList(message: EngineMessage(item.topMessage)),
                        animationCache: item.controllerInteraction.presentationContext.animationCache,
                        animationRenderer: item.controllerInteraction.presentationContext.animationRenderer
                    ))
                }

                let showAllTitle = strings.Music_ShowAll
                let (showAllMinWidth, showAllContinueLayout) = makeShowAllButtonLayout(contentWidth, 10.0, nil, false, showAllTitle, messageTheme.accentTextColor, false, false)

                var maxContentWidth = max(contentWidth, showAllMinWidth)
                if let statusSuggestedWidthAndContinue {
                    maxContentWidth = max(maxContentWidth, statusSuggestedWidthAndContinue.0 + sideInset * 2.0)
                }

                return (maxContentWidth, { [weak self] boundingWidth in
                    let innerWidth = boundingWidth - sideInset * 2.0

                    // The cover: a square across the whole bubble, with a photo's corners — the bubble's at the top,
                    // merged with the tracks below.
                    let coverWidth = boundingWidth - imageInsets.left - imageInsets.right
                    let coverFrame = CGRect(origin: CGPoint(x: imageInsets.left, y: imageInsets.top), size: CGSize(width: coverWidth, height: coverWidth))
                    var coverPosition = position
                    if case let .linear(top, _) = position {
                        coverPosition = .linear(top: top, bottom: .Neighbour(false, .text, .default))
                    }
                    let coverCorners = chatMessageBubbleImageContentCorners(relativeContentPosition: coverPosition, normalRadius: layoutConstants.image.defaultCornerRadius, mergedRadius: layoutConstants.image.mergedCornerRadius, mergedWithAnotherContentRadius: layoutConstants.image.contentMergedCornerRadius, layoutConstants: layoutConstants, chatPresentationData: item.presentationData)
                    let coverApply = makeCoverLayout(TransformImageArguments(corners: coverCorners, imageSize: coverFrame.size, boundingSize: coverFrame.size, intrinsicInsets: UIEdgeInsets(), emptyColor: messageTheme.mediaPlaceholderColor))

                    // The shade: the lower half of the cover (Figma Shade, 151 of 302).
                    let shadeHeight = floor(coverFrame.height / 2.0)
                    let shadeFrame = CGRect(origin: CGPoint(x: coverFrame.minX, y: coverFrame.maxY - shadeHeight), size: CGSize(width: coverFrame.width, height: shadeHeight))

                    // The row over it (Figma Audio Row): 16 pt padding, name over owner and count, the menu trailing.
                    let rowPadding: CGFloat = 16.0
                    let moreIconWidth: CGFloat = 17.0
                    let moreSize = CGSize(width: 44.0, height: 44.0)
                    let textX = coverFrame.minX + rowPadding
                    let textWidth = max(1.0, coverFrame.width - rowPadding * 2.0 - moreIconWidth)
                    let (titleLayout, titleApply) = makeTitleLayout(TextNodeLayoutArguments(attributedString: titleString, backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: textWidth, height: .greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
                    let (subtitleLayout, subtitleApply) = makeSubtitleLayout(TextNodeLayoutArguments(attributedString: subtitleString, backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: textWidth, height: .greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
                    let subtitleFrame = CGRect(origin: CGPoint(x: textX, y: coverFrame.maxY - rowPadding - subtitleLayout.size.height), size: subtitleLayout.size)
                    let titleFrame = CGRect(origin: CGPoint(x: textX, y: subtitleFrame.minY - titleLayout.size.height), size: titleLayout.size)
                    let rowCenterY = floor((titleFrame.minY + subtitleFrame.maxY) / 2.0)
                    let moreFrame = CGRect(origin: CGPoint(x: coverFrame.maxX - rowPadding - floor((moreIconWidth + moreSize.width) / 2.0), y: rowCenterY - moreSize.height / 2.0), size: moreSize)

                    // Track rows, unchanged: the Music row's round cover at 40 pt and the text 54 pt in.
                    let playSize: CGFloat = 44.0
                    let trackTextX = sideInset + playSize + 10.0

                    // Track rows: the Music row's round cover at 40 pt, aligned with Play.
                    let rowHeight: CGFloat = 52.0
                    let trackCoverSize: CGFloat = 40.0
                    var currentY = coverFrame.maxY + 8.0
                    var trackApplies: [(CGRect, CGRect, (() -> TextNode), CGRect, (() -> TextNode), CGRect, (() -> TextNode)?, CGRect, () -> Void, TrackInfo?)] = []
                    for i in 0 ..< previewTrackCount {
                        let (makeTrackTitle, makePerformer, makeDuration, makeCover) = trackLayouts[i]
                        let track = i < previewTracks.count ? previewTracks[i] : nil
                        let rowFrame = CGRect(origin: CGPoint(x: 0.0, y: currentY), size: CGSize(width: boundingWidth, height: track == nil ? 0.0 : rowHeight))
                        let coverFrame = CGRect(origin: CGPoint(x: sideInset + floor((playSize - trackCoverSize) / 2.0), y: floor((rowHeight - trackCoverSize) / 2.0)), size: CGSize(width: trackCoverSize, height: trackCoverSize))

                        var durationApply: (() -> TextNode)?
                        var durationFrame = CGRect()
                        var durationWidth: CGFloat = 0.0
                        if let duration = track?.duration {
                            let (durationLayout, apply) = makeDuration(TextNodeLayoutArguments(attributedString: NSAttributedString(string: durationString(duration), font: durationFont, textColor: messageTheme.fileDurationColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: innerWidth, height: .greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
                            durationApply = apply
                            durationWidth = durationLayout.size.width
                            durationFrame = CGRect(origin: CGPoint(x: sideInset + innerWidth - durationLayout.size.width, y: 0.0), size: durationLayout.size)
                        }
                        let trackTextWidth = max(1.0, sideInset + innerWidth - trackTextX - (durationWidth > 0.0 ? durationWidth + 8.0 : 0.0))
                        let (trackTitleLayout, trackTitleApply) = makeTrackTitle(TextNodeLayoutArguments(attributedString: NSAttributedString(string: track?.title ?? "", font: trackTitleFont, textColor: messageTheme.fileTitleColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: trackTextWidth, height: .greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
                        let performerText = track?.performer ?? strings.Music_UnknownArtist
                        let (performerLayout, performerApply) = makePerformer(TextNodeLayoutArguments(attributedString: NSAttributedString(string: track == nil ? "" : performerText, font: trackPerformerFont, textColor: messageTheme.fileDescriptionColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(1.0, sideInset + innerWidth - trackTextX), height: .greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
                        let trackTextHeight = trackTitleLayout.size.height + 1.0 + performerLayout.size.height
                        let trackTitleFrame = CGRect(origin: CGPoint(x: trackTextX, y: floor((rowHeight - trackTextHeight) / 2.0)), size: trackTitleLayout.size)
                        let performerFrame = CGRect(origin: CGPoint(x: trackTextX, y: trackTitleFrame.maxY + 1.0), size: performerLayout.size)
                        durationFrame.origin.y = trackTitleFrame.minY + floor((trackTitleLayout.size.height - durationFrame.height) / 2.0)

                        let coverApply = makeCover(TransformImageArguments(corners: ImageCorners(radius: trackCoverSize / 2.0), imageSize: CGSize(width: trackCoverSize, height: trackCoverSize), boundingSize: CGSize(width: trackCoverSize, height: trackCoverSize), intrinsicInsets: UIEdgeInsets(), emptyColor: theme.list.mediaPlaceholderColor))

                        trackApplies.append((rowFrame, trackTitleFrame, trackTitleApply, performerFrame, performerApply, durationFrame, durationApply, coverFrame, { let _ = coverApply() }, track))
                        if track != nil {
                            currentY += rowHeight
                        }
                    }

                    // Show All under a hairline, as the contact card's action.
                    var separatorFrame = CGRect()
                    var showAllFrame = CGRect()
                    var showAllApply: ((ListViewItemUpdateAnimation) -> ChatMessageAttachedContentButtonNode)?
                    if showsAll {
                        currentY += 4.0
                        separatorFrame = CGRect(origin: CGPoint(x: sideInset, y: currentY), size: CGSize(width: innerWidth, height: UIScreenPixel))
                        let (showAllSize, apply) = showAllContinueLayout(innerWidth, 33.0)
                        showAllApply = apply
                        showAllFrame = CGRect(origin: CGPoint(x: sideInset, y: currentY + 3.0), size: showAllSize)
                        currentY = showAllFrame.maxY
                    } else {
                        currentY += 4.0
                    }

                    let statusSizeAndApply = statusSuggestedWidthAndContinue?.1(innerWidth)
                    var layoutHeight = currentY
                    var statusFrame = CGRect()
                    if let statusSizeAndApply {
                        statusFrame = CGRect(origin: CGPoint(x: sideInset + innerWidth - statusSizeAndApply.0.width, y: currentY), size: statusSizeAndApply.0)
                        layoutHeight = statusFrame.maxY + layoutConstants.text.bubbleInsets.bottom
                    } else {
                        layoutHeight += layoutConstants.text.bubbleInsets.bottom
                    }
                    let layoutSize = CGSize(width: boundingWidth, height: layoutHeight)

                    return (layoutSize, { [weak self] animation, synchronousLoads, _ in
                        guard let self else {
                            return
                        }
                        self.item = item
                        self.playlistId = playlistData?.2.playlistId

                        // Cover, or the playlist screen's placeholder when the playlist has none.
                        animation.animator.updateFrame(layer: self.coverNode.layer, frame: coverFrame, completion: nil)
                        let coverResource = playlistData?.0.image.flatMap { largestImageRepresentation($0.representations) }?.resource
                        let coverResourceId = coverResource.flatMap { EngineMediaResource.Id($0.id) }
                        let placeholderColor = messageTheme.mediaPlaceholderColor
                        let coverKey = "\(coverResourceId?.stringRepresentation ?? "-") \(placeholderColor.rgb) \(placeholderColor.alpha)"
                        if coverKey != self.coverKey {
                            self.coverKey = coverKey
                            let placeholderIcon = generateTintedImage(image: UIImage(bundleImageName: "Music/PlaylistsTile"), color: .white)
                            let placeholder = coverDrawing(image: nil, placeholderColor: placeholderColor, placeholderIcon: placeholderIcon)
                            if let coverResourceId {
                                self.coverNode.setSignal(.single(placeholder)
                                |> then(item.context.engine.resources.data(id: coverResourceId, attemptSynchronously: synchronousLoads)
                                |> filter { $0.isComplete }
                                |> take(1)
                                |> map { data -> (TransformImageArguments) -> DrawingContext? in
                                    return coverDrawing(image: UIImage(contentsOfFile: data.path), placeholderColor: placeholderColor, placeholderIcon: placeholderIcon)
                                }), attemptSynchronously: synchronousLoads)
                            } else {
                                self.coverNode.setSignal(.single(placeholder), attemptSynchronously: synchronousLoads)
                            }
                        }
                        let _ = coverApply()

                        // The shade: the client's edge effect, blurred and darkened from clear to 64% black (Figma
                        // Shade), clipped to the cover's merged lower corners.
                        if self.shadeContainerView.superview == nil {
                            self.view.insertSubview(self.shadeContainerView, aboveSubview: self.coverNode.view)
                        }
                        animation.animator.updateFrame(layer: self.shadeContainerView.layer, frame: shadeFrame, completion: nil)
                        self.shadeContainerView.layer.cornerRadius = layoutConstants.image.contentMergedCornerRadius
                        self.shadeContainerView.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                        let shadeBounds = CGRect(origin: CGPoint(), size: shadeFrame.size)
                        self.shadeView.frame = shadeBounds
                        self.shadeView.update(content: .black, blur: true, alpha: 0.64, contentGradient: [EdgeEffectView.GradientStop(location: 0.0, alpha: 1.0), EdgeEffectView.GradientStop(location: 1.0, alpha: 0.0)], rect: shadeBounds, edge: .bottom, edgeSize: shadeBounds.height, transition: .immediate)

                        let _ = titleApply()
                        let _ = subtitleApply()
                        animation.animator.updateFrame(layer: self.titleNode.layer, frame: titleFrame, completion: nil)
                        animation.animator.updateFrame(layer: self.subtitleNode.layer, frame: subtitleFrame, completion: nil)

                        // Figma's ellipsis glyph: the Music sheet's own More dots, white over the shade.
                        self.moreButtonNode.setImage(generateTintedImage(image: UIImage(bundleImageName: "Music/More"), color: .white), for: .normal)
                        animation.animator.updateFrame(layer: self.moreButtonNode.layer, frame: moreFrame, completion: nil)

                        for i in 0 ..< self.trackNodes.count {
                            let trackNode = self.trackNodes[i]
                            let (rowFrame, trackTitleFrame, trackTitleApply, performerFrame, performerApply, durationFrame, durationApply, trackCoverFrame, coverApply, track) = trackApplies[i]
                            trackNode.isHidden = track == nil
                            animation.animator.updateFrame(layer: trackNode.layer, frame: rowFrame, completion: nil)
                            let _ = trackTitleApply()
                            let _ = performerApply()
                            trackNode.titleNode.frame = trackTitleFrame
                            trackNode.performerNode.frame = performerFrame
                            if let durationApply {
                                let _ = durationApply()
                                trackNode.durationNode.isHidden = false
                                trackNode.durationNode.frame = durationFrame
                            } else {
                                trackNode.durationNode.isHidden = true
                            }
                            trackNode.coverNode.frame = trackCoverFrame
                            coverApply()

                            let fileId = track?.file.fileId.id
                            trackNode.fileId = fileId
                            if let track, let webpage = playlistData?.1, fileId != previousTrackFileIds[i] {
                                let fileReference: FileMediaReference = .webPage(webPage: WebpageReference(webpage), media: track.file)
                                // The Music row's cover: no dimming, the player's placeholder note when there is no art.
                                trackNode.coverNode.setSignal(playerAlbumArt(engine: item.context.engine, fileReference: fileReference, albumArt: .init(thumbnailResource: ExternalMusicAlbumArtResource(file: fileReference, title: track.title, performer: track.performer ?? "", isThumbnail: true), fullSizeResource: ExternalMusicAlbumArtResource(file: fileReference, title: track.title, performer: track.performer ?? "", isThumbnail: false)), thumbnail: true, placeholderIconSize: 20.0, attemptSynchronously: synchronousLoads))
                            }
                        }

                        self.subscribeToPlayerIfNeeded(context: item.context)
                        self.updatePlayingIndicators(animated: false)

                        self.separatorNode.isHidden = !showsAll
                        self.showAllButtonNode.isHidden = !showsAll
                        if let showAllApply {
                            let _ = showAllApply(animation)
                            self.separatorNode.backgroundColor = messageTheme.accentTextColor.withMultipliedAlpha(0.2)
                            animation.animator.updateFrame(layer: self.separatorNode.layer, frame: separatorFrame, completion: nil)
                            animation.animator.updateFrame(layer: self.showAllButtonNode.layer, frame: showAllFrame, completion: nil)
                        }

                        if let statusSizeAndApply {
                            self.dateAndStatusNode.frame = statusFrame
                            if self.dateAndStatusNode.supernode == nil {
                                self.addSubnode(self.dateAndStatusNode)
                                statusSizeAndApply.1(.None)
                            } else {
                                statusSizeAndApply.1(animation)
                            }
                        } else if self.dateAndStatusNode.supernode != nil {
                            self.dateAndStatusNode.removeFromSupernode()
                        }

                        if messageEffect != nil {
                            self.dateAndStatusNode.pressed = { [weak self] in
                                guard let self, let item = self.item else {
                                    return
                                }
                                item.controllerInteraction.playMessageEffect(item.message)
                            }
                        } else {
                            self.dateAndStatusNode.pressed = nil
                        }
                    })
                })
            })
        }
    }

    private func perform(_ action: MusicSharedPlaylistAction) {
        guard let item = self.item, let playlistId = self.playlistId else {
            return
        }
        item.context.sharedContext.handleMusicSharedPlaylist(context: item.context, playlistId: playlistId, action: action)
    }

    @objc private func morePressed() {
        self.perform(.menu(sourceView: self.moreButtonNode.view))
    }

    @objc private func showAllPressed() {
        self.perform(.open)
    }

    @objc private func contentTap(_ recognizer: UITapGestureRecognizer) {
        guard case .ended = recognizer.state else {
            return
        }
        let point = recognizer.location(in: self.view)
        if self.coverNode.frame.contains(point) || self.titleNode.frame.union(self.subtitleNode.frame).contains(point) {
            self.perform(.open)
            return
        }
        for trackNode in self.trackNodes where !trackNode.isHidden {
            if trackNode.frame.contains(point), let fileId = trackNode.fileId {
                self.perform(.playTrack(fileId: fileId))
                return
            }
        }
    }

    override public func animateInsertion(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }

    override public func animateAdded(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }

    override public func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
    }

    override public func tapActionAtPoint(_ point: CGPoint, gesture: TapLongTapOrDoubleTapGesture, isEstimating: Bool) -> ChatMessageBubbleContentTapAction {
        if self.moreButtonNode.frame.contains(point) {
            return ChatMessageBubbleContentTapAction(content: .ignore)
        }
        if !self.showAllButtonNode.isHidden && self.showAllButtonNode.frame.contains(point) {
            return ChatMessageBubbleContentTapAction(content: .ignore)
        }
        if self.dateAndStatusNode.supernode != nil, let _ = self.dateAndStatusNode.hitTest(self.view.convert(point, to: self.dateAndStatusNode.view), with: nil) {
            return ChatMessageBubbleContentTapAction(content: .ignore)
        }
        return ChatMessageBubbleContentTapAction(content: .none)
    }

    override public func reactionTargetView(value: MessageReaction.Reaction) -> UIView? {
        if !self.dateAndStatusNode.isHidden {
            return self.dateAndStatusNode.reactionView(value: value)
        }
        return nil
    }

    override public func messageEffectTargetView() -> UIView? {
        if !self.dateAndStatusNode.isHidden {
            return self.dateAndStatusNode.messageEffectTargetView()
        }
        return nil
    }

    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.dateAndStatusNode.supernode != nil, let result = self.dateAndStatusNode.hitTest(self.view.convert(point, to: self.dateAndStatusNode.view), with: event) {
            return result
        }
        return super.hitTest(point, with: event)
    }
}

/// Music section concept: how many tracks of a group sent together a chat bubble shows; the rest open from Show All.
public let chatMessageMusicGroupPreviewCount = 5

/// Show All under the first tracks of a group of tracks sent together: the same hairline and button as the playlist
/// card's, opening every track of the group in a sheet. Carries the bubble's date when nothing follows it.
public class ChatMessageMusicGroupShowAllBubbleContentNode: ChatMessageBubbleContentNode {
    private let separatorNode: ASDisplayNode
    private let buttonNode: ChatMessageAttachedContentButtonNode
    private let dateAndStatusNode: ChatMessageDateAndStatusNode

    required public init(lottieSettings: LottieRenderingSettings) {
        self.separatorNode = ASDisplayNode()
        self.buttonNode = ChatMessageAttachedContentButtonNode()
        self.dateAndStatusNode = ChatMessageDateAndStatusNode()

        super.init(lottieSettings: lottieSettings)

        self.addSubnode(self.separatorNode)
        self.addSubnode(self.buttonNode)
        self.buttonNode.addTarget(self, action: #selector(self.buttonPressed), forControlEvents: .touchUpInside)

        self.dateAndStatusNode.reactionSelected = { [weak self] _, value, sourceView in
            guard let self, let item = self.item else {
                return
            }
            item.controllerInteraction.updateMessageReaction(item.topMessage, .reaction(value), false, sourceView)
        }
        self.dateAndStatusNode.openReactionPreview = { [weak self] gesture, sourceView, value in
            guard let self, let item = self.item else {
                gesture?.cancel()
                return
            }
            item.controllerInteraction.openMessageReactionContextMenu(item.topMessage, sourceView, gesture, value)
        }
    }

    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func accessibilityActivate() -> Bool {
        self.buttonPressed()
        return true
    }

    @objc private func buttonPressed() {
        guard let item = self.item else {
            return
        }
        var messages: [EngineRawMessage] = []
        for (message, _) in item.content {
            messages.append(message)
        }
        item.context.sharedContext.openMusicTrackGroup(context: item.context, messages: messages)
    }

    override public func asyncLayoutContent() -> (_ item: ChatMessageBubbleContentItem, _ layoutConstants: ChatMessageItemLayoutConstants, _ preparePosition: ChatMessageBubblePreparePosition, _ messageSelection: Bool?, _ constrainedSize: CGSize, _ avatarInset: CGFloat) -> (ChatMessageBubbleContentProperties, CGSize?, CGFloat, (CGSize, ChatMessageBubbleContentPosition) -> (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation, Bool, ListViewItemApply?) -> Void))) {
        let statusLayout = self.dateAndStatusNode.asyncLayout()
        let makeButtonLayout = ChatMessageAttachedContentButtonNode.asyncLayout(self.buttonNode)

        return { [weak self] item, layoutConstants, _, _, _, _ in
            var incoming = item.message.effectivelyIncoming(item.context.account.peerId)
            if let subject = item.associatedData.subject, case let .messageOptions(_, _, info) = subject, case .forward = info {
                incoming = false
            }
            let theme = item.presentationData.theme.theme
            let messageTheme = incoming ? theme.chat.message.incoming : theme.chat.message.outgoing
            let strings = item.presentationData.strings

            let contentProperties = ChatMessageBubbleContentProperties(hidesSimpleAuthorHeader: false, headerSpacing: 0.0, hidesBackground: .never, forceFullCorners: false, forceAlignment: .none)

            return (contentProperties, nil, CGFloat.greatestFiniteMagnitude, { [weak self] constrainedSize, position in
                let sideInset = layoutConstants.text.bubbleInsets.right
                let contentWidth = min(constrainedSize.width, 300.0)

                var edited = false
                if item.attributes.updatingMedia != nil {
                    edited = true
                }
                var viewCount: Int?
                var dateReactionsAndPeers = mergedMessageReactionsAndPeers(accountPeerId: item.context.account.peerId, accountPeer: item.associatedData.accountPeer, message: item.topMessage)
                if item.message.isRestricted(platform: "ios", contentSettings: item.context.currentContentSettings.with { $0 }) {
                    dateReactionsAndPeers = ([], [])
                }
                for attribute in item.message.attributes {
                    if let attribute = attribute as? EditedMessageAttribute {
                        edited = !attribute.isHidden
                    } else if let attribute = attribute as? ViewCountMessageAttribute {
                        viewCount = attribute.count
                    }
                }

                let dateText = stringForMessageTimestampStatus(context: item.context, message: EngineMessage(item.message), dateTimeFormat: item.presentationData.dateTimeFormat, nameDisplayOrder: item.presentationData.nameDisplayOrder, strings: strings, associatedData: item.associatedData)

                let statusType: ChatMessageDateAndStatusType?
                if case .customChatContents = item.associatedData.subject {
                    statusType = nil
                } else if item.message.timestamp == 0 {
                    statusType = nil
                } else {
                    switch position {
                    case .linear(_, .None), .linear(_, .Neighbour(true, _, _)):
                        if incoming {
                            statusType = .BubbleIncoming
                        } else {
                            if item.message.flags.contains(.Failed) {
                                statusType = .BubbleOutgoing(.Failed)
                            } else if (item.message.flags.isSending && !item.message.isSentOrAcknowledged) || item.attributes.updatingMedia != nil {
                                statusType = .BubbleOutgoing(.Sending)
                            } else {
                                statusType = .BubbleOutgoing(.Sent(read: item.read))
                            }
                        }
                    default:
                        statusType = nil
                    }
                }

                var statusSuggestedWidthAndContinue: (CGFloat, (CGFloat) -> (CGSize, (ListViewItemUpdateAnimation) -> Void))?
                if let statusType {
                    statusSuggestedWidthAndContinue = statusLayout(ChatMessageDateAndStatusNode.Arguments(
                        context: item.context,
                        presentationData: item.presentationData,
                        edited: edited,
                        impressionCount: viewCount,
                        dateText: dateText,
                        type: statusType,
                        layoutInput: .trailingContent(contentWidth: 1000.0, reactionSettings: shouldDisplayInlineDateReactions(message: EngineMessage(item.topMessage), isPremium: item.associatedData.isPremium, forceInline: item.associatedData.forceInlineReactions) ? ChatMessageDateAndStatusNode.TrailingReactionSettings(displayInline: true, preferAdditionalInset: false) : nil),
                        constrainedSize: CGSize(width: contentWidth - sideInset * 2.0, height: .greatestFiniteMagnitude),
                        availableReactions: item.associatedData.availableReactions,
                        savedMessageTags: item.associatedData.savedMessageTags,
                        reactions: dateReactionsAndPeers.reactions,
                        reactionPeers: dateReactionsAndPeers.peers,
                        displayAllReactionPeers: item.message.id.peerId.namespace == Namespaces.Peer.CloudUser,
                        areReactionsTags: item.topMessage.areReactionsTags(accountPeerId: item.context.account.peerId),
                        areStarReactionsEnabled: item.associatedData.areStarReactionsEnabled,
                        messageEffect: nil,
                        replyCount: 0,
                        starsCount: nil,
                        isPinned: false,
                        hasAutoremove: item.message.isSelfExpiring,
                        canViewReactionList: canViewMessageReactionList(message: EngineMessage(item.topMessage)),
                        animationCache: item.controllerInteraction.presentationContext.animationCache,
                        animationRenderer: item.controllerInteraction.presentationContext.animationRenderer
                    ))
                }

                let title = strings.Music_ShowAll
                let (buttonMinWidth, buttonContinueLayout) = makeButtonLayout(contentWidth, 10.0, nil, false, title, messageTheme.accentTextColor, false, false)

                var maxContentWidth = buttonMinWidth
                if let statusSuggestedWidthAndContinue {
                    maxContentWidth = max(maxContentWidth, statusSuggestedWidthAndContinue.0 + sideInset * 2.0)
                }

                return (maxContentWidth, { [weak self] boundingWidth in
                    let innerWidth = boundingWidth - sideInset * 2.0

                    // Under a hairline, as the playlist card's Show All.
                    var currentY: CGFloat = 4.0
                    let separatorFrame = CGRect(origin: CGPoint(x: sideInset, y: currentY), size: CGSize(width: innerWidth, height: UIScreenPixel))
                    let (buttonSize, buttonApply) = buttonContinueLayout(innerWidth, 33.0)
                    let buttonFrame = CGRect(origin: CGPoint(x: sideInset, y: currentY + 3.0), size: buttonSize)
                    currentY = buttonFrame.maxY

                    let statusSizeAndApply = statusSuggestedWidthAndContinue?.1(innerWidth)
                    var layoutHeight = currentY
                    var statusFrame = CGRect()
                    if let statusSizeAndApply {
                        statusFrame = CGRect(origin: CGPoint(x: sideInset + innerWidth - statusSizeAndApply.0.width, y: currentY), size: statusSizeAndApply.0)
                        layoutHeight = statusFrame.maxY + layoutConstants.text.bubbleInsets.bottom
                    } else {
                        layoutHeight += 4.0
                    }

                    return (CGSize(width: boundingWidth, height: layoutHeight), { [weak self] animation, _, _ in
                        guard let self else {
                            return
                        }
                        self.item = item

                        let _ = buttonApply(animation)
                        self.separatorNode.backgroundColor = messageTheme.accentTextColor.withMultipliedAlpha(0.2)
                        animation.animator.updateFrame(layer: self.separatorNode.layer, frame: separatorFrame, completion: nil)
                        animation.animator.updateFrame(layer: self.buttonNode.layer, frame: buttonFrame, completion: nil)

                        if let statusSizeAndApply {
                            self.dateAndStatusNode.frame = statusFrame
                            if self.dateAndStatusNode.supernode == nil {
                                self.addSubnode(self.dateAndStatusNode)
                                statusSizeAndApply.1(.None)
                            } else {
                                statusSizeAndApply.1(animation)
                            }
                        } else if self.dateAndStatusNode.supernode != nil {
                            self.dateAndStatusNode.removeFromSupernode()
                        }
                    })
                })
            })
        }
    }

    override public func animateInsertion(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }

    override public func animateAdded(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }

    override public func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false)
    }

    override public func tapActionAtPoint(_ point: CGPoint, gesture: TapLongTapOrDoubleTapGesture, isEstimating: Bool) -> ChatMessageBubbleContentTapAction {
        if self.buttonNode.frame.contains(point) {
            return ChatMessageBubbleContentTapAction(content: .ignore)
        }
        if self.dateAndStatusNode.supernode != nil, let _ = self.dateAndStatusNode.hitTest(self.view.convert(point, to: self.dateAndStatusNode.view), with: nil) {
            return ChatMessageBubbleContentTapAction(content: .ignore)
        }
        return ChatMessageBubbleContentTapAction(content: .none)
    }

    override public func reactionTargetView(value: MessageReaction.Reaction) -> UIView? {
        if !self.dateAndStatusNode.isHidden {
            return self.dateAndStatusNode.reactionView(value: value)
        }
        return nil
    }

    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.dateAndStatusNode.supernode != nil, let result = self.dateAndStatusNode.hitTest(self.view.convert(point, to: self.dateAndStatusNode.view), with: event) {
            return result
        }
        return super.hitTest(point, with: event)
    }
}
