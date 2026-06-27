import SwiftUI

/// A small line under the status badge: the connected strap (tap to switch),
/// a "looking for…" note, or a "choose your strap" prompt on first run.
struct DeviceHint: View {
    let connectedName: String?
    let rememberedName: String?
    let needsChoice: Bool
    var onTap: () -> Void

    var body: some View {
        if needsChoice {
            row(text: "Choose your strap", icon: "exclamationmark.circle.fill", tint: Theme.elevated)
        } else if let name = connectedName {
            row(text: name, icon: "dot.radiowaves.left.and.right", tint: .secondary)
        } else if let name = rememberedName {
            row(text: "Looking for \(name)…", icon: "dot.radiowaves.left.and.right", tint: .secondary)
        }
    }

    private func row(text: String, icon: String, tint: Color) -> some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10))
                Text(text).font(.system(size: 11, weight: .medium, design: .rounded)).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 8)).opacity(0.6)
            }
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    VStack(spacing: 10) {
        DeviceHint(connectedName: "Helio Strap", rememberedName: nil, needsChoice: false, onTap: {})
        DeviceHint(connectedName: nil, rememberedName: "Helio Strap", needsChoice: false, onTap: {})
        DeviceHint(connectedName: nil, rememberedName: nil, needsChoice: true, onTap: {})
    }
    .padding().background(.black)
}
#endif
