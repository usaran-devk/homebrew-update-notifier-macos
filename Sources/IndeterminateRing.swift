import SwiftUI

@MainActor
struct IndeterminateRing: View {
    let color: Color
    let size: CGFloat
    let lineWidth: CGFloat

    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.0, to: 0.7)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
                .animation(isAnimating ? Animation.linear(duration: 1.0).repeatForever(autoreverses: false) : .default, value: isAnimating)
                .frame(width: size, height: size)
        }
        .onAppear { isAnimating = true }
        .onDisappear { isAnimating = false }
    }
}
