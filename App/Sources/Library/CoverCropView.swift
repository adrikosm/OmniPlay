import SwiftUI

/// Full-screen crop: the picture behind a cover-shaped window, the outside dimmed. Drag places it, pinch zooms,
/// double tap switches Fit and Fill; Fit, Fill and Centre do the same without gestures. "Use as cover" hands back
/// the window's pixels, at most 1024 px tall.
struct CoverCropView: View {
    let image: CGImage
    let onUse: (CGImage) async -> Void
    let onCancel: () -> Void
    @State private var scale: CGFloat = 0
    @State private var offset: CGSize = .zero
    @State private var pinchStart: CGFloat?
    @State private var dragStart: CGSize?
    @State private var window: CGSize = .zero
    @State private var saving = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGSize { CGSize(width: image.width, height: image.height) }
    private var fit: CGFloat { window.width > 0 ? min(window.width / size.width, window.height / size.height) : 1 }
    private var fill: CGFloat { window.width > 0 ? max(window.width / size.width, window.height / size.height) : 1 }

    var body: some View {
        let landscape = verticalSizeClass == .compact
        let layout = landscape ? AnyLayout(HStackLayout(spacing: Theme.s8)) : AnyLayout(VStackLayout(spacing: Theme.s6))
        layout {
            GeometryReader { geo in
                let frame = Self.window(in: geo.size)
                picture(frame: frame).frame(width: geo.size.width, height: geo.size.height)
                    .onAppear { setWindow(frame) }
                    .onChange(of: geo.size) { setWindow(Self.window(in: $1)) }
            }
            controls.frame(maxWidth: landscape ? 300 : .infinity)
        }
        .padding(Theme.s4)
        .canvas()
        .preferredColorScheme(.dark)
    }

    /// The largest cover-shaped window that fits.
    static func window(in space: CGSize) -> CGSize {
        let width = min(space.width, space.height * Theme.coverAspect)
        return CGSize(width: max(width, 1), height: max(width / Theme.coverAspect, 1))
    }

    private func setWindow(_ frame: CGSize) {
        let first = window == .zero
        window = frame
        if first {
            scale = fill
        }
        scale = min(max(scale, fit), fill * 6)
        offset = clamped(offset)
    }

    private func picture(frame: CGSize) -> some View {
        ZStack {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(min(size.width, size.height) <= 128 ? .none : .high)
                .frame(width: size.width * scale, height: size.height * scale)
                .offset(offset)
            // The outside of the window, dimmed to 60 %.
            Rectangle().fill(Theme.canvas.opacity(0.6))
                .mask {
                    Rectangle().overlay {
                        RoundedRectangle(cornerRadius: Theme.coverRadius, style: .continuous)
                            .frame(width: frame.width, height: frame.height).blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: Theme.coverRadius, style: .continuous)
                .strokeBorder(Theme.edge.opacity(0.35), lineWidth: 1)
                .frame(width: frame.width, height: frame.height)
                .allowsHitTesting(false)
        }
        .clipped()
        .contentShape(.rect)
        .gesture(
            DragGesture()
                .onChanged { value in
                    let start = dragStart ?? offset
                    dragStart = start
                    offset = clamped(CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height))
                }
                .onEnded { _ in dragStart = nil }
                .simultaneously(with: MagnifyGesture()
                    .onChanged { value in
                        let start = pinchStart ?? scale
                        pinchStart = start
                        scale = min(max(start * value.magnification, fit), fill * 6)
                        offset = clamped(offset)
                    }
                    .onEnded { _ in pinchStart = nil })
        )
        .onTapGesture(count: 2) { set(abs(scale - fill) < 0.001 ? fit : fill) }
        .accessibilityElement()
        .accessibilityLabel("Cover crop")
        .accessibilityValue("Zoom \(Int((scale / max(fill, 0.0001) * 100).rounded())) percent")
        .accessibilityHint("Swipe up or down to zoom.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(min(scale * 1.25, fill * 6))
            case .decrement: set(max(scale / 1.25, fit))
            @unknown default: break
            }
        }
    }

    private var controls: some View {
        VStack(spacing: Theme.s3) {
            ViewThatFits {
                HStack(spacing: Theme.s2) { placementButtons }
                VStack(spacing: Theme.s2) { placementButtons }
            }
            Button {
                saving = true
                Task {
                    if let crop = cropped() {
                        await onUse(crop)
                    }
                    saving = false
                }
            } label: {
                Text(saving ? "Saving…" : "Use as cover").frame(maxWidth: .infinity)
            }
            .buttonStyle(.primary)
            .disabled(saving)
            Button("Cancel", action: onCancel).buttonStyle(.link)
        }
    }

    @ViewBuilder private var placementButtons: some View {
        Button("Fit") { set(fit) }.buttonStyle(PillButtonStyle(kind: .secondary, height: 40))
        Button("Fill") { set(fill) }.buttonStyle(PillButtonStyle(kind: .secondary, height: 40))
        Button("Centre") { withAnimation(Theme.motion(Theme.settle, reduce: reduceMotion)) { offset = .zero } }
            .buttonStyle(PillButtonStyle(kind: .secondary, height: 40))
    }

    private func set(_ newScale: CGFloat) {
        withAnimation(Theme.motion(Theme.settle, reduce: reduceMotion)) {
            scale = newScale
            offset = clamped(offset)
        }
    }

    /// A filled picture never shows an edge inside the window; a smaller one stays inside it.
    private func clamped(_ o: CGSize) -> CGSize {
        let dx = abs(size.width * scale - window.width) / 2, dy = abs(size.height * scale - window.height) / 2
        return CGSize(width: min(max(o.width, -dx), dx), height: min(max(o.height, -dy), dy))
    }

    /// The window's contents, the canvas colour where the picture does not reach.
    private func cropped() -> CGImage? {
        guard window.width > 0, scale > 0 else { return nil }
        let outHeight = min(1024, max(256, window.height / scale))
        let k = outHeight / window.height
        let width = Int((window.width * k).rounded()), height = Int(outHeight.rounded())
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.03, green: 0.03, blue: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = min(size.width, size.height) <= 128 ? .none : .high
        let drawn = CGSize(width: size.width * scale * k, height: size.height * scale * k)
        // Core Graphics counts y from the bottom; SwiftUI's offset counts it from the top.
        let x = (window.width / 2 + offset.width) * k - drawn.width / 2
        let y = (window.height / 2 - offset.height) * k - drawn.height / 2
        ctx.draw(image, in: CGRect(origin: CGPoint(x: x, y: y), size: drawn))
        return ctx.makeImage()
    }
}
