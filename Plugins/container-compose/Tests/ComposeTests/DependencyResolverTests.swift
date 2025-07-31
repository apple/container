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
}