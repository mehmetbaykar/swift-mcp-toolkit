/// A strongly typed interface for exposing Swift functions as tools in a Model Context Protocol server.
///
/// Conforming types define the JSON Schema for their expected arguments and map incoming `tools/call`
/// requests into native Swift code. This makes it straightforward to build tools with rich metadata
/// and type safety, while remaining fully compatible with the MCP specification.
///
/// Use the [``JSONSchemaBuilder`` DSL or the ``Schemable`` protocol](https://github.com/ajevans99/swift-json-schema) to describe your parameters.
/// Once registered, the tool’s schema and metadata will be surfaced automatically through
/// `tools/list`, and its handler will be invoked on `tools/call`.
///
/// ```swift
/// struct GreetingTool: MCPTool {
///   let name = "greeting"
///
///   @Schemable
///   struct Parameters {
///     let name: String
///   }
///
///   func call(with arguments: Parameters) async throws -> Content {
///     "Hello, \(arguments.name)!"
///   }
/// }
/// ```
public protocol MCPTool: Sendable {
  /// Type alias for the content produced by the result builder.
  typealias Content = [ToolContentItem]

  /// The strongly typed arguments expected when the tool is invoked via `tools/call`.
  associatedtype Parameters
  /// The JSON Schema builder output describing the `Parameters` shape.
  associatedtype Schema: JSONSchemaComponent<Parameters>

  /// The unique identifier exposed to MCP clients.
  var name: String { get }
  /// An optional natural-language description surfaced through `tools/list`.
  var description: String? { get }
  /// Additional metadata that MCP clients may use when prioritising tools.
  var annotations: Tool.Annotations { get }

  /// The JSON Schema definition that is published through `tools/list`.
  @JSONSchemaBuilder
  var parameters: Schema { get }

  /// Execute the tool with validated arguments and return content.
  ///
  /// Implement this method to define your tool's behavior:
  ///
  /// ```swift
  /// func call(with arguments: Parameters) async throws -> Content {
  ///   "Hello, \(arguments.name)!"
  /// }
  /// ```
  ///
  /// Any errors thrown from this method will automatically be caught and converted to
  /// error responses with `isError: true`. To provide custom error content, throw a ``ToolError``:
  ///
  /// ```swift
  /// func call(with arguments: Parameters) async throws -> Content {
  ///   guard !arguments.name.isEmpty else {
  ///     throw ToolError {
  ///       "Name cannot be empty"
  ///       "Please provide a valid name"
  ///     }
  ///   }
  ///   return ["Hello, \(arguments.name)!"]
  /// }
  /// ```
  ///
  /// - Parameter arguments: The decoded argument payload that satisfied ``parameters``.
  /// - Returns: Content items to return to the caller.
  /// - Throws: Any Swift error. Use ``ToolError`` for custom error content.
  @ToolContentBuilder
  func call(with arguments: Parameters) async throws(ToolError) -> Content
}

/// An opt-in tool protocol for returning both human-readable content and typed structured output.
///
/// Conforming to this protocol keeps the existing ``MCPTool`` input-side ergonomics while adding
/// output schema publication and `structuredContent` support on top of the official MCP SDK.
///
/// Tools that do not need structured output should continue conforming to ``MCPTool`` only.
public protocol MCPStructuredTool: MCPTool {
  /// The typed payload encoded into `CallTool.Result.structuredContent`.
  associatedtype Output: Codable & Sendable
  /// The JSON Schema builder output describing the structured result shape.
  associatedtype OutputSchema: JSONSchemaComponent<Output>

  /// The JSON Schema definition published as `outputSchema` through `tools/list`.
  @JSONSchemaBuilder
  var outputSchema: OutputSchema { get }

  /// Execute the tool with validated arguments and return both content and structured output.
  ///
  /// - Parameter arguments: The decoded argument payload that satisfied ``MCPTool/parameters``.
  /// - Returns: The content and structured payload to return to the caller.
  /// - Throws: ``ToolError`` for custom error content.
  func callStructured(with arguments: Parameters) async throws(ToolError)
    -> StructuredToolResult<Output>
}

/// A combined tool result that includes optional user-facing content and typed structured output.
public struct StructuredToolResult<Output: Codable & Sendable>: Sendable {
  /// User-facing tool content returned alongside the structured payload.
  public let content: [ToolContentItem]
  /// The structured payload encoded into `CallTool.Result.structuredContent`.
  public let structuredContent: Output

  /// Creates a result with structured output only.
  ///
  /// - Parameter structuredContent: The structured payload to encode.
  public init(structuredContent: Output) {
    self.content = []
    self.structuredContent = structuredContent
  }

  /// Creates a result with both content and structured output.
  ///
  /// - Parameters:
  ///   - content: User-facing content items to return.
  ///   - structuredContent: The structured payload to encode.
  public init(content: [ToolContentItem], structuredContent: Output) {
    self.content = content
    self.structuredContent = structuredContent
  }

  /// Creates a result with both content and structured output using the tool content builder.
  ///
  /// - Parameters:
  ///   - structuredContent: The structured payload to encode.
  ///   - content: A result builder that produces user-facing content items.
  public init(
    structuredContent: Output,
    @ToolContentBuilder content: () -> [ToolContentItem]
  ) {
    self.content = content()
    self.structuredContent = structuredContent
  }
}

/// An error type that tools can throw to provide custom error content.
///
/// Use this error type when you want to return specific error messages with structured content:
///
/// ```swift
/// func call(with arguments: Parameters) async throws -> Content {
///   guard arguments.value > 0 else {
///     throw ToolError {
///       "Invalid input: value must be positive"
///       "Received: \(arguments.value)"
///     }
///   }
///   return ["Success!"]
/// }
/// ```
public struct ToolError: Error, Sendable {
  /// The error content items to return.
  public let content: [ToolContentItem]

  /// Creates a tool error with declarative content.
  ///
  /// - Parameter content: A result builder that produces the error content.
  public init(@ToolContentBuilder content: () -> [ToolContentItem]) {
    self.content = content()
  }

  /// Creates a tool error with a single text message.
  ///
  /// - Parameter message: The error message.
  public init(_ message: String) {
    self.content = [ToolContentItem(text: message)]
  }
}

extension MCPTool {
  /// This is called by the MCP server infrastructure and handles automatic error conversion.
  func callToolResult(with arguments: Parameters) async throws -> CallTool.Result {
    if let structuredTool = self as? any MCPStructuredTool {
      let adapter = structuredToolAdapter(for: structuredTool)
      return try await adapter.callToolResult(arguments)
    }

    do {
      let contentItems = try await call(with: arguments) as Content
      return CallTool.Result(content: contentItems.map { $0.toToolContent() })
    } catch let error {
      return CallTool.Result(
        content: error.content.map { $0.toToolContent() },
        isError: true
      )
    }
  }
}

extension MCPTool {
  /// Default implementation that emits no description.
  public var description: String? {
    nil
  }

  /// Default implementation that emits no annotations.
  public var annotations: Tool.Annotations {
    nil
  }
}

extension MCPTool where Parameters: Schemable, Parameters.Schema.Output == Parameters {
  /// Provides a synthesized schema for ``Parameters`` when it conforms to ``Schemable``.
  public var parameters: some JSONSchemaComponent<Parameters> {
    Parameters.schema
  }
}

extension MCPStructuredTool {
  /// Default implementation that preserves the existing content-only ``MCPTool`` behavior.
  public func call(with arguments: Parameters) async throws(ToolError) -> Content {
    let result = try await callStructured(with: arguments)
    return result.content
  }
}

extension MCPStructuredTool where Output: Schemable, Output.Schema.Output == Output {
  /// Provides a synthesized output schema for structured results when `Output` conforms to
  /// ``Schemable``.
  public var outputSchema: some JSONSchemaComponent<Output> {
    Output.schema
  }
}

// MARK: - Tool Result Building

/// Represents a single content item for tool results.
///
/// This wrapper type provides a convenient way to construct tool content with string literals
/// while avoiding retroactive conformance issues with the MCP SDK's `Tool.Content` type.
public struct ToolContentItem: Sendable, ExpressibleByStringLiteral,
  ExpressibleByStringInterpolation
{
  private let content: Tool.Content

  /// Creates a text content item.
  public init(text: String) {
    self.content = .text(text: text, annotations: nil, _meta: nil)
  }

  /// Creates an image content item.
  public init(imageData: String, mimeType: String, metadata: Metadata? = nil) {
    self.content = .image(
      data: imageData,
      mimeType: mimeType,
      annotations: nil,
      _meta: metadata
    )
  }

  /// Creates an audio content item.
  public init(audioData: String, mimeType: String) {
    self.content = .audio(data: audioData, mimeType: mimeType, annotations: nil, _meta: nil)
  }

  /// Creates an embedded resource content item.
  public init(resourceUri: String, mimeType: String, text: String? = nil) {
    let resourceContent = Resource.Content.text(text ?? "", uri: resourceUri, mimeType: mimeType)
    self.content = .resource(resource: resourceContent)
  }

  /// Creates content from the underlying MCP type.
  public init(_ content: Tool.Content) {
    self.content = content
  }

  public init(stringLiteral value: String) {
    self.content = .text(text: value, annotations: nil, _meta: nil)
  }

  /// Converts to the underlying MCP `Tool.Content` type.
  fileprivate func toToolContent() -> Tool.Content {
    content
  }
}

/// A result builder for constructing tool call result content declaratively.
///
/// Use this builder to create tool content in a more readable, declarative way:
///
/// ```swift
/// func call(with arguments: Parameters) async throws(ToolError) -> Content {
///   "Hello, \(arguments.name)!"
///
///   if arguments.verbose {
///     "Additional details here"
///   }
///
///   ToolContentItem(imageData: data, mimeType: "image/png")
/// }
/// ```
public typealias ToolContentBuilder = ContentBuilder<ToolContentItem>

extension ContentBuilder where Item == ToolContentItem {
  /// Builds an expression from a `Group` of tool content items.
  public static func buildExpression(_ group: Group<ToolContentItem>) -> ToolContentItem {
    ToolContentItem(text: group.joinedText)
  }
}

struct StructuredToolAdapter: Sendable {
  let outputSchema: MCP.Value
  let callToolResult: @Sendable (Any) async throws -> CallTool.Result
}

func structuredToolAdapter<T: MCPStructuredTool>(
  for tool: T
) -> StructuredToolAdapter {
  StructuredToolAdapter(
    outputSchema: .init(schemaValue: tool.outputSchema.schemaValue),
    callToolResult: { erasedArguments in
      guard let arguments = erasedArguments as? T.Parameters else {
        throw MCPError.invalidParams("Structured tool argument type mismatch for \(tool.name)")
      }

      do {
        let result = try await tool.callStructured(with: arguments)
        return try CallTool.Result(
          content: result.content.map { $0.toToolContent() },
          structuredContent: result.structuredContent
        )
      } catch let error as ToolError {
        return CallTool.Result(
          content: error.content.map { $0.toToolContent() },
          isError: true
        )
      }
    }
  )
}
