import XCTest
@testable import Rikugan

final class DownloadPolicyTests: XCTestCase {
    func testSafeNames() {
        XCTAssertEqual(DownloadPolicy.safeName("../../state.json"), "state.json")
        XCTAssertEqual(DownloadPolicy.safeName("..\\..\\state.json"), "state.json")
        XCTAssertEqual(DownloadPolicy.safeName(".."), "download")
        XCTAssertEqual(DownloadPolicy.safeName("bad\0name.bin"), "badname.bin")
        XCTAssertLessThanOrEqual(DownloadPolicy.safeName(String(repeating: "x", count: 1000)).count, 180)
    }
    func testRelaunchNeverShowsPhantomRunningTasks() {
        for state in ["running", "pausing", "paused"] {
            XCTAssertEqual(DownloadPolicy.recoveredState(state, hasResumeData: false), "failed")
            XCTAssertEqual(DownloadPolicy.recoveredState(state, hasResumeData: true), "paused")
        }
        XCTAssertEqual(DownloadPolicy.recoveredState("finished", hasResumeData: false), "finished")
        XCTAssertEqual(DownloadPolicy.recoveredState("cancelled", hasResumeData: true), "cancelled")
    }
}
