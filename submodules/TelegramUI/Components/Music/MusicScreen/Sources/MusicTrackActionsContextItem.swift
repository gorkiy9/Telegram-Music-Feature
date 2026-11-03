import Foundation
import UIKit
import AsyncDisplayKit
import Display
import ComponentFlow
import ContextUI
import TelegramPresentationData
import PlainButtonComponent
import BundleIconComponent
import MultilineTextComponent

/// The row of quick actions on top of a track's menu: an icon over a title for each, the width shared equally.
/// Built like the client's other in-menu controls (`TableStructuralMenuAlignmentItem`), from its button, icon and text components.
final class MusicTrackActionsContextItem: ContextMenuCustomItem {
    struct Action {
        let title: String
        let iconName: String
        let action: () -> Void
    }

    let actions: [Action]

    init(actions: [Action]) {
        self.actions = actions
    }

    func node(presentationData: PresentationData, getController: @escaping () -> ContextControllerProtocol?, actionSelected: @escaping (ContextMenuActionResult) -> Void) -> ContextMenuCustomNode {
        return MusicTrackActionsContextItemNode(presentationData: presentationData, item: self, actionSelected: actionSelected)
    }
}

private final class MusicTrackActionsContextItemNode: ASDisplayNode, ContextMenuCustomNode {
    private var presentationData: PresentationData
    private let item: MusicTrackActionsContextItem
    private let actionSelected: (ContextMenuActionResult) -> Void

    private let buttons: [ComponentView<Empty>]
    private var validLayout: (constrainedWidth: CGFloat, constrainedHeight: CGFloat, resultSize: CGSize)?

    init(presentationData: PresentationData, item: MusicTrackActionsContextItem, actionSelected: @escaping (ContextMenuActionResult) -> Void) {
        self.presentationData = presentationData
        self.item = item
        self.actionSelected = actionSelected
        self.buttons = item.actions.map { _ in ComponentView() }

        super.init()

        self.isUserInteractionEnabled = true
    }

    func updateTheme(presentationData: PresentationData) {
        self.presentationData = presentationData
        if let validLayout = self.validLayout {
            let (_, apply) = self.updateLayout(constrainedWidth: validLayout.constrainedWidth, constrainedHeight: validLayout.constrainedHeight)
            apply(validLayout.resultSize, .immediate)
        }
    }

    func updateLayout(constrainedWidth: CGFloat, constrainedHeight: CGFloat) -> (CGSize, (CGSize, ContainedViewLayoutTransition) -> Void) {
        let size = CGSize(width: constrainedWidth, height: 66.0)

        return (size, { [weak self] size, _ in
            guard let self else {
                return
            }
            self.validLayout = (constrainedWidth, constrainedHeight, size)

            let sideInset: CGFloat = 8.0
            let buttonWidth = floor((size.width - sideInset * 2.0) / CGFloat(max(1, self.buttons.count)))
            let theme = self.presentationData.theme.contextMenu
            for (index, action) in self.item.actions.enumerated() {
                let button = self.buttons[index]
                let buttonSize = CGSize(width: buttonWidth, height: size.height)
                let _ = button.update(
                    transition: .immediate,
                    component: AnyComponent(PlainButtonComponent(
                        content: AnyComponent(VStack([
                            AnyComponentWithIdentity(id: "icon", component: AnyComponent(BundleIconComponent(
                                name: action.iconName,
                                tintColor: theme.primaryColor,
                                maxSize: CGSize(width: 24.0, height: 24.0)
                            ))),
                            AnyComponentWithIdentity(id: "title", component: AnyComponent(MultilineTextComponent(
                                text: .plain(NSAttributedString(string: action.title, font: Font.regular(12.0), textColor: theme.primaryColor)),
                                maximumNumberOfLines: 1
                            )))
                        ], spacing: 4.0)),
                        minSize: buttonSize,
                        action: { [weak self] in
                            self?.actionSelected(.dismissWithoutContent)
                            action.action()
                        }
                    )),
                    environment: {},
                    containerSize: buttonSize
                )
                if let buttonView = button.view {
                    if buttonView.superview == nil {
                        self.view.addSubview(buttonView)
                    }
                    buttonView.frame = CGRect(origin: CGPoint(x: sideInset + CGFloat(index) * buttonWidth, y: 0.0), size: buttonSize)
                }
            }
        })
    }

    func canBeHighlighted() -> Bool {
        return false
    }

    func updateIsHighlighted(isHighlighted: Bool) {
    }

    func performAction() {
    }
}
