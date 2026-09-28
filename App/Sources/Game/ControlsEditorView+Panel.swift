import InputKit
import SwiftUI

extension ControlsEditorView {
    // MARK: Panel

    func panel(landscape: Bool, full: CGSize) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack(spacing: Theme.s2) {
                    Text("Controls").font(.title3.weight(.bold)).tracking(-0.4).foregroundStyle(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    moreMenu(landscape)
                    Button("Done") {
                        onDone(ControlsLayoutSet(landscape: set.landscape, portrait: set.portrait, opacity: set.opacity, source: "user"))
                    }
                    .buttonStyle(.link)
                    .font(.body.weight(.semibold))
                }
                GlassSegmentBar(
                    items: [(Arrangement.diamond, "Diamond"), (.row, "Row"), (.hidden, "Hidden")],
                    selection: Binding(get: { arrangement(landscape) }, set: { arrange($0, landscape: landscape, full: full) }),
                    fill: true
                )
                .rise(1)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.s2), GridItem(.flexible())], spacing: Theme.s2) {
                    ForEach(Array(faces(landscape).enumerated()), id: \.element.id) { index, control in
                        remapRow(control).rise(2 + index)
                    }
                }
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        Text("Opacity").font(.subheadline).foregroundStyle(Theme.textPrimary)
                        Slider(value: $opacity, in: 0.2 ... 1.0).tint(Theme.textPrimary).accessibilityLabel("Touch control opacity")
                    }
                    .padding(.horizontal, 14).frame(minHeight: 48)
                    Rectangle().fill(Theme.separator).frame(height: 0.5).padding(.leading, 14)
                    Toggle("Hide with a controller", isOn: $hideWithController)
                        .font(.subheadline).foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14).frame(minHeight: 48)
                }
                .background(Theme.fill, in: .rect(cornerRadius: 16, style: .continuous))
                .rise(6)
                Text(selectedHint(landscape)).font(.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .padding(18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
    }

    /// Size for the selected control, else how the canvas works.
    func selectedHint(_ landscape: Bool) -> String {
        guard let selected, let anchor = current(landscape).anchor(target(selected)) else {
            return "Drag a button to move it. Pinch to resize. Touch and hold for more."
        }
        let name = selected == Self.dpadID ? "D-pad" : current(landscape).buttons.first { $0.id == selected }?.label ?? "Button"
        return "\(name): \(Int(anchor.size)) pt. Pinch to resize."
    }

    /// A face button: its letter, what it does, and a menu of every key to give it instead.
    func remapRow(_ control: ControlsLayout.Control) -> some View {
        keyMenu { key in
            remember()
            // The mapping belongs to the button, not the orientation.
            set.landscape.setKey(key, for: control.id)
            set.portrait.setKey(key, for: control.id)
        } label: {
            HStack(spacing: 10) {
                Text(control.label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(width: 30, height: 30).background(Theme.fillStrong, in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text(control.keys.first.map { KeyCatalog.label(for: $0) + " key" } ?? "No key").font(.caption)
                        .foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Text(control.keys.first.map(KeyCatalog.action) ?? "None").font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                Chevron()
            }
            .padding(.horizontal, Theme.s3)
            .frame(minHeight: 56)
            .background(Theme.fill, in: .rect(cornerRadius: 16, style: .continuous))
            .contentShape(.rect)
        }
        .accessibilityLabel("Button \(control.label), \(control.keys.first.map(KeyCatalog.action) ?? "None")")
        .accessibilityHint("Choose another key")
    }

    func moreMenu(_ landscape: Bool) -> some View {
        Menu {
            Button("Undo", systemImage: "arrow.uturn.backward") { undo() }.disabled(history.isEmpty)
            keyMenu { key in
                remember()
                var id = ""
                edit(landscape) { id = $0.add(key) }
                selected = id
            } label: {
                Label("Add a button", systemImage: "plus.circle")
            }
            Button("Reset to the built-in layout", systemImage: "arrow.counterclockwise") {
                remember()
                set = builtIn
                selected = nil
            }
            Divider()
            Button("Discard changes", systemImage: "xmark", role: .destructive, action: onCancel)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                .frame(width: 36, height: 36).background(Theme.fill, in: .circle)
                .frame(width: 44, height: 44)
        }
        .tint(Theme.textPrimary)
        .accessibilityLabel("More")
    }

    func keyMenu(_ pick: @escaping (GameKey) -> Void, @ViewBuilder label: () -> some View) -> some View {
        Menu {
            ForEach(KeyCatalog.groups) { group in
                Menu(group.title) {
                    ForEach(group.keys, id: \.key.rawValue) { entry in
                        Button(entry.name) { pick(entry.key) }
                    }
                }
            }
        } label: {
            label()
        }
    }

    // MARK: Arrangement

    enum Arrangement: Hashable { case diamond, row, hidden }

    func arrangement(_ landscape: Bool) -> Arrangement {
        guard padVisible else { return .hidden }
        return current(landscape).faceArrangement == .row ? .row : .diamond
    }

    /// Diamond and Row re-lay the face buttons in both orientations; Hidden turns the pad off for this game.
    func arrange(_ choice: Arrangement, landscape: Bool, full: CGSize) {
        guard choice != .hidden else { padVisible = false; return }
        padVisible = true
        remember()
        let shape: ControlsLayout.FaceArrangement = choice == .row ? .row : .diamond
        let (long, short) = (max(full.width, full.height), min(full.width, full.height))
        withAnimation(Theme.motion(Theme.settle, reduce: reduceMotion)) {
            set.landscape.arrangeFaces(shape, canvas: (long, short))
            set.portrait.arrangeFaces(shape, canvas: (short, long))
        }
    }

    func faces(_ landscape: Bool) -> [ControlsLayout.Control] {
        let layout = current(landscape)
        // A, B, X, Y reading order for the remap grid.
        return layout.faceIDs.reversed().compactMap { id in layout.buttons.first { $0.id == id } }
            .sorted { order($0.label) < order($1.label) }
    }

    func order(_ label: String) -> Int { ["A", "B", "X", "Y"].firstIndex(of: label) ?? 4 }

    // MARK: Editing

    func target(_ id: String) -> String? { id == Self.dpadID ? nil : id }

    func current(_ landscape: Bool) -> ControlsLayout { landscape ? set.landscape : set.portrait }

    func edit(_ landscape: Bool, _ change: (inout ControlsLayout) -> Void) {
        if landscape {
            change(&set.landscape)
        } else {
            change(&set.portrait)
        }
    }

    func remember() {
        history.append(set)
        if history.count > 50 {
            history.removeFirst()
        }
    }

    func undo() {
        guard let last = history.popLast() else { return }
        withAnimation(Theme.settle) { set = last }
        if let selected, current(true).anchor(target(selected)) == nil, current(false).anchor(target(selected)) == nil {
            self.selected = nil
        }
    }
}
