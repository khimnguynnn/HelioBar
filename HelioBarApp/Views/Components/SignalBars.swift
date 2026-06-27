import SwiftUI

/// Three little bars showing 0–3 signal strength.
struct SignalBars: View {
    let level: Int   // 0...3

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= level ? Color.secondary : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(3 + i * 3))
            }
        }
        .frame(width: 14, height: 12, alignment: .bottom)
        .accessibilityLabel("Signal \(level) of 3")
    }
}

#if !SWIFT_PACKAGE
#Preview {
    HStack(spacing: 16) { SignalBars(level: 0); SignalBars(level: 1); SignalBars(level: 2); SignalBars(level: 3) }
        .padding().background(.black)
}
#endif
