// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ToshLLM

final class MCPConfigImportTests: XCTestCase {
    func testRemoteServerImportPreservesHeadersJSON() throws {
        let json = """
        {
          "mcpServers": {
            "crowdin": {
              "url": "https://mcp.crowdin.com/mcp/developer",
              "headers": {
                "Authorization": "Bearer secret-token",
                "X-Custom": "value"
              }
            }
          }
        }
        """

        let imported = try MCPConfigImport.entries(fromJSON: json)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported[0].server.name, "crowdin")
        XCTAssertEqual(imported[0].server.url, "https://mcp.crowdin.com/mcp/developer")

        let headersData = try XCTUnwrap(imported[0].headersJSON?.data(using: .utf8))
        let headers = try XCTUnwrap(JSONSerialization.jsonObject(with: headersData) as? [String: String])
        XCTAssertEqual(headers, [
            "Authorization": "Bearer secret-token",
            "X-Custom": "value"
        ])
    }

    func testRemoteServerWithoutHeadersLeavesHeadersJSONNil() throws {
        let json = """
        {
          "mcpServers": {
            "public": {
              "url": "https://example.com/mcp",
              "headers": {}
            }
          }
        }
        """

        let imported = try MCPConfigImport.entries(fromJSON: json)
        XCTAssertEqual(imported.count, 1)
        XCTAssertNil(imported[0].headersJSON)
    }
}
