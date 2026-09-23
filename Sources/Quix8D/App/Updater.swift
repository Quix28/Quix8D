import Foundation
import Security

/// Installs new versions from the public repo's GitHub releases.
enum Updater {
    struct Release {
        let version: String
        let dmgURL: URL
    }

    enum Failure: LocalizedError {
        case notInstalled
        case noDMG
        case appNotFound
        case untrustedSignature
        case command(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "Updates only work from the installed Quix8D.app."
            case .noDMG: "The latest release has no DMG to download."
            case .appNotFound: "The downloaded DMG doesn't contain Quix8D.app."
            case .untrustedSignature: "The downloaded app isn't signed by the same developer, so it wasn't installed."
            case .command(let message): message
            }
        }
    }

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/Quix28/Quix8D/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func latestRelease() async throws -> Release {
        struct Response: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let assets: [Asset]
        }
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let dmg = response.assets.first(where: { $0.name.hasSuffix(".dmg") }) else { throw Failure.noDMG }
        let version = response.tag_name.hasPrefix("v") ? String(response.tag_name.dropFirst()) : response.tag_name
        return Release(version: version, dmgURL: dmg.browser_download_url)
    }

    /// Dotted numeric compare: "1.10" is newer than "1.9".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Downloads the DMG and replaces the running app. Relaunch afterwards.
    static func install(_ release: Release) async throws {
        let installedApp = Bundle.main.bundleURL
        guard installedApp.pathExtension == "app" else { throw Failure.notInstalled }

        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Quix8D-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let (downloaded, _) = try await URLSession.shared.download(from: release.dmgURL)
        let dmg = workDirectory.appendingPathComponent("update.dmg")
        try FileManager.default.moveItem(at: downloaded, to: dmg)

        let mountPoint = workDirectory.appendingPathComponent("mount")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

        let newApp = mountPoint.appendingPathComponent("Quix8D.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else { throw Failure.appNotFound }
        guard isSignedLikeRunningApp(newApp) else { throw Failure.untrustedSignature }

        // Stage next to the installed app so the swap stays on one volume.
        let staged = installedApp.deletingLastPathComponent().appendingPathComponent(".Quix8D-update.app")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", [newApp.path, staged.path])
        _ = try FileManager.default.replaceItemAt(installedApp, withItemAt: staged)
    }

    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
    }

    /// Same designated requirement as this process, so only our own builds install.
    private static func isSignedLikeRunningApp(_ app: URL) -> Bool {
        var selfCode: SecCode?
        var selfStaticCode: SecStaticCode?
        var requirement: SecRequirement?
        var newCode: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStaticCode) == errSecSuccess, let selfStaticCode,
              SecCodeCopyDesignatedRequirement(selfStaticCode, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(newCode, flags, requirement) == errSecSuccess
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw Failure.command("\((tool as NSString).lastPathComponent) failed: \(message)")
        }
    }
}
