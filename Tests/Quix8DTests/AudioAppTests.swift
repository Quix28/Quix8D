import XCTest
@testable import Quix8D

final class AudioAppTests: XCTestCase {
    func testHelperFoldsIntoOutermostApp() {
        let app = AudioApp(executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)")
        XCTAssertEqual(app.id, "/Applications/Google Chrome.app")
        XCTAssertEqual(app.name, "Google Chrome")
    }

    func testWebKitProcessIsSafari() {
        let app = AudioApp(executablePath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU")
        XCTAssertEqual(app.id, "WebKit")
    }

    func testBareExecutableUsesItsName() {
        let app = AudioApp(executablePath: "/usr/local/bin/mpv")
        XCTAssertEqual(app.id, "/usr/local/bin/mpv")
        XCTAssertEqual(app.name, "mpv")
    }
}
