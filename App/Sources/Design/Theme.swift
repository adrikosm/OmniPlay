import SwiftUI

/// Midnight Obsidian: one visual system for every screen. A near-black canvas with one faint cool light at the top,
/// glass for lists, sheets, menus and the controls over a game, SF Pro throughout (SF Mono only for data).
/// Ice blue is the one accent and only marks Play, Continue, Resume, switches that are on, text links and the cursor.
/// Main actions are white pills, secondary ones a quiet fill. No raw colours outside this file.
enum Theme {
    // Canvas
    static let canvas = Color(hex: 0x07080D)
    static let canvasLight = Color(hex: 0x111A2E)

    // Glass: the tint laid over a blur, and the cool edge light around it.
    static let glassTint = Color(hex: 0x121726)
    static let edge = Color(red: 200 / 255, green: 220 / 255, blue: 1)
    /// Secondary buttons, selected rows, steppers.
    static let fill = edge.opacity(0.13)
    /// The selected segment, a pressed secondary button, the letter disc on a remap row.
    static let fillStrong = edge.opacity(0.24)
    static let separator = edge.opacity(0.12)

    // Text (all at least 4.5:1 on the canvas and on glass over it)
    static let textPrimary = Color(hex: 0xF8FAFC)
    static let textSecondary = Color(hex: 0xA9B4C6)
    static let textTertiary = Color(hex: 0x8391A7)
    static let textDisabled = Color(hex: 0x64748B)

    // Accent and status
    static let accent = Color(hex: 0x38BDF8)
    static let accentPressed = Color(hex: 0x7DD3FC)
    static let danger = Color(hex: 0xFF453A)
    /// Error text on a danger-tinted background.
    static let dangerText = Color(hex: 0xFFB3AE)
    static let success = Color(hex: 0x30D158)

    // Covers without art
    static let slateTop = Color(hex: 0x2A3550)
    static let slateBottom = Color(hex: 0x10141F)

    // Shape
    static let listRadius: CGFloat = 18
    static let sheetRadius: CGFloat = 30
    static let panelRadius: CGFloat = 34
    static let fieldRadius: CGFloat = 12
    static let coverRadius: CGFloat = 16
    static let coverAspect: CGFloat = 130 / 172
    static let rowHeight: CGFloat = 46

    // Spacing rhythm (4/8 grid)
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32

    /// Every number the player can change: tabular digits, so a rolling value never jitters its row.
    static let value: Font = .system(.subheadline, design: .monospaced, weight: .medium)
    static let mono: Font = .system(.footnote, design: .monospaced)

    /// Motion. Exits run faster than entrances; nothing loops while a game renders.
    /// Content settling in: fade and a 14 pt rise.
    static let rise: Animation = .timingCurve(0.19, 1, 0.22, 1, duration: 0.9)
    /// Big headlines sliding up from behind their clip.
    static let mask: Animation = .timingCurve(0.19, 1, 0.22, 1, duration: 1.1)
    /// Bars and meters filling left to right.
    static let wipe: Animation = .timingCurve(0.77, 0, 0.175, 1, duration: 1.3)
    /// Sheets, side panels and menus: iOS's own curve, no bounce.
    static let sheet: Animation = .timingCurve(0.32, 0.72, 0, 1, duration: 0.55)
    /// The library's featured title rolling to the next game, in step with the shelf.
    static let roll: Animation = .timingCurve(0.77, 0, 0.175, 1, duration: 0.7)
    static let settle: Animation = .spring(duration: 0.5, bounce: 0)
    static let quick: Animation = .easeOut(duration: 0.18)
    static let press: Animation = .spring(response: 0.22, dampingFraction: 0.78)
    static let snap: Animation = .snappy(duration: 0.28)

    /// The animation to use, or a short cross-fade when Reduce Motion is on (state still has to change visibly).
    static func motion(_ animation: Animation, reduce: Bool) -> Animation { reduce ? .easeInOut(duration: 0.25) : animation }
}

extension String {
    /// "yesterday" → "Yesterday", for relative dates standing alone.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension Date {
    /// "Today, 9:06", "Yesterday, 21:14", "22 Sep, 21:14".
    var dayAndTime: String {
        let time = formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(self) {
            return "Today, \(time)"
        }
        if Calendar.current.isDateInYesterday(self) {
            return "Yesterday, \(time)"
        }
        return formatted(.dateTime.day().month(.abbreviated)) + ", " + time
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension Binding {
    /// Shown while the optional holds a value; dismissing clears it. Never sets it.
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: {
            if !$0 {
                wrappedValue = nil
            }
        })
    }
}

// MARK: - Canvas

/// The one background: near-black with a single cool light above the top edge, so glass has something to refract.
struct CanvasBackground: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = max(geo.size.height, 1)
            ZStack {
                LinearGradient(
                    stops: [.init(color: Color(hex: 0x0A0C14), location: 0), .init(color: Theme.canvas, location: 0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // radial-gradient(90% 70% at 50% -20%, #111A2E, transparent 70%)
                RadialGradient(
                    colors: [Theme.canvasLight, Theme.canvasLight.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: w * 0.63
                )
                .frame(width: w * 1.8, height: w * 1.8)
                .scaleEffect(x: 1, y: (0.7 * h) / (0.9 * w))
                .position(x: w / 2, y: -0.2 * h)
            }
        }
        .background(Theme.canvas)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    /// Every screen: the canvas behind, system list and bar backgrounds out of the way.
    func canvas() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CanvasBackground())
            .scrollContentBackground(.hidden)
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

// MARK: - Glass

/// Blur plus a dark cool tint, a 1 pt light along the top edge and a hairline all round. `heavy` is for sheets and
/// menus that must hold text over anything. Reduce Transparency swaps the blur for a solid fill.
struct Glass<S: InsettableShape>: ViewModifier {
    let shape: S
    var heavy = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    shape.fill(Theme.glassTint)
                } else {
                    shape.fill(.ultraThinMaterial).overlay(shape.fill(Theme.glassTint.opacity(heavy ? 0.85 : 0.5)))
                }
            }
            .overlay {
                shape.strokeBorder(Theme.edge.opacity(0.16), lineWidth: 1)
                    .mask(alignment: .top) {
                        LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom).frame(height: 14)
                    }
            }
            .overlay { shape.strokeBorder(Theme.edge.opacity(contrast == .increased ? 0.4 : 0.10), lineWidth: 0.5) }
    }
}

extension View {
    func glass(_ shape: some InsettableShape, heavy: Bool = false) -> some View { modifier(Glass(shape: shape, heavy: heavy)) }

    func glass(radius: CGFloat = Theme.listRadius, heavy: Bool = false) -> some View {
        glass(RoundedRectangle(cornerRadius: radius, style: .continuous), heavy: heavy)
    }

    /// A grouped list's container.
    func surface(radius: CGFloat = Theme.listRadius) -> some View { glass(radius: radius) }
}

// MARK: - Grouped lists (iOS Settings style)

/// A header, a glass container whose rows are separated by hairlines, and an optional footer caption.
struct GlassSection<Content: View>: View {
    var header: String?
    var footer: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    /// A header with a link or control on the right ("Clear finished").
    init(_ header: String?, footer: String? = nil, trailing: some View, @ViewBuilder content: () -> Content) {
        self.init(header, footer: footer, content: content)
        self.trailing = AnyView(trailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            if header != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let header {
                        Text(header).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: 0)
                    trailing
                }
                .padding(.horizontal, Theme.s4)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, Theme.s4)
                        }
                        row
                    }
                }
            }
            .surface()
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.s4)
            }
        }
    }
}

/// One list row: optional SF Symbol, title, optional subtitle, and a trailing value, switch, link or chevron.
struct ListRow<Trailing: View>: View {
    var icon: String?
    let title: String
    var subtitle: String?
    var minHeight: CGFloat = Theme.rowHeight
    var dimmed = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.s3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(.body, weight: .regular))
                    .foregroundStyle(dimmed ? Theme.textDisabled : Theme.textSecondary)
                    .frame(width: 26)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(dimmed ? Theme.textTertiary : Theme.textPrimary)
                if let subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(dimmed ? Theme.textDisabled : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.s2)
            trailing
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s2)
        .frame(minHeight: minHeight)
        .contentShape(.rect)
    }
}

extension ListRow where Trailing == EmptyView {
    init(icon: String? = nil, title: String, subtitle: String? = nil, minHeight: CGFloat = Theme.rowHeight, dimmed: Bool = false) {
        self.init(icon: icon, title: title, subtitle: subtitle, minHeight: minHeight, dimmed: dimmed) { EmptyView() }
    }
}

/// The trailing chevron of a row that opens something.
struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
    }
}

/// A row button that highlights while pressed, like a Settings cell.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.fill : .clear)
            .animation(configuration.isPressed ? nil : Theme.quick, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == RowButtonStyle {
    static var row: RowButtonStyle { RowButtonStyle() }
}

/// A trailing mono value in a row (file names, sizes, versions).
struct RowValue: View {
    let text: String
    var mono = false

    var body: some View {
        Text(text)
            .font(mono ? Theme.mono : .subheadline)
            .foregroundStyle(Theme.textSecondary)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

// MARK: - The mark

/// The 4b mark: three face buttons on a diamond with a play arrow in the fourth place. `assembled` false draws the
/// pieces out of place so a change to true pops the dots in one by one and slides the arrow home.
struct OmniMark: View {
    var size: CGFloat
    var color: Color = Theme.textPrimary
    var assembled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let unit = size / 100
        ZStack(alignment: .topLeading) {
            ForEach(
                Array([CGPoint(x: 50, y: 22), CGPoint(x: 22, y: 50), CGPoint(x: 50, y: 78)].enumerated()),
                id: \.offset
            ) { index, center in
                Circle().fill(color)
                    .frame(width: 26 * unit, height: 26 * unit)
                    .scaleEffect(assembled || reduceMotion ? 1 : 0.01)
                    .opacity(assembled ? 1 : 0)
                    .position(x: center.x * unit, y: center.y * unit)
                    .animation(
                        Theme.motion(.timingCurve(0.32, 0.72, 0, 1, duration: 0.7), reduce: reduceMotion)
                            .delay(reduceMotion ? 0 : 0.12 * Double(index)),
                        value: assembled
                    )
            }
            Path { p in
                p.move(to: CGPoint(x: 68 * unit, y: 35.5 * unit))
                p.addLine(to: CGPoint(x: 68 * unit, y: 64.5 * unit))
                p.addLine(to: CGPoint(x: 92 * unit, y: 50 * unit))
                p.closeSubpath()
            }
            .fill(color)
            .offset(x: assembled || reduceMotion ? 0 : -30 * unit)
            .opacity(assembled ? 1 : 0)
            .animation(Theme.motion(Theme.rise, reduce: reduceMotion).delay(reduceMotion ? 0 : 0.45), value: assembled)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
