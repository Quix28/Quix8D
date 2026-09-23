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

    private static let lastRunVersionKey = "lastRunVersion"

    /// Message for the first launch after an update, however it was installed;
    /// nil on first install or a normal launch.
    static func updateNotice(lastRunVersion: String?, current: String) -> String? {
        guard let lastRunVersion, isNewer(current, than: lastRunVersion) else { return nil }
        return "Quix8D is updated to \(current). You're up to date."
    }

    /// Records this launch's version and returns the notice, if any.
    static func takeUpdateNotice(defaults: UserDefaults = .standard) -> String? {
        let notice = updateNotice(lastRunVersion: defaults.string(forKey: lastRunVersionKey), current: currentVersion)
        defaults.set(currentVersion, forKey: lastRunVersionKey)
        return notice
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

    /// Where the update goes: in place when possible. A copy run from the DMG,
    /// or one macOS translocated to a read-only path because it was never moved
    /// out of Downloads, goes to Applications instead.
    static func installTarget(for bundle: URL, isWritable: (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) }) -> URL {
        let folder = bundle.deletingLastPathComponent()
        let isReadOnlyCopy = bundle.path.contains("/AppTranslocation/") || bundle.path.hasPrefix("/Volumes/")
        if !isReadOnlyCopy, isWritable(folder) { return bundle }
        let applications = URL(fileURLWithPath: "/Applications")
        let folderForApp = isWritable(applications)
            ? applications
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        return folderForApp.appendingPathComponent("Quix8D.app")
    }

    /// Downloads the DMG and installs it; returns the app to relaunch.
    /// `progress` gets 0...1 while downloading.
    static func install(_ release: Release, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw Failure.notInstalled }
        let installedApp = installTarget(for: Bundle.main.bundleURL)

        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Quix8D-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let dmg = workDirectory.appendingPathComponent("update.dmg")
        try await download(release.dmgURL, to: dmg, progress: progress)

        let mountPoint = workDirectory.appendingPathComponent("mount")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

        let newApp = mountPoint.appendingPathComponent("Quix8D.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else { throw Failure.appNotFound }
        guard isSignedLikeRunningApp(newApp) else { throw Failure.untrustedSignature }

        // Stage next to the target so the swap stays on one volume.
        let folder = installedApp.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appendingPathComponent(".Quix8D-update.app")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", [newApp.path, staged.path])
        if FileManager.default.fileExists(atPath: installedApp.path) {
            _ = try FileManager.default.replaceItemAt(installedApp, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: installedApp)
        }
        return installedApp
    }

    static func download(_ url: URL, to destination: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let total = max(response.expectedContentLength, 1)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        var chunk = Data()
        chunk.reserveCapacity(1 << 16)
        var received: Int64 = 0
        for try await byte in bytes {
            chunk.append(byte)
            guard chunk.count == 1 << 16 else { continue }
            try file.write(contentsOf: chunk)
            received += Int64(chunk.count)
            chunk.removeAll(keepingCapacity: true)
            let fraction = Double(received) / Double(total)
            await progress(min(fraction, 1))
        }
        try file.write(contentsOf: chunk)
        await progress(1)
    }

    static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
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
