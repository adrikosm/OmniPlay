import SwiftUI

// MARK: - Buttons

/// Pills. `accent` is only Play, Continue and Resume; `primary` is every other main action (white); `secondary` a
/// quiet fill; `destructive` a faint red wash with red text. Presses shrink a little and brighten.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case accent, primary, secondary, destructive }
    var kind: Kind
    var height: CGFloat = 48
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let small = height < 40
        configuration.label
            .font(small ? .subheadline.weight(.semibold) : .body.weight(.semibold))
            .tracking(-0.2)
            .labelStyle(PillLabelStyle())
            .foregroundStyle(foreground)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, small ? 14 : 22)
            .padding(.vertical, Theme.s1)
            .frame(minHeight: height)
            .background(fill(pressed), in: .capsule)
            // Small pills keep their look but get a full 44 pt target.
            .padding(.vertical, max(0, (44 - height) / 2))
            .contentShape(.rect)
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .animation(Theme.motion(Theme.press, reduce: reduceMotion), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed) { _, now in now && kind == .accent }
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.textDisabled }
        return switch kind {
        case .accent, .primary: Theme.canvas
        case .secondary: Theme.textPrimary
        case .destructive: Theme.danger
        }
    }

    private func fill(_ pressed: Bool) -> Color {
        guard isEnabled else { return Theme.fill }
        return switch kind {
        case .accent: pressed ? Theme.accentPressed : Theme.accent
        case .primary: pressed ? .white : Theme.textPrimary.opacity(0.94)
        case .secondary: pressed ? Theme.fillStrong : Theme.fill
        case .destructive: Theme.danger.opacity(pressed ? 0.26 : 0.15)
        }
    }
}

/// Icon then title, the icon a touch smaller, as on the design's Continue button.
private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.s2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var accent: PillButtonStyle { PillButtonStyle(kind: .accent) }
    static var primary: PillButtonStyle { PillButtonStyle(kind: .primary) }
    static var secondary: PillButtonStyle { PillButtonStyle(kind: .secondary) }
    static var destructive: PillButtonStyle { PillButtonStyle(kind: .destructive) }
}

/// A round glass button (back, favourite, sort, controller, pause). Shrinks and brightens while pressed.
struct RoundButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: size, height: size)
            .glass(Circle())
            .overlay(Circle().fill(Theme.edge.opacity(configuration.isPressed ? 0.18 : 0)))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .animation(Theme.motion(Theme.press, reduce: reduceMotion), value: configuration.isPressed)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
    }
}

extension ButtonStyle where Self == RoundButtonStyle {
    static var round: RoundButtonStyle { RoundButtonStyle() }
    static func round(_ size: CGFloat) -> RoundButtonStyle { RoundButtonStyle(size: size) }
}

/// A text link (Done, Show, Restore, Import, Clear finished): accent, 44 pt tall, lighter while pressed. A destructive
/// link (Reset) is red.
struct LinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let color = configuration.role == .destructive ? Theme.danger : Theme.accent
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isEnabled ? color.opacity(configuration.isPressed ? 0.7 : 1) : Theme.textDisabled)
            .frame(minHeight: 44)
            .contentShape(.rect)
    }
}

extension ButtonStyle where Self == LinkButtonStyle {
    static var link: LinkButtonStyle { LinkButtonStyle() }
}

/// Press feedback for covers and tiles: a small scale and a dim. Scale never moves layout bounds.
struct PressButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.motion(Theme.press, reduce: reduceMotion), value: configuration.isPressed)
    }
}

// MARK: - Segmented control

/// A glass track with the selected segment slightly lighter; the highlight slides between choices.
/// Counts sit after the title in the secondary colour ("All  5").
struct GlassSegmentBar<Value: Hashable>: View {
    let items: [(value: Value, title: String)]
    @Binding var selection: Value
    var counts: [Value: Int] = [:]
    /// Stretch the segments across the available width (side panels) instead of hugging their titles.
    var fill = false
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button {
                    withAnimation(Theme.motion(Theme.snap, reduce: reduceMotion)) { selection = item.value }
                } label: {
                    HStack(spacing: 6) {
                        Text(item.title)
                        if let count = counts[item.value] {
                            Text(count, format: .number).monospacedDigit()
                                .foregroundStyle(selected ? Theme.textPrimary.opacity(0.8) : Theme.textTertiary)
                        }
                    }
                    .font(.footnote.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: fill ? .infinity : nil, minHeight: 44)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fillStrong)
                                .padding(.vertical, 4)
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityValue(counts[item.value].map { "\($0)" } ?? "")
            }
        }
        .padding(.horizontal, 4)
        .background(Theme.edge.opacity(0.075), in: .rect(cornerRadius: 12, style: .continuous))
        .glass(radius: 12)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: - Pills (Game details only)

/// The only pills in the app: engine and input on the game page.
struct InfoPill: View {
    let text: String
    var icon: String?

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let icon {
                Image(systemName: icon)
            }
        }
        .labelStyle(PillLabelStyle())
        .font(.footnote.weight(.medium))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
        .background(Theme.edge.opacity(0.06), in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.edge.opacity(0.2), lineWidth: 0.5))
    }
}
