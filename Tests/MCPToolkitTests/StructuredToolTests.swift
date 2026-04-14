import Foundation
import MCPToolkit
import Testing

private struct StructuredSearchTool: MCPStructuredTool {
  typealias Output = SearchResult

  let name = "structured_search"
  let description: String? = "Return search results with typed structured output."

  @Schemable
  struct Parameters {
    let query: String
  }

  @Schemable
  struct SearchResult: Codable, Sendable {
    let summary: String
    let resultCount: Int
  }

  func callStructured(with arguments: Parameters) async throws(ToolError)
    -> StructuredToolResult<SearchResult>
  {
    guard !arguments.query.isEmpty else {
      throw ToolError("Query cannot be empty")
    }

    let summary = "Found 2 results for \(arguments.query)"
    return StructuredToolResult(
      structuredContent: SearchResult(summary: summary, resultCount: 2)
    ) {
      ToolContentItem(text: summary)
    }
  }
}

@Suite("Structured tool output")
struct StructuredToolTests {
  @Test("toTool() publishes an output schema for structured tools")
  func toToolIncludesOutputSchema() {
    let tool = StructuredSearchTool().toTool()

    #expect(tool.name == "structured_search")
    #expect(tool.outputSchema != nil)
  }

  @Test("call(arguments:) returns content and structuredContent")
  func callReturnsStructuredContent() async throws {
    let result = try await StructuredSearchTool().call(arguments: [
      "query": .string("swift")
    ])

    #expect(result.isError != true)
    #expect(
      result.content
        == [.text(text: "Found 2 results for swift", annotations: nil, _meta: nil)]
    )
    #expect(
      result.structuredContent
        == .object([
          "summary": .string("Found 2 results for swift"),
          "resultCount": .int(2),
        ])
    )
  }

  @Test("structured tools return error content without structuredContent on ToolError")
  func callReturnsErrorWithoutStructuredContent() async throws {
    let result = try await StructuredSearchTool().call(arguments: [
      "query": .string("")
    ])

    #expect(result.isError == true)
    #expect(
      result.content == [.text(text: "Query cannot be empty", annotations: nil, _meta: nil)]
    )
    #expect(result.structuredContent == nil)
  }
}

@Suite("Structured tool server integration")
struct StructuredToolIntegrationTests {
  @Test("register(tools:) surfaces outputSchema and structuredContent")
  func serverHandlesStructuredToolLifecycle() async throws {
    let transport = TestTransport()
    let server = Server(name: "Structured Tool Server", version: "1.0.0")
    let tool = StructuredSearchTool()

    await server.register(tools: [tool])
    try await server.start(transport: transport)

    do {
      let encoder = JSONEncoder()
      let decoder = JSONDecoder()

      await transport.push(try encoder.encode(ListTools.request(.init())))

      let listResponses = try await transport.waitForSent(count: 1)
      let listResponseData = try #require(listResponses.first)
      let listResponse = try decoder.decode(Response<ListTools>.self, from: listResponseData)
      let listResult = try listResponse.result.get()
      let registeredTool = try #require(listResult.tools.first)

      #expect(registeredTool.name == tool.name)
      #expect(registeredTool.outputSchema != nil)

      await transport.push(
        try encoder.encode(
          CallTool.request(.init(name: tool.name, arguments: ["query": .string("mcp")]))
        )
      )

      let callResponses = try await transport.waitForSent(count: 1)
      let callResponseData = try #require(callResponses.first)
      let callResponse = try decoder.decode(Response<CallTool>.self, from: callResponseData)
      let callResult = try callResponse.result.get()

      #expect(callResult.isError != true)
      #expect(
        callResult.content == [.text(text: "Found 2 results for mcp", annotations: nil, _meta: nil)]
      )
      #expect(
        callResult.structuredContent
          == .object([
            "summary": .string("Found 2 results for mcp"),
            "resultCount": .int(2),
          ])
      )
    } catch {
      await transport.finish()
      await server.stop()
      throw error
    }

    await transport.finish()
    await server.stop()
  }
}
