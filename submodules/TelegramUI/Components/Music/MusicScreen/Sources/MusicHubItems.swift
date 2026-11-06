import Foundation
import UIKit
import AsyncDisplayKit
import Display
import ComponentFlow
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import ManagedAnimationNode
import GradientBackground
import GlassBackgroundComponent
import ButtonComponent
import BundleIconComponent

/// One tile of the hub (Figma Music / Default, "Section Item"): a colour that drifts under Liquid Glass,
/// the section's animated glyph and its title.
struct MusicHubTile: Equatable {
    enum Kind: Hashable {
        case songs
        case artists
        case playlists
        case favorites
    }

    let kind: Kind
    let title: String
    let animation: String
    let playToken: Int
}

/// The tile palettes of the Figma "Section Item" fills: no theme colour carries them.
private struct MusicHubTilePalette {
    /// Ends of the diagonal gradient under the glass.
    let start: UIColor
    let end: UIColor
    /// The soft light that drifts over the gradient.
    let glow: UIColor
    /// Glyph and title.
    let foreground: UIColor

    static func palette(kind: MusicHubTile.Kind, isDark: Bool) -> MusicHubTilePalette {
        switch kind {
        case .songs:
            return isDark
                ? MusicHubTilePalette(start: UIColor(rgb: 0x5c1a86), end: UIColor(rgb: 0x2d0a45), glow: UIColor(rgb: 0xa24bdc), foreground: UIColor(rgb: 0xe7c2ff))
                : MusicHubTilePalette(start: UIColor(rgb: 0xd98cf2), end: UIColor(rgb: 0xf1c9fb), glow: UIColor(rgb: 0xeeceff), foreground: UIColor(rgb: 0x7700b4))
        case .artists:
            return isDark
                ? MusicHubTilePalette(start: UIColor(rgb: 0x1c3a8a), end: UIColor(rgb: 0x0b1a45), glow: UIColor(rgb: 0x4a74e0), foreground: UIColor(rgb: 0xc2d4ff))
                : MusicHubTilePalette(start: UIColor(rgb: 0x9fb9f3), end: UIColor(rgb: 0xd5e0fb), glow: UIColor(rgb: 0xdae2ff), foreground: UIColor(rgb: 0x0068d1))
        case .playlists:
            return isDark
                ? MusicHubTilePalette(start: UIColor(rgb: 0x7a4410), end: UIColor(rgb: 0x3d2006), glow: UIColor(rgb: 0xd48a2e), foreground: UIColor(rgb: 0xffdcae))
                : MusicHubTilePalette(start: UIColor(rgb: 0xf9c27f), end: UIColor(rgb: 0xfde4b8), glow: UIColor(rgb: 0xffedd8), foreground: UIColor(rgb: 0xaf6b00))
        case .favorites:
            return isDark
                ? MusicHubTilePalette(start: UIColor(rgb: 0x8a1c1f), end: UIColor(rgb: 0x450b0c), glow: UIColor(rgb: 0xe0484c), foreground: UIColor(rgb: 0xffc6c7))
                : MusicHubTilePalette(start: UIColor(rgb: 0xff7d80), end: UIColor(rgb: 0xffb3b4), glow: UIColor(rgb: 0xffc6c7), foreground: UIColor(rgb: 0xaf0a00))
        }
    }
}

private final class MusicHubTileView: UIView, UIGestureRecognizerDelegate {
    static let cornerRadius: CGFloat = 26.0

    /// Everything the press tilts; the tile itself keeps the frame its parent gives it.
    private let pressView = UIView()
    private let gradientNode = GradientBackgroundNode(adjustSaturation: false)
    /// Light on the rim: a radial gradient seen only through a stroke of the outline.
    private let edgeLightLayer = CAGradientLayer()
    private let edgeLightMask = CAShapeLayer()
    private var isPressed = false
    private var isIconPlaying = false
    private var isFlowing = false
    /// Bumped whenever flowing stops, so a step scheduled before cannot start a second chain.
    private var flowGeneration = 0
    private let glassView = GlassBackgroundView()
    private let titleNode = ImmediateTextNode()
    private var animationNode: SimpleAnimationNode?

    private var tile: MusicHubTile?
    private var isDark: Bool?
    private var phase: Double = 0.0
    /// Index of the tile in the grid: picks its own step length and the corner each colour starts in.
    private var flowIndex: Int = 0
    var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.pressView.isUserInteractionEnabled = false
        self.pressView.clipsToBounds = true
        self.pressView.layer.cornerRadius = MusicHubTileView.cornerRadius
        self.pressView.layer.cornerCurve = .continuous
        self.addSubview(self.pressView)

        self.gradientNode.isUserInteractionEnabled = false
        self.pressView.addSubview(self.gradientNode.view)

        self.pressView.addSubview(self.glassView)
        self.glassView.contentView.addSubview(self.titleNode.view)
        self.titleNode.isUserInteractionEnabled = false

        self.edgeLightLayer.type = .radial
        self.edgeLightLayer.colors = [UIColor(white: 1.0, alpha: 0.95).cgColor, UIColor(white: 1.0, alpha: 0.35).cgColor, UIColor(white: 1.0, alpha: 0.0).cgColor]
        self.edgeLightLayer.locations = [0.0, 0.45, 1.0]
        self.edgeLightLayer.opacity = 0.0
        self.edgeLightLayer.compositingFilter = "overlayBlendMode"
        self.edgeLightMask.fillColor = nil
        self.edgeLightMask.strokeColor = UIColor.white.cgColor
        self.edgeLightMask.lineWidth = 3.0
        self.edgeLightLayer.mask = self.edgeLightMask
        self.pressView.layer.addSublayer(self.edgeLightLayer)

        let press = UILongPressGestureRecognizer(target: self, action: #selector(self.pressGesture(_:)))
        press.minimumPressDuration = 0.0
        press.allowableMovement = .greatestFiniteMagnitude
        press.delegate = self
        self.addGestureRecognizer(press)
    }

    /// Recognizes on touch down and keeps the touch, so the list's pan cannot start while the tile is held.
    @objc private func pressGesture(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began, .changed:
            // Leaving the tile releases it; coming back presses it again.
            self.setPressed(self.bounds.contains(point), at: point)
        case .ended:
            let wasPressed = self.isPressed
            self.setPressed(false, at: nil)
            if wasPressed, self.bounds.contains(point) {
                self.tapped()
            }
        default:
            self.setPressed(false, at: nil)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    /// Any pan above the tile (the list's scroll) waits for the press, which only ends when the finger lifts.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return otherGestureRecognizer is UIPanGestureRecognizer
    }

    /// Pressing sinks the tile: it shrinks and tilts away under the finger, and the rim lights up on the side that rises, following the finger.
    private func setPressed(_ pressed: Bool, at point: CGPoint?) {
        let size = self.bounds.size
        guard size.width > 0.0 else {
            return
        }
        let wasPressed = self.isPressed
        self.isPressed = pressed

        var transform = CATransform3DIdentity
        var lightOpacity: Float = 0.0
        if pressed, let point {
            let dx = max(-1.0, min(1.0, (point.x - size.width / 2.0) / (size.width / 2.0)))
            let dy = max(-1.0, min(1.0, (point.y - size.height / 2.0) / (size.height / 2.0)))
            let maxAngle: CGFloat = 10.0 * .pi / 180.0
            transform.m34 = -1.0 / 500.0
            transform = CATransform3DRotate(transform, -dy * maxAngle, 1.0, 0.0, 0.0)
            transform = CATransform3DRotate(transform, dx * maxAngle, 0.0, 1.0, 0.0)
            transform = CATransform3DScale(transform, 0.95, 0.95, 1.0)
            lightOpacity = 1.0

            // The raised side faces the light: the opposite of the finger, on the rim.
            let light = CGPoint(x: 0.5 - dx * 0.5, y: 0.5 - dy * 0.5)
            CATransaction.begin()
            CATransaction.setAnimationDuration(wasPressed ? 0.12 : 0.0)
            self.edgeLightLayer.startPoint = light
            self.edgeLightLayer.endPoint = CGPoint(x: light.x + 0.75, y: light.y + 0.75 * size.width / size.height)
            CATransaction.commit()
        }

        let transition: ContainedViewLayoutTransition = pressed && wasPressed ? .animated(duration: 0.12, curve: .easeInOut) : .animated(duration: pressed ? 0.2 : 0.45, curve: .spring)
        transition.updateTransform(layer: self.pressView.layer, transform: transform, beginWithCurrentState: true)
        transition.updateAlpha(layer: self.edgeLightLayer, alpha: CGFloat(lightOpacity))
        if pressed && !wasPressed {
            HapticFeedback().impact(.light)
            // Played on touch down: the section opens on release and pushes the hub away before a later start could be seen.
            self.playIcon()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if self.window != nil {
            self.startFlowing()
        } else {
            self.isFlowing = false
            self.flowGeneration += 1
        }
    }

    private func playIcon() {
        guard let animationNode = self.animationNode, !self.isIconPlaying else {
            return
        }
        self.isIconPlaying = true
        animationNode.reset(immediately: true)
        animationNode.play()
        // Once per press: sliding back onto the tile must not restart it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.isIconPlaying = false
        }
    }

    private func tapped() {
        self.action?()
    }

    func update(tile: MusicHubTile, index: Int, phase: Double, theme: PresentationTheme, size: CGSize) {
        let isDark = theme.overallDarkAppearance
        let palette = MusicHubTilePalette.palette(kind: tile.kind, isDark: isDark)
        let previousTile = self.tile
        let previousIsDark = self.isDark
        self.tile = tile
        self.phase = phase
        self.flowIndex = index

        if previousTile?.kind != tile.kind || self.isDark != isDark {
            self.isDark = isDark
            // Four points of the client's wallpaper gradient, from the tile's palette.
            // Rotated per tile, so no two tiles show the same picture at the same phase.
            let colors = [palette.start, palette.glow, palette.end, palette.start.mixedWith(palette.glow, alpha: 0.5)]
            let shift = index % colors.count
            self.gradientNode.updateColors(colors: Array(colors[shift...] + colors[..<shift]))
        }

        self.pressView.bounds = CGRect(origin: CGPoint(), size: size)
        self.pressView.center = CGPoint(x: size.width / 2.0, y: size.height / 2.0)
        self.edgeLightLayer.frame = CGRect(origin: CGPoint(), size: size)
        self.edgeLightMask.frame = CGRect(origin: CGPoint(), size: size)
        self.edgeLightMask.path = UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: size).insetBy(dx: 0.75, dy: 0.75), cornerRadius: MusicHubTileView.cornerRadius - 0.75).cgPath

        if self.gradientNode.frame.size != size {
            self.gradientNode.frame = CGRect(origin: CGPoint(), size: size)
            self.gradientNode.updateLayout(size: size, transition: .immediate, extendAnimation: false, backwards: false, completion: {})
        }

        self.glassView.frame = CGRect(origin: CGPoint(), size: size)
        self.glassView.update(size: size, cornerRadius: MusicHubTileView.cornerRadius, isDark: isDark, tintColor: GlassBackgroundView.TintColor(kind: .custom(style: .clear, color: palette.start.withAlphaComponent(isDark ? 0.25 : 0.35))), isInteractive: true, transition: .immediate)

        self.titleNode.attributedText = NSAttributedString(string: tile.title, font: Font.semibold(17.0), textColor: palette.foreground)
        let titleSize = self.titleNode.updateLayout(CGSize(width: size.width - 32.0, height: 40.0))
        self.titleNode.frame = CGRect(origin: CGPoint(x: 16.0, y: floor(size.height - 26.0 - titleSize.height / 2.0)), size: titleSize)

        // The glyph's 40 pt canvas centred on the Figma icon frame (48 pt at 8, 8).
        let animationSize = CGSize(width: 40.0, height: 40.0)
        let animationNode: SimpleAnimationNode
        if let current = self.animationNode, previousTile?.animation == tile.animation, previousTile?.kind == tile.kind, previousIsDark == isDark {
            animationNode = current
            if previousTile?.playToken != tile.playToken {
                animationNode.reset(immediately: true)
                animationNode.play()
            }
        } else {
            self.animationNode?.removeFromSupernode()
            animationNode = SimpleAnimationNode(animationName: tile.animation, replaceColors: [0xffffff: palette.foreground.argb & 0xffffff], size: animationSize, lottieSettings: .noAccountFallback)
            animationNode.isUserInteractionEnabled = false
            animationNode.seekToEnd(immediately: true)
            self.animationNode = animationNode
            self.glassView.contentView.addSubview(animationNode.view)
        }
        animationNode.frame = CGRect(origin: CGPoint(x: 12.0, y: 12.0), size: animationSize)

        self.startFlowing()
    }

    /// The wallpaper gradient steps through its eight phases one after another, so the colours flow under the glass without a pause. Each tile starts after its own delay.
    private func startFlowing() {
        guard !self.isFlowing, self.window != nil, self.bounds.width > 0.0 else {
            return
        }
        self.isFlowing = true
        self.flowGeneration += 1
        let generation = self.flowGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + self.phase.truncatingRemainder(dividingBy: 3.0)) { [weak self] in
            self?.flowStep(generation: generation)
        }
    }

    /// One phase every 3 s on a fixed clock, not on the animation's completion, which can fire at once and spin the gradient.
    private func flowStep(generation: Int) {
        guard self.isFlowing, generation == self.flowGeneration, self.window != nil else {
            return
        }
        // Steps of different length per tile keep the tiles drifting apart instead of moving in step.
        let stepDurations: [Double] = [3.0, 3.7, 2.6, 4.3]
        let stepDuration = stepDurations[self.flowIndex % stepDurations.count]
        self.gradientNode.animateEvent(transition: .animated(duration: stepDuration, curve: .linear), extendAnimation: false, backwards: false, completion: {})
        DispatchQueue.main.asyncAfter(deadline: .now() + stepDuration) { [weak self] in
            self?.flowStep(generation: generation)
        }
    }
}

/// The hub's four sections as a 2 × 2 grid of tiles.
final class MusicHubTilesItem: ListViewItem, ItemListItem {
    static let tileHeight: CGFloat = 120.0
    static let spacing: CGFloat = 8.0

    let theme: PresentationTheme
    let tiles: [MusicHubTile]
    let sideInset: CGFloat
    let topInset: CGFloat
    /// Space under the tiles, for lists that have no Play and Shuffle row to carry it (the track picker).
    let bottomInset: CGFloat
    let sectionId: ItemListSectionId
    let action: (MusicHubTile.Kind) -> Void

    let selectable: Bool = false

    init(theme: PresentationTheme, tiles: [MusicHubTile], sideInset: CGFloat, topInset: CGFloat, bottomInset: CGFloat = 0.0, sectionId: ItemListSectionId, action: @escaping (MusicHubTile.Kind) -> Void) {
        self.theme = theme
        self.tiles = tiles
        self.sideInset = sideInset
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.sectionId = sectionId
        self.action = action
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            Queue.mainQueue().async {
                let node = MusicHubTilesItemNode()
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
            guard let nodeValue = node() as? MusicHubTilesItemNode else {
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

final class MusicHubTilesItemNode: ListViewItemNode {
    private var tileViews: [MusicHubTile.Kind: MusicHubTileView] = [:]
    private var item: MusicHubTilesItem?

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)
    }

    func asyncLayout() -> (_ item: MusicHubTilesItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, () -> Void) {
        return { [weak self] item, params in
            let rows = CGFloat((item.tiles.count + 1) / 2)
            let height = rows * MusicHubTilesItem.tileHeight + max(0.0, rows - 1.0) * MusicHubTilesItem.spacing
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: UIEdgeInsets(top: item.topInset, left: 0.0, bottom: item.bottomInset, right: 0.0))
            return (layout, { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item
                let sideInset = params.leftInset + item.sideInset
                let fullWidth = params.width - sideInset - params.rightInset - item.sideInset
                // A lone tile spans the whole row (Favorites); otherwise two columns.
                let tileWidth = item.tiles.count == 1 ? fullWidth : floor((fullWidth - MusicHubTilesItem.spacing) / 2.0)
                let tileSize = CGSize(width: tileWidth, height: MusicHubTilesItem.tileHeight)
                var validKinds = Set<MusicHubTile.Kind>()
                for (index, tile) in item.tiles.enumerated() {
                    validKinds.insert(tile.kind)
                    let tileView: MusicHubTileView
                    if let current = strongSelf.tileViews[tile.kind] {
                        tileView = current
                    } else {
                        tileView = MusicHubTileView()
                        strongSelf.tileViews[tile.kind] = tileView
                        strongSelf.view.addSubview(tileView)
                    }
                    tileView.action = { [weak strongSelf] in
                        strongSelf?.item?.action(tile.kind)
                    }
                    // Columns fill first, as in Figma: Tracks over Playlists, Artists over Favorites.
                    let column = CGFloat(index % 2)
                    let row = CGFloat(index / 2)
                    tileView.frame = CGRect(origin: CGPoint(x: sideInset + column * (tileWidth + MusicHubTilesItem.spacing), y: row * (MusicHubTilesItem.tileHeight + MusicHubTilesItem.spacing)), size: tileSize)
                    tileView.update(tile: tile, index: index, phase: Double(index) * 2.3, theme: item.theme, size: tileSize)
                }
                for (kind, view) in strongSelf.tileViews where !validKinds.contains(kind) {
                    view.removeFromSuperview()
                    strongSelf.tileViews[kind] = nil
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

/// Play and Shuffle as a pair of system Liquid Glass buttons (Figma "Buttons"): Play tinted with the accent.
final class MusicPlaybackButtonsItem: ListViewItem, ItemListItem {
    static let height: CGFloat = 54.0

    let theme: PresentationTheme
    let playTitle: String
    let shuffleTitle: String
    let sideInset: CGFloat
    let topInset: CGFloat
    /// Space down to the first track; it belongs to the buttons so that a letter header under them sits below it.
    let bottomInset: CGFloat
    let sectionId: ItemListSectionId
    let action: (_ shuffled: Bool) -> Void

    let selectable: Bool = false

    init(theme: PresentationTheme, playTitle: String, shuffleTitle: String, sideInset: CGFloat, topInset: CGFloat, bottomInset: CGFloat, sectionId: ItemListSectionId, action: @escaping (_ shuffled: Bool) -> Void) {
        self.theme = theme
        self.playTitle = playTitle
        self.shuffleTitle = shuffleTitle
        self.sideInset = sideInset
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.sectionId = sectionId
        self.action = action
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            Queue.mainQueue().async {
                let node = MusicPlaybackButtonsItemNode()
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
            guard let nodeValue = node() as? MusicPlaybackButtonsItemNode else {
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

final class MusicPlaybackButtonsItemNode: ListViewItemNode {
    private let playButton = ComponentView<Empty>()
    private let shuffleButton = ComponentView<Empty>()
    private var item: MusicPlaybackButtonsItem?

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)
    }

    /// Figma "Button - Liquid Glass - Text": 17 pt semibold title with a 24 pt glyph (same metrics as every other button of the section).
    static let titleFont = Font.semibold(17.0)

    private static func content(icon: String, iconSize: CGSize, title: String, color: UIColor, spacing: CGFloat) -> AnyComponentWithIdentity<Empty> {
        return AnyComponentWithIdentity(id: AnyHashable(title), component: AnyComponent(HStack([
            AnyComponentWithIdentity(id: 0, component: AnyComponent(BundleIconComponent(name: icon, tintColor: color, maxSize: iconSize))),
            AnyComponentWithIdentity(id: 1, component: AnyComponent(Text(text: title, font: MusicPlaybackButtonsItemNode.titleFont, color: color)))
        ], spacing: spacing)))
    }

    func asyncLayout() -> (_ item: MusicPlaybackButtonsItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, () -> Void) {
        return { [weak self] item, params in
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: MusicPlaybackButtonsItem.height), insets: UIEdgeInsets(top: item.topInset, left: 0.0, bottom: item.bottomInset, right: 0.0))
            return (layout, { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item
                let theme = item.theme
                let spacing: CGFloat = 8.0
                let sideInset = params.leftInset + item.sideInset
                let buttonWidth = floor((params.width - sideInset - params.rightInset - item.sideInset - spacing) / 2.0)
                let buttonSize = CGSize(width: buttonWidth, height: MusicPlaybackButtonsItem.height)

                // Play is the player's filled triangle: its 60 pt canvas scaled to 23 pt gives a 13 × 15 pt glyph with 5 pt margins.
                let accent = theme.list.itemCheckColors.fillColor
                let playForeground = theme.list.itemCheckColors.foregroundColor
                let _ = strongSelf.playButton.update(
                    transition: .immediate,
                    component: AnyComponent(ButtonComponent(
                        background: ButtonComponent.Background(style: .actualGlass, color: accent, foreground: playForeground, pressedColor: accent, cornerRadius: buttonSize.height * 0.5),
                        content: MusicPlaybackButtonsItemNode.content(icon: "GlobalMusicPlayer/Play", iconSize: CGSize(width: 24.0, height: 24.0), title: item.playTitle, color: playForeground, spacing: 3.0),
                        action: { [weak strongSelf] in
                            strongSelf?.item?.action(false)
                        }
                    )),
                    environment: {},
                    containerSize: buttonSize
                )
                // A near-clear colour keeps the plain panel glass; its brightness tells the button the theme.
                let shuffleGlass = theme.overallDarkAppearance ? UIColor(white: 0.0, alpha: 0.01) : UIColor(white: 1.0, alpha: 0.01)
                let shuffleForeground = theme.list.itemPrimaryTextColor
                let _ = strongSelf.shuffleButton.update(
                    transition: .immediate,
                    component: AnyComponent(ButtonComponent(
                        background: ButtonComponent.Background(style: .actualGlass, color: shuffleGlass, foreground: shuffleForeground, pressedColor: shuffleGlass, cornerRadius: buttonSize.height * 0.5),
                        content: MusicPlaybackButtonsItemNode.content(icon: "Music/Shuffle", iconSize: CGSize(width: 24.0, height: 24.0), title: item.shuffleTitle, color: shuffleForeground, spacing: 4.0),
                        action: { [weak strongSelf] in
                            strongSelf?.item?.action(true)
                        }
                    )),
                    environment: {},
                    containerSize: buttonSize
                )
                if let view = strongSelf.playButton.view {
                    if view.superview == nil {
                        strongSelf.view.addSubview(view)
                    }
                    view.frame = CGRect(origin: CGPoint(x: sideInset, y: 0.0), size: buttonSize)
                }
                if let view = strongSelf.shuffleButton.view {
                    if view.superview == nil {
                        strongSelf.view.addSubview(view)
                    }
                    view.frame = CGRect(origin: CGPoint(x: sideInset + buttonWidth + spacing, y: 0.0), size: buttonSize)
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

/// Add Tracks on the playlist edit screen: one full-width accent Liquid Glass button (Figma "Button - Liquid Glass - Text").
final class MusicAddTracksButtonItem: ListViewItem, ItemListItem {
    static let height: CGFloat = 54.0

    let theme: PresentationTheme
    let title: String
    let topInset: CGFloat
    let bottomInset: CGFloat
    let sectionId: ItemListSectionId
    let action: () -> Void

    let selectable: Bool = false

    init(theme: PresentationTheme, title: String, topInset: CGFloat, bottomInset: CGFloat, sectionId: ItemListSectionId, action: @escaping () -> Void) {
        self.theme = theme
        self.title = title
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.sectionId = sectionId
        self.action = action
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            Queue.mainQueue().async {
                let node = MusicAddTracksButtonItemNode()
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
            guard let nodeValue = node() as? MusicAddTracksButtonItemNode else {
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

final class MusicAddTracksButtonItemNode: ListViewItemNode {
    private let button = ComponentView<Empty>()
    private var item: MusicAddTracksButtonItem?

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)
    }

    func asyncLayout() -> (_ item: MusicAddTracksButtonItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, () -> Void) {
        return { [weak self] item, params in
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: MusicAddTracksButtonItem.height), insets: UIEdgeInsets(top: item.topInset, left: 0.0, bottom: item.bottomInset, right: 0.0))
            return (layout, { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item
                let sideInset: CGFloat = 0.0
                let buttonSize = CGSize(width: params.width - params.leftInset - params.rightInset - sideInset * 2.0, height: MusicAddTracksButtonItem.height)
                let accent = item.theme.list.itemCheckColors.fillColor
                let foreground = item.theme.list.itemCheckColors.foregroundColor
                let content = AnyComponentWithIdentity(id: AnyHashable(item.title), component: AnyComponent(HStack([
                    AnyComponentWithIdentity(id: 0, component: AnyComponent(BundleIconComponent(name: "Chat/Context Menu/Add", tintColor: foreground, maxSize: CGSize(width: 24.0, height: 24.0)))),
                    AnyComponentWithIdentity(id: 1, component: AnyComponent(Text(text: item.title, font: Font.semibold(17.0), color: foreground)))
                ], spacing: 3.0)))
                let _ = strongSelf.button.update(
                    transition: .immediate,
                    component: AnyComponent(ButtonComponent(
                        background: ButtonComponent.Background(style: .actualGlass, color: accent, foreground: foreground, pressedColor: accent, cornerRadius: buttonSize.height * 0.5),
                        content: content,
                        action: { [weak strongSelf] in
                            strongSelf?.item?.action()
                        }
                    )),
                    environment: {},
                    containerSize: buttonSize
                )
                if let view = strongSelf.button.view {
                    if view.superview == nil {
                        strongSelf.view.addSubview(view)
                    }
                    view.frame = CGRect(origin: CGPoint(x: params.leftInset + sideInset, y: 0.0), size: buttonSize)
                }
            })
        }
    }
}

/// A switch row as one Liquid Glass capsule over the plain background (Figma Music Settings, "Row"):
/// the grouped card it replaces needed the darker grouped fill around it.
final class MusicGlassSwitchItem: ListViewItem, ItemListItem {
    static let height: CGFloat = 52.0

    let presentationData: ItemListPresentationData
    let title: String
    let value: Bool
    let sideInset: CGFloat
    let topInset: CGFloat
    let sectionId: ItemListSectionId
    let updated: (Bool) -> Void

    let selectable: Bool = false

    init(presentationData: ItemListPresentationData, title: String, value: Bool, sideInset: CGFloat, topInset: CGFloat, sectionId: ItemListSectionId, updated: @escaping (Bool) -> Void) {
        self.presentationData = presentationData
        self.title = title
        self.value = value
        self.sideInset = sideInset
        self.topInset = topInset
        self.sectionId = sectionId
        self.updated = updated
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            Queue.mainQueue().async {
                let node = MusicGlassSwitchItemNode()
                let (layout, apply) = node.asyncLayout()(self, params)
                node.contentSize = layout.contentSize
                node.insets = layout.insets
                completion(node, {
                    return (nil, { _ in apply(false) })
                })
            }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let nodeValue = node() as? MusicGlassSwitchItemNode else {
                assertionFailure()
                return
            }
            let (layout, apply) = nodeValue.asyncLayout()(self, params)
            completion(layout, { _ in
                apply(animation.isAnimated)
            })
        }
    }
}

final class MusicGlassSwitchItemNode: ListViewItemNode {
    private let glassView = GlassBackgroundView()
    private let titleNode = ImmediateTextNode()
    private let switchNode = SwitchNode()
    private var item: MusicGlassSwitchItem?

    init() {
        super.init(layerBacked: false, rotated: false, seeThrough: false)

        self.view.addSubview(self.glassView)
        self.titleNode.isUserInteractionEnabled = false
        self.titleNode.maximumNumberOfLines = 1
        self.titleNode.truncationMode = .byTruncatingTail
        self.glassView.contentView.addSubview(self.titleNode.view)
        self.glassView.contentView.addSubview(self.switchNode.view)

        self.isAccessibilityElement = true
        self.accessibilityTraits = .button

        self.switchNode.valueUpdated = { [weak self] value in
            self?.item?.updated(value)
        }
    }

    override func accessibilityActivate() -> Bool {
        guard let item = self.item else {
            return false
        }
        let value = !self.switchNode.isOn
        self.switchNode.setOn(value, animated: true)
        item.updated(value)
        return true
    }

    func asyncLayout() -> (_ item: MusicGlassSwitchItem, _ params: ListViewItemLayoutParams) -> (ListViewItemNodeLayout, (Bool) -> Void) {
        return { [weak self] item, params in
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: MusicGlassSwitchItem.height), insets: UIEdgeInsets(top: item.topInset, left: 0.0, bottom: 0.0, right: 0.0))
            return (layout, { [weak self] animated in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.item = item
                let theme = item.presentationData.theme
                let size = CGSize(width: params.width - params.leftInset - params.rightInset - item.sideInset * 2.0, height: MusicGlassSwitchItem.height)
                strongSelf.glassView.frame = CGRect(origin: CGPoint(x: params.leftInset + item.sideInset, y: 0.0), size: size)
                strongSelf.glassView.update(size: size, cornerRadius: size.height * 0.5, isDark: theme.overallDarkAppearance, tintColor: GlassBackgroundView.TintColor(kind: .panel), transition: .immediate)

                strongSelf.switchNode.frameColor = theme.list.itemSwitchColors.frameColor
                strongSelf.switchNode.contentColor = theme.list.itemSwitchColors.contentColor
                strongSelf.switchNode.handleColor = theme.list.itemSwitchColors.handleColor
                if let switchView = strongSelf.switchNode.view as? UISwitch {
                    if strongSelf.switchNode.bounds.width.isZero {
                        switchView.sizeToFit()
                    }
                    let switchSize = switchView.bounds.size
                    // The switch keeps the 15 pt trailing inset of the system switch row.
                    strongSelf.switchNode.frame = CGRect(origin: CGPoint(x: size.width - switchSize.width - 15.0, y: floor((size.height - switchSize.height) / 2.0)), size: switchSize)
                    if switchView.isOn != item.value {
                        switchView.setOn(item.value, animated: animated)
                    }
                }

                strongSelf.titleNode.attributedText = NSAttributedString(string: item.title, font: Font.regular(item.presentationData.fontSize.itemListBaseFontSize), textColor: theme.list.itemPrimaryTextColor)
                let titleSize = strongSelf.titleNode.updateLayout(CGSize(width: strongSelf.switchNode.frame.minX - 16.0 - 8.0, height: size.height))
                strongSelf.titleNode.frame = CGRect(origin: CGPoint(x: 16.0, y: floor((size.height - titleSize.height) / 2.0)), size: titleSize)

                strongSelf.accessibilityLabel = item.title
                strongSelf.accessibilityValue = item.value ? musicString(item.presentationData.strings, ru: "Вкл.", en: "On") : musicString(item.presentationData.strings, ru: "Выкл.", en: "Off")
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
