// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ToshLLM

final class GPUPeerGroupTests: XCTestCase {
    /// Measured on a Mac Pro with nine GPUs: a Vega II Duo, two bridged W6800X Duo
    /// modules and three unlinked cards.
    private let ninePack: [GPUDevice] = [
        GPUDevice(index: 0, name: "AMD Radeon Pro 580", vramMB: 8_180),
        GPUDevice(index: 1, name: "AMD Radeon Pro Vega II Duo", vramMB: 32_736,
                  peerGroupID: 9_143_958_961_641_079_496, peerCount: 2),
        GPUDevice(index: 2, name: "AMD Radeon Pro Vega II Duo", vramMB: 32_736,
                  peerGroupID: 9_143_958_961_641_079_496, peerCount: 2),
        GPUDevice(index: 3, name: "AMD Radeon PRO W6800X", vramMB: 32_752),
        GPUDevice(index: 4, name: "AMD Radeon PRO W6800", vramMB: 32_752),
        GPUDevice(index: 5, name: "AMD Radeon PRO W6800X Duo", vramMB: 32_752,
                  peerGroupID: 12_073_373_929_257_557_946, peerCount: 4),
        GPUDevice(index: 6, name: "AMD Radeon PRO W6800X Duo", vramMB: 32_752,
                  peerGroupID: 12_073_373_929_257_557_946, peerCount: 4),
        GPUDevice(index: 7, name: "AMD Radeon PRO W6800X Duo", vramMB: 32_752,
                  peerGroupID: 12_073_373_929_257_557_946, peerCount: 4),
        GPUDevice(index: 8, name: "AMD Radeon PRO W6800X Duo", vramMB: 32_752,
                  peerGroupID: 12_073_373_929_257_557_946, peerCount: 4),
    ]

    func testLinkedGPUsGroupTogetherAndUnlinkedOnesStayOut() {
        let groups = HardwareInfo.peerGroups(of: ninePack)
        XCTAssertEqual(groups.map(\.count), [4, 2])
        XCTAssertEqual(groups[0].map(\.index), [5, 6, 7, 8])
        XCTAssertEqual(groups[1].map(\.index), [1, 2])
        // The standalone W6800X is the control: same family as the bridged Duos and
        // still on its own, so a group means a link and not a card model.
        XCTAssertFalse(groups.flatMap { $0 }.contains { $0.index == 3 })
    }

    func testNoGroupsWithoutALink() {
        let single = [GPUDevice(index: 0, name: "AMD Radeon RX 6700 XT", vramMB: 12_272)]
        XCTAssertTrue(HardwareInfo.peerGroups(of: single).isEmpty)
    }

    /// A peer group needs two members; one die reporting a group id is not a link.
    func testLoneMemberIsNotAGroup() {
        let lonely = [GPUDevice(index: 0, name: "Duo", vramMB: 32_736, peerGroupID: 7, peerCount: 1)]
        XCTAssertTrue(HardwareInfo.peerGroups(of: lonely).isEmpty)
    }

    /// The reporter's machine: two Duo cards, four Metal devices, one name.
    func testDuoCardsCountAsOneCardEach() {
        let twoDuos = (0..<4).map {
            GPUDevice(index: $0, name: "AMD Radeon Pro Vega II Duo", vramMB: 32_736)
        }
        let groups = HardwareInfo.modelGroups(of: twoDuos)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].cards, 2)
        XCTAssertEqual(groups[0].gpus, 4)
        XCTAssertEqual(groups[0].vramGB, 32)
    }

    func testNonDuoCardsAreOneGPUEach() {
        let groups = HardwareInfo.modelGroups(of: [
            GPUDevice(index: 0, name: "AMD Radeon PRO W6800X", vramMB: 32_752),
            GPUDevice(index: 1, name: "AMD Radeon PRO W6800X", vramMB: 32_752),
        ])
        XCTAssertEqual(groups[0].cards, 2)
        XCTAssertEqual(groups[0].gpus, 2)
    }

    /// Mixed machines keep one row per model, in the order Metal listed them.
    func testModelGroupsKeepEnumerationOrder() {
        let groups = HardwareInfo.modelGroups(of: ninePack)
        XCTAssertEqual(groups.map(\.name), [
            "AMD Radeon Pro 580",
            "AMD Radeon Pro Vega II Duo",
            "AMD Radeon PRO W6800X",
            "AMD Radeon PRO W6800",
            "AMD Radeon PRO W6800X Duo",
        ])
        XCTAssertEqual(groups.map(\.cards), [1, 1, 1, 1, 2])
        XCTAssertEqual(groups.map(\.gpus),  [1, 2, 1, 1, 4])
    }

    /// A Duo with one die disabled is still a card, not half of one.
    func testOddDieCountRoundsUpToAWholeCard() {
        let lone = [GPUDevice(index: 0, name: "AMD Radeon Pro Vega II Duo", vramMB: 32_736)]
        XCTAssertEqual(HardwareInfo.modelGroups(of: lone)[0].cards, 1)
    }

    func testVramRoundsToTheNearestGigabyte() {
        XCTAssertEqual(GPUDevice(index: 0, name: "RX 6700 XT", vramMB: 12_272).vramGB, 12)
        XCTAssertEqual(GPUDevice(index: 0, name: "Vega II Duo", vramMB: 32_736).vramGB, 32)
    }
}
