import Foundation
import Testing

@testable import ContainerPlugin

struct CommandLineExecutableTest {
    @Test
    func testCLIPluginConfigLoad() async throws {
        #expect(CommandLine.executablePathUrl.lastPathComponent == "swiftpm-testing-helper")
    }
}
