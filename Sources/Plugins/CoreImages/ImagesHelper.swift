//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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
import ContainerPersistence
import ContainerPlugin
import ContainerVersion
import ContainerXPC
import Containerization
import Foundation
import Logging
import SystemPackage

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

        var appRoot = ApplicationRoot.path

        var installRoot = InstallRoot.path

        var logRoot = LogRoot.path

        func run() async throws {
            let containerSystemConfig: ContainerSystemConfig = try await ConfigurationLoader.load()
            let commandName = ImagesHelper._commandName
            let logPath = logRoot.map { $0.appending("\(commandName).log") }
            let log = ServiceLogger.bootstrap(category: "ImagesHelper", debug: debug, logPath: logPath)
            log.info("starting helper", metadata: ["name": "\(commandName)"])
            defer {
                log.info("stopping helper", metadata: ["name": "\(commandName)"])
            }

            do {
                log.info("configuring XPC server")
                var routes = [String: XPCServer.RouteHandler]()
                try self.initializeContentService(root: appRoot, log: log, routes: &routes)
                try self.initializeImagesService(root: appRoot, containerSystemConfig: containerSystemConfig, log: log, routes: &routes)
                let xpc = XPCServer(
                    identifier: serviceIdentifier,
                    routes: routes,
                    log: log
                )
                log.info("starting XPC server")
                try await xpc.listen()
            } catch {
                log.error(
                    "helper failed",
                    metadata: [
                        "name": "\(commandName)",
                        "error": "\(error)",
                    ])
                ImagesHelper.exit(withError: error)
            }
        }

        private func initializeImagesService(root: FilePath, containerSystemConfig: ContainerSystemConfig, log: Logger, routes: inout [String: XPCServer.RouteHandler]) throws {
            // TODO: remove as part of ImageStore URL removal PR
            let rootURL = URL(fileURLWithPath: root.string)
            let contentStore = RemoteContentStoreClient()
            let imageStore = try ImageStore(path: rootURL, contentStore: contentStore)
            let unpackStrategy = SnapshotStore.defaultUnpackStrategy(initImage: containerSystemConfig.vminit.image)
            let snapshotStore = try SnapshotStore(path: rootURL, unpackStrategy: unpackStrategy, log: log)
            let service = try ImagesService(contentStore: contentStore, imageStore: imageStore, snapshotStore: snapshotStore, log: log)
            let harness = ImagesServiceHarness(service: service, log: log)

            routes[ImagesServiceXPCRoute.imagePull.rawValue] = XPCServer.route(harness.pull)
            routes[ImagesServiceXPCRoute.imageList.rawValue] = XPCServer.route(harness.list)
            routes[ImagesServiceXPCRoute.imageDelete.rawValue] = XPCServer.route(harness.delete)
            routes[ImagesServiceXPCRoute.imageTag.rawValue] = XPCServer.route(harness.tag)
            routes[ImagesServiceXPCRoute.imagePush.rawValue] = XPCServer.route(harness.push)
            routes[ImagesServiceXPCRoute.imageSave.rawValue] = XPCServer.route(harness.save)
            routes[ImagesServiceXPCRoute.imageLoad.rawValue] = XPCServer.route(harness.load)
            routes[ImagesServiceXPCRoute.imageUnpack.rawValue] = XPCServer.route(harness.unpack)
            routes[ImagesServiceXPCRoute.imageCleanupOrphanedBlobs.rawValue] = XPCServer.route(harness.cleanUpOrphanedBlobs)
            routes[ImagesServiceXPCRoute.imageDiskUsage.rawValue] = XPCServer.route(harness.calculateDiskUsage)
            routes[ImagesServiceXPCRoute.snapshotDelete.rawValue] = XPCServer.route(harness.deleteSnapshot)
            routes[ImagesServiceXPCRoute.snapshotGet.rawValue] = XPCServer.route(harness.getSnapshot)
        }

        private func initializeContentService(root: FilePath, log: Logger, routes: inout [String: XPCServer.RouteHandler]) throws {
            // TODO: remove as part of ImageStore URL removal PR
            let rootURL = URL(fileURLWithPath: root.string)
            let service = try ContentStoreService(root: rootURL, log: log)
            let harness = ContentServiceHarness(service: service, log: log)

            routes[ImagesServiceXPCRoute.contentClean.rawValue] = XPCServer.route(harness.clean)
            routes[ImagesServiceXPCRoute.contentGet.rawValue] = XPCServer.route(harness.get)
            routes[ImagesServiceXPCRoute.contentDelete.rawValue] = XPCServer.route(harness.delete)
            routes[ImagesServiceXPCRoute.contentIngestStart.rawValue] = XPCServer.route(harness.newIngestSession)
            routes[ImagesServiceXPCRoute.contentIngestCancel.rawValue] = XPCServer.route(harness.cancelIngestSession)
            routes[ImagesServiceXPCRoute.contentIngestComplete.rawValue] = XPCServer.route(harness.completeIngestSession)
        }
    }
}
