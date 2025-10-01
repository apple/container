//===----------------------------------------------------------------------===//
// Copyright © 2025 Mazdak Rezvani and contributors. All rights reserved.
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
import Testing
import ContainerizationError

@testable import ComposeCore

struct DependencyResolverTests {
    
    @Test
    func testResolveNoDependencies() throws {
        let services: [String: Service] = [
            "web": Service(name: "web", image: "nginx"),
            "db": Service(name: "db", image: "postgres"),
            "cache": Service(name: "cache", image: "redis")
        ]
        
        let resolution = try DependencyResolver.resolve(services: services)
        
        #expect(resolution.startOrder.count == 3)
        #expect(resolution.stopOrder.count == 3)
        #expect(resolution.parallelGroups.count == 1)
        #expect(resolution.parallelGroups[0].count == 3)
    }
    
    @Test
    func testResolveLinearDependencies() throws {
        let services: [String: Service] = [
            "db": Service(name: "db", image: "postgres"),
            "cache": Service(name: "cache", image: "redis", dependsOn: ["db"]),
            "web": Service(name: "web", image: "nginx", dependsOn: ["cache"])
        ]
        
        let resolution = try DependencyResolver.resolve(services: services)
        
        #expect(resolution.startOrder == ["db", "cache", "web"])
        #expect(resolution.stopOrder == ["web", "cache", "db"])
        #expect(resolution.parallelGroups.count == 3)
        #expect(resolution.parallelGroups[0] == ["db"])
        #expect(resolution.parallelGroups[1] == ["cache"])
        #expect(resolution.parallelGroups[2] == ["web"])
    }
    
    @Test
    func testResolveComplexDependencies() throws {
        let services: [String: Service] = [
            "db": Service(name: "db", image: "postgres"),
            "cache": Service(name: "cache", image: "redis"),
            "api1": Service(name: "api1", image: "api", dependsOn: ["db", "cache"]),
            "api2": Service(name: "api2", image: "api", dependsOn: ["db"]),
            "web": Service(name: "web", image: "nginx", dependsOn: ["api1", "api2"])
        ]
        
        let resolution = try DependencyResolver.resolve(services: services)
        
        // db and cache should start first (parallel)
        #expect(resolution.parallelGroups[0].contains("db"))
        #expect(resolution.parallelGroups[0].contains("cache"))
        
        // api1 and api2 should start after their dependencies
        let api1Index = resolution.startOrder.firstIndex(of: "api1")!
        let api2Index = resolution.startOrder.firstIndex(of: "api2")!
        let dbIndex = resolution.startOrder.firstIndex(of: "db")!
        let cacheIndex = resolution.startOrder.firstIndex(of: "cache")!
        
        #expect(api1Index > dbIndex)
        #expect(api1Index > cacheIndex)
        #expect(api2Index > dbIndex)
        
        // web should be last
        #expect(resolution.startOrder.last == "web")
        #expect(resolution.stopOrder.first == "web")
    }
    
    @Test
    func testResolveCircularDependency() throws {
        let services: [String: Service] = [
            "a": Service(name: "a", image: "ubuntu", dependsOn: ["b"]),
            "b": Service(name: "b", image: "ubuntu", dependsOn: ["c"]),
            "c": Service(name: "c", image: "ubuntu", dependsOn: ["a"])
        ]
        
        #expect {
            _ = try DependencyResolver.resolve(services: services)
        } throws: { error in
            guard let containerError = error as? ContainerizationError else {
                return false
            }
            return containerError.message.contains("Circular dependency")
        }
    }
    
    @Test
    func testResolveMissingDependency() throws {
        let services: [String: Service] = [
            "web": Service(name: "web", image: "nginx", dependsOn: ["db"]),
            "worker": Service(name: "worker", image: "worker")
        ]
        
        #expect {
            _ = try DependencyResolver.resolve(services: services)
        } throws: { error in
            guard let containerError = error as? ContainerizationError else {
                return false
            }
            return containerError.message.contains("depends on unknown service")
        }
    }
    
    @Test
    func testFilterWithDependencies() {
        let services: [String: Service] = [
            "db": Service(name: "db", image: "postgres"),
            "cache": Service(name: "cache", image: "redis"),
            "api": Service(name: "api", image: "api", dependsOn: ["db", "cache"]),
            "web": Service(name: "web", image: "nginx", dependsOn: ["api"]),
            "worker": Service(name: "worker", image: "worker", dependsOn: ["db"])
        ]
        
        // Select only web - should include all its dependencies
        let filtered = DependencyResolver.filterWithDependencies(
            services: services,
            selected: ["web"]
        )
        
        #expect(filtered.count == 4)
        #expect(filtered.keys.contains("web"))
        #expect(filtered.keys.contains("api"))
        #expect(filtered.keys.contains("db"))
        #expect(filtered.keys.contains("cache"))
        #expect(!filtered.keys.contains("worker"))
    }
    
    @Test
    func testFilterMultipleServices() {
        let services: [String: Service] = [
            "db": Service(name: "db", image: "postgres"),
            "cache": Service(name: "cache", image: "redis"),
            "api": Service(name: "api", image: "api", dependsOn: ["db"]),
            "web": Service(name: "web", image: "nginx", dependsOn: ["api"]),
            "worker": Service(name: "worker", image: "worker", dependsOn: ["cache"])
        ]

        // Select web and worker
        let filtered = DependencyResolver.filterWithDependencies(
            services: services,
            selected: ["web", "worker"]
        )

        #expect(filtered.count == 5) // All services needed
        #expect(filtered.keys.contains("web"))
        #expect(filtered.keys.contains("worker"))
        #expect(filtered.keys.contains("api"))
        #expect(filtered.keys.contains("db"))
        #expect(filtered.keys.contains("cache"))
    }

    @Test
    func testFilterEmptySelection() {
        let services: [String: Service] = [
            "db": Service(name: "db", image: "postgres"),
            "web": Service(name: "web", image: "nginx", dependsOn: ["db"])
        ]

        // Empty selection should return all services
        let filtered = DependencyResolver.filterWithDependencies(
            services: services,
            selected: []
        )

        #expect(filtered.count == 2)
        #expect(filtered.keys.contains("db"))
        #expect(filtered.keys.contains("web"))
    }

    @Test
    func testFilterNonExistentService() {
        let services: [String: Service] = [
            "db": Service(name: "db", image: "postgres"),
            "web": Service(name: "web", image: "nginx", dependsOn: ["db"])
        ]

        // Selecting non-existent service should return empty
        let filtered = DependencyResolver.filterWithDependencies(
            services: services,
            selected: ["nonexistent"]
        )

        #expect(filtered.isEmpty)
    }

    @Test
    func testResolveEmptyServices() throws {
        let services: [String: Service] = [:]

        let resolution = try DependencyResolver.resolve(services: services)

        #expect(resolution.startOrder.isEmpty)
        #expect(resolution.stopOrder.isEmpty)
        #expect(resolution.parallelGroups.isEmpty)
    }

    @Test
    func testResolveSingleService() throws {
        let services: [String: Service] = [
            "web": Service(name: "web", image: "nginx")
        ]

        let resolution = try DependencyResolver.resolve(services: services)

        #expect(resolution.startOrder == ["web"])
        #expect(resolution.stopOrder == ["web"])
        #expect(resolution.parallelGroups.count == 1)
        #expect(resolution.parallelGroups[0] == ["web"])
    }

    @Test
    func testResolveDependsOnHealthy() throws {
        let services: [String: Service] = [
            "db": Service(name: "db", image: "postgres", healthCheck: HealthCheck(test: ["/bin/true"])),
            "web": Service(name: "web", image: "nginx", dependsOnHealthy: ["db"])
        ]

        let resolution = try DependencyResolver.resolve(services: services)

        #expect(resolution.startOrder == ["db", "web"])
        #expect(resolution.stopOrder == ["web", "db"])
        #expect(resolution.parallelGroups.count == 2)
        #expect(resolution.parallelGroups[0] == ["db"])
        #expect(resolution.parallelGroups[1] == ["web"])
    }

    @Test
    func testResolveDependsOnStarted() throws {
        let services: [String: Service] = [
            "db": Service(name: "db", image: "postgres"),
            "web": Service(name: "web", image: "nginx", dependsOnStarted: ["db"])
        ]

        let resolution = try DependencyResolver.resolve(services: services)

        #expect(resolution.startOrder == ["db", "web"])
        #expect(resolution.stopOrder == ["web", "db"])
        #expect(resolution.parallelGroups.count == 2)
        #expect(resolution.parallelGroups[0] == ["db"])
        #expect(resolution.parallelGroups[1] == ["web"])
    }

    @Test
    func testResolveDependsOnCompletedSuccessfully() throws {
        let services: [String: Service] = [
            "db": Service(name: "db", image: "postgres"),
            "web": Service(name: "web", image: "nginx", dependsOnCompletedSuccessfully: ["db"])
        ]

        let resolution = try DependencyResolver.resolve(services: services)

        #expect(resolution.startOrder == ["db", "web"])
        #expect(resolution.stopOrder == ["web", "db"])
        #expect(resolution.parallelGroups.count == 2)
        #expect(resolution.parallelGroups[0] == ["db"])
        #expect(resolution.parallelGroups[1] == ["web"])
    }

    @Test
    func testResolveMultipleDependencyTypes() throws {
        let services: [String: Service] = [
            "db": Service(name: "db", image: "postgres", healthCheck: HealthCheck(test: ["/bin/true"])),
            "cache": Service(name: "cache", image: "redis"),
            "web": Service(name: "web", image: "nginx", dependsOnHealthy: ["db"], dependsOnStarted: ["cache"])
        ]

        let resolution = try DependencyResolver.resolve(services: services)

        // db and cache have no dependencies, so they can start in parallel (order may vary due to sorting)
        #expect(resolution.startOrder.count == 3)
        #expect(resolution.startOrder.contains("db"))
        #expect(resolution.startOrder.contains("cache"))
        #expect(resolution.startOrder.contains("web"))
        #expect(resolution.startOrder.last == "web") // web should be last

        #expect(resolution.stopOrder.first == "web") // web should stop first
        #expect(resolution.parallelGroups.count == 2) // Two parallel groups: [db,cache] and [web]
        #expect(resolution.parallelGroups[0].count == 2) // First group has both db and cache
        #expect(resolution.parallelGroups[1] == ["web"]) // Second group has only web
    }

    @Test
    func testResolveMixedDependencies() throws {
        let services: [String: Service] = [
            "db": Service(name: "db", image: "postgres", healthCheck: HealthCheck(test: ["/bin/true"])),
            "cache": Service(name: "cache", image: "redis"),
            "api": Service(name: "api", image: "api", dependsOn: ["db"], dependsOnStarted: ["cache"]),
            "web": Service(name: "web", image: "nginx", dependsOn: ["api"], dependsOnHealthy: ["db"])
        ]

        let resolution = try DependencyResolver.resolve(services: services)

        // db and cache should start first (parallel)
        #expect(resolution.parallelGroups[0].contains("db"))
        #expect(resolution.parallelGroups[0].contains("cache"))

        // api should start after db and cache
        let apiIndex = resolution.startOrder.firstIndex(of: "api")!
        let dbIndex = resolution.startOrder.firstIndex(of: "db")!
        let cacheIndex = resolution.startOrder.firstIndex(of: "cache")!

        #expect(apiIndex > dbIndex)
        #expect(apiIndex > cacheIndex)

        // web should be last
        #expect(resolution.startOrder.last == "web")
    }
}
