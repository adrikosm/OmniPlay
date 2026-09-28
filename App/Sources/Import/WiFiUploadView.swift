import Foundation
import GameCore
import LocalGameServer
import SwiftUI

/// Wi-Fi upload: a page on this phone that a computer on the same network opens to send a game folder.
/// Off by default, started here, stopped the moment this screen closes or the app leaves the foreground.
/// The address is the whole job, so it is the hero; the status list says what the computer is doing.
struct WiFiUploadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var server: UploadServer?
    @State private var address: String?
    @State private var connected = false
    @State private var expected: Int64?
    @State private var receivedBytes: Int64 = 0
    @State private var receivedFiles = 0
    @State private var lastFile: String?
    @State private var completed: String?
    @State private var stopped: String?
    @State private var failure: String?
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s6) {
                HStack {
                    Text("Wi-Fi upload").font(.headline).foregroundStyle(Theme.textPrimary).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(.link)
                }
                Split(leadingWidth: 440) {
                    hero
                } trailing: {
                    status
                }
            }
            .padding(.horizontal, Theme.s6)
            .padding(.vertical, Theme.s4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(CanvasBackground())
        .preferredColorScheme(.dark)
        .task { await run() }
        .onDisappear { Task { await server?.stop() } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                Task { await server?.stop() }
                stopped = "Stopped because OmniPlay left the foreground. Close this screen and open it again to restart."
            }
        }
    }

    // MARK: Address

    private var hero: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            Text("On a computer on the same Wi-Fi, open").font(.subheadline).foregroundStyle(Theme.textSecondary).rise(0)
            if let address {
                // The scheme stays off screen (browsers add it) but in the copied text.
                let shown = address.replacingOccurrences(of: "http://", with: "")
                let cut = shown.firstIndex(of: "/") ?? shown.endIndex
                VStack(alignment: .leading, spacing: 0) {
                    Text(shown[..<cut]).display(38).monospacedDigit().maskedRise(0)
                    Text(shown[cut...]).display(38).maskedRise(1)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(shown)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.s4) { copyButton; note }
                    VStack(alignment: .leading, spacing: Theme.s3) { copyButton; note }
                }
                .padding(.top, Theme.s3)
                .rise(3)
            } else if failure == nil, stopped == nil {
                HStack(spacing: Theme.s2) {
                    ProgressView().controlSize(.small)
                    Text("Starting…").font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                .frame(minHeight: 90)
            }
            if let message = failure ?? stopped {
                Text(message).font(.footnote).foregroundStyle(failure != nil ? Theme.danger : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = address
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : "Copy address", systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.secondary)
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
    }

    private var note: some View {
        Text("The address stops working when you leave this screen.")
            .font(.footnote).foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 220, alignment: .leading)
    }

    // MARK: Status

    private var status: some View {
        GlassSection("Status") {
            ListRow(title: connected ? "Computer connected" : "Waiting for a computer") {
                if connected {
                    Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.success)
                        .transition(.scale.combined(with: .opacity))
                } else if address != nil, stopped == nil {
                    ProgressView().controlSize(.small)
                }
            }
            if let completed {
                ListRow(title: completed) {
                    Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.success)
                }
            } else if receivedFiles > 0 {
                transfer
            }
        }
        .animation(Theme.settle, value: connected)
        .animation(Theme.settle, value: receivedFiles > 0)
        .rise(2)
    }

    private var transfer: some View {
        let fraction = expected.map { min(1, Double(receivedBytes) / Double(max($0, 1))) }
        return VStack(alignment: .leading, spacing: Theme.s2) {
            Text(lastFile.map { "Receiving \($0)" } ?? "Receiving").font(.subheadline).foregroundStyle(Theme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            GeometryReader { geo in
                Capsule().fill(Theme.fill).overlay(alignment: .leading) {
                    Capsule().fill(Theme.accent).frame(width: max(4, geo.size.width * (fraction ?? 0.08)))
                }
            }
            .frame(height: 4)
            .animation(Theme.wipe, value: receivedBytes)
            Text(expected.map { "\(Self.megabytes(receivedBytes)) of \(Self.megabytes($0))" }
                ?? "\(Self.megabytes(receivedBytes)), \(receivedFiles) files")
                .font(Theme.mono).foregroundStyle(Theme.textSecondary).monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, Theme.s3)
        .accessibilityElement(children: .combine)
    }

    private static func megabytes(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    private func run() async {
        let staging = model.paths.tier(.importStaging, for: GameID())
        let server = UploadServer(stagingRoot: staging)
        self.server = server
        do {
            let port = try await server.start()
            guard let ip = LANAddress.current() else {
                failure = "This iPhone is not on a Wi-Fi network. Join one, then open this screen again."
                await server.stop()
                return
            }
            address = "http://\(ip):\(port)/\(server.token)"
        } catch {
            failure = "The upload page could not start: \(error.localizedDescription)"
            return
        }
        for await event in server.events {
            switch event {
            case .browserConnected:
                connected = true
            case let .expecting(bytes):
                expected = bytes
                completed = nil
            case let .fileReceived(path, bytes):
                connected = true
                receivedFiles += 1
                receivedBytes += bytes
                lastFile = path.split(separator: "/").first.map(String.init)
            case let .sessionCompleted(dir, files, bytes):
                completed = "Received \(files) files, \(bytes.formatted(.byteCount(style: .file))). Importing."
                await model.imports?.enqueue(dir)
                (receivedFiles, receivedBytes, expected) = (0, 0, nil)
            case let .failed(reason):
                failure = "\(reason). Ask the browser to upload again."
            }
        }
    }
}

/// The phone's IPv4 address on Wi-Fi (`en0`), or any non-loopback IPv4 as a fallback.
enum LANAddress {
    static func current() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var fallback: String?
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (ifa.pointee.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            let ip = String(cString: host)
            if name == "en0" {
                return ip
            }
            if fallback == nil, !ip.hasPrefix("169.254") {
                fallback = ip
            }
        }
        return fallback
    }
}
