import XCTest
@testable import Quix8D

final class UpdaterTests: XCTestCase {
    func testVersionsCompareNumerically() {
        XCTAssertTrue(Updater.isNewer("1.1", than: "1.0"))
        XCTAssertTrue(Updater.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(Updater.isNewer("2", than: "1.9.9"))
        XCTAssertFalse(Updater.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("1.0", than: "1.1"))
    }

    @MainActor
    func testDownloadWritesWholeFileAndReportsProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.bin")
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        try payload.write(to: source)

        var reported: [Double] = []
        let destination = directory.appendingPathComponent("copy.bin")
        try await Updater.download(source, to: destination) { reported.append($0) }

        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(reported.last, 1)
        XCTAssertEqual(reported, reported.sorted())
    }

    func testInstallTargetStaysInPlaceWhenWritable() {
        let app = URL(fileURLWithPath: "/Applications/Quix8D.app")
        XCTAssertEqual(Updater.installTarget(for: app) { _ in true }, app)
    }

    func testReadOnlyCopiesInstallToApplications() {
        let translocated = URL(fileURLWithPath: "/private/var/folders/lg/x/T/AppTranslocation/E373/d/Quix8D.app")
        let fromDMG = URL(fileURLWithPath: "/Volumes/Quix8D/Quix8D.app")
        let target = URL(fileURLWithPath: "/Applications/Quix8D.app")
        XCTAssertEqual(Updater.installTarget(for: translocated) { _ in true }, target)
        XCTAssertEqual(Updater.installTarget(for: fromDMG) { _ in true }, target)
    }

    func testFallsBackToUserApplicationsWithoutAdminRights() {
        let translocated = URL(fileURLWithPath: "/private/var/folders/x/T/AppTranslocation/A/d/Quix8D.app")
        let target = Updater.installTarget(for: translocated) { $0.path != "/Applications" }
        XCTAssertEqual(target.path, FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/Quix8D.app")
    }

    func testUpdateNoticeOnlyAfterAnUpgrade() {
        XCTAssertNotNil(Updater.updateNotice(lastRunVersion: "1.1.003", current: "1.1.004"))
        XCTAssertNil(Updater.updateNotice(lastRunVersion: nil, current: "1.1.004"), "first install")
        XCTAssertNil(Updater.updateNotice(lastRunVersion: "1.1.004", current: "1.1.004"), "normal launch")
        XCTAssertNil(Updater.updateNotice(lastRunVersion: "1.2", current: "1.1.004"), "downgrade")
    }
}
