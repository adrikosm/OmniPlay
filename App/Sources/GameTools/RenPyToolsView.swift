import GameStore
import GameTools
import RuntimeCore
import SwiftUI

/// Ren'Py Tools: a console that runs the player's own Python in the game's store while it plays, with history and
/// favourites, and developer switches that the host script applies at the next launch. The game's files are never
/// changed.
struct RenPyToolsView: View {
    @Environment(AppModel.self) var model
    let game: GameRecord
    let capabilities: GameToolsCapabilities
    let tools: MutationEngine?
    @State var code = ""
    @State var execute = false
    @State var transcript: [Line] = []
    @State var history: [String] = []
    @State var favourites: [String] = []
    @State var running = false
    @FocusState var typing: Bool
    @State var confirmFirstUse = false
    @State var switches: [String: Bool] = [:]
    @State var seenResult: String?
    @State var insertName = ""
    @State var insertCode = ""
    @State var inserts: [ModRecord] = []
    @State var insertMessage: String?

    struct Line: Identifiable {
        let id = UUID()
        let input: String
        let output: String
        let ok: Bool
    }

    var body: some View {
        ScrollView {
            Split(spacing: Theme.s6) {
                console.rise(0)
            } trailing: {
                VStack(alignment: .leading, spacing: Theme.s6) {
                    presets
                    switchesList
                    insertsList
                }
                .rise(2)
            }
            .padding(.horizontal, Theme.s4)
            .padding(.vertical, Theme.s3)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { typing = false }
            }
        }
        .canvas()
        .navigationTitle("Ren'Py Tools")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            history = model.consoleLines("history", for: game.id)
            favourites = model.consoleLines("favourites", for: game.id)
            for name in Self.switchInfo.map(\.name) {
                switches[name] = model.developerSwitch(name, for: game.id)
            }
            reloadInserts()
        }
        .confirmationDialog("Run your own Python?", isPresented: $confirmFirstUse, titleVisibility: .visible) {
            Button("Run") {
                UserDefaults.standard.set(true, forKey: warnedKey)
                Task { await submit() }
            }
        } message: {
            Text(
                """
                Console lines change the game directly and cannot be undone here. The saves backed up before this \
                session are the way back.
                """
            )
        }
    }

    // MARK: Console

    @ViewBuilder var console: some View {
        if capabilities.canUseRenPyConsole, tools?.console != nil {
            VStack(alignment: .leading, spacing: Theme.s3) {
                GlassSegmentBar(items: [(false, "Evaluate"), (true, "Run statements")], selection: $execute, fill: true)
                HStack(spacing: 10) {
                    commandField
                    Button {
                        if UserDefaults.standard.bool(forKey: warnedKey) {
                            Task { await submit() }
                        } else {
                            confirmFirstUse = true
                        }
                    } label: {
                        if running {
                            ProgressView().tint(Theme.canvas)
                        } else {
                            Text("Run")
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary, height: 54))
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || running)
                    .accessibilityLabel(execute ? "Run" : "Evaluate")
                }
                terminal
                recall("Favourites", favourites)
                recall("Recent", Array(history.suffix(12).reversed()))
            }
        } else {
            GlassSection {
                ListRow(icon: "terminal", title: "Console", subtitle: "Start the game to run Python in its store.", dimmed: true)
            }
        }
    }

    /// "›" and the line in mono. The caret is the accent colour; while the field is idle a caret still blinks
    /// where typing would start.
    var commandField: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("›").font(.system(.body, design: .monospaced, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            ZStack(alignment: .leading) {
                TextField("", text: $code, axis: .vertical)
                    .focused($typing)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1 ... 6)
                    .onSubmit {
                        if UserDefaults.standard.bool(forKey: warnedKey) {
                            Task { await submit() }
                        }
                    }
                    .accessibilityLabel("Python")
                if code.isEmpty, !typing {
                    BlinkingCaret().allowsHitTesting(false)
                }
            }
            if !code.isEmpty {
                Button { toggleFavourite(code) } label: {
                    Image(systemName: favourites.contains(code) ? "star.fill" : "star")
                        .foregroundStyle(favourites.contains(code) ? Theme.textPrimary : Theme.textTertiary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 32, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(favourites.contains(code) ? "Remove from favourites" : "Add to favourites")
            }
        }
        .padding(.horizontal, Theme.s4)
        .frame(minHeight: 54)
        .glass(radius: 16)
        .contentShape(.rect)
        .onTapGesture { typing = true }
    }

    /// The session so far, oldest first like a terminal, kept scrolled to the newest answer. Commands in tertiary,
    /// answers in white, errors in red; each new line fades in.
    var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.s2) {
                    if transcript.isEmpty {
                        Text(execute ? "Statements run in the game's store: score = 10" : "Expressions answer here: score")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(transcript) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("› " + line.input).foregroundStyle(Theme.textTertiary)
                            if !line.output.isEmpty {
                                Text(line.output)
                                    .foregroundStyle(line.ok ? Theme.textPrimary : Theme.danger)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(line.id)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .font(Theme.mono)
                .padding(Theme.s4)
            }
            .frame(minHeight: 120, maxHeight: 240)
            .defaultScrollAnchor(.bottom)
            .glass(radius: Theme.listRadius)
            .onChange(of: transcript.last?.id) { _, id in
                withAnimation(Theme.snap) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .animation(Theme.rise, value: transcript.count)
        .sensoryFeedback(trigger: transcript.count) { _, _ in transcript.last.map { $0.ok ? .success : .error } }
    }

    @ViewBuilder
    func recall(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textSecondary).padding(.horizontal, Theme.s1)
            ScrollView(.horizontal) {
                HStack(spacing: Theme.s2) {
                    ForEach(lines, id: \.self) { line in
                        Button { code = line } label: {
                            Text(line).font(Theme.mono).lineLimit(1)
                                .padding(.horizontal, Theme.s3).frame(minHeight: 36)
                                .background(Theme.fill, in: .rect(cornerRadius: 10, style: .continuous))
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(PressButtonStyle(scale: 0.96))
                        .foregroundStyle(Theme.textPrimary)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Presets

    /// Every image the game defines and every line of its script, marked seen in `persistent`: galleries that unlock
    /// on sight open up, and Skip passes all text. Persistent data outlives saves, so the saves are backed up first.
    var presets: some View {
        GlassSection("Presets", footer: "Changes this game's persistent data. The saves are backed up first.") {
            Button { Task { await markSeen() } } label: {
                ListRow(icon: "eye", title: "Mark everything as seen", subtitle: seenResult ?? "Unlocks galleries, lets Skip pass all text")
            }
            .buttonStyle(.plain)
            .disabled(tools?.console == nil || running)
        }
    }

    /// Keys as the engine writes them: image names as string tuples; statements by name, or by their 64-bit hash
    /// where `config.hash_seen` says so (Ren'Py 8.4 on).
    static let markSeenScript = """
    for _op_name in list(renpy.display.image.images):
        persistent._seen_images[tuple(str(_op_i) for _op_i in _op_name)] = True
    _op_hash = renpy.astsupport.hash64 if getattr(renpy.config, "hash_seen", False) else (lambda _op_n: _op_n)
    for _op_name in list(renpy.game.script.namemap):
        persistent._seen_ever[_op_hash(_op_name)] = True
    renpy.save_persistent()
    """

    func markSeen() async {
        guard let tools, let console = tools.console else { return }
        running = true
        defer { running = false }
        guard await tools.backUpOnce() else {
            seenResult = "The saves could not be backed up first, so nothing was changed."
            return
        }
        do {
            let run = try await console.runScript(Self.markSeenScript, execute: true)
            guard run.ok else { seenResult = run.output; return }
            let counts = try await console.runScript("(len(persistent._seen_images), len(persistent._seen_ever))", execute: false)
            let n = counts.output.split { !$0.isNumber }
            seenResult = counts.ok && n.count == 2 ? "Done: \(n[0]) images and \(n[1]) lines are now seen" : counts.output
        } catch {
            seenResult = "The game did not answer in time."
        }
    }

    var warnedKey: String { "renpyTools.console.warned.\(game.id.rawValue.uuidString)" }

    func submit() async {
        guard let console = tools?.console else { return }
        let input = code
        running = true
        defer { running = false }
        var ok = false
        do {
            let result = try await console.runScript(input, execute: execute)
            ok = result.ok
            transcript.append(Line(input: input, output: result.output, ok: result.ok))
        } catch StateBridgeError.timedOut {
            transcript.append(Line(input: input, output: "The game did not answer in time.", ok: false))
        } catch {
            transcript.append(Line(input: input, output: "\(error)", ok: false))
        }
        transcript = Array(transcript.suffix(40))
        history.removeAll { $0 == input }
        history.append(input)
        model.setConsoleLines(history, "history", for: game.id)
        // A line that failed stays in the field to be fixed; one that worked makes room for the next.
        if ok {
            code = ""
        }
    }

    func toggleFavourite(_ line: String) {
        if let i = favourites.firstIndex(of: line) {
            favourites.remove(at: i)
        } else {
            favourites.append(line)
        }
        model.setConsoleLines(favourites, "favourites", for: game.id)
    }
}

/// A text caret in the accent colour, blinking once a second.
struct BlinkingCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 2, height: 20)
            .phaseAnimator(reduceMotion ? [1.0] : [1.0, 0.0]) { caret, phase in caret.opacity(phase) } animation: { _ in
                .easeInOut(duration: 0.5).delay(0.25)
            }
            .accessibilityHidden(true)
    }
}
