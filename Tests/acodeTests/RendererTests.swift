import Testing
@testable import acode

@Test func test_renderer_color_disabled() {
    #expect(Renderer.colorEnabled(isTTY: false, noColor: false) == false)
    #expect(Renderer.colorEnabled(isTTY: true, noColor: true) == false)
    #expect(Renderer.colorEnabled(isTTY: true, noColor: false) == true)
}

@Test func test_redacts_api_key() {
    // Anthropic-style key.
    let anthropic = "using key sk-ant-api03-abc123def456 now"
    let redactedAnthropic = Renderer.redactKeys(in: anthropic)
    #expect(redactedAnthropic.contains("[REDACTED]"))
    #expect(!redactedAnthropic.contains("sk-ant-api03-abc123def456"))

    // OpenAI-style key.
    let openai = "token sk-proj-abc123def456ghi789jkl012mno end"
    let redactedOpenAI = Renderer.redactKeys(in: openai)
    #expect(redactedOpenAI.contains("[REDACTED]"))
    #expect(!redactedOpenAI.contains("sk-proj-abc123def456ghi789jkl012mno"))

    // JSON header value.
    let header = "{\"x-api-key\": \"sk-ant-secretvalue123456\"}"
    let redactedHeader = Renderer.redactKeys(in: header)
    #expect(redactedHeader.contains("[REDACTED]"))
    #expect(!redactedHeader.contains("secretvalue123456"))

    // Normal message passes through unchanged.
    let normal = "Model: claude-sonnet, 3 messages, 5 tools"
    #expect(Renderer.redactKeys(in: normal) == normal)
}
