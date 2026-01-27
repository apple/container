//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ArgumentParser
import ContainerImagesService
import ContainerImagesServiceClient
import ContainerLog
import ContainerPlugin
import ContainerVersion
import ContainerXPC
import Containerization
import Foundation
import Logging

@main
struct ImagesHelper: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-core-images",
        abstract: "XPC service for managing OCI images",
        version: ReleaseVersion.singleLine(appName: "container-core-images"),
        subcommands: [
            Start.self
        ]
    )
}

extension ImagesHelper {
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Starts the image plugin"
        )

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        @Option(name: .long, help: "XPC service prefix")
        var serviceIdentifier: String = "com.apple.container.core.container-core-images"

        var appRoot = ApplicationRoot.url

        var installRoot = InstallRoot.url

        private static let unpackStrategy = SnapshotStore.defaultUnpackStrategy

        func run() async throws {
            let commandName = ImagesHelper._commandName
            let log = setupLogger()
            log.info("starting \(commandName)")
            defer {
                log.info("stopping \(commandName)")
            }
            do {
                log.info("configuring XPC server")
                var routes = [String: XPCServer.RouteHandler]()
                try self.initializeContentService(root: appRoot, log: log, routes: &routes)
                try self.initializeImagesService(root: appRoot, log: log, routes: &routes)
                let xpc = XPCServer(
                    identifier: serviceIdentifier,
                    routes: routes,
                    log: log
                )
                log.info("starting XPC server")
                try await xpc.listen()
            } catch {
                log.error("\(commandName) failed", metadata: ["error": "\(error)"])
                ImagesHelper.exit(withError: error)
            }
        }

        private func initializeImagesService(root: URL, log: Logger, routes: inout [String: XPCServer.RouteHandler]) throws {
            let contentStore = RemoteContentStoreClient()
            let imageStore = try ImageStore(path: root, contentStore: contentStore)
            let snapshotStore = try SnapshotStore(path: root, unpackStrategy: Self.unpackStrategy, log: log)
            let service = try ImagesService(contentStore: contentStore, imageStore: imageStore, snapshotStore: snapshotStore, log: log)
            let harness = ImagesServiceHarness(service: service, log: log)

            routes[ImagesServiceXPCRoute.imagePull.rawValue] = harness.pull
            routes[ImagesServiceXPCRoute.imageList.rawValue] = harness.list
            routes[ImagesServiceXPCRoute.imageDelete.rawValue] = harness.delete
            routes[ImagesServiceXPCRoute.imageTag.rawValue] = harness.tag
            routes[ImagesServiceXPCRoute.imagePush.rawValue] = harness.push
            routes[ImagesServiceXPCRoute.imageSave.rawValue] = harness.save
            routes[ImagesServiceXPCRoute.imageLoad.rawValue] = harness.load
            routes[ImagesServiceXPCRoute.imageUnpack.rawValue] = harness.unpack
            routes[ImagesServiceXPCRoute.imageCleanupOrphanedBlobs.rawValue] = harness.cleanupOrphanedBlobs
            routes[ImagesServiceXPCRoute.imageDiskUsage.rawValue] = harness.calculateDiskUsage
            routes[ImagesServiceXPCRoute.snapshotDelete.rawValue] = harness.deleteSnapshot
            routes[ImagesServiceXPCRoute.snapshotGet.rawValue] = harness.getSnapshot
        }

        private func initializeContentService(root: URL, log: Logger, routes: inout [String: XPCServer.RouteHandler]) throws {
            let service = try ContentStoreService(root: root, log: log)
            let harness = ContentServiceHarness(service: service, log: log)

            routes[ImagesServiceXPCRoute.contentClean.rawValue] = harness.clean
            routes[ImagesServiceXPCRoute.contentGet.rawValue] = harness.get
            routes[ImagesServiceXPCRoute.contentDelete.rawValue] = harness.delete
            routes[ImagesServiceXPCRoute.contentIngestStart.rawValue] = harness.newIngestSession
            routes[ImagesServiceXPCRoute.contentIngestCancel.rawValue] = harness.cancelIngestSession
            routes[ImagesServiceXPCRoute.contentIngestComplete.rawValue] = harness.completeIngestSession
        }

        private func setupLogger() -> Logger {
            LoggingSystem.bootstrap { label in
                OSLogHandler(
                    label: label,
                    category: "ImagesHelper"
                )
            }
            var log = Logger(label: "com.apple.container")
            if debug {
                log.logLevel = .debug
            }
            return log
        }
    }
}
