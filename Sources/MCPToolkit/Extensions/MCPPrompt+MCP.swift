import Foundation
import JSONSchema
import JSONSchemaBuilder
import MCP

// MARK: - PromptMessage to SDK Conversion

extension PromptMessage {
  /// Converts this prompt message to the MCP SDK's `Prompt.Message` type.
  ///
  /// - Returns: A configured `Prompt.Message` populated with this message's content.
  internal func toPromptMessage() -> Prompt.Message {
    switch role {
    case .user:
      return .user(content.toPromptContent())
    case .assistant:
      return .assistant(content.toPromptContent())
    }
  }
}

extension PromptMessageContent {
  /// Converts this content to the MCP SDK's `Prompt.Message.Content` type.
  ///
  /// - Returns: A configured `Prompt.Message.Content` populated with this content.
  internal func toPromptContent() -> Prompt.Message.Content {
    switch self {
    case .text(let text):
      return .text(text: text)
    case .image(let data, let mimeType):
      return .image(data: data, mimeType: mimeType)
    case .audio(let data, let mimeType):
      return .audio(data: data, mimeType: mimeType)
    case .resource(let uri, let mimeType, let text, let blob):
      if let blob {
        let data = Data(base64Encoded: blob) ?? Data()
        return .resource(resource: .binary(data, uri: uri, mimeType: mimeType))
      } else {
        return .resource(resource: .text(text ?? "", uri: uri, mimeType: mimeType))
      }
    }
  }
}

// MARK: - MCPPrompt to SDK Conversion

extension MCPPrompt {
  /// Creates the `swift-sdk` representation of the prompt for `prompts/list` responses.
  ///
  /// - Returns: A configured `Prompt` populated with the prompt's metadata.
  /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-06-18/server/prompts#listing-prompts
  public func toPrompt() -> Prompt {
    // Extract argument information from the schema
    let promptArguments = extractArguments()

    return Prompt(
      name: name,
      description: description,
      arguments: promptArguments.isEmpty ? nil : promptArguments
    )
  }

  /// Extracts argument definitions from the schema for listing purposes.
  private func extractArguments() -> [Prompt.Argument] {
    let schemaValue = arguments.schemaValue
    guard case .object(let objectValue) = schemaValue,
      let properties = objectValue["properties"],
      case .object(let propsObject) = properties
    else {
      return []
    }

    // Extract required fields
    var requiredFields: Set<String> = []
    if let required = objectValue["required"], case .array(let requiredArray) = required {
      for item in requiredArray {
        if case .string(let fieldName) = item {
          requiredFields.insert(fieldName)
        }
      }
    }

    // Build argument list from properties
    return propsObject.compactMap { (key, value) -> Prompt.Argument? in
      var argDescription: String?
      if case .object(let propObject) = value,
        let desc = propObject["description"],
        case .string(let descString) = desc
      {
        argDescription = descString
      }

      return Prompt.Argument(
        name: key,
        description: argDescription,
        required: requiredFields.contains(key) ? true : nil
      )
    }
  }

  /// Converts raw MCP argument values into the strongly typed `Arguments` payload
  /// and calls `getMessages`.
  ///
  /// This helper is invoked by the `Server.register(prompts:)` integration to:
  /// 1. Transform the `[String: MCP.Value]?` arguments into `JSONValue`.
  /// 2. Parse and validate them against the prompt's declared schema.
  /// 3. Forward the confirmed payload into `getMessages(arguments:)`.
  ///
  /// - Parameter arguments: The raw JSON-like dictionary the MCP client provided.
  /// - Returns: A `GetPrompt.Result` containing the generated messages.
  /// - Throws: `MCPError` for validation failures or errors from `getMessages`.
  /// - SeeAlso: https://modelcontextprotocol.io/specification/2025-06-18/server/prompts#getting-a-prompt
  public func callGetMessages(with arguments: [String: MCP.Value]?) async throws
    -> GetPrompt
    .Result
  {
    let object = (arguments ?? [:]).mapValues(JSONValue.init(value:))
    return try await callGetMessages(with: object)
  }

  /// Converts the raw SDK prompt arguments into a schema-shaped object and calls `getMessages`.
  ///
  /// The official `swift-sdk` 0.12.0 prompt transport now supplies `[String: String]?` here,
  /// so this adapter stays internal to the registration path instead of weakening the public
  /// helper API above.
  ///
  /// - Parameter arguments: Raw prompt arguments from `GetPrompt.Parameters.arguments`.
  /// - Returns: A `GetPrompt.Result` containing the generated messages.
  /// - Throws: `MCPError` for validation failures or errors from `getMessages`.
  func callGetMessages(stringArguments arguments: [String: String]?) async throws
    -> GetPrompt.Result
  {
    try await callGetMessages(with: coercePromptArguments(arguments ?? [:]))
  }

  private func callGetMessages(with object: [String: JSONValue]) async throws -> GetPrompt.Result {
    let params: Arguments

    do {
      params = try self.arguments.parseAndValidate(.object(object))
    } catch ParseAndValidateIssue.parsingFailed(let parseIssues) {
      let issueMessages = parseIssues.map(\.description).joined(separator: "; ")
      throw MCPError.invalidParams("Argument parsing failed: \(issueMessages)")
    } catch ParseAndValidateIssue.validationFailed(let validationResult) {
      throw MCPError.invalidParams(
        "Argument validation failed: \(validationResult.prettyJSONString())"
      )
    } catch ParseAndValidateIssue.parsingAndValidationFailed(let parseIssues, let validationResult)
    {
      let parseMessages = parseIssues.map(\.description).joined(separator: "; ")
      throw MCPError.invalidParams(
        "Argument parsing and validation failed. Parsing: \(parseMessages). Validation: \(validationResult.prettyJSONString())"
      )
    } catch {
      throw MCPError.invalidParams("Unexpected error parsing arguments: \(error)")
    }

    let messages = try await getMessages(arguments: params)
    return GetPrompt.Result(
      description: description,
      messages: messages.map { $0.toPromptMessage() }
    )
  }

  private func coercePromptArguments(_ arguments: [String: String]) -> [String: JSONValue] {
    let propertySchemas = promptPropertySchemas()
    return arguments.reduce(into: [:]) { partialResult, pair in
      partialResult[pair.key] = coercePromptArgument(pair.value, using: propertySchemas[pair.key])
    }
  }

  private func promptPropertySchemas() -> [String: JSONValue] {
    let schemaValue = arguments.schemaValue
    guard case .object(let objectValue) = schemaValue,
      let properties = objectValue["properties"],
      case .object(let propsObject) = properties
    else {
      return [:]
    }

    return propsObject
  }

  private func coercePromptArgument(_ rawValue: String, using schemaValue: JSONValue?) -> JSONValue
  {
    guard let schemaValue, case .object(let schemaObject) = schemaValue else {
      return .string(rawValue)
    }

    let supportedTypes = schemaTypes(from: schemaObject)

    if supportedTypes.contains("boolean") {
      switch rawValue.lowercased() {
      case "true":
        return .boolean(true)
      case "false":
        return .boolean(false)
      default:
        break
      }
    }

    if supportedTypes.contains("integer"), let intValue = Int(rawValue) {
      return .integer(intValue)
    }

    if supportedTypes.contains("number"), let doubleValue = Double(rawValue) {
      return .number(doubleValue)
    }

    if supportedTypes.contains("null"), rawValue == "null" {
      return .null
    }

    return .string(rawValue)
  }

  private func schemaTypes(from schemaObject: [String: JSONValue]) -> Set<String> {
    guard let typeValue = schemaObject["type"] else {
      return []
    }

    switch typeValue {
    case .string(let typeName):
      return [typeName]
    case .array(let values):
      return Set(values.compactMap(\.string))
    default:
      return []
    }
  }
}
