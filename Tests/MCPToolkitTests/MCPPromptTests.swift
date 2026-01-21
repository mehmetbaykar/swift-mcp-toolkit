import Foundation
import MCPToolkit
import Testing

// MARK: - Test Prompts

struct SimpleGreetingPrompt: MCPPrompt {
  let name = "greeting"
  let description: String? = "Generate a personalized greeting"

  @Schemable
  struct Arguments {
    /// The name of the person to greet
    let name: String
  }

  @PromptMessageBuilder
  func getMessages(arguments: Arguments) async throws -> Messages {
    PromptMessage.user("You are a helpful assistant.")
    PromptMessage.assistant("Hello, \(arguments.name)!")
  }
}

struct FormalGreetingPrompt: MCPPrompt {
  let name = "formal_greeting"
  let description: String? = "Generate a formal or casual greeting"

  @Schemable
  struct Arguments {
    /// The name of the person to greet
    let name: String
    /// Whether to use formal style
    let formal: Bool?
  }

  func getMessages(arguments: Arguments) async throws -> Messages {
    var messages: [PromptMessage] = [
      .user("You are helping \(arguments.name).")
    ]

    if arguments.formal == true {
      messages.append(.assistant("Good day, \(arguments.name). How may I assist you?"))
    } else {
      messages.append(.assistant("Hey \(arguments.name)! What's up?"))
    }

    return messages
  }
}

struct NoArgsPrompt: MCPPrompt {
  typealias Arguments = EmptyPromptArguments

  let name = "simple"
  let description: String? = "A simple prompt with no arguments"

  @PromptMessageBuilder
  func getMessages(arguments: EmptyPromptArguments) async throws -> Messages {
    PromptMessage.user("Hello!")
  }
}

struct MultiContentPrompt: MCPPrompt {
  let name = "multi_content"

  @Schemable
  struct Arguments {
    let includeImage: Bool
    let includeAudio: Bool
    let includeResource: Bool
  }

  func getMessages(arguments: Arguments) async throws -> Messages {
    var messages: [PromptMessage] = [
      .user("Analyze the following:")
    ]

    if arguments.includeImage {
      messages.append(.user(imageData: "base64ImageData", mimeType: "image/png"))
    }

    if arguments.includeAudio {
      messages.append(.user(audioData: "base64AudioData", mimeType: "audio/mp3"))
    }

    if arguments.includeResource {
      messages.append(
        .user(resource: "file://test.txt", mimeType: "text/plain", text: "test content")
      )
    }

    messages.append(.assistant("I'll analyze that for you."))
    return messages
  }
}

struct StringLiteralPrompt: MCPPrompt {
  let name = "string_literal"

  @Schemable
  struct Arguments {
    let message: String
  }

  @PromptMessageBuilder
  func getMessages(arguments: Arguments) async throws -> Messages {
    // Using string literals (defaults to user role)
    "You are a helpful assistant."
    "The user says: \(arguments.message)"
  }
}

struct GroupedPrompt: MCPPrompt {
  let name = "grouped"

  @Schemable
  struct Arguments {
    let topic: String
  }

  @PromptMessageBuilder
  func getMessages(arguments: Arguments) async throws -> Messages {
    PromptMessageGroup(role: .user) {
      "You are an expert on \(arguments.topic)."
      "Please follow these guidelines:"
      "1. Be concise"
      "2. Be accurate"
      "3. Cite sources"
    }

    PromptMessage.assistant("I understand. I'll help with \(arguments.topic).")
  }
}

struct ErrorPrompt: MCPPrompt {
  let name = "error_prompt"

  @Schemable
  struct Arguments {
    let shouldError: Bool
  }

  func getMessages(arguments: Arguments) async throws -> Messages {
    if arguments.shouldError {
      throw PromptError("Something went wrong")
    }
    return [.user("Success!")]
  }
}

// MARK: - Test Suites

@Suite("MCPPrompt Protocol")
struct MCPPromptProtocolTests {
  @Test("toPrompt() generates correct metadata")
  func toPromptProducesValidMetadata() {
    let prompt = SimpleGreetingPrompt()
    let mcpPrompt = prompt.toPrompt()

    #expect(mcpPrompt.name == "greeting")
    #expect(mcpPrompt.description == "Generate a personalized greeting")
    #expect(mcpPrompt.arguments != nil)
    #expect(mcpPrompt.arguments?.count == 1)

    let nameArg = mcpPrompt.arguments?.first { $0.name == "name" }
    #expect(nameArg != nil)
    #expect(nameArg?.required == true)
  }

  @Test("toPrompt() extracts optional arguments correctly")
  func toPromptHandlesOptionalArgs() {
    let prompt = FormalGreetingPrompt()
    let mcpPrompt = prompt.toPrompt()

    #expect(mcpPrompt.arguments?.count == 2)

    let nameArg = mcpPrompt.arguments?.first { $0.name == "name" }
    let formalArg = mcpPrompt.arguments?.first { $0.name == "formal" }

    #expect(nameArg?.required == true)
    #expect(formalArg?.required == nil)  // Optional, so not required
  }

  @Test("toPrompt() handles empty arguments")
  func toPromptHandlesNoArgs() {
    let prompt = NoArgsPrompt()
    let mcpPrompt = prompt.toPrompt()

    #expect(mcpPrompt.name == "simple")
    #expect(mcpPrompt.description == "A simple prompt with no arguments")
    // Empty arguments should result in empty or nil arguments list
    #expect(mcpPrompt.arguments?.isEmpty != false)
  }

  @Test("Default description is nil")
  func defaultDescriptionIsNil() {
    struct NoDescPrompt: MCPPrompt {
      typealias Arguments = EmptyPromptArguments
      let name = "no_desc"

      @PromptMessageBuilder
      func getMessages(arguments: EmptyPromptArguments) async throws -> Messages {
        "Hello"
      }
    }

    let prompt = NoDescPrompt()
    #expect(prompt.description == nil)
  }
}

@Suite("MCPPrompt Message Generation")
struct MCPPromptMessageTests {
  @Test("callGetMessages returns correct messages")
  func callGetMessagesWorks() async throws {
    let prompt = SimpleGreetingPrompt()
    let result = try await prompt.callGetMessages(with: ["name": .string("Alice")])

    #expect(result.description == "Generate a personalized greeting")
    #expect(result.messages.count == 2)

    // First message should be user
    let firstMessage = result.messages[0]
    #expect(firstMessage.role == .user)
    if case .text(let text) = firstMessage.content {
      #expect(text == "You are a helpful assistant.")
    } else {
      Issue.record("Expected text content")
    }

    // Second message should be assistant
    let secondMessage = result.messages[1]
    #expect(secondMessage.role == .assistant)
    if case .text(let text) = secondMessage.content {
      #expect(text == "Hello, Alice!")
    } else {
      Issue.record("Expected text content")
    }
  }

  @Test("callGetMessages handles conditional content")
  func callGetMessagesHandlesConditionals() async throws {
    let prompt = FormalGreetingPrompt()

    // Formal style
    let formalResult = try await prompt.callGetMessages(with: [
      "name": .string("Bob"),
      "formal": .bool(true),
    ])

    #expect(formalResult.messages.count == 2)
    if case .text(let text) = formalResult.messages[1].content {
      #expect(text.contains("Good day"))
    } else {
      Issue.record("Expected text content")
    }

    // Casual style
    let casualResult = try await prompt.callGetMessages(with: [
      "name": .string("Bob"),
      "formal": .bool(false),
    ])

    if case .text(let text) = casualResult.messages[1].content {
      #expect(text.contains("Hey"))
    } else {
      Issue.record("Expected text content")
    }
  }

  @Test("callGetMessages works with empty arguments")
  func callGetMessagesWithEmptyArgs() async throws {
    let prompt = NoArgsPrompt()
    let result = try await prompt.callGetMessages(with: nil)

    #expect(result.messages.count == 1)
    #expect(result.messages[0].role == .user)
  }

  @Test("callGetMessages handles validation errors")
  func callGetMessagesHandlesValidationErrors() async throws {
    let prompt = SimpleGreetingPrompt()

    do {
      _ = try await prompt.callGetMessages(with: [:])  // Missing required "name"
      Issue.record("Expected validation error")
    } catch {
      // Expected - should throw MCPError
      #expect(
        String(describing: error).contains("parsing")
          || String(describing: error).contains("validation")
      )
    }
  }
}

@Suite("PromptMessage Content Types")
struct PromptMessageContentTests {
  @Test("Text content creates correctly")
  func textContentWorks() {
    let message = PromptMessage.user("Hello")
    #expect(message.role == .user)
    if case .text(let text) = message.content {
      #expect(text == "Hello")
    } else {
      Issue.record("Expected text content")
    }
  }

  @Test("Image content creates correctly")
  func imageContentWorks() {
    let message = PromptMessage.user(imageData: "base64data", mimeType: "image/png")
    #expect(message.role == .user)
    if case .image(let data, let mimeType) = message.content {
      #expect(data == "base64data")
      #expect(mimeType == "image/png")
    } else {
      Issue.record("Expected image content")
    }
  }

  @Test("Audio content creates correctly")
  func audioContentWorks() {
    let message = PromptMessage.assistant(audioData: "audiodata", mimeType: "audio/mp3")
    #expect(message.role == .assistant)
    if case .audio(let data, let mimeType) = message.content {
      #expect(data == "audiodata")
      #expect(mimeType == "audio/mp3")
    } else {
      Issue.record("Expected audio content")
    }
  }

  @Test("Resource content creates correctly")
  func resourceContentWorks() {
    let message = PromptMessage.user(
      resource: "file://test.txt",
      mimeType: "text/plain",
      text: "content",
      blob: "blob"
    )
    #expect(message.role == .user)
    if case .resource(let uri, let mimeType, let text, let blob) = message.content {
      #expect(uri == "file://test.txt")
      #expect(mimeType == "text/plain")
      #expect(text == "content")
      #expect(blob == "blob")
    } else {
      Issue.record("Expected resource content")
    }
  }

  @Test("String literal creates user message")
  func stringLiteralCreatesUserMessage() {
    let message: PromptMessage = "Hello, world!"
    #expect(message.role == .user)
    if case .text(let text) = message.content {
      #expect(text == "Hello, world!")
    } else {
      Issue.record("Expected text content")
    }
  }

  @Test("Multi-content prompt generates all types")
  func multiContentPromptWorks() async throws {
    let prompt = MultiContentPrompt()
    let result = try await prompt.callGetMessages(with: [
      "includeImage": .bool(true),
      "includeAudio": .bool(true),
      "includeResource": .bool(true),
    ])

    // Should have: user text, image, audio, resource, assistant text = 5 messages
    #expect(result.messages.count == 5)

    // Check image content
    if case .image(let data, let mimeType) = result.messages[1].content {
      #expect(data == "base64ImageData")
      #expect(mimeType == "image/png")
    } else {
      Issue.record("Expected image content at index 1")
    }

    // Check audio content
    if case .audio(let data, let mimeType) = result.messages[2].content {
      #expect(data == "base64AudioData")
      #expect(mimeType == "audio/mp3")
    } else {
      Issue.record("Expected audio content at index 2")
    }

    // Check resource content
    if case .resource(let uri, _, _, _) = result.messages[3].content {
      #expect(uri == "file://test.txt")
    } else {
      Issue.record("Expected resource content at index 3")
    }
  }
}

@Suite("PromptMessageBuilder")
struct PromptMessageBuilderTests {
  @Test("Builder works with string literals")
  func builderWithStringLiterals() async throws {
    let prompt = StringLiteralPrompt()
    let result = try await prompt.callGetMessages(with: ["message": .string("test")])

    #expect(result.messages.count == 2)
    #expect(result.messages[0].role == .user)
    #expect(result.messages[1].role == .user)
  }

  @Test("Builder works with PromptMessageGroup")
  func builderWithGroup() async throws {
    let prompt = GroupedPrompt()
    let result = try await prompt.callGetMessages(with: ["topic": .string("Swift")])

    #expect(result.messages.count == 2)

    // First message should be the grouped content
    if case .text(let text) = result.messages[0].content {
      #expect(text.contains("expert on Swift"))
      #expect(text.contains("1. Be concise"))
      #expect(text.contains("2. Be accurate"))
      #expect(text.contains("3. Cite sources"))
    } else {
      Issue.record("Expected text content from group")
    }
  }
}

@Suite("PromptError")
struct PromptErrorTests {
  @Test("PromptError can be thrown from getMessages")
  func promptErrorCanBeThrown() async {
    let prompt = ErrorPrompt()

    do {
      _ = try await prompt.callGetMessages(with: ["shouldError": .bool(true)])
      Issue.record("Expected PromptError to be thrown")
    } catch let error as PromptError {
      #expect(error.message == "Something went wrong")
    } catch {
      Issue.record("Expected PromptError, got \(type(of: error))")
    }
  }

  @Test("Success path works when no error")
  func successPathWorks() async throws {
    let prompt = ErrorPrompt()
    let result = try await prompt.callGetMessages(with: ["shouldError": .bool(false)])

    #expect(result.messages.count == 1)
    if case .text(let text) = result.messages[0].content {
      #expect(text == "Success!")
    } else {
      Issue.record("Expected text content")
    }
  }
}

@Suite("Prompt Server Integration")
struct PromptServerIntegrationTests {
  @Test("register(prompts:) responds to prompts/list")
  func serverHandlesPromptsList() async throws {
    let transport = TestTransport()
    let server = Server(name: "Prompt Server", version: "1.0.0")
    let prompt = SimpleGreetingPrompt()

    await server.register(prompts: [prompt])
    try await server.start(transport: transport)

    do {
      let encoder = JSONEncoder()
      let decoder = JSONDecoder()

      await transport.push(try encoder.encode(ListPrompts.request(.init())))

      let responses = try await transport.waitForSent(count: 1)
      let data = try #require(responses.first)
      let response = try decoder.decode(Response<ListPrompts>.self, from: data)
      let result = try response.result.get()
      let registeredPrompt = try #require(result.prompts.first)

      #expect(registeredPrompt.name == prompt.name)
      #expect(registeredPrompt.description == prompt.description)
    } catch {
      await transport.finish()
      await server.stop()
      throw error
    }

    await transport.finish()
    await server.stop()
  }

  @Test("register(prompts:) responds to prompts/get")
  func serverHandlesPromptsGet() async throws {
    let transport = TestTransport()
    let server = Server(name: "Prompt Server", version: "1.0.0")
    let prompt = SimpleGreetingPrompt()

    await server.register(prompts: [prompt])
    try await server.start(transport: transport)

    do {
      let encoder = JSONEncoder()
      let decoder = JSONDecoder()

      await transport.push(
        try encoder.encode(
          GetPrompt.request(.init(name: prompt.name, arguments: ["name": .string("Test")]))
        )
      )

      let responses = try await transport.waitForSent(count: 1)
      let data = try #require(responses.first)
      let response = try decoder.decode(Response<GetPrompt>.self, from: data)
      let result = try response.result.get()

      #expect(result.description == prompt.description)
      #expect(result.messages.count == 2)
    } catch {
      await transport.finish()
      await server.stop()
      throw error
    }

    await transport.finish()
    await server.stop()
  }

  @Test("register(prompts:) handles unknown prompt")
  func serverHandlesUnknownPrompt() async throws {
    let transport = TestTransport()
    let server = Server(name: "Prompt Server", version: "1.0.0")

    await server.register(prompts: [SimpleGreetingPrompt()])
    try await server.start(transport: transport)

    do {
      let encoder = JSONEncoder()
      let decoder = JSONDecoder()

      await transport.push(
        try encoder.encode(
          GetPrompt.request(.init(name: "nonexistent", arguments: nil))
        )
      )

      let responses = try await transport.waitForSent(count: 1)
      let data = try #require(responses.first)
      let response = try decoder.decode(Response<GetPrompt>.self, from: data)

      // Should return an error
      switch response.result {
      case .success:
        Issue.record("Expected error for unknown prompt")
      case .failure:
        break  // Expected
      }
    } catch {
      await transport.finish()
      await server.stop()
      throw error
    }

    await transport.finish()
    await server.stop()
  }
}
