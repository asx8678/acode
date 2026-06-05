import Testing
@testable import acode

@Test func test_renderer_color_disabled() {
    #expect(Renderer.colorEnabled(isTTY: false, noColor: false) == false)
    #expect(Renderer.colorEnabled(isTTY: true, noColor: true) == false)
    #expect(Renderer.colorEnabled(isTTY: true, noColor: false) == true)
}
