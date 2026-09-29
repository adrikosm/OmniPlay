import GameCore
import GameDetection
import GameStore
import PhotosUI
import RuntimeCore
import SaveKit
import SwiftUI

/// The game page: the cover grown from the shelf, the title, Continue as the loudest thing on screen and three facts.
/// Detection detail waits below the fold behind a "Technical details" hint. Play stays disabled with a plain reason
/// until a runtime is bundled; nothing here decides a runtime itself.
struct GameDetailView: View {
    @Environment(AppModel.self) var model
    let game: GameRecord
    /// Continue from the library: start playing as soon as the page knows the game can run.
    var autoplay = false
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.dynamicTypeSize) var typeSize
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var autoplayed = false
    @State var snapshot: DetectionSnapshot?
    @State var facts = Facts()
    @State var showPicker = false
    @State var showPlayer = false
    @State var artworkPath: String?
    @State var showPhotos = false
    @State var showFiles = false
    @State var photoItem: PhotosPickerItem?
    @State var lowMemory = false
    @State var preflight: LaunchPreflight?
    @State var confirmRelaunch = false
    @State var confirmDelete = false
    @State var deleting = false
    @State var deleteError: String?
    /// Why the game will stop at its first picture: it needs an RTP that is not installed.
    @State var missingRTP: String?
    @State var askRTP = false
    @State var showEngineFiles = false
    @Environment(\.dismiss) var dismiss
    /// The visible height of the scroll view, so the hero can fill the first screen.
    @State var viewport: CGFloat = 0

    /// What the page reads besides detection: the file it came from, how the last session ended, the newest snapshot.
    struct Facts: Sendable {
        var sourceName: String?
        var lastSession: String?
        var sessionFailed = false
        var snapshot: String?
        /// `game` is the record as the page opened; playing updates this one.
        var lastPlayedAt: Date?
    }

    var wide: Bool { Adaptive.wide(vertical: verticalSizeClass, horizontal: horizontalSizeClass, type: typeSize) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // The hero fills the first screen with the hint at its foot; taller content just pushes the hint down.
                    VStack(spacing: 0) {
                        hero.frame(maxWidth: .infinity, alignment: .topLeading)
                        Spacer(minLength: Theme.s4)
                        hint { withAnimation(Theme.settle) { proxy.scrollTo("technical", anchor: .top) } }
                    }
                    .frame(minHeight: max(viewport, 0))
                    technical.id("technical").padding(.top, Theme.s8)
                    deleteSection.padding(.top, Theme.s8)
                }
                .padding(.horizontal, Theme.s4)
                .padding(.bottom, Theme.s8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onGeometryChange(for: CGFloat.self) { $0.size.height - $0.safeAreaInsets.top - $0.safeAreaInsets.bottom } action: {
                viewport = $0
            }
        }
        .canvas()
        .navigationTitle(game.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { coverMenu }
        }
        .task {
            artworkPath = game.artworkPath
            lowMemory = model.isLowMemory(game.id)
            await load()
            if let snapshot {
                preflight = await model.preflight(game, snapshot: snapshot)
            }
            if autoplay, !autoplayed, canPlay, !slotSpent {
                autoplayed = true
                play()
            }
        }
        .onChange(of: showEngineFiles) { _, open in
            if !open {
                checkRTP()
            }
        }
        .navigationDestination(isPresented: $showEngineFiles) { EngineAssetsView() }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
            if case let .success(url) = result {
                Task { await importCover(from: url) }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await importCover(data: data)
                }
                photoItem = nil
            }
        }
        .centeredSheet(isPresented: $showPicker) { close in
            if let snapshot {
                RuntimePicker(game: game, report: snapshot.report, current: snapshot.resolution.selectedRuntime, close: close) {
                    await choose($0)
                    close()
                }
            }
        }
        .fullScreenCover(isPresented: $showPlayer, onDismiss: { Task { await refreshAfterPlay() } }, content: {
            if let snapshot {
                PlayerScreen(game: game, snapshot: snapshot).environment(model)
            }
        })
    }

    // MARK: Hero

    @ViewBuilder var hero: some View {
        if wide {
            HStack(alignment: .top, spacing: 34) {
                cover(width: 172)
                details
            }
            .padding(.top, Theme.s1)
            .padding(.leading, Theme.s6)
        } else {
            VStack(alignment: .leading, spacing: Theme.s6) {
                cover(width: 150)
                details
            }
            .padding(.top, Theme.s4)
        }
    }

    func cover(width: CGFloat) -> some View {
        CoverImage(path: artworkPath, engine: game.engine, maxPixels: 800, title: game.title)
            .frame(width: width, height: width / Theme.coverAspect)
            .coverEdge(radius: 20)
            .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
            .contextMenu { coverMenuItems.tint(Theme.textPrimary) }
            .accessibilityLabel("Cover of \(game.title)")
    }

    var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.s2) {
                InfoPill(text: game.engineName(versionParts: 3))
                if let input = inputLine {
                    InfoPill(text: input, icon: "gamecontroller")
                }
            }
            .rise(0)
            Text(game.title)
                .display(50)
                .lineLimit(2)
                .minimumScaleFactor(0.55)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.s3)
                .maskedRise(1)
                .accessibilityAddTraits(.isHeader)
            if let source = facts.sourceName {
                Text(source).font(Theme.mono).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                    .padding(.top, Theme.s1)
                    .rise(2)
            }
            actions.padding(.top, 18).rise(3)
            factsRow.padding(.top, 22).rise(4)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    var actions: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(spacing: 10) {
                if slotSpent {
                    Button { confirmRelaunch = true } label: { Label("Save & Relaunch", systemImage: "arrow.counterclockwise") }
                        .buttonStyle(.accent)
                        .confirmationDialog("Relaunch OmniPlay?", isPresented: $confirmRelaunch, titleVisibility: .visible) {
                            Button("Save & Relaunch") { Task { await model.relaunch(opening: game.id) } }
                        } message: {
                            Text("Any running game is stopped and its saves flushed. OmniPlay closes and reopens on this game.")
                        }
                } else {
                    Button { play() } label: { Label(playTitle, systemImage: "play.fill") }
                        .buttonStyle(.accent)
                        .disabled(!canPlay)
                        .confirmationDialog("This game needs an RTP", isPresented: $askRTP, titleVisibility: .visible) {
                            Button("Import RTP…") { showEngineFiles = true }
                            Button("Play anyway") { showPlayer = true }
                        } message: {
                            Text(missingRTP ?? "")
                        }
                }
                NavigationLink { GameToolsView(game: game, snapshot: snapshot) } label: { Text("Game Tools") }
                    .buttonStyle(.secondary)
            }
            if slotSpent {
                note("Restart needed. This engine can run one game per app launch.")
            } else if snapshot != nil, !canPlay || snapshot?.resolution.manualOverride == true {
                note(playReason)
            } else if let missingRTP {
                note(missingRTP)
            }
        }
    }

    /// Asks first when the engine would stop at a missing RTP picture, since that also spends its one boot.
    func play() {
        if missingRTP == nil {
            showPlayer = true
        } else {
            askRTP = true
        }
    }

    func checkRTP() {
        missingRTP = snapshot.flatMap {
            RTPManager.explanation(for: RTPManager.status(for: $0.report.descriptor, paths: model.paths))
        }
    }

    func note(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420, alignment: .leading)
    }

    /// Three facts a player asks about, in one row. Detection detail lives under Technical details.
    var factsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 36) { factItems }
            VStack(alignment: .leading, spacing: Theme.s3) { factItems }
        }
    }

    @ViewBuilder var factItems: some View {
        fact("Last played", lastPlayedAt?.formatted(.relative(presentation: .named)).capitalizedFirst ?? "Not yet")
        fact("Last session", facts.lastSession ?? "None yet", failed: facts.sessionFailed)
        fact("Snapshot", facts.snapshot ?? "None yet")
    }

    func fact(_ label: String, _ value: String, failed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.footnote).foregroundStyle(Theme.textSecondary)
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(failed ? Theme.danger : Theme.textPrimary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    /// "Technical details" and a small chevron that nudges down; a tap scrolls to them.
    func hint(_ reveal: @escaping () -> Void) -> some View {
        Button(action: reveal) {
            HStack(spacing: 6) {
                Text("Technical details")
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    .phaseAnimator(reduceMotion ? [0.0] : [0.0, 4.0]) { chevron, y in chevron.offset(y: y) } animation: { _ in
                        .easeInOut(duration: 0.7)
                    }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(minHeight: 44)
            .padding(.horizontal, Theme.s4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .rise(6)
    }
}
