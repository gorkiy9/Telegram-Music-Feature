import Foundation
import UIKit
import Display
import BundleIconComponent

/// The tap feedback of the section's and the player's glass buttons: the icon dips under the finger, overshoots a
/// little and settles, as the client's toggles do. It runs on the icon the button shows when it is called, so a
/// button whose icon changes with the tap calls it after the change has been applied.
public enum MusicButtonIconAnimation {
    public static func bounce(in view: UIView?) {
        guard let view, let iconView = self.visibleIconView(in: view) else {
            return
        }
        iconView.layer.removeAnimation(forKey: "musicTapBounce")
        iconView.layer.animateKeyframes(values: [1.0, 0.8, 1.12, 1.0] as [NSNumber], keyTimes: [0.0, 0.3, 0.65, 1.0], duration: 0.4, keyPath: "transform.scale", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue)
    }

    /// The last icon in the hierarchy that is not on its way out: a button cross-fading its content keeps the old
    /// icon until the fade ends, and adds the new one after it.
    private static func visibleIconView(in view: UIView) -> UIView? {
        var result: UIView?
        func visit(_ view: UIView) {
            if view is BundleIconComponent.View, !view.isHidden, view.alpha > 0.01, (view.superview?.alpha ?? 1.0) > 0.01 {
                result = view
            }
            for subview in view.subviews {
                visit(subview)
            }
        }
        visit(view)
        return result
    }
}
