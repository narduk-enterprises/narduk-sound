import Testing

@testable import NardukSonify

@Suite struct NardukSonifyTests {
    @Test func targetBuilds() {
        _ = NardukSonifyPlaceholder.self
    }
}
