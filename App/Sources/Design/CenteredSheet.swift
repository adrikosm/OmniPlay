import SwiftUI

// MARK: - Centred sheets

/// A small glass sheet in the middle of the screen over a dimmed page (runtime choice, save details, restore
/// picker). Present it without the system slide: `withTransaction(\.disablesAnimations, true) { shown = true }`;
/// the sheet springs in by itself and fades out before it goes.
struct CenteredSheet<Content: View>: View {
    @Binding var isPresented: Bool
    var width: CGFloat = 440
    @ViewBuilder var content: (_ close: @escaping () -> Void) -> Content
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.5 : 0)
                .ignoresSafeArea()
                .onTapGesture { close() }
                .accessibilityHidden(true)
            if shown {
                ScrollView {
                    content(close).padding(22)
                }
                .scrollBounceBehavior(.basedOnSize)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: width)
                .glass(radius: Theme.sheetRadius, heavy: true)
                .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
                .padding(Theme.s4)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
                .accessibilityAddTraits(.isModal)
            }
        }
        .onAppear { withAnimation(Theme.motion(Theme.sheet, reduce: reduceMotion)) { shown = true } }
    }

    private func close() {
        withAnimation(Theme.quick) { shown = false } completion: {
            withTransaction(\.disablesAnimations, true) { isPresented = false }
        }
    }
}

extension View {
    func centeredSheet(
        isPresented: Binding<Bool>,
        width: CGFloat = 440,
        @ViewBuilder content: @escaping (_ close: @escaping () -> Void) -> some View
    ) -> some View {
        fullScreenCover(isPresented: isPresented) {
            CenteredSheet(isPresented: isPresented, width: width, content: content)
                .presentationBackground(.clear)
                .preferredColorScheme(.dark)
        }
    }
}

/// The title row of a centred sheet: a bold title and a round close button.
struct SheetHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Text(title).font(.title3.weight(.bold)).tracking(-0.4).foregroundStyle(Theme.textPrimary).accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.s3)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 13, weight: .bold)) }
                .buttonStyle(.round(32))
                .frame(width: 44, height: 44)
                .accessibilityLabel("Close")
        }
    }
}

/// A choice in a centred sheet: title, one-line reason, a radio mark; the selected row is filled.
struct RadioRow: View {
    let title: String
    var subtitle: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                    if let subtitle {
                        Text(subtitle).font(.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.s2)
                ZStack {
                    Circle().strokeBorder(selected ? Theme.textPrimary : Theme.textTertiary, lineWidth: 1.5)
                    if selected {
                        Circle().fill(Theme.textPrimary).padding(5).transition(.scale)
                    }
                }
                .frame(width: 22, height: 22)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(selected ? Theme.fill : .clear, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.separator, lineWidth: selected ? 0 : 0.5))
            .contentShape(.rect)
        }
        .buttonStyle(PressButtonStyle(scale: 0.98))
        .animation(Theme.snap, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
