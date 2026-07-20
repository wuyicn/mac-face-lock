import SwiftUI

struct DecorativeCardBorder: View {
    let cornerRadius: CGFloat
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(color, lineWidth: lineWidth)
            .allowsHitTesting(false)
    }
}
