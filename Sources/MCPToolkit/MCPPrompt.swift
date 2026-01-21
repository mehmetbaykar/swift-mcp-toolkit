/// A strongly typed interface for exposing prompt templates in a Model Context Protocol server.
///
/// Conforming types define the arguments for their prompts and provide message content using a
/// declarative result builder syntax. This makes it straightforward to build prompts with rich
/// metadata and type safety, while remaining fully compatible with the MCP specification.
///
/// Use the ``Schemable`` protocol to describe your arguments.
/// Once registered, the prompt's metadata will be surfaced automatically through
/// `prompts/list`, and its handler will be invoked on `prompts/get`.
///
/// ## Example: A Simple Greeting Prompt
///
/// ```swift
/// struct GreetingPrompt: MCPPrompt {
///   let name = "greeting"
///   let description: String? = "Generate a personalized greeting"
///
///   @Schemable
///   struct Arguments {
///     let name: String
///     let formal: Bool?
///   }
///
///   @PromptMessageBuilder
///   func getMessages(arguments: Arguments) async throws -> Messages {
///     PromptMessage.user("You are a friendly assistant helping \(arguments.name).")
///
///     if arguments.formal == true {
///       PromptMessage.assistant("Good day, \(arguments.name). How may I assist you?")
///     } else {
///       PromptMessage.assistant("Hey \(arguments.name)! What can I help you with?")
///     }
///   }
/// }
/// ```
///
/// ## Multi-Content Messages
///
/// Prompts can include various content types including text, images, audio, and resources:
///
/// ```swift
/// struct ImageAnalysisPrompt: MCPPrompt {
///   let name = "analyze_image"
///
///   @Schemable
///   struct Arguments {
///     let imageUri: String
///     let detailLevel: String?
///   }
///
///   @PromptMessageBuilder
///   func getMessages(arguments: Arguments) async throws -> Messages {
///     PromptMessage.user(resource: arguments.imageUri, mimeType: "image/png")
///     PromptMessage.user("Please analyze this image.")
///   }
/// }
/// ```
public protocol MCPPrompt: Sendable {
  /// Type alias for the messages produced by the result builder.
  typealias Messages = [PromptMessage]

  /// The strongly typed arguments expected when the prompt is retrieved via `prompts/get`.
  associatedtype Arguments
  /// The JSON Schema builder output describing the `Arguments` shape.
  associatedtype Schema: JSONSchemaComponent<Arguments>

  /// The unique identifier exposed to MCP clients.
  var name: String { get }
  /// An optional natural-language description surfaced through `prompts/list`.
  var description: String? { get }

  /// The JSON Schema definition for the arguments.
  @JSONSchemaBuilder
  var arguments: Schema { get }

  /// Generate the prompt messages with validated arguments.
  ///
  /// Implement this method to define your prompt's message structure:
  ///
  /// ```swift
  /// @PromptMessageBuilder
  /// func getMessages(arguments: Arguments) async throws -> Messages {
  ///   PromptMessage.user("Hello, \(arguments.name)!")
  /// }
  /// ```
  ///
  /// - Parameter arguments: The decoded argument payload that satisfied the schema.
  /// - Returns: Message items to return to the caller.
  /// - Throws: ``PromptError`` for custom error handling.
  @PromptMessageBuilder
  func getMessages(arguments: Arguments) async throws -> Messages
}

extension MCPPrompt {
  /// Default implementation that emits no description.
  public var description: String? {
    nil
  }
}

extension MCPPrompt where Arguments: Schemable, Arguments.Schema.Output == Arguments {
  /// Provides a synthesized schema for ``Arguments`` when it conforms to ``Schemable``.
  public var arguments: some JSONSchemaComponent<Arguments> {
    Arguments.schema
  }
}

// MARK: - Empty Arguments Support

/// A type representing empty arguments for prompts that don't require any.
///
/// Use this type when your prompt doesn't need any arguments:
///
/// ```swift
/// struct SimplePrompt: MCPPrompt {
///   typealias Arguments = EmptyPromptArguments
///
///   let name = "simple"
///
///   @PromptMessageBuilder
///   func getMessages(arguments: EmptyPromptArguments) async throws -> Messages {
///     PromptMessage.user("Hello!")
///   }
/// }
/// ```
public struct EmptyPromptArguments: Schemable, Sendable {
  public init() {}

  public static var schema: some JSONSchemaComponent<EmptyPromptArguments> {
    JSONObject {}.map { _ in EmptyPromptArguments() }
  }
}

// MARK: - Prompt Error

/// An error type that prompts can throw to provide custom error handling.
///
/// Use this error type when you want to signal prompt-specific errors:
///
/// ```swift
/// func getMessages(arguments: Arguments) async throws -> Messages {
///   guard !arguments.name.isEmpty else {
///     throw PromptError("Name cannot be empty")
///   }
///   return [.user("Hello, \(arguments.name)!")]
/// }
/// ```
public struct PromptError: Error, Sendable {
  /// The error message.
  public let message: String

  /// Creates a prompt error with a message.
  ///
  /// - Parameter message: The error message.
  public init(_ message: String) {
    self.message = message
  }
}

// MARK: - Prompt Message

/// Represents a single message in a prompt conversation.
///
/// This wrapper type provides a convenient way to construct prompt messages with various content
/// types while avoiding retroactive conformance issues with the MCP SDK's types.
public struct PromptMessage: Sendable {
  /// The role of the message sender.
  public let role: PromptMessageRole
  /// The content of the message.
  public let content: PromptMessageContent

  /// Creates a prompt message with the specified role and content.
  public init(role: PromptMessageRole, content: PromptMessageContent) {
    self.role = role
    self.content = content
  }

  // MARK: - Factory Methods

  /// Creates a user message with text content.
  ///
  /// - Parameter text: The text content.
  /// - Returns: A user message with the specified text.
  public static func user(_ text: String) -> PromptMessage {
    PromptMessage(role: .user, content: .text(text))
  }

  /// Creates an assistant message with text content.
  ///
  /// - Parameter text: The text content.
  /// - Returns: An assistant message with the specified text.
  public static func assistant(_ text: String) -> PromptMessage {
    PromptMessage(role: .assistant, content: .text(text))
  }

  /// Creates a user message with image content.
  ///
  /// - Parameters:
  ///   - data: The base64-encoded image data.
  ///   - mimeType: The MIME type of the image (e.g., "image/png").
  /// - Returns: A user message with the specified image.
  public static func user(imageData data: String, mimeType: String) -> PromptMessage {
    PromptMessage(role: .user, content: .image(data: data, mimeType: mimeType))
  }

  /// Creates an assistant message with image content.
  ///
  /// - Parameters:
  ///   - data: The base64-encoded image data.
  ///   - mimeType: The MIME type of the image (e.g., "image/png").
  /// - Returns: An assistant message with the specified image.
  public static func assistant(imageData data: String, mimeType: String) -> PromptMessage {
    PromptMessage(role: .assistant, content: .image(data: data, mimeType: mimeType))
  }

  /// Creates a user message with audio content.
  ///
  /// - Parameters:
  ///   - data: The base64-encoded audio data.
  ///   - mimeType: The MIME type of the audio (e.g., "audio/mp3").
  /// - Returns: A user message with the specified audio.
  public static func user(audioData data: String, mimeType: String) -> PromptMessage {
    PromptMessage(role: .user, content: .audio(data: data, mimeType: mimeType))
  }

  /// Creates an assistant message with audio content.
  ///
  /// - Parameters:
  ///   - data: The base64-encoded audio data.
  ///   - mimeType: The MIME type of the audio (e.g., "audio/mp3").
  /// - Returns: An assistant message with the specified audio.
  public static func assistant(audioData data: String, mimeType: String) -> PromptMessage {
    PromptMessage(role: .assistant, content: .audio(data: data, mimeType: mimeType))
  }

  /// Creates a user message with embedded resource content.
  ///
  /// - Parameters:
  ///   - uri: The URI of the resource.
  ///   - mimeType: The MIME type of the resource.
  ///   - text: Optional text representation of the resource.
  ///   - blob: Optional base64-encoded binary content.
  /// - Returns: A user message with the specified resource.
  public static func user(
    resource uri: String,
    mimeType: String,
    text: String? = nil,
    blob: String? = nil
  ) -> PromptMessage {
    PromptMessage(
      role: .user,
      content: .resource(uri: uri, mimeType: mimeType, text: text, blob: blob)
    )
  }

  /// Creates an assistant message with embedded resource content.
  ///
  /// - Parameters:
  ///   - uri: The URI of the resource.
  ///   - mimeType: The MIME type of the resource.
  ///   - text: Optional text representation of the resource.
  ///   - blob: Optional base64-encoded binary content.
  /// - Returns: An assistant message with the specified resource.
  public static func assistant(
    resource uri: String,
    mimeType: String,
    text: String? = nil,
    blob: String? = nil
  ) -> PromptMessage {
    PromptMessage(
      role: .assistant,
      content: .resource(uri: uri, mimeType: mimeType, text: text, blob: blob)
    )
  }
}

// MARK: - ExpressibleByStringLiteral

extension PromptMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
  /// Creates a user message from a string literal.
  ///
  /// This allows you to write prompts more concisely:
  ///
  /// ```swift
  /// @PromptMessageBuilder
  /// func getMessages(arguments: Arguments) async throws -> Messages {
  ///   "Hello, world!"  // Becomes PromptMessage.user("Hello, world!")
  /// }
  /// ```
  public init(stringLiteral value: String) {
    self.role = .user
    self.content = .text(value)
  }
}

// MARK: - Prompt Message Role

/// The role of a message sender in a prompt conversation.
public enum PromptMessageRole: String, Sendable, Hashable, Codable {
  /// A message from the user.
  case user
  /// A message from the assistant.
  case assistant
}

// MARK: - Prompt Message Content

/// The content of a prompt message.
public enum PromptMessageContent: Sendable, Hashable {
  /// Text content.
  case text(String)
  /// Image content with base64-encoded data and MIME type.
  case image(data: String, mimeType: String)
  /// Audio content with base64-encoded data and MIME type.
  case audio(data: String, mimeType: String)
  /// Embedded resource content with URI, MIME type, and optional text/blob.
  case resource(uri: String, mimeType: String, text: String?, blob: String?)
}

// MARK: - Result Builder

/// A result builder for constructing prompt messages declaratively.
///
/// Use this builder to create prompt messages in a more readable, declarative way:
///
/// ```swift
/// @PromptMessageBuilder
/// func getMessages(arguments: Arguments) async throws -> Messages {
///   PromptMessage.user("You are a helpful assistant.")
///
///   if arguments.verbose {
///     PromptMessage.user("Please provide detailed explanations.")
///   }
///
///   PromptMessage.assistant("I understand. How can I help you today?")
/// }
/// ```
public typealias PromptMessageBuilder = ContentBuilder<PromptMessage>

extension ContentBuilder where Item == PromptMessage {
  /// Builds an expression from a `PromptMessageGroup`.
  public static func buildExpression(_ group: PromptMessageGroup) -> PromptMessage {
    group.asMessage()
  }
}

// MARK: - Prompt Message Group

/// Groups multiple text strings into a single prompt message.
///
/// Use `PromptMessageGroup` to combine multiple strings that should be treated as a single
/// logical message content block:
///
/// ```swift
/// PromptMessageGroup(role: .user) {
///   "You are a helpful assistant."
///   "Please follow these guidelines:"
///   "1. Be concise"
///   "2. Be accurate"
/// }
/// ```
public struct PromptMessageGroup: Sendable {
  private let role: PromptMessageRole
  private let lines: [String]
  private let separator: String

  /// Creates a prompt message group with the specified role and content.
  ///
  /// - Parameters:
  ///   - role: The role of the message (user or assistant).
  ///   - separator: The separator used to join lines. Defaults to newline.
  ///   - content: A result builder that produces the text lines.
  public init(
    role: PromptMessageRole,
    separator: String = "\n",
    @ArrayBuilder<String> _ content: () -> [String]
  ) {
    self.role = role
    self.lines = content()
    self.separator = separator
  }

  /// Converts this group to a single prompt message.
  fileprivate func asMessage() -> PromptMessage {
    PromptMessage(role: role, content: .text(lines.joined(separator: separator)))
  }
}
