import Testing
import Logging
import ContainerizationError
@testable import ComposeCore

struct EnvironmentDecoderTests {
    @Test
    func invalidEnvListKeysThrow() throws {
        let yaml = """
        version: '3'
        services:
          bad:
            image: alpine
            environment:
              - "123INVALID=value"
              - 'INVALID-CHAR=value' # inline comment
              - "INVALID.DOT=value"
        """

        let log = Logger(label: "test")
        let parser = ComposeParser(log: log)
        #expect {
            _ = try parser.parse(from: yaml.data(using: .utf8)!)
        } throws: { error in
            guard let containerError = error as? ContainerizationError else { return false }
            return containerError.message.contains("Invalid environment variable name")
        }
    }
}
