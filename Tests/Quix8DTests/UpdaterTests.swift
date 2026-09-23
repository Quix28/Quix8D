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
}
