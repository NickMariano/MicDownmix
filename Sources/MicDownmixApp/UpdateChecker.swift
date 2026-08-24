import AppKit
import Foundation

/// Checks GitHub Releases for a newer version, and hands the installer to macOS.
///
/// The downloaded package is verified before it is opened: signed by the same Developer Team as this
/// build, and accepted by Gatekeeper. Downloading an installer over the network and running it is
/// precisely where a compromised or substituted file would do the most damage, so neither the
/// release metadata nor the transport is trusted on its own.
@MainActor
final class UpdateChecker: ObservableObject {

    static let repository = "NickMariano/MicDownmix"
    private static let lastCheckKey = "lastUpdateCheck"
    /// Once a day is enough for a tool like this, and stays well inside GitHub's unauthenticated
    /// rate limit even with many users behind one address.
    private static let checkInterval: TimeInterval = 60 * 60 * 24

    struct Release {
        let version: String
        let downloadURL: URL
        let notesURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var latest: Release?

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    // MARK: - Checking

    /// Runs at most once a day unless the user asked.
    func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        guard last == nil || Date().timeIntervalSince(last!) > Self.checkInterval else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard state != .checking, state != .downloading else { return }
        state = .checking

        Task {
            do {
                let release = try await fetchLatest()
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                latest = release
                if Self.isNewer(release.version, than: currentVersion) {
                    state = .available(version: release.version)
                } else {
                    state = .upToDate
                }
            } catch {
                // A silent background check must not nag about a flaky network.
                state = userInitiated ? .failed(error.localizedDescription) : .idle
            }
        }
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let notes = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw UpdateError.malformed
        }

        guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".pkg") == true }),
              let urlString = asset["browser_download_url"] as? String,
              let url = URL(string: urlString), url.scheme == "https" else {
            throw UpdateError.noPackage
        }

        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       downloadURL: url, notesURL: notes)
    }

    /// Numeric component-wise comparison, so 1.10 is newer than 1.9.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: - Installing

    func downloadAndInstall() {
        guard let release = latest else { return }
        state = .downloading

        Task {
            do {
                let file = try await download(release)
                try verify(file)
                // Hand off to macOS's own installer so the user sees and approves what is happening,
                // rather than this app quietly installing something in the background.
                NSWorkspace.shared.open(file)
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func download(_ release: Release) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: release.downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicDownmix-\(release.version).pkg")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Refuses anything not signed by this build's own team and accepted by Gatekeeper.
    private func verify(_ file: URL) throws {
        let signature = try run("/usr/sbin/pkgutil", ["--check-signature", file.path])
        guard let team = Self.teamIdentifier, signature.contains(team) else {
            throw UpdateError.untrusted("it is not signed by the same developer as this copy")
        }
        let assessment = try run("/usr/sbin/spctl", ["--assess", "--type", "install", file.path])
        _ = assessment
    }

    /// This build's Team ID, read from its own signature rather than hardcoded, so a rebuilt or
    /// re-signed copy stays consistent with whatever signed it.
    static var teamIdentifier: String? {
        guard let output = try? run("/usr/bin/codesign",
                                    ["-dv", "--verbose=2", Bundle.main.bundlePath]) else { return nil }
        for line in output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value == "not set" ? nil : value
        }
        return nil
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String]) throws -> String {
        try Self.run(path, arguments)
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UpdateError.untrusted(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    func openReleasePage() {
        let url = latest?.notesURL ?? URL(string: "https://github.com/\(Self.repository)/releases/latest")!
        NSWorkspace.shared.open(url)
    }
}

enum UpdateError: LocalizedError {
    case badResponse(Int)
    case malformed
    case noPackage
    case untrusted(String)

    var errorDescription: String? {
        switch self {
        case let .badResponse(code): return "GitHub returned \(code)."
        case .malformed: return "Could not read the release information."
        case .noPackage: return "That release has no installer attached."
        case let .untrusted(detail): return "Refused the download: \(detail)"
        }
    }
}
