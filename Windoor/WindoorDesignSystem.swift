import SwiftUI

enum WindoorDesign {
    enum Layout {
        static let settingsWidth: CGFloat = 440
        static let settingsHeight: CGFloat = 720
        static let pagePadding: CGFloat = 20
        static let sectionSpacing: CGFloat = 24
        static let cardHeaderPadding: CGFloat = 12
        static let cardContentPadding: CGFloat = 16
        static let controlColumnWidth: CGFloat = 150
        static let rowLabelWidth: CGFloat = 110
        static let footerHorizontalPadding: CGFloat = 20
        static let footerVerticalPadding: CGFloat = 12
    }

    enum Card {
        static let cornerRadius: CGFloat = 12
        static let shadowRadius: CGFloat = 2
        static let shadowOpacity: CGFloat = 0.05
    }

    enum Icon {
        static let badgeSize: CGFloat = 28
        static let badgeCornerRadius: CGFloat = 6
        static let menuItemSize = NSSize(width: 16, height: 16)
        static let languageColor = Color.green
        static let moveColor = Color.blue
        static let resizeColor = Color.orange
        static let detailColor = Color.gray
    }
}

struct WindoorIconBadge: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .foregroundColor(.white)
            .frame(width: WindoorDesign.Icon.badgeSize, height: WindoorDesign.Icon.badgeSize)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: WindoorDesign.Icon.badgeCornerRadius))
    }
}

extension NSImage {
    func windoorMenuIcon() -> NSImage {
        size = WindoorDesign.Icon.menuItemSize
        isTemplate = true
        return self
    }
}
