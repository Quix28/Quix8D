import AppKit
import CoreAudio
import Darwin

/// Helper processes fold into the outermost `.app` bundle containing them.
struct AudioApp: Identifiable, Hashable {
    let id: String
    let name: String

    var icon: NSImage {
        if let cached = Self.icons[id] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: id)
        Self.icons[id] = icon
        return icon
    }

    // Main thread only; NSWorkspace's lookup is too slow to repeat on every redraw.
    private static var icons: [String: NSImage] = [:]

    init(executablePath: String) {
        let components = (executablePath as NSString).pathComponents
        if let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) {
            let appPath = NSString.path(withComponents: Array(components[...appIndex]))
            id = appPath
            name = FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
        } else if executablePath.contains("WebKit.framework") {
            // Safari and every WKWebView play through one shared WebKit process.
            id = "WebKit"
            name = "Safari & web views"
        } else {
            id = executablePath
            name = (executablePath as NSString).lastPathComponent
        }
    }

    init(id: String) {
        if id.hasSuffix(".app") {
            self.init(executablePath: id + "/Contents/MacOS/app")
        } else if id == "WebKit" {
            self.init(executablePath: "/System/Library/Frameworks/WebKit.framework/WebKit")
        } else {
            self.init(executablePath: id)
        }
    }

    init?(pid: pid_t) {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        self.init(executablePath: String(cString: buffer))
    }
}

enum AudioApps {
    static func current() -> [(app: AudioApp, processes: [AudioObjectID])] {
        var groups: [AudioApp: [AudioObjectID]] = [:]
        for (process, pid) in ProcessTapCapture.currentAudioProcesses() {
            guard let app = AudioApp(pid: pid) else { continue }
            groups[app, default: []].append(process)
        }
        return groups
            .map { (app: $0.key, processes: $0.value.sorted()) }
            .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }
}
