import GameCore
import GameImport
import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false
    @State private var pickerError: String?
    @State private var showWiFi = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Split(leadingWidth: 420) {
                    intro
                } trailing: {
                    if let imports = model.imports {
                        if imports.items.isEmpty {
                            formats
                        } else {
                            ImportList(imports: imports)
                        }
                    }
                }
                .padding(.horizontal, Theme.s4)
                .padding(.top, Theme.s6)
                .padding(.bottom, 96)
            }
            .scrollBounceBehavior(.basedOnSize)
            .canvas()
            .toolbarVisibility(.hidden, for: .navigationBar)
            .fileImporter(
                isPresented: $showPicker,
                allowedContentTypes: [.folder, .zip, .archive, .data],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case let .success(urls): Task { for url in urls {
                        await model.imports?.enqueue(url)
                    } }
                case let .failure(error): pickerError = error.localizedDescription
                }
            }
            .sheet(isPresented: $showWiFi) { WiFiUploadView().environment(model) }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Bring a").display(48).maskedRise(0)
                Text("game in").display(48).maskedRise(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text(
                "Pick a game folder or archive from Files. Folders, zip, 7z, RAR and tar work, and so do Windows installers "
                    + "with the game inside. OmniPlay copies it into its own space, checks every file, and leaves the original untouched."
            )
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .rise(2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { importButtons }
                VStack(alignment: .leading, spacing: 10) { importButtons }
            }
            .padding(.top, Theme.s2)
            .rise(3)
            if let pickerError {
                Text(pickerError).font(.footnote).foregroundStyle(Theme.danger)
            }
        }
    }

    @ViewBuilder
    private var importButtons: some View {
        Button { showPicker = true } label: { Label("Choose from Files", systemImage: "folder") }
            .buttonStyle(.primary)
            .disabled(model.imports == nil)
        Button { showWiFi = true } label: { Label("Wi-Fi upload", systemImage: "wifi") }
            .buttonStyle(.secondary)
            .disabled(model.imports == nil)
    }

    /// What the importer actually opens (`ContainerSniffer`, `PEOverlayScanner`), and the engines that play.
    private var formats: some View {
        GlassSection("What OmniPlay reads") {
            ForEach(Self.formatRows, id: \.1) { row in
                ListRow(icon: row.0, title: row.1, subtitle: row.2)
            }
        }
        .rise(4)
    }

    private static let formatRows = [
        ("folder", "Game folders", "As copied from a PC or Mac, including Ren'Py .app bundles"),
        ("doc.zipper", "Archives", "zip, 7z, RAR, tar, gz, xz and zstd, nested ones too"),
        ("macwindow", "Windows installers", "Self-extracting .exe with CAB, zip, 7z or RAR inside; Godot .exe and .pck"),
        ("gamecontroller", "Engines that play", "RPG Maker 2000 to MZ, Ren'Py 7 and 8, Godot 3 and 4, HTML5"),
    ]
}

private struct ImportList: View {
    @Environment(AppModel.self) private var model
    let imports: ImportsModel

    var body: some View {
        GlassSection("Imports", trailing: clear) {
            ForEach(imports.items) { item in
                ImportRow(
                    item: item,
                    open: { model.open($0) },
                    resolve: { change in Task { await imports.resolve(item, change) } }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.settle, value: imports.items.map(\.id))
        .rise(4)
    }

    @ViewBuilder private var clear: some View {
        if imports.items.contains(where: \.state.isTerminal) {
            Button("Clear finished") { withAnimation(Theme.settle) { imports.clearFinished() } }.buttonStyle(.link)
        }
    }
}

/// One import: the file name in mono, a thin accent bar while it runs, and its four steps ticking off. Finished
/// imports keep one line and a Show link; questions (duplicate, password, which folder) are answered in place.
private struct ImportRow: View {
    let item: ImportItem
    let open: (GameID) -> Void
    let resolve: (@escaping (inout ImportPipeline.Options) -> Void) -> Void
    @State private var passphrase = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.s3) {
                Text(item.name).font(.system(.subheadline, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if case let .ready(id) = item.state {
                    Button("Show") { open(id) }.buttonStyle(.link)
                } else if !item.state.isTerminal {
                    Button("Cancel") { item.cancel() }.buttonStyle(.link)
                }
            }
            switch item.state {
            case .ready:
                Text("Added to Library").font(.footnote).foregroundStyle(Theme.textSecondary)
            case .queued, .staging, .inspecting, .extracting, .normalizing, .detecting, .resolvingRuntime, .analyzingMedia, .preparing,
                 .registering:
                bar
                steps
            case let .failed(.duplicate(existing, title)):
                Text("You already have \"\(title)\". Replace it, or keep both?").font(.footnote).foregroundStyle(Theme.textSecondary)
                HStack(spacing: Theme.s6) {
                    Button("Replace") { resolve { $0.duplicates = .replace(existing) } }.buttonStyle(.link)
                    Button("Keep both") { resolve { $0.duplicates = .keepBoth } }.buttonStyle(.link)
                }
            case .failed(.passwordRequired), .failed(.passwordIncorrect):
                Text(item.options.passphrase == nil ? "This archive is password protected." : "That password did not open the archive.")
                    .font(.footnote).foregroundStyle(item.options.passphrase == nil ? Theme.textSecondary : Theme.danger)
                HStack(spacing: Theme.s3) {
                    SecureField("Password", text: $passphrase)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .padding(.horizontal, Theme.s3).frame(minHeight: 44)
                        .background(Theme.fill, in: .rect(cornerRadius: Theme.fieldRadius, style: .continuous))
                        .submitLabel(.go)
                        .onSubmit { unlock() }
                    Button("Unlock") { unlock() }.buttonStyle(.link).disabled(passphrase.isEmpty)
                }
            case let .failed(.multipleRoots(candidates)):
                Text("Several game folders are inside. Which one is the game?").font(.footnote).foregroundStyle(Theme.textSecondary)
                ForEach(candidates.sorted(), id: \.self) { candidate in
                    Button { resolve { $0.chosenRoot = candidate } } label: {
                        Label(candidate, systemImage: "folder").font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.link)
                }
            case let .failed(failure):
                Text(Self.copy(for: failure)).font(.footnote).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            case .cancelled:
                Text("Cancelled. Nothing was kept.").font(.footnote).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3)
        .accessibilityElement(children: .contain)
        .sensoryFeedback(trigger: item.state.isTerminal) { _, done in
            guard done else { return nil }
            if case .ready = item.state {
                return .success
            }
            if case .failed = item.state {
                return .error
            }
            return nil
        }
    }

    /// Overall progress: the bytes of the step under way where known, otherwise how many of the four steps are done.
    private var bar: some View {
        let current = Self.step(for: item.state)
        let within = progress.flatMap(fraction) ?? 0
        let overall = min(1, (Double(max(current, 0)) + within) / Double(Self.stepTitles.count))
        return GeometryReader { geo in
            Capsule().fill(Theme.fill)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.accent).frame(width: max(4, geo.size.width * overall))
                }
        }
        .frame(height: 4)
        .animation(Theme.wipe, value: overall)
        .accessibilityElement()
        .accessibilityLabel("Import progress")
        .accessibilityValue(Text(overall, format: .percent.precision(.fractionLength(0))))
    }

    /// The four things an import does: a check for done, a spinner for the one under way, an empty ring for the rest.
    private var steps: some View {
        let current = Self.step(for: item.state)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.stepTitles.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 10) {
                    ZStack {
                        if index < current {
                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Theme.textSecondary)
                                .transition(.scale.combined(with: .opacity))
                        } else if index == current {
                            ProgressView().controlSize(.mini).tint(Theme.textPrimary)
                        } else {
                            Circle().strokeBorder(Theme.textDisabled, lineWidth: 1.2).frame(width: 12, height: 12)
                        }
                    }
                    .frame(width: 16)
                    Text(index < current ? Self.doneTitles[index] : title).font(.footnote)
                        .foregroundStyle(index == current ? Theme.textPrimary : index < current ? Theme.textSecondary : Theme.textTertiary)
                    if index == current, let p = progress, let f = fraction(p) {
                        Spacer(minLength: Theme.s2)
                        Text(f, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary).contentTransition(.numericText())
                    }
                }
            }
        }
        .animation(Theme.snap, value: current)
    }

    private var progress: ImportProgress? {
        switch item.state {
        case let .staging(p), let .extracting(p), let .preparing(p): p
        default: nil
        }
    }

    static let stepTitles = ["Copying into OmniPlay", "Checking every file", "Detecting the engine", "Adding to your library"]
    static let doneTitles = ["Copied into OmniPlay", "Checked every file", "Detected the engine", "Added to your library"]

    static func step(for state: ImportState) -> Int {
        switch state {
        case .queued, .staging, .extracting: 0
        case .inspecting, .normalizing: 1
        case .detecting, .resolvingRuntime, .analyzingMedia, .preparing: 2
        case .registering: 3
        case .ready: 4
        case .failed, .cancelled: -1
        }
    }

    private func unlock() {
        let entered = passphrase
        guard !entered.isEmpty else { return }
        resolve { $0.passphrase = entered }
    }

    private func fraction(_ p: ImportProgress) -> Double? {
        guard let total = p.totalBytes, total > 0 else { return nil }
        return min(1, Double(p.completedBytes) / Double(total))
    }

    static func copy(for failure: ImportFailure) -> String {
        switch failure {
        case let .unreadableSource(s): "The source could not be read: \(s)"
        case let .unsupportedContainer(hex): "This file type is not supported yet (\(hex))."
        case let .safetyViolation(v): "Rejected for safety: \(v.detail)\(v.entryPath.map { " at \($0)" } ?? "")."
        case let .storageInsufficient(required, available):
            "Not enough space: needs \(required.formatted(.byteCount(style: .file))), "
                + "\(available.formatted(.byteCount(style: .file))) available."
        case let .extractionFailed(entry, underlying): "Extraction failed at \(entry): \(underlying)"
        case .passwordRequired: "This archive is password protected."
        case .passwordIncorrect: "That password did not open the archive."
        case let .missingVolume(name): "Missing archive volume: \(name). Keep all volumes together and choose the first one."
        case .noGameRoot: "No game was found inside."
        case let .multipleRoots(c): "Several game folders found (\(c.joined(separator: ", "))). Import the one you want on its own."
        case let .duplicate(_, title): "Already in your library as \"\(title)\"."
        case let .detectionRefused(reason): "This game cannot run on iPhone: \(reason)"
        case .cancelled: "Cancelled."
        case let .internalError(s): "Something went wrong: \(s)"
        }
    }
}
