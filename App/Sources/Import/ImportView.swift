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
                VStack(alignment: .leading, spacing: Theme.s6) {
                    intro
                    if let imports = model.imports {
                        ImportList(imports: imports)
                    }
                }
                .padding(Theme.s4)
                .padding(.bottom, Theme.s8)
            }
            .inkScreen()
            .navigationTitle("Import")
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
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            Text("Bring a game in").font(Theme.title(30)).foregroundStyle(Theme.textPrimary)
            Text(
                "Pick a game folder or archive from Files: zip, 7z and tar work today, RAR and installers follow. "
                    + "OmniPlay copies it into its own space, checks every file, and keeps the original untouched."
            )
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: 420, alignment: .leading)
            HStack(spacing: Theme.s3) {
                Button { showPicker = true } label: { Label("Choose from Files", systemImage: "folder") }
                    .buttonStyle(LanternButtonStyle())
                    .disabled(model.imports == nil)
                Button { showWiFi = true } label: { Label("Wi-Fi upload", systemImage: "wifi") }
                    .foregroundStyle(Theme.textPrimary).frame(minHeight: 50).padding(.horizontal, Theme.s4).glassCard(radius: 25)
                    .disabled(model.imports == nil)
            }
            .sheet(isPresented: $showWiFi) { WiFiUploadView().environment(model) }
            if let pickerError {
                Text(pickerError).font(.footnote).foregroundStyle(Theme.danger)
            }
        }
    }
}

private struct ImportList: View {
    @Environment(AppModel.self) private var model
    let imports: ImportsModel

    var body: some View {
        if !imports.items.isEmpty {
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack {
                    Text("Imports").font(.headline).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if imports.items.contains(where: \.state.isTerminal) {
                        Button("Clear finished") { imports.clearFinished() }.font(.footnote)
                    }
                }
                ForEach(imports.items) { item in
                    ImportRow(
                        item: item,
                        showLibrary: { model.selectedTab = .library },
                        resolve: { change in Task { await imports.resolve(item, change) } }
                    )
                }
            }
        }
    }
}

private struct ImportRow: View {
    let item: ImportItem
    let showLibrary: () -> Void
    let resolve: (@escaping (inout ImportPipeline.Options) -> Void) -> Void
    @State private var passphrase = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                if !item.state.isTerminal {
                    Button("Cancel", role: .cancel) { item.cancel() }.font(.footnote)
                }
            }
            switch item.state {
            case let .staging(p), let .extracting(p), let .preparing(p):
                ProgressView(value: fraction(p)).tint(Theme.lantern)
                Text(progressText(p)).font(.footnote).foregroundStyle(Theme.textSecondary)
            case .ready:
                HStack {
                    Label("Added to your library", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Theme.lantern)
                    Spacer()
                    Button("Show", action: showLibrary).font(.footnote)
                }
            case let .failed(.duplicate(existing, title)):
                Text("You already have \"\(title)\". Replace it, or keep both?").font(.footnote).foregroundStyle(Theme.textSecondary)
                HStack(spacing: Theme.s3) {
                    Button("Replace") { resolve { $0.duplicates = .replace(existing) } }
                    Button("Keep both") { resolve { $0.duplicates = .keepBoth } }
                }
                .font(.footnote.weight(.semibold))
            case .failed(.passwordRequired):
                Text(item.options.passphrase == nil ? "This archive is password protected." : "That password did not open the archive.")
                    .font(.footnote).foregroundStyle(Theme.textSecondary)
                HStack(spacing: Theme.s2) {
                    SecureField("Password", text: $passphrase)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, Theme.s3).frame(minHeight: 44)
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
                        .submitLabel(.go)
                        .onSubmit { unlock() }
                    Button("Unlock") { unlock() }.font(.footnote.weight(.semibold)).disabled(passphrase.isEmpty)
                }
            case let .failed(.multipleRoots(candidates)):
                Text("Several game folders are inside. Which one is the game?").font(.footnote).foregroundStyle(Theme.textSecondary)
                ForEach(candidates.sorted(), id: \.self) { candidate in
                    Button {
                        resolve { $0.chosenRoot = candidate }
                    } label: {
                        Label(candidate, systemImage: "folder").font(.footnote.weight(.semibold)).frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        ).frame(minHeight: 44)
                    }
                }
            case let .failed(failure):
                Text(Self.copy(for: failure)).font(.footnote).foregroundStyle(Theme.danger)
            case .cancelled:
                Text("Cancelled. Nothing was kept.").font(.footnote).foregroundStyle(Theme.textSecondary)
            default:
                Text(Self.label(for: item.state)).font(.footnote).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(Theme.s3)
        .glassCard(radius: 14)
        .accessibilityElement(children: .combine)
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

    private func progressText(_ p: ImportProgress) -> String {
        let done = p.completedBytes.formatted(.byteCount(style: .file))
        if let total = p.totalBytes {
            return "\(Self.label(for: item.state)) \(done) of \(total.formatted(.byteCount(style: .file)))"
        }
        return "\(Self.label(for: item.state)) \(done)"
    }

    static func label(for state: ImportState) -> String {
        switch state {
        case .queued: "Waiting"
        case .staging: "Copying"
        case .inspecting: "Checking files"
        case .extracting: "Extracting"
        case .normalizing: "Tidying names"
        case .detecting: "Identifying the engine"
        case .resolvingRuntime: "Choosing a runtime"
        case .analyzingMedia: "Checking media"
        case .preparing: "Preparing"
        case .registering: "Adding to library"
        case .ready: "Ready"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
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
        case .noGameRoot: "No game was found inside."
        case let .multipleRoots(c): "Several game folders found (\(c.joined(separator: ", "))). Import the one you want on its own."
        case let .duplicate(_, title): "Already in your library as \"\(title)\"."
        case let .detectionRefused(reason): "This game cannot run on iPhone: \(reason)"
        case .cancelled: "Cancelled."
        case let .internalError(s): "Something went wrong: \(s)"
        }
    }
}
