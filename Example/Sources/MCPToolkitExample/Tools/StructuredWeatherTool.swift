import MCPToolkit

struct StructuredWeatherTool: MCPStructuredTool {
  typealias Output = WeatherReport

  let name = "structured_weather"
  let description: String? = "Return the weather for a location with structured output."

  @Schemable
  enum Unit {
    case fahrenheit
    case celsius
  }

  @Schemable
  @ObjectOptions(.additionalProperties { false })
  struct Parameters {
    /// Location as city, like "Detroit" or "New York"
    let location: String

    /// Unit for temperature
    let unit: Unit
  }

  @Schemable
  struct WeatherReport: Codable, Sendable {
    let location: String
    let condition: String
    let temperature: Int
    let unit: String
  }

  func callStructured(with arguments: Parameters) async throws(ToolError)
    -> StructuredToolResult<WeatherReport>
  {
    let (temperature, unit, summary): (Int, String, String) =
      switch arguments.unit {
      case .fahrenheit:
        (
          75,
          "fahrenheit",
          "The weather in \(arguments.location) is 75°F and sunny."
        )
      case .celsius:
        (
          24,
          "celsius",
          "The weather in \(arguments.location) is 24°C and sunny."
        )
      }

    return StructuredToolResult(
      structuredContent: WeatherReport(
        location: arguments.location,
        condition: "sunny",
        temperature: temperature,
        unit: unit
      )
    ) {
      ToolContentItem(text: summary)
    }
  }
}
