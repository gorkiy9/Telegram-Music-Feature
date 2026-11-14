import Foundation
import UIKit

public struct AttachmentMainButtonState {
    public enum Background {
        case color(UIColor)
        case premium
        
        public var colorValue: UIColor? {
            if case let .color(color) = self {
                return color
            }
            return nil
        }
    }
    
    public enum Progress: Equatable {
        case none
        case side
        case center
    }
    
    public enum Font: Equatable {
        case regular
        case bold
    }
    
    /// Where the badge sits: right after the title (as before), or as a counter at the button's trailing edge, with
    /// the title and icon moving left to make room for it.
    public enum BadgeAlignment: Equatable {
        case inline
        case trailing
    }

    public enum Position: String, Equatable {
        case top
        case bottom
        case left
        case right
    }
    
    public let text: String?
    public let badge: String?
    public let font: Font
    public let background: Background
    public let textColor: UIColor
    public let isVisible: Bool
    public let progress: Progress
    public let isEnabled: Bool
    public let hasShimmer: Bool
    public let iconName: String?
    /// An SF Symbol drawn in place of `iconName`, at the title's size and weight.
    public let iconSystemName: String?
    public let badgeAlignment: BadgeAlignment
    public let iconCustomEmojiId: Int64?
    public let smallSpacing: Bool
    public let position: Position?
    public let hidesPanelBackground: Bool
    /// The button is an alternative to the tabs' content (e.g. "Edit Current Photo" while replacing a
    /// message's media), so it is laid out above the tab row instead of replacing it.
    public let keepsTabRow: Bool
    
    public init(
        text: String?,
        badge: String? = nil,
        font: Font,
        background: Background,
        textColor: UIColor,
        isVisible: Bool,
        progress: Progress,
        isEnabled: Bool,
        hasShimmer: Bool,
        iconName: String? = nil,
        iconSystemName: String? = nil,
        badgeAlignment: BadgeAlignment = .inline,
        iconCustomEmojiId: Int64? = nil,
        smallSpacing: Bool = false,
        position: Position? = nil,
        hidesPanelBackground: Bool = false,
        keepsTabRow: Bool = false
    ) {
        self.text = text
        self.badge = badge
        self.font = font
        self.background = background
        self.textColor = textColor
        self.isVisible = isVisible
        self.progress = progress
        self.isEnabled = isEnabled
        self.hasShimmer = hasShimmer
        self.iconName = iconName
        self.iconSystemName = iconSystemName
        self.badgeAlignment = badgeAlignment
        self.iconCustomEmojiId = iconCustomEmojiId
        self.smallSpacing = smallSpacing
        self.position = position
        self.hidesPanelBackground = hidesPanelBackground
        self.keepsTabRow = keepsTabRow
    }
    
    public static var initial: AttachmentMainButtonState {
        return AttachmentMainButtonState(text: nil, font: .bold, background: .color(.clear), textColor: .clear, isVisible: false, progress: .none, isEnabled: false, hasShimmer: false)
    }
}
