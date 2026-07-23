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
import ContainerAPIClient
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation

extension Application {
    public struct ImageTree: AsyncLoggableCommand {
        public init() {}
        public static let configuration = CommandConfiguration(
            commandName: "tree",
            abstract: "Show images in a tree view based on parent-child relationships",
            aliases: ["tr"]
        )

        @Flag(name: .shortAndLong, help: "Show image sizes")
        var size = false

        @OptionGroup
        public var logOptions: Flags.Logging

        public mutating func run() async throws {
            let containerSystemConfig: ContainerSystemConfig = try await Application.loadContainerSystemConfig()
            
            var images = try await ClientImage.list().filter { img in
                !Utility.isInfraImage(name: img.reference, builderImage: containerSystemConfig.build.image, initImage: containerSystemConfig.vminit.image)
            }
            images.sort { $0.reference < $1.reference }
            
            let resources = try await Self.buildResources(images: images, containerSystemConfig: containerSystemConfig)
            
            // Build tree
            let rootNodes = buildTree(from: resources)
            
            // Print tree
            if rootNodes.isEmpty {
                return
            }
            
            for node in rootNodes {
                // Determine root print style. The root doesn't have the ├── marker
                printRootNode(node)
            }
        }

        private static func buildResources(images: [ClientImage], containerSystemConfig: ContainerSystemConfig) async throws -> [ImageResource] {
            var resources: [ImageResource] = []
            for image in images {
                resources.append(
                    try await image.toImageResource(containerSystemConfig: containerSystemConfig)
                )
            }
            return resources
        }
        
        private class Node {
            let resource: ImageResource
            let allDiffIDs: [[String]]
            let displaySize: String
            var children: [Node] = []
            
            init(resource: ImageResource, allDiffIDs: [[String]], displaySize: String) {
                self.resource = resource
                self.allDiffIDs = allDiffIDs
                self.displaySize = displaySize
            }
        }
        
        private func buildTree(from resources: [ImageResource]) -> [Node] {
            let formatter = ByteCountFormatter()
            var nodes: [Node] = []
            
            for resource in resources {
                let allDiffIDs = resource.variants.map { $0.config.rootfs.diffIDs }
                let sizeStr = resource.variants.first.map { formatter.string(fromByteCount: $0.size) } ?? "0 MB"
                nodes.append(Node(resource: resource, allDiffIDs: allDiffIDs, displaySize: sizeStr))
            }
            
            // Sort nodes by number of diffIDs (parents have fewer diffIDs)
            nodes.sort { ($0.allDiffIDs.first?.count ?? 0) < ($1.allDiffIDs.first?.count ?? 0) }
            
            var roots: [Node] = []
            
            for node in nodes {
                var foundParent = false
                // Find a parent: a node with maximum diffIDs that is a strict prefix of current node's diffIDs
                for potentialParent in roots.flatMap({ getAllNodes(in: $0) }).sorted(by: { ($0.allDiffIDs.first?.count ?? 0) > ($1.allDiffIDs.first?.count ?? 0) }) {
                    if isPrefixOfAny(potentialParent.allDiffIDs, of: node.allDiffIDs) {
                        potentialParent.children.append(node)
                        foundParent = true
                        break
                    }
                }
                
                if !foundParent {
                    roots.append(node)
                }
            }
            
            // Sort roots and children alphabetically
            roots.sort { $0.resource.displayReference < $1.resource.displayReference }
            for root in roots {
                sortChildren(of: root)
            }
            
            return roots
        }
        
        private func getAllNodes(in root: Node) -> [Node] {
            var result = [root]
            for child in root.children {
                result.append(contentsOf: getAllNodes(in: child))
            }
            return result
        }
        
        private func sortChildren(of node: Node) {
            node.children.sort { $0.resource.displayReference < $1.resource.displayReference }
            for child in node.children {
                sortChildren(of: child)
            }
        }
        
        private func isPrefixOfAny(_ parentDiffIDsList: [[String]], of childDiffIDsList: [[String]]) -> Bool {
            for parentDiffIDs in parentDiffIDsList {
                for childDiffIDs in childDiffIDsList {
                    if isPrefix(parentDiffIDs, of: childDiffIDs) {
                        return true
                    }
                }
            }
            return false
        }
        
        private func isPrefix(_ prefix: [String], of full: [String]) -> Bool {
            guard prefix.count < full.count && prefix.count > 0 else { return false }
            for i in 0..<prefix.count {
                if prefix[i] != full[i] {
                    return false
                }
            }
            return true
        }
        
        private func printRootNode(_ node: Node) {
            var line = node.resource.displayReference
            if size {
                line += " (\(node.displaySize))"
            }
            print(line)
            
            for (index, child) in node.children.enumerated() {
                printNode(child, prefix: "", isLast: index == node.children.count - 1)
            }
        }
        
        private func printNode(_ node: Node, prefix: String, isLast: Bool) {
            let marker = isLast ? "└── " : "├── "
            var line = prefix + marker + node.resource.displayReference
            if size {
                line += " (\(node.displaySize))"
            }
            print(line)
            
            let childPrefix = prefix + (isLast ? "    " : "│   ")
            for (index, child) in node.children.enumerated() {
                printNode(child, prefix: childPrefix, isLast: index == node.children.count - 1)
            }
        }
    }
}
