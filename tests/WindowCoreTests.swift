import XCTest

final class WindowCoreTests: XCTestCase {
    func testWatchCore() { runWatchCoreTests() }
    func testCraftCore() { CraftCoreTests.main() }
    func testEveningCore() { EveningCoreTests.main() }
    func testFluidity() { FluidityTests.main() }

    @MainActor func testLive() async throws { try await LiveTests.main() }
    @MainActor func testLiveWatch() async { await runLiveWatchTests() }
    @MainActor func testCraftLive() async { await CraftLiveTests.main() }
    @MainActor func testEveningLive() async { await EveningLiveTests.main() }
    @MainActor func testMonitoringCopy() async { await MonitoringCopyTests.main() }
    @MainActor func testMicroInteractions() async { await MicroInteractionTests.main() }
}
