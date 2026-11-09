import Foundation
import UIKit
import AsyncDisplayKit
import Display

/// Whether a cover row is the track the player is on, and whether it plays (Figma Audio Row, Playing Now).
public enum ListMessageItemPlayingIndicator: Equatable {
    case playing
    case paused
}

/// The playing track's cover overlay (Figma Playing Now 316:26503): a 40% black circle over the cover with a white
/// sound wave in the middle, after SF Symbols' waveform.mid at 20 pt — five round bars that rise and fall while the
/// track plays and rest in the glyph's shape while it is paused. Reduce Motion keeps them resting.
final class ListMessagePlayingIndicatorNode: ASDisplayNode {
    /// The glyph's bar heights at rest, for a 20 pt canvas; the bars are 2 pt wide with 2 pt between them.
    private static let restHeights: [CGFloat] = [6.0, 11.0, 16.0, 11.0, 6.0]
    /// How high each bar reaches while playing, and how long one rise takes: unequal, so the wave never repeats in step.
    private static let peakHeights: [CGFloat] = [12.0, 16.0, 9.0, 15.0, 11.0]
    private static let durations: [Double] = [0.42, 0.55, 0.37, 0.49, 0.61]
    private static let barWidth: CGFloat = 2.0
    private static let barSpacing: CGFloat = 2.0
    private static let minHeight: CGFloat = 3.0

    private let backgroundNode: ASDisplayNode
    private let barLayers: [CALayer]
    private var state: ListMessageItemPlayingIndicator?
    private var isInHierarchyNow = false

    override init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true
        self.backgroundNode.backgroundColor = UIColor(white: 0.0, alpha: 0.4)
        self.barLayers = (0 ..< ListMessagePlayingIndicatorNode.restHeights.count).map { _ in
            let layer = CALayer()
            layer.backgroundColor = UIColor.white.cgColor
            layer.cornerRadius = ListMessagePlayingIndicatorNode.barWidth / 2.0
            return layer
        }

        super.init()

        self.isLayerBacked = true
        self.isUserInteractionEnabled = false
        self.addSubnode(self.backgroundNode)
        for layer in self.barLayers {
            self.layer.addSublayer(layer)
        }
    }

    override func didEnterHierarchy() {
        super.didEnterHierarchy()
        self.isInHierarchyNow = true
        self.updateAnimations()
    }

    override func didExitHierarchy() {
        super.didExitHierarchy()
        self.isInHierarchyNow = false
        self.updateAnimations()
    }

    func update(size: CGSize, state: ListMessageItemPlayingIndicator) {
        self.backgroundNode.frame = CGRect(origin: CGPoint(), size: size)
        self.backgroundNode.cornerRadius = size.width / 2.0

        let count = CGFloat(self.barLayers.count)
        let totalWidth = count * ListMessagePlayingIndicatorNode.barWidth + (count - 1.0) * ListMessagePlayingIndicatorNode.barSpacing
        let originX = floorToScreenPixels((size.width - totalWidth) / 2.0)
        let centerY = size.height / 2.0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in self.barLayers.enumerated() {
            let height = ListMessagePlayingIndicatorNode.restHeights[index]
            layer.bounds = CGRect(x: 0.0, y: 0.0, width: ListMessagePlayingIndicatorNode.barWidth, height: height)
            layer.position = CGPoint(x: originX + CGFloat(index) * (ListMessagePlayingIndicatorNode.barWidth + ListMessagePlayingIndicatorNode.barSpacing) + ListMessagePlayingIndicatorNode.barWidth / 2.0, y: centerY)
        }
        CATransaction.commit()

        if self.state != state {
            self.state = state
            self.updateAnimations()
        }
    }

    private func updateAnimations() {
        let animates = self.state == .playing && self.isInHierarchyNow && !UIAccessibility.isReduceMotionEnabled
        for (index, layer) in self.barLayers.enumerated() {
            if animates {
                if layer.animation(forKey: "wave") == nil {
                    let animation = CABasicAnimation(keyPath: "bounds.size.height")
                    animation.fromValue = ListMessagePlayingIndicatorNode.minHeight as NSNumber
                    animation.toValue = ListMessagePlayingIndicatorNode.peakHeights[index] as NSNumber
                    animation.duration = ListMessagePlayingIndicatorNode.durations[index]
                    animation.autoreverses = true
                    animation.repeatCount = .infinity
                    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    animation.timeOffset = Double(index) * 0.17
                    animation.isRemovedOnCompletion = false
                    layer.add(animation, forKey: "wave")
                }
            } else if layer.animation(forKey: "wave") != nil {
                // The bars settle back into the glyph's shape rather than snapping to it.
                let current = layer.presentation()?.bounds.height ?? layer.bounds.height
                layer.removeAnimation(forKey: "wave")
                let settle = CABasicAnimation(keyPath: "bounds.size.height")
                settle.fromValue = current as NSNumber
                settle.toValue = layer.bounds.height as NSNumber
                settle.duration = 0.2
                settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(settle, forKey: "settle")
            }
        }
    }
}
