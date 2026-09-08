import XCTest
@testable import ToshLLM

final class ServerModelSelectionTests: XCTestCase {
    @MainActor func testInstanceSelectionDoesNotChangeOtherServerOrGlobals() {
        let global = ServerSettings.fromDefaults()
        let first = ServerController()
        var firstProfile = global.makeProfile(name: "First")
        firstProfile.pinned = []
        first.profile = firstProfile
        let second = ServerController()
        var secondProfile = global.makeProfile(name: "Second")
        secondProfile.pinned = [Profile.Pin.model]
        secondProfile.modelPath = "/models/second.gguf"
        second.profile = secondProfile

        first.selectModel(path: "/models/first.gguf", ncmoe: 7)

        XCTAssertEqual(first.effectiveSettings().modelPath, "/models/first.gguf")
        XCTAssertEqual(first.effectiveSettings().ncmoe, 7)
        XCTAssertEqual(second.effectiveSettings().modelPath, "/models/second.gguf")
        XCTAssertEqual(ServerSettings.fromDefaults().modelPath, global.modelPath)
        XCTAssertEqual(ServerSettings.fromDefaults().ncmoe, global.ncmoe)
    }

    @MainActor func testPinnedModelSurvivesGlobalChangesAndPersistence() throws {
        var profile = ServerSettings.fromDefaults().makeProfile(name: "Independent")
        profile.pinned = [Profile.Pin.ctx]
        profile.selectInstanceModel(path: "/models/local.gguf", ncmoe: 5)
        let restored = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))
        var changedGlobals = ServerSettings.fromDefaults()
        changedGlobals.modelPath = "/models/new-global.gguf"
        changedGlobals.ncmoe = 19
        changedGlobals.applyPinned(restored, Set(try XCTUnwrap(restored.pinned)))
        XCTAssertEqual(changedGlobals.modelPath, "/models/local.gguf")
        XCTAssertEqual(changedGlobals.ncmoe, 5)
        XCTAssertTrue(restored.pinned?.contains(Profile.Pin.ctx) == true)
    }

    @MainActor func testRunningAndStartingInstancesRejectModelChanges() {
        let server = ServerController()
        var profile = ServerSettings.fromDefaults().makeProfile(name: "Busy")
        profile.pinned = [Profile.Pin.model]
        profile.modelPath = "/models/running.gguf"
        server.profile = profile
        for state in [ServerController.State.running, .starting] {
            server.state = state
            server.selectModel(path: "/models/replacement.gguf", ncmoe: 0)
            XCTAssertEqual(server.profile?.modelPath, "/models/running.gguf")
        }
        server.state = .stopped
    }

    @MainActor func testLegacyFullProfileKeepsItsOverrides() {
        var profile = ServerSettings.fromDefaults().makeProfile(name: "Legacy")
        profile.pinned = nil
        let originalContext = profile.ctx
        profile.selectInstanceModel(path: "/models/new.gguf", ncmoe: 3)
        XCTAssertNil(profile.pinned)
        XCTAssertEqual(profile.ctx, originalContext)
        XCTAssertEqual(profile.modelPath, "/models/new.gguf")
    }
}
