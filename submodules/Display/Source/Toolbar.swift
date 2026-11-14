import Foundation
import UIKit

public struct ToolbarAction: Equatable {
    public enum Color: Equatable {
        case accent
        case custom(UIColor)
    }

    public let title: String
    public let isEnabled: Bool
    public let color: Color
    /// A bundle image drawn instead of the title (the title stays for VoiceOver); nil keeps the text button.
    public let icon: String?
    
    public init(title: String, isEnabled: Bool, color: Color = .accent, icon: String? = nil) {
        self.title = title
        self.isEnabled = isEnabled
        self.color = color
        self.icon = icon
    }
}

public struct Toolbar: Equatable {
    public let leftAction: ToolbarAction?
    public let rightAction: ToolbarAction?
    public let middleAction: ToolbarAction?
    
    public init(leftAction: ToolbarAction?, rightAction: ToolbarAction?, middleAction: ToolbarAction?) {
        self.leftAction = leftAction
        self.rightAction = rightAction
        self.middleAction = middleAction
    }
}
