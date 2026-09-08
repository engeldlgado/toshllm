import XCTest
@testable import ToshLLM

final class ServerNavigationTests: XCTestCase {
    @MainActor func testSelectedInstanceIsTheOnlyVisibleServer() {
        let navigation = ControlPanelState()
        let primary = ServerController()
        let secondary = ServerController()
        let servers = [primary, secondary]
        XCTAssertEqual(navigation.visibleServers(from: servers).map(\.id), servers.map(\.id))
        navigation.focusServer(secondary.id)
        XCTAssertEqual(navigation.visibleServers(from: servers).map(\.id), [secondary.id])
        navigation.focusServer(primary.id)
        XCTAssertEqual(navigation.visibleServers(from: servers).map(\.id), [primary.id])
        navigation.serverAnchor = nil
        XCTAssertEqual(navigation.visibleServers(from: servers).count, 2)
    }

    @MainActor func testServerLogBufferKeepsLatestOutputWhileCoalescingUIRefreshes() {
        let buffer = ServerLogBuffer()
        buffer.set("start\n")
        buffer.append("one\n")
        buffer.append("two\n", limit: 12, retained: 8)
        XCTAssertEqual(buffer.text, String("start\none\ntwo\n".suffix(8)))
    }
}
