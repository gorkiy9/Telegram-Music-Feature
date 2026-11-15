import Foundation
import UIKit
import AsyncDisplayKit
import Display
import ComponentFlow
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import ButtonComponent
import BundleIconComponent
import MultilineTextComponent
import DynamicIslandMask
import AccountContext
import TelegramCore
import AvatarNode
import AvatarVideoNode

/// Lies over the list and lets it take every touch except the author's line, which opens the author's profile.
private final class MusicPlaylistHeaderOverlayView: UIView {
    var interactiveViews: () -> [UIView] = { [] }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.isHidden || self.alpha < 0.01 {
            return nil
        }
        for view in self.interactiveViews() {
            if view.superview === self, !view.isHidden, view.alpha > 0.1, view.isUserInteractionEnabled, view.point(inside: self.convert(point, to: view), with: event) {
                return view
            }
        }
        return nil
    }
}

/// The status line under the name: plain text, or the playlist's author drawn as a forwarded message's author — a
/// small round avatar and the name in medium in the peer's name colour — followed by the rest of the line.
private final class MusicPlaylistSubtitleView: UIView {
    /// The forwarded header's 16 pt avatar beside 14 pt text, scaled to the status's 17 pt; 4 pt before the name.
    static let avatarSize: CGFloat = 20.0
    static let avatarSpacing: CGFloat = 4.0

    private let text = ComponentView<Empty>()
    private var avatarNode: AvatarNode?

    func update(context: AccountContext?, theme: PresentationTheme, peer: EnginePeer?, string: NSAttributedString, constrainedWidth: CGFloat) -> CGSize {
        let avatarInset: CGFloat = peer != nil && context != nil ? MusicPlaylistSubtitleView.avatarSize + MusicPlaylistSubtitleView.avatarSpacing : 0.0
        let textSize = self.text.update(
            transition: .immediate,
            component: AnyComponent(MultilineTextComponent(text: .plain(string), truncationType: .end, maximumNumberOfLines: 1)),
            environment: {},
            containerSize: CGSize(width: max(1.0, constrainedWidth - avatarInset), height: 100.0)
        )
        let height = max(textSize.height, avatarInset > 0.0 ? MusicPlaylistSubtitleView.avatarSize : 0.0)
        if let textView = self.text.view {
            if textView.superview == nil {
                self.addSubview(textView)
            }
            textView.frame = CGRect(origin: CGPoint(x: avatarInset, y: floor((height - textSize.height) / 2.0)), size: textSize)
        }
        if let context, let peer {
            let avatarNode: AvatarNode
            if let current = self.avatarNode {
                avatarNode = current
            } else {
                avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 9.0))
                self.avatarNode = avatarNode
                self.addSubview(avatarNode.view)
            }
            let avatarSize = CGSize(width: MusicPlaylistSubtitleView.avatarSize, height: MusicPlaylistSubtitleView.avatarSize)
            avatarNode.frame = CGRect(origin: CGPoint(x: 0.0, y: floor((height - avatarSize.height) / 2.0)), size: avatarSize)
            avatarNode.updateSize(size: avatarSize)
            if peer.smallProfileImage != nil {
                avatarNode.setPeerV2(context: context, theme: theme, peer: peer, displayDimensions: avatarSize)
            } else {
                avatarNode.setPeer(context: context, theme: theme, peer: peer, displayDimensions: avatarSize)
            }
        } else if let avatarNode = self.avatarNode {
            self.avatarNode = nil
            avatarNode.view.removeFromSuperview()
        }
        return CGSize(width: avatarInset + textSize.width, height: height)
    }
}

/// The top of a playlist, laid out as a profile's header (`PeerInfoHeaderNode`) with the same metrics and motion
/// (Figma Playlist / Default, / No Cover, / Avatar Small, / Avatar Hidden).
/// A cover opens expanded across the whole width with the name over its shade; any scroll up folds it into the round
/// avatar, and a pull of 32 pt at the top unfolds it again. Without a cover there is only the round avatar. Scrolling on,
/// the avatar shrinks to 0.55 and melts into the Dynamic Island through the profile's mask and blur, while the name and
/// status shrink into the bar. The header lies under the list and follows its offset.
final class MusicPlaylistHeaderView: UIView {
    /// The playlist's author with the rest of the status line (the track count), shown as a forwarded message's author.
    struct Author {
        let context: AccountContext
        let peer: EnginePeer
        let name: String
        let nameColor: UIColor
        let suffix: String
    }

    /// Figma Playlist/Name and Playlist/Status: the profile's title and status sizes.
    static let titleFont = Font.semibold(28.0)
    static let subtitleFont = Font.regular(17.0)
    /// A forwarded message's author name is medium.
    static let subtitleAuthorFont = Font.medium(17.0)
    static let avatarSize: CGFloat = 100.0
    private static let titleHeight: CGFloat = 34.0
    private static let subtitleHeight: CGFloat = 22.0
    /// The profile's: the round avatar 22 pt under the status bar, its scale and the title's at the end of the collapse.
    private static let avatarTopInset: CGFloat = 22.0
    private static let avatarMinScale: CGFloat = 0.55
    /// The bar's sizes: title 17 semibold, status 13 regular, as the client's navigation title.
    private static let titleMinScale: CGFloat = 17.0 / 28.0
    private static let subtitleMinScale: CGFloat = 13.0 / 17.0
    /// Where the collapsed name's centre lands, from the status bar's bottom: the name and status together are centred
    /// in the 44 pt bar, which starts 10 pt below it.
    private static let titleLockOffset: CGFloat = {
        let titleHeight = MusicPlaylistHeaderView.titleHeight * MusicPlaylistHeaderView.titleMinScale
        let subtitleHeight = MusicPlaylistHeaderView.subtitleHeight * MusicPlaylistHeaderView.subtitleMinScale
        let pairHeight = titleHeight + 1.0 + subtitleHeight
        return 10.0 + 22.0 - pairHeight * 0.5 + titleHeight * 0.5
    }()
    private static let titleMaxLockOffset: CGFloat = 7.0

    /// Clips the round avatar under a wide rounded edge 47 pt from the top, where the island takes it.
    private let clippingView = UIView()
    /// Placed at the avatar's centre with no size, as the profile's avatar list node.
    private let avatarContainer = UIView()
    private let maskedView = UIView()
    private let bottomCoverView = UIView()
    private let coverContainer = UIView()
    private let coverImageView = UIImageView()
    /// An emoji cover animated over its still frame, as a profile's emoji photo (`AvatarVideoNode`).
    private var coverEmojiNode: AvatarVideoNode?
    private let shadeView = UIImageView()
    private let maskNode = DynamicIslandMaskNode()
    private let topCoverNode = DynamicIslandBlurNode()

    /// The name and status in both of the profile's text states (`MultiScaleTextNode`): regular, centred and dark, and
    /// expanded, left-aligned and white over the cover. A fold moves them together and crossfades the states.
    private let regularTitle = ComponentView<Empty>()
    private let expandedTitle = ComponentView<Empty>()
    private let regularSubtitle = MusicPlaylistSubtitleView()
    private let expandedSubtitle = MusicPlaylistSubtitleView()
    /// The name and status, kept above the list and the bar's fade by the screen: they rise into the bar.
    let overlayView: UIView = MusicPlaylistHeaderOverlayView()
    /// Set while the status shows the author: a tap on it opens the author's profile.
    var authorPressed: (() -> Void)?
    /// False when the name at the bar's size would reach the bar's buttons: the bar then shows its own truncated title.
    private(set) var titleRisesIntoBar = false

    private var shadeImage: UIImage?
    private var placeholderTheme: PresentationTheme?
    private var placeholderImage: UIImage?

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.isUserInteractionEnabled = false
        if let overlayView = self.overlayView as? MusicPlaylistHeaderOverlayView {
            overlayView.interactiveViews = { [weak self] in
                guard let self else {
                    return []
                }
                return [self.regularSubtitle, self.expandedSubtitle]
            }
        }
        for subtitleView in [self.regularSubtitle, self.expandedSubtitle] {
            subtitleView.isUserInteractionEnabled = false
            subtitleView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.subtitleTapped)))
        }
        self.clippingView.clipsToBounds = true
        self.coverContainer.clipsToBounds = true
        self.coverImageView.contentMode = .scaleAspectFill
        self.coverImageView.clipsToBounds = true
        self.bottomCoverView.isHidden = true
        self.topCoverNode.isHidden = true

        self.addSubview(self.clippingView)
        self.clippingView.addSubview(self.avatarContainer)
        self.avatarContainer.addSubview(self.maskedView)
        self.maskedView.addSubview(self.bottomCoverView)
        self.maskedView.addSubview(self.coverContainer)
        self.coverContainer.addSubview(self.coverImageView)
        self.coverContainer.addSubview(self.shadeView)
        self.maskedView.addSubview(self.topCoverNode.view)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func subtitleTapped() {
        self.authorPressed?()
    }

    /// The height the header takes at rest: the list starts under it.
    static func height(width: CGFloat, statusBarHeight: CGFloat, isExpanded: Bool) -> CGFloat {
        if isExpanded {
            return width
        }
        // Avatar, 9 pt, the name and status 1 pt apart, then the profile's 16 pt.
        return statusBarHeight + avatarTopInset + avatarSize + 9.0 + titleHeight + 1.0 + subtitleHeight + 16.0
    }

    /// The bottom shade under the name (Figma "Shade"): 45% black over the cover's lower 200 pt.
    private static func makeShadeImage() -> UIImage? {
        return generateImage(CGSize(width: 1.0, height: 200.0), rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            let colors = [UIColor(white: 0.0, alpha: 0.0).cgColor, UIColor(white: 0.0, alpha: 0.45).cgColor] as CFArray
            var locations: [CGFloat] = [0.0, 1.0]
            if let gradient = CGGradient(colorsSpace: DeviceGraphicsContextSettings.shared.colorSpace, colors: colors, locations: &locations) {
                context.drawLinearGradient(gradient, start: CGPoint(), end: CGPoint(x: 0.0, y: size.height), options: [])
            }
        })
    }

    /// The round placeholder of a playlist without a cover: its hub tile's glyph on the media placeholder fill.
    private static func avatarPlaceholder(theme: PresentationTheme) -> UIImage? {
        let size = CGSize(width: avatarSize, height: avatarSize)
        let icon = generateTintedImage(image: UIImage(bundleImageName: "Music/PlaylistsTile"), color: theme.list.itemSecondaryTextColor)
        return generateImage(size, rotatedContext: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setFillColor(theme.list.mediaPlaceholderColor.cgColor)
            context.fill(CGRect(origin: CGPoint(), size: size))
            if let icon {
                let iconSize = CGSize(width: 48.0, height: 48.0)
                UIGraphicsPushContext(context)
                icon.draw(in: CGRect(origin: CGPoint(x: (size.width - iconSize.width) * 0.5, y: (size.height - iconSize.height) * 0.5), size: iconSize))
                UIGraphicsPopContext()
            }
        })
    }

    /// Values that follow the scroll are animated additively, as the profile's header does: a fold or unfold keeps
    /// playing while the next scroll steps move the same layers.
    private static func setPosition(_ layer: CALayer, _ position: CGPoint, transition: ContainedViewLayoutTransition) {
        let previous = layer.position
        layer.position = position
        if case let .animated(duration, curve) = transition, previous != position {
            layer.animatePosition(from: CGPoint(x: previous.x - position.x, y: previous.y - position.y), to: CGPoint(), duration: duration, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, additive: true)
        }
    }

    private static func setScale(_ layer: CALayer, _ scale: CGFloat, transition: ContainedViewLayoutTransition) {
        let previous = (layer.value(forKeyPath: "transform.scale") as? NSNumber).flatMap { CGFloat($0.doubleValue) } ?? 1.0
        layer.transform = CATransform3DMakeScale(scale, scale, 1.0)
        if case let .animated(duration, curve) = transition, previous != scale {
            layer.animateScale(from: previous - scale, to: 0.0, duration: duration, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, additive: true)
        }
    }

    /// `offset` is the list's: 0 at rest, negative while pulled down.
    func update(theme: PresentationTheme, title: String, subtitle: String, author: Author? = nil, cover: UIImage?, coverMarkup: (context: AccountContext, markup: TelegramMediaImage.EmojiMarkup)? = nil, isExpanded: Bool, size: CGSize, statusBarHeight: CGFloat, hasDynamicIsland: Bool, offset: CGFloat, transition: ContainedViewLayoutTransition) {
        let width = size.width
        let sideInset: CGFloat = 16.0
        let isExpanded = isExpanded && cover != nil

        let textSize = CGSize(width: width - sideInset * 2.0, height: 100.0)
        let text: (ComponentView<Empty>, String, UIFont, UIColor) -> CGSize = { view, string, font, color in
            return view.update(
                transition: .immediate,
                component: AnyComponent(MultilineTextComponent(text: .plain(NSAttributedString(string: string, font: font, textColor: color)), truncationType: .end, maximumNumberOfLines: 1)),
                environment: {},
                containerSize: textSize
            )
        }
        let titleSize = text(self.regularTitle, title, MusicPlaylistHeaderView.titleFont, theme.list.itemPrimaryTextColor)
        let expandedTitleSize = text(self.expandedTitle, title, MusicPlaylistHeaderView.titleFont, .white)
        let subtitleString: (UIColor, UIColor) -> NSAttributedString = { nameColor, color in
            guard let author else {
                return NSAttributedString(string: subtitle, font: MusicPlaylistHeaderView.subtitleFont, textColor: color)
            }
            let string = NSMutableAttributedString(string: author.name, font: MusicPlaylistHeaderView.subtitleAuthorFont, textColor: nameColor)
            string.append(NSAttributedString(string: author.suffix, font: MusicPlaylistHeaderView.subtitleFont, textColor: color))
            return string
        }
        self.regularSubtitle.isUserInteractionEnabled = author != nil
        self.expandedSubtitle.isUserInteractionEnabled = author != nil
        let subtitleSize = self.regularSubtitle.update(context: author?.context, theme: theme, peer: author?.peer, string: subtitleString(author?.nameColor ?? theme.list.itemSecondaryTextColor, theme.list.itemSecondaryTextColor), constrainedWidth: textSize.width)
        let expandedSubtitleSize = self.expandedSubtitle.update(context: author?.context, theme: theme, peer: author?.peer, string: subtitleString(.white, .white), constrainedWidth: textSize.width)

        if let cover {
            if self.coverImageView.image !== cover {
                self.coverImageView.image = cover
            }
        } else {
            if self.placeholderTheme !== theme {
                self.placeholderTheme = theme
                self.placeholderImage = MusicPlaylistHeaderView.avatarPlaceholder(theme: theme)
            }
            if self.coverImageView.image !== self.placeholderImage {
                self.coverImageView.image = self.placeholderImage
            }
        }
        if self.shadeImage == nil {
            self.shadeImage = MusicPlaylistHeaderView.makeShadeImage()
            self.shadeView.image = self.shadeImage
        }

        let avatarSize = MusicPlaylistHeaderView.avatarSize
        let avatarRestCenterY = statusBarHeight + MusicPlaylistHeaderView.avatarTopInset + avatarSize * 0.5

        // The name's collapse, as the profile's: it rises with the content until it locks under the status bar.
        let titleRestCenterY = avatarRestCenterY + avatarSize * 0.5 + 9.0 + MusicPlaylistHeaderView.titleHeight * 0.5
        let titleCollapseOffset = titleRestCenterY - statusBarHeight - MusicPlaylistHeaderView.titleLockOffset
        let titleCollapseFraction = isExpanded ? 0.0 : max(0.0, min(1.0, offset / titleCollapseOffset))

        // The avatar: a square across the width while expanded, stretched from its centre by a pull; otherwise a circle
        // moving with the content, shrinking with the name.
        let avatarCenter: CGPoint
        let coverSize: CGSize
        let coverScale: CGFloat
        if isExpanded {
            avatarCenter = CGPoint(x: width * 0.5, y: width * 0.5 - offset * 0.5)
            coverSize = CGSize(width: width, height: width)
            coverScale = 1.0 + max(0.0, -offset / width)
        } else {
            let avatarOffset = titleCollapseFraction * MusicPlaylistHeaderView.titleMaxLockOffset + 10.0 * titleCollapseFraction
            avatarCenter = CGPoint(x: width * 0.5, y: -offset + avatarOffset + avatarRestCenterY)
            coverSize = CGSize(width: avatarSize, height: avatarSize)
            coverScale = 1.0 * (1.0 - titleCollapseFraction) + MusicPlaylistHeaderView.avatarMinScale * titleCollapseFraction
        }

        let clipOffset: CGFloat = !isExpanded && hasDynamicIsland ? 47.0 : 0.0
        self.clippingView.frame = CGRect(origin: CGPoint(x: 0.0, y: clipOffset), size: CGSize(width: width, height: 1000.0))
        self.clippingView.layer.sublayerTransform = CATransform3DMakeTranslation(0.0, -clipOffset, 0.0)
        ContainedViewLayoutTransition.animated(duration: 0.15, curve: .easeInOut).updateCornerRadius(layer: self.clippingView.layer, cornerRadius: clipOffset > 0.0 ? width / 2.5 : 0.0)

        MusicPlaylistHeaderView.setPosition(self.avatarContainer.layer, avatarCenter, transition: transition)
        self.avatarContainer.bounds = CGRect()
        transition.updateBounds(layer: self.coverContainer.layer, bounds: CGRect(origin: CGPoint(), size: coverSize))
        transition.updatePosition(layer: self.coverContainer.layer, position: CGPoint())
        transition.updateCornerRadius(layer: self.coverContainer.layer, cornerRadius: isExpanded ? 0.0 : avatarSize * 0.5)
        MusicPlaylistHeaderView.setScale(self.coverContainer.layer, coverScale, transition: transition)
        transition.updateFrame(view: self.coverImageView, frame: CGRect(origin: CGPoint(), size: coverSize))
        if cover != nil, let coverMarkup {
            // Laid out once at the expanded size and scaled to the cover, so a fold shrinks it with the container.
            let emojiSize = CGSize(width: width, height: width)
            let emojiNode: AvatarVideoNode
            if let current = self.coverEmojiNode {
                emojiNode = current
            } else {
                emojiNode = AvatarVideoNode(context: coverMarkup.context)
                self.coverEmojiNode = emojiNode
                self.coverContainer.insertSubview(emojiNode.view, aboveSubview: self.coverImageView)
            }
            emojiNode.update(markup: coverMarkup.markup, size: emojiSize)
            emojiNode.updateLayout(size: emojiSize, cornerRadius: 0.0, transition: .immediate)
            emojiNode.bounds = CGRect(origin: CGPoint(), size: emojiSize)
            transition.updatePosition(node: emojiNode, position: CGPoint(x: coverSize.width * 0.5, y: coverSize.height * 0.5))
            transition.updateTransformScale(node: emojiNode, scale: coverSize.width / emojiSize.width)
            emojiNode.updateVisibility(true)
        } else if let emojiNode = self.coverEmojiNode {
            self.coverEmojiNode = nil
            emojiNode.view.removeFromSuperview()
        }
        transition.updateFrame(view: self.shadeView, frame: CGRect(x: 0.0, y: coverSize.height - 200.0, width: coverSize.width, height: 200.0))
        transition.updateAlpha(layer: self.shadeView.layer, alpha: isExpanded ? 1.0 : 0.0)

        // The profile's Dynamic Island mask: fixed to the top of the screen, it turns the avatar into the island.
        if hasDynamicIsland && statusBarHeight > 0.0 {
            let maskValue = isExpanded ? 0.0 : max(0.0, min(1.0, offset / 120.0))
            self.maskedView.mask = self.maskNode.view
            if maskValue > 0.03 {
                self.bottomCoverView.isHidden = false
                self.topCoverNode.isHidden = false
                self.maskNode.backgroundColor = .clear
            } else {
                self.bottomCoverView.isHidden = true
                self.topCoverNode.isHidden = true
                self.maskNode.backgroundColor = .white
            }
            self.topCoverNode.update(maskValue)
            self.maskNode.update(maskValue)
            self.bottomCoverView.backgroundColor = UIColor(white: 0.0, alpha: maskValue)

            var maskOffset: CGFloat = 0.0
            if offset < 0.0 {
                maskOffset -= offset
            }
            let maskPosition = CGPoint(x: 0.0, y: -avatarCenter.y + 48.0 + 85.0 + maskOffset)
            let maskBounds = CGRect(origin: CGPoint(), size: CGSize(width: 171.0, height: 171.0))
            // The mask stays fixed to the screen while the avatar moves, so it moves back by the same additive amount.
            MusicPlaylistHeaderView.setPosition(self.maskNode.layer, maskPosition, transition: transition)
            self.maskNode.bounds = maskBounds
            MusicPlaylistHeaderView.setPosition(self.bottomCoverView.layer, maskPosition, transition: transition)
            self.bottomCoverView.bounds = maskBounds
            MusicPlaylistHeaderView.setPosition(self.topCoverNode.layer, maskPosition, transition: transition)
            self.topCoverNode.bounds = maskBounds
            // Expanded, the mask grows over the whole cover, as the profile's does.
            let maskScale: CGFloat = isExpanded ? width / 100.0 : 1.0
            MusicPlaylistHeaderView.setScale(self.maskNode.layer, maskScale, transition: transition)
            MusicPlaylistHeaderView.setScale(self.bottomCoverView.layer, maskScale, transition: transition)
            MusicPlaylistHeaderView.setScale(self.topCoverNode.layer, maskScale, transition: transition)
            transition.updateAnchorPoint(layer: self.maskNode.layer, anchorPoint: CGPoint(x: 0.5, y: isExpanded ? 0.37 : 0.5))
        } else {
            self.maskedView.mask = nil
            self.bottomCoverView.isHidden = true
            self.topCoverNode.isHidden = true
        }

        // The name and status.
        var titleCenter: CGPoint
        var subtitleCenter: CGPoint
        var titleScale: CGFloat = 1.0
        var subtitleScale: CGFloat = 1.0
        var titleAlpha: CGFloat = 1.0
        var subtitleAlpha: CGFloat = 1.0
        if isExpanded {
            let coverBottom = avatarCenter.y + coverSize.height * coverScale * 0.5
            subtitleCenter = CGPoint(x: sideInset + expandedSubtitleSize.width * 0.5, y: coverBottom - 16.0 - MusicPlaylistHeaderView.subtitleHeight * 0.5)
            titleCenter = CGPoint(x: sideInset + expandedTitleSize.width * 0.5, y: subtitleCenter.y - MusicPlaylistHeaderView.subtitleHeight * 0.5 - 4.0 - MusicPlaylistHeaderView.titleHeight * 0.5)
            self.titleRisesIntoBar = false
        } else {
            titleScale = 1.0 - (1.0 - MusicPlaylistHeaderView.titleMinScale) * titleCollapseFraction
            subtitleScale = 1.0 - (1.0 - MusicPlaylistHeaderView.subtitleMinScale) * titleCollapseFraction
            let titleCenterY = titleRestCenterY - min(titleCollapseOffset, offset)
            titleCenter = CGPoint(x: width * 0.5, y: titleCenterY)
            subtitleCenter = CGPoint(x: width * 0.5, y: titleCenterY + MusicPlaylistHeaderView.titleHeight * 0.5 * titleScale + 1.0 + MusicPlaylistHeaderView.subtitleHeight * 0.5 * subtitleScale)

            // Between the back button and the share and more pair.
            let barTitleWidth = width - 2.0 * (16.0 + 104.0 + 8.0)
            self.titleRisesIntoBar = titleSize.width * MusicPlaylistHeaderView.titleMinScale <= barTitleWidth
            if !self.titleRisesIntoBar {
                titleScale = 1.0
                subtitleScale = 1.0
                titleCenter.y = titleRestCenterY - offset
                subtitleCenter.y = titleCenter.y + MusicPlaylistHeaderView.titleHeight * 0.5 + 1.0 + MusicPlaylistHeaderView.subtitleHeight * 0.5
                let barBottom = statusBarHeight + 10.0 + 44.0
                titleAlpha = max(0.0, min(1.0, (titleCenter.y - MusicPlaylistHeaderView.titleHeight * 0.5 - barBottom) / 20.0))
                subtitleAlpha = max(0.0, min(1.0, (subtitleCenter.y - MusicPlaylistHeaderView.subtitleHeight * 0.5 - barBottom) / 20.0))
            } else if subtitleSize.width * MusicPlaylistHeaderView.subtitleMinScale > barTitleWidth {
                subtitleAlpha = 1.0 - titleCollapseFraction
            }
        }

        self.overlayView.frame = CGRect(origin: CGPoint(), size: size)
        // Both states sit at the current state's place, the profile's way: the regular one by its centre, the expanded
        // one by its leading edge.
        let place: (ComponentView<Empty>, CGSize, CGPoint, CGFloat, CGFloat) -> Void = { view, size, center, scale, alpha in
            guard let view = view.view else {
                return
            }
            if view.superview == nil {
                self.overlayView.addSubview(view)
            }
            view.bounds = CGRect(origin: CGPoint(), size: size)
            MusicPlaylistHeaderView.setPosition(view.layer, center, transition: transition)
            MusicPlaylistHeaderView.setScale(view.layer, scale, transition: transition)
            transition.updateAlpha(layer: view.layer, alpha: alpha)
        }
        let leadingX = sideInset
        let regularTitleCenter = isExpanded ? CGPoint(x: leadingX + titleSize.width * 0.5, y: titleCenter.y) : titleCenter
        let expandedTitleCenter = isExpanded ? titleCenter : CGPoint(x: titleCenter.x - (titleSize.width - expandedTitleSize.width) * 0.5 * titleScale, y: titleCenter.y)
        let regularSubtitleCenter = isExpanded ? CGPoint(x: leadingX + subtitleSize.width * 0.5, y: subtitleCenter.y) : subtitleCenter
        let expandedSubtitleCenter = isExpanded ? subtitleCenter : CGPoint(x: subtitleCenter.x - (subtitleSize.width - expandedSubtitleSize.width) * 0.5 * subtitleScale, y: subtitleCenter.y)

        self.overlayView.frame = CGRect(origin: CGPoint(), size: size)
        place(self.regularTitle, titleSize, regularTitleCenter, titleScale, isExpanded ? 0.0 : titleAlpha)
        place(self.expandedTitle, expandedTitleSize, expandedTitleCenter, titleScale, isExpanded ? titleAlpha : 0.0)
        let placeView: (UIView, CGSize, CGPoint, CGFloat, CGFloat) -> Void = { view, size, center, scale, alpha in
            if view.superview == nil {
                self.overlayView.addSubview(view)
            }
            view.bounds = CGRect(origin: CGPoint(), size: size)
            MusicPlaylistHeaderView.setPosition(view.layer, center, transition: transition)
            MusicPlaylistHeaderView.setScale(view.layer, scale, transition: transition)
            transition.updateAlpha(layer: view.layer, alpha: alpha)
        }
        placeView(self.regularSubtitle, subtitleSize, regularSubtitleCenter, subtitleScale, isExpanded ? 0.0 : subtitleAlpha)
        placeView(self.expandedSubtitle, expandedSubtitleSize, expandedSubtitleCenter, subtitleScale, isExpanded ? subtitleAlpha : 0.0)
    }
}

/// Empty room above the playlist's rows while its cover is expanded.
final class MusicPlaylistSpacerItem: ListViewItem {
    let height: CGFloat
    let selectable: Bool = false

    init(height: CGFloat) {
        self.height = height
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            Queue.mainQueue().async {
                let node = ListViewItemNode(layerBacked: true, rotated: false, seeThrough: false)
                node.contentSize = CGSize(width: params.width, height: self.height)
                node.insets = UIEdgeInsets()
                completion(node, {
                    return (nil, { _ in })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            completion(ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: self.height), insets: UIEdgeInsets()), { _ in })
        }
    }

    var neighborDescriptor: AnyEquatable {
        return .noNeighborInfluence
    }
}

/// The playlist's description under its header (Figma Playlist Info Card): the profile's labeled value row on the plain fill.
final class MusicPlaylistInfoItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let label: String
    let text: String
    let sectionId: ItemListSectionId

    let selectable: Bool = false

    init(presentationData: ItemListPresentationData, label: String, text: String, sectionId: ItemListSectionId) {
        self.presentationData = presentationData
        self.label = label
        self.text = text
        self.sectionId = sectionId
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = MusicPlaylistInfoItemNode()
            let (layout, apply) = node.asyncLayout()(self, params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? MusicPlaylistInfoItemNode else {
                assertionFailure()
                return
            }
            let makeLayout = nodeValue.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params)
                Queue.mainQueue().async {
                    completion(layout, { _ in
                        apply()
                    })
                }
            }
        }
    }
}

final class MusicPlaylistInfoItemNode: ListViewItemNode {
    private let labelNode = TextNode()
    private let textNode = TextNode()

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)
        self.addSubnode(self.labelNode)
        self.addSubnode(self.textNode)
    }

    func asyncLayout() -> (_ item: MusicPlaylistInfoItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, () -> Void) {
        let makeLabelLayout = TextNode.asyncLayout(self.labelNode)
        let makeTextLayout = TextNode.asyncLayout(self.textNode)
        return { [weak self] item, params in
            let theme = item.presentationData.theme
            let sideInset: CGFloat = 16.0
            let verticalInset: CGFloat = 15.0
            let constrainedSize = CGSize(width: params.width - params.leftInset - params.rightInset - sideInset * 2.0, height: CGFloat.greatestFiniteMagnitude)
            let (labelLayout, labelApply) = makeLabelLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.label, font: Font.regular(item.presentationData.fontSize.itemListBaseLabelFontSize), textColor: theme.list.itemSecondaryTextColor), maximumNumberOfLines: 1, truncationType: .end, constrainedSize: constrainedSize))
            let (textLayout, textApply) = makeTextLayout(TextNodeLayoutArguments(attributedString: NSAttributedString(string: item.text, font: Font.regular(item.presentationData.fontSize.itemListBaseFontSize), textColor: theme.list.itemPrimaryTextColor), maximumNumberOfLines: 0, truncationType: .end, constrainedSize: constrainedSize))
            let labelSpacing: CGFloat = 3.0
            let height = verticalInset + labelLayout.size.height + labelSpacing + textLayout.size.height + verticalInset
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets())
            return (layout, { [weak self] in
                guard let self else {
                    return
                }
                let _ = labelApply()
                let _ = textApply()
                let x = params.leftInset + sideInset
                self.labelNode.frame = CGRect(origin: CGPoint(x: x, y: verticalInset), size: labelLayout.size)
                self.textNode.frame = CGRect(origin: CGPoint(x: x, y: verticalInset + labelLayout.size.height + labelSpacing), size: textLayout.size)
            })
        }
    }
}

/// The playlist's actions (Figma Playlist "Buttons"): Play wide and tinted, then Shuffle, Favorite and Search as round glass buttons;
/// an empty playlist has Add Tracks in Play's place and Favorite only.
final class MusicPlaylistActionsItem: ListViewItem, ItemListItem {
    enum Action {
        case play
        case shuffle
        case favorite
        case search
        case addTracks
        /// The track picker's Add: every track of the playlist.
        case addAll
    }

    static let height: CGFloat = 54.0

    let theme: PresentationTheme
    let isEmpty: Bool
    let isFavorite: Bool
    let playTitle: String
    let addTracksTitle: String
    /// Set on a playlist opened inside the track picker: one full-width Add button for all its tracks (Figma Playlists / Add Track 176:29747).
    let pickerAddTitle: String?
    let topInset: CGFloat
    let bottomInset: CGFloat
    let sectionId: ItemListSectionId
    let action: (Action) -> Void

    let selectable: Bool = false

    init(theme: PresentationTheme, isEmpty: Bool, isFavorite: Bool, playTitle: String, addTracksTitle: String, pickerAddTitle: String? = nil, topInset: CGFloat, bottomInset: CGFloat, sectionId: ItemListSectionId, action: @escaping (Action) -> Void) {
        self.theme = theme
        self.isEmpty = isEmpty
        self.isFavorite = isFavorite
        self.playTitle = playTitle
        self.addTracksTitle = addTracksTitle
        self.pickerAddTitle = pickerAddTitle
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.sectionId = sectionId
        self.action = action
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            Queue.mainQueue().async {
                let node = MusicPlaylistActionsItemNode()
                let (layout, apply) = node.asyncLayout()(self, params)
                node.contentSize = layout.contentSize
                node.insets = layout.insets
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? MusicPlaylistActionsItemNode else {
                assertionFailure()
                return
            }
            let (layout, apply) = nodeValue.asyncLayout()(self, params)
            completion(layout, { _ in
                apply()
            })
        }
    }
}

final class MusicPlaylistActionsItemNode: ListViewItemNode {
    private let mainButton = ComponentView<Empty>()
    private let shuffleButton = ComponentView<Empty>()
    private let favoriteButton = ComponentView<Empty>()
    private let searchButton = ComponentView<Empty>()
    private var item: MusicPlaylistActionsItem?
    /// The favorite toggle bounces like the player's: on the icon its tap brings in (star ↔ crossed star), once the
    /// library's new state reaches the list; a tap that changes nothing bounces the current icon.
    private var favoriteContentId: AnyHashable?
    private var pendingFavoriteBounce = false

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)
    }

    /// The system Liquid Glass button's 17 pt semibold title with its glyph 8 pt before it: the glyphs' canvases carry about 5 pt of margin.
    private static func titleContent(icon: String, iconSize: CGSize, title: String, color: UIColor) -> AnyComponentWithIdentity<Empty> {
        return AnyComponentWithIdentity(id: AnyHashable(title), component: AnyComponent(HStack([
            AnyComponentWithIdentity(id: 0, component: AnyComponent(BundleIconComponent(name: icon, tintColor: color, maxSize: iconSize))),
            AnyComponentWithIdentity(id: 1, component: AnyComponent(Text(text: title, font: Font.semibold(17.0), color: color)))
        ], spacing: 3.0)))
    }

    private func updateButton(_ view: ComponentView<Empty>, background: ButtonComponent.Background, content: AnyComponentWithIdentity<Empty>, frame: CGRect, action: MusicPlaylistActionsItem.Action) {
        let _ = view.update(
            transition: .immediate,
            component: AnyComponent(ButtonComponent(
                background: background,
                content: content,
                action: { [weak self, weak view] in
                    if action == .play || action == .shuffle {
                        MusicButtonIconAnimation.bounce(in: view?.view)
                    } else if action == .favorite {
                        self?.favoriteTapped()
                    }
                    self?.item?.action(action)
                }
            )),
            environment: {},
            containerSize: frame.size
        )
        if let buttonView = view.view {
            if buttonView.superview == nil {
                self.view.addSubview(buttonView)
            }
            buttonView.isHidden = false
            buttonView.frame = frame
        }
    }

    private func favoriteTapped() {
        self.pendingFavoriteBounce = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: { [weak self] in
            guard let self, self.pendingFavoriteBounce else {
                return
            }
            self.pendingFavoriteBounce = false
            MusicButtonIconAnimation.bounce(in: self.favoriteButton.view)
        })
    }

    /// Add at the same 17 pt semibold title and 24 pt glyph as every other button of the section, across the full width.
    private func layoutPickerButton(item: MusicPlaylistActionsItem, title: String, leftX: CGFloat, rightX: CGFloat, height: CGFloat) {
        let theme = item.theme
        let accent = theme.list.itemCheckColors.fillColor
        let accentForeground = theme.list.itemCheckColors.foregroundColor
        let accentBackground = ButtonComponent.Background(style: .actualGlass, color: accent, foreground: accentForeground, pressedColor: accent, cornerRadius: height * 0.5)
        self.updateButton(self.mainButton, background: accentBackground, content: MusicPlaylistActionsItemNode.titleContent(icon: "Chat/Context Menu/Add", iconSize: CGSize(width: 24.0, height: 24.0), title: title, color: accentForeground), frame: CGRect(x: leftX, y: 0.0, width: rightX - leftX, height: height), action: .addAll)
        self.searchButton.view?.isHidden = true
        self.shuffleButton.view?.isHidden = true
        self.favoriteButton.view?.isHidden = true
    }

    func asyncLayout() -> (_ item: MusicPlaylistActionsItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, () -> Void) {
        return { [weak self] item, params in
            let height = MusicPlaylistActionsItem.height
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets(top: item.topInset, left: 0.0, bottom: item.bottomInset, right: 0.0))
            return (layout, { [weak self] in
                guard let self else {
                    return
                }
                self.item = item
                let theme = item.theme
                let sideInset: CGFloat = 16.0
                let spacing: CGFloat = 8.0
                let leftX = params.leftInset + sideInset
                let rightX = params.width - params.rightInset - sideInset
                if let pickerAddTitle = item.pickerAddTitle {
                    self.layoutPickerButton(item: item, title: pickerAddTitle, leftX: leftX, rightX: rightX, height: height)
                    return
                }
                let roundCount: CGFloat = item.isEmpty ? 1.0 : 3.0
                let mainWidth = rightX - leftX - roundCount * (height + spacing)

                let accent = theme.list.itemCheckColors.fillColor
                let accentForeground = theme.list.itemCheckColors.foregroundColor
                let accentBackground = ButtonComponent.Background(style: .actualGlass, color: accent, foreground: accentForeground, pressedColor: accent, cornerRadius: height * 0.5)
                // A near-clear colour keeps the plain glass; its brightness tells the button the theme.
                let glass = theme.overallDarkAppearance ? UIColor(white: 0.0, alpha: 0.01) : UIColor(white: 1.0, alpha: 0.01)
                let foreground = theme.list.itemPrimaryTextColor
                let glassBackground = ButtonComponent.Background(style: .actualGlass, color: glass, foreground: foreground, pressedColor: glass, cornerRadius: height * 0.5)

                let mainContent: AnyComponentWithIdentity<Empty>
                if item.isEmpty {
                    mainContent = MusicPlaylistActionsItemNode.titleContent(icon: "Chat/Context Menu/Add", iconSize: CGSize(width: 24.0, height: 24.0), title: item.addTracksTitle, color: accentForeground)
                } else {
                    mainContent = MusicPlaylistActionsItemNode.titleContent(icon: "GlobalMusicPlayer/Play", iconSize: CGSize(width: 24.0, height: 24.0), title: item.playTitle, color: accentForeground)
                }
                self.updateButton(self.mainButton, background: accentBackground, content: mainContent, frame: CGRect(x: leftX, y: 0.0, width: mainWidth, height: height), action: item.isEmpty ? .addTracks : .play)

                let roundSize = CGSize(width: height, height: height)
                let iconContent: (String, CGFloat, UIColor) -> AnyComponentWithIdentity<Empty> = { name, size, color in
                    return AnyComponentWithIdentity(id: AnyHashable("\(name) \(color)"), component: AnyComponent(BundleIconComponent(name: name, tintColor: color, maxSize: CGSize(width: size, height: size))))
                }
                var x = leftX + mainWidth + spacing
                if item.isEmpty {
                    self.shuffleButton.view?.isHidden = true
                } else {
                    self.updateButton(self.shuffleButton, background: glassBackground, content: iconContent("Music/Shuffle", 24.0, foreground), frame: CGRect(origin: CGPoint(x: x, y: 0.0), size: roundSize), action: .shuffle)
                    x += height + spacing
                }
                // As the player's Favorites toggle: a favorite playlist shows the crossed star (the tap removes it) in the
                // accent colour on accent-tinted glass.
                let accentGlass = theme.list.itemAccentColor.withMultipliedAlpha(0.1)
                let favoriteBackground = item.isFavorite ? ButtonComponent.Background(style: .actualGlass, color: accentGlass, foreground: theme.list.itemAccentColor, pressedColor: accentGlass, cornerRadius: height * 0.5) : glassBackground
                let favoriteContent = iconContent(item.isFavorite ? "Music/StarSlash" : "Music/Star", 24.0, item.isFavorite ? theme.list.itemAccentColor : foreground)
                let favoriteChanged = self.favoriteContentId != nil && self.favoriteContentId != favoriteContent.id
                self.favoriteContentId = favoriteContent.id
                self.updateButton(self.favoriteButton, background: favoriteBackground, content: favoriteContent, frame: CGRect(origin: CGPoint(x: x, y: 0.0), size: roundSize), action: .favorite)
                if favoriteChanged && self.pendingFavoriteBounce {
                    self.pendingFavoriteBounce = false
                    MusicButtonIconAnimation.bounce(in: self.favoriteButton.view)
                }
                x += height + spacing
                if item.isEmpty {
                    self.searchButton.view?.isHidden = true
                } else {
                    self.updateButton(self.searchButton, background: glassBackground, content: iconContent("Chat/Context Menu/Search", 24.0, foreground), frame: CGRect(origin: CGPoint(x: x, y: 0.0), size: roundSize), action: .search)
                }
            })
        }
    }

    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.4)
    }

    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
