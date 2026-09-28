import SwiftUI

// MARK: - Motion helpers

/// Content arriving: fade plus a 14 pt rise, 70 ms after the block before it. Runs once, when the view first appears.
private struct Rise: ViewModifier {
    let step: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear {
                withAnimation(Theme.motion(Theme.rise, reduce: reduceMotion).delay(reduceMotion ? 0 : 0.07 * Double(step))) { shown = true }
            }
    }
}

/// A headline line rising from behind its own clip, 90 ms after the line above.
private struct MaskedRise: ViewModifier {
    let line: Int
    var delay: Double = 0
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .padding(.bottom, 4) // room for descenders inside the clip
            .visualEffect { [shown, reduceMotion] view, proxy in
                view.offset(y: shown || reduceMotion ? 0 : proxy.size.height * 1.05)
            }
            .opacity(reduceMotion && !shown ? 0 : 1)
            .clipped()
            .padding(.bottom, -4)
            .onAppear {
                withAnimation(Theme.motion(Theme.mask, reduce: reduceMotion).delay(delay + 0.09 * Double(line))) { shown = true }
            }
    }
}

/// A bar filling from the left.
private struct WipeIn: ViewModifier {
    var delay: Double = 0.2
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                GeometryReader { geo in Rectangle().frame(width: shown || reduceMotion ? geo.size.width : 0) }
            }
            .onAppear { withAnimation(Theme.wipe.delay(delay)) { shown = true } }
    }
}

extension View {
    /// Fade and rise into place once, `step` × 70 ms after the page appears.
    func rise(_ step: Int = 0) -> some View { modifier(Rise(step: step)) }

    /// `rise(step)` only while `condition` holds (the first few items of a lazy row, not every item scrolled into view).
    @ViewBuilder func rise(_ step: Int, when condition: Bool) -> some View {
        if condition {
            rise(step)
        } else {
            self
        }
    }

    /// A big headline line sliding up from behind its clip, `line` × 90 ms after the first.
    func maskedRise(_ line: Int = 0, delay: Double = 0) -> some View { modifier(MaskedRise(line: line, delay: delay)) }

    /// A bar or meter wiping in from the left.
    func wipeIn(delay: Double = 0.2) -> some View { modifier(WipeIn(delay: delay)) }

    /// Large-title type: bold, tight tracking, scaled with Dynamic Type from the given point size.
    func display(_ size: CGFloat, weight: Font.Weight = .bold) -> some View { modifier(DisplayType(size: size, weight: weight)) }
}

private struct DisplayType: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    /// Follows Dynamic Type as the large title does.
    @ScaledMetric(relativeTo: .largeTitle) private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight)).tracking(-0.035 * size * scale).foregroundStyle(Theme.textPrimary)
    }
}

// MARK: - Covers

extension View {
    /// A cover's rounded clip with a hairline, so white art still has an edge on the canvas.
    func coverEdge(radius: CGFloat = Theme.coverRadius) -> some View {
        clipShape(.rect(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.edge.opacity(0.12), lineWidth: 0.5))
    }
}
