import ClickBaitCore
import SwiftUI

/// ClickBait's shared look, named once: the corners and motions the companion's surfaces
/// (pills, chat) and the notch use, each by what it means. The values are as tuned; changing
/// one here changes everything that means the same thing.
enum Look {
    enum Corner {
        /// The companion's pills: answers, problems, guide labels (`TinyPill`, `GuidePill`).
        static let pill: CGFloat = 11
        /// Small tiles in the notch: the cover, shelf rows and the file drop.
        static let tile: CGFloat = 12
        /// The notch's cards (`NotchCard`).
        static let card: CGFloat = 20
    }

    enum Motion {
        /// A press or hover answering at once.
        static let press = Animation.spring(response: 0.2, dampingFraction: 0.7)
        /// Something arriving: the chat bubble and its content.
        static let reveal = Animation.spring(response: 0.3, dampingFraction: 0.86)
        /// The island opening, and changing tabs (`NotchPanel.openSpring`).
        static let open = Animation.spring(response: NotchPanel.openSpring.response,
                                           dampingFraction: NotchPanel.openSpring.damping)
        /// The island closing: a quick ease-out (`NotchPanel.closeCurve`).
        static let close: Animation = {
            let c = NotchPanel.closeCurve
            return .timingCurve(c.x1, c.y1, c.x2, c.y2, duration: c.duration)
        }()
    }
}
