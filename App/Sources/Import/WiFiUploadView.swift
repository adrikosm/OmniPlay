import CoreImage.CIFilterBuiltins
import Foundation
import GameCore
import LocalGameServer
import SwiftUI

/// Wi-Fi upload: a page on this phone that a computer on the same network opens to send a game folder.
/// Off by default, started here, stopped the moment this screen closes or the app leaves the foreground.
struct WiFiUploadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var server: UploadServer?
    @State private var address: String?
    @State private var received: [(String, Int64)] = []
    @State private var status = "Starting…"
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    Text("On a computer on the same Wi-Fi, open this address in a browser and pick the game folder.")
                        .foregroundStyle(Theme.textSecondary)
                    if let address {
                        VStack(spacing: Theme.s3) {
                            if let qr = Self.qrCode(address) {
                                Image(decorative: qr, scale: 1).interpolation(.none).resizable().scaledToFit().frame(
                                    width: 180,
                                    height: 180
                                )
                                .padding(Theme.s3).background(.white, in: .rect(cornerRadius: 12))
                            }
                            Text(address).font(.system(.title3, design: .monospaced, weight: .semibold)).foregroundStyle(Theme.lantern)
                                .textSelection(.enabled).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(Theme.s4).glassCard()
                    }
                    Text(status).font(.footnote).foregroundStyle(Theme.textSecondary)
                    if let failure {
                        Text(failure).font(.footnote).foregroundStyle(Theme.danger)
                    }
                    if !received.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.s1) {
                            Text("Received").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                            ForEach(received.suffix(8), id: \.0) { file in
                                HStack {
                                    Text(file.0).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(file.1.formatted(.byteCount(style: .file))).font(.caption)
                                }
                                .foregroundStyle(Theme.textSecondary)
                            }
                            Text("\(received.count) files").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(Theme.s4).frame(maxWidth: .infinity, alignment: .leading).glassCard()
                    }
                }
                .padding(Theme.s4)
            }
            .inkScreen()
            .navigationTitle("Wi-Fi upload")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .task { await run() }
        .onDisappear { Task { await server?.stop() } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                Task { await server?.stop() }; status = "Stopped because OmniPlay left the foreground."
            }
        }
    }

    private func run() async {
        let staging = model.paths.tier(.importStaging, for: GameID())
        let server = UploadServer(stagingRoot: staging)
        self.server = server
        do {
            let port = try await server.start()
            guard let ip = LANAddress.current() else {
                status = "This device is not on a Wi-Fi network."
                await server.stop()
                return
            }
            address = "http://\(ip):\(port)/\(server.token)"
            status = "Waiting for a browser. The address stops working when you leave this screen."
        } catch {
            failure = "The upload page could not start: \(error.localizedDescription)"
            return
        }
        for await event in server.events {
            switch event {
            case let .fileReceived(path, bytes):
                received.append((path, bytes))
                status = "Receiving…"
            case let .sessionCompleted(dir, files, bytes):
                status = "Received \(files) files (\(bytes.formatted(.byteCount(style: .file)))). Importing."
                await model.imports?.enqueue(dir)
                received.removeAll()
            case let .failed(reason):
                failure = "\(reason). Ask the browser to upload again."
            }
        }
    }

    static func qrCode(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(
            output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))
        )
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
