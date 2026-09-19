import SwiftUI

/// The one visual system every screen draws from. Dark by design: a midnight ink base, a single lantern
/// accent, New York serif for titles, SF for everything else, iOS glass for chrome. No raw colours elsewhere.
enum Theme {
    // Palette
    static let ink = Color(red: 0.039, green: 0.055, blue: 0.102) // #0A0E1A
    static let inkRaised = Color(red: 0.075, green: 0.094, blue: 0.157) // #13182A
    static let lantern = Color(red: 0.961, green: 0.722, blue: 0.290) // #F5B84A, 9.4:1 on ink
    static let lanternDeep = Color(red: 0.792, green: 0.522, blue: 0.106) // #CA851B
    static let textPrimary = Color(red: 0.949, green: 0.957, blue: 0.973) // #F2F4F8
    static let textSecondary = Color(red: 0.663, green: 0.698, blue: 0.769) // #A9B2C4, 7.5:1 on ink
    static let hairline = Color.white.opacity(0.10)
    static let danger = Color(red: 1.0, green: 0.478, blue: 0.478) // #FF7A7A

    // Shape
    static let tileRadius: CGFloat = 22
    static let cardRadius: CGFloat = 18
    static let chipRadius: CGFloat = 9
    static let coverAspect: CGFloat = 3 / 4

    // Spacing rhythm (4/8 grid)
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32

    // Type: serif carries the personality on titles; SF does the work everywhere else.
    static func title(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .semibold, design: .serif) }
    static let tileTitle: Font = .system(.subheadline, design: .serif, weight: .semibold)
    static let chip: Font = .system(.caption2, design: .rounded, weight: .semibold)

    // Motion tokens
    static let quick: Animation = .easeOut(duration: 0.18)
    static let settle: Animation = .spring(response: 0.42, dampingFraction: 0.86)
}

/// Full-bleed background: ink with one warm glow bleeding in from the top corner, like light off a cover.
struct InkBackground: View {
    var body: some View {
        ZStack {
            Theme.ink
            RadialGradient(
                colors: [Theme.lantern.opacity(0.22), Theme.lantern.opacity(0.0)],
                center: UnitPoint(x: 0.15, y: -0.05), startRadius: 0, endRadius: 520
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Glass card chrome with a hairline edge so it stays legible over dark covers.
struct GlassCard: ViewModifier {
    var radius: CGFloat = Theme.cardRadius
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Small rounded label used for engine and state badges.
struct Chip: View {
    let text: String
    var tint: Color = Theme.textSecondary
    var body: some View {
        Text(text)
            .font(Theme.chip)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.s2)
            .padding(.vertical, Theme.s1)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: Theme.chipRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.chipRadius).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

extension View {
    func glassCard(radius: CGFloat = Theme.cardRadius) -> some View { modifier(GlassCard(radius: radius)) }

    /// Every screen: ink behind, system list chrome hidden, dark scheme.
    func inkScreen() -> some View {
        background(InkBackground())
            .scrollContentBackground(.hidden)
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

/// Primary action: lantern fill, dark text, 50 pt tall so the target clears 44 pt with room.
struct LanternButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(isEnabled ? Theme.ink : Theme.textSecondary)
            .padding(.horizontal, Theme.s6)
            .frame(minHeight: 50)
            .background(isEnabled ? (configuration.isPressed ? Theme.lanternDeep : Theme.lantern) : Theme.inkRaised, in: .capsule)
            .overlay(Capsule().strokeBorder(isEnabled ? .clear : Theme.hairline, lineWidth: 1))
            .animation(Theme.quick, value: configuration.isPressed)
    }
}
