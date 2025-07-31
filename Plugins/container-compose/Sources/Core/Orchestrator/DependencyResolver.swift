//===----------------------------------------------------------------------===//
// Copyright © 2025 Apple Inc. and the container project authors. All rights reserved.
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

import Foundation
import ContainerizationError

/// Resolves service dependencies using topological sorting.
///
/// The DependencyResolver analyzes service dependencies and determines:
/// - The order in which services should be started
/// - The order in which services should be stopped (reverse of start order)
/// - Which services can be started in parallel
/// - Detection of circular dependencies
///
/// This ensures that dependent services are always started after their
/// dependencies and stopped before them.
public struct DependencyResolver {
    
    /// Result of dependency resolution
    public struct ResolutionResult {
        /// Services in the order they should be started
        public let startOrder: [String]
        
        /// Services in the order they should be stopped (reverse of start)
        public var stopOrder: [String] {
            return startOrder.reversed()
        }
        
        /// Groups of services that can be started in parallel
        public let parallelGroups: [[String]]
    }
    
    /// Resolve dependencies for the given services.
    ///
    /// Uses Kahn's algorithm for topological sorting to determine the order
    /// in which services should be started, ensuring all dependencies are
    /// satisfied.
    ///
    /// - Parameter services: Dictionary of service name to service definition
    /// - Returns: Resolution result containing start order and parallel groups
    /// - Throws: `ContainerizationError` if circular dependencies are detected or unknown services are referenced
    public static func resolve(services: [String: Service]) throws -> ResolutionResult {
        // Build adjacency list and in-degree map
        var graph: [String: Set<String>] = [:]
        var inDegree: [String: Int] = [:]
        
        // Initialize
        for name in services.keys {
            graph[name] = Set()
            inDegree[name] = 0
        }
        
        // Build dependency graph
        for (name, service) in services {
            for dependency in service.dependsOn {
                // Validate dependency exists
                guard services[dependency] != nil else {
                    throw ContainerizationError(
                        .notFound,
                        message: "Service '\(name)' depends on unknown service '\(dependency)'"
                    )
                }
                
                // Add edge from dependency to dependent
                graph[dependency]!.insert(name)
                inDegree[name]! += 1
            }
        }
        
        // Detect cycles using DFS
        try detectCycles(services: services)
        
        // Perform topological sort with level grouping
        var queue: [String] = []
        var result: [String] = []
        var parallelGroups: [[String]] = []
        
        // Find all nodes with no dependencies
        for (name, degree) in inDegree where degree == 0 {
            queue.append(name)
        }
        
        // Process level by level
        while !queue.isEmpty {
            let currentLevel = queue
            queue = []
            
            parallelGroups.append(currentLevel.sorted())
            
            for node in currentLevel {
                result.append(node)
                
                // Reduce in-degree for all dependents
                for dependent in graph[node]! {
                    inDegree[dependent]! -= 1
                    if inDegree[dependent]! == 0 {
                        queue.append(dependent)
                    }
                }
            }
        }
        
        // Verify all nodes were processed
        if result.count != services.count {
            throw ContainerizationError(
                .invalidArgument,
                message: "Circular dependency detected in service dependencies"
            )
        }
        
        return ResolutionResult(
            startOrder: result,
            parallelGroups: parallelGroups
        )
    }
    
    /// Detect cycles in the dependency graph using DFS
    private static func detectCycles(services: [String: Service]) throws {
        var visited = Set<String>()
        var recursionStack = Set<String>()
        
        func hasCycle(service: String, path: [String]) throws {
            if recursionStack.contains(service) {
                let cycleStart = path.firstIndex(of: service) ?? 0
                let cycle = path[cycleStart...] + [service]
                throw ContainerizationError(
                    .invalidArgument,
                    message: "Circular dependency detected: \(cycle.joined(separator: " → "))"
                )
            }
            
            if visited.contains(service) {
                return
            }
            
            visited.insert(service)
            recursionStack.insert(service)
            
            if let serviceConfig = services[service] {
                for dependency in serviceConfig.dependsOn {
                    try hasCycle(service: dependency, path: path + [service])
                }
            }
            
            recursionStack.remove(service)
        }
        
        for serviceName in services.keys {
            if !visited.contains(serviceName) {
                try hasCycle(service: serviceName, path: [])
            }
        }
    }
    
    /// Filter services based on selected services and their dependencies
    public static func filterWithDependencies(
        services: [String: Service],
        selected: [String]
    ) -> [String: Service] {
        if selected.isEmpty {
            return services
        }
        
        var result: [String: Service] = [:]
        var toProcess = Set(selected)
        var processed = Set<String>()
        
        while !toProcess.isEmpty {
            let current = toProcess.removeFirst()
            if processed.contains(current) {
                continue
            }
            processed.insert(current)
            
            guard let service = services[current] else {
                continue
            }
            
            result[current] = service
            
            // Add dependencies
            for dep in service.dependsOn {
                toProcess.insert(dep)
            }
        }
        
        return result
    }
}