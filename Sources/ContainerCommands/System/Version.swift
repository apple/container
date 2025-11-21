import ArgumentParser
import ContainerVersion
import Foundation

extension Application {
    public struct VersionCommand: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "version",
            abstract: "Show version information"
        )

        @Option(name: .long, help: "Format of the output")
        var format: ListFormat = .table

        @OptionGroup
        var global: Flags.Global

        public init() {}

        public func run() async throws {
            let versionInfo = VersionInfo(
                version: ReleaseVersion.version(),
                build: buildType(),
                commit: ReleaseVersion.gitCommit() ?? "unspecified",
                appName: "container CLI"
            )

            switch format {
            case .table:
                printVersionTable(versionInfo)
            case .json:
                printVersionJSON(versionInfo)
            }
        }

        private func buildType() -> String {
            #if DEBUG
            return "debug"
            #else
            return "release"
            #endif
        }

        private func printVersionTable(_ info: VersionInfo) {
            print("\(info.appName) version \(info.version)")
            print("Build: \(info.build)")
            print("Commit: \(info.commit)")
        }

        private func printVersionJSON(_ info: VersionInfo) throws {
            let data = try JSONEncoder().encode(info)
            print(String(data: data, encoding: .utf8) ?? "{}")
        }
    }

    public struct VersionInfo: Codable {
        let version: String
        let build: String
        let commit: String
        let appName: String
    }
}
