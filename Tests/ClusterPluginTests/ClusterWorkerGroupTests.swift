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
import ContainerResource
import Foundation
import Testing

@testable import ContainerCluster

struct ClusterWorkerGroupTests {
    @Test func bareNumberIsCount() throws {
        #expect(try WorkerGroup(parsing: "3") == WorkerGroup(count: 3))
    }

    @Test func bareZeroIsAllowed() throws {
        #expect(try WorkerGroup(parsing: "0") == WorkerGroup(count: 0))
    }

    @Test func keyValueGroup() throws {
        #expect(try WorkerGroup(parsing: "count=2,cpus=2,memory=8g") == WorkerGroup(count: 2, cpus: 2, memory: "8g"))
    }

    @Test func countDefaultsToOne() throws {
        #expect(try WorkerGroup(parsing: "cpus=2") == WorkerGroup(count: 1, cpus: 2, memory: nil))
    }

    @Test func virtualizationAndKernel() throws {
        let group = try WorkerGroup(parsing: "count=2,cpus=4,memory=8g,virtualization=true,kernel=/opt/vmlinux-kvm")
        #expect(group == (try WorkerGroup(count: 2, cpus: 4, memory: "8g", virtualization: true, kernel: "/opt/vmlinux-kvm")))
    }

    @Test func virtualizationDefaultsToFalse() throws {
        let group = try WorkerGroup(parsing: "count=2")
        #expect(!group.virtualization)
        #expect(group.kernel == nil)
        #expect(!(try WorkerGroup(parsing: "virtualization=false")).virtualization)
    }

    /// Matches `container machine set virtualization=<bool>`, which also takes any case and `t`/`f`.
    @Test(arguments: ["true", "TRUE", "True", "t"])
    func virtualizationAcceptsMachineBoolSpellings(_ value: String) throws {
        #expect(try WorkerGroup(parsing: "virtualization=\(value)").virtualization)
    }

    @Test func relativeKernelIsResolvedAgainstCurrentDirectory() throws {
        let group = try WorkerGroup(parsing: "kernel=bin/vmlinux-arm64")
        let expected = FileManager.default.currentDirectoryPath + "/bin/vmlinux-arm64"
        #expect(group.kernel.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == URL(fileURLWithPath: expected).standardizedFileURL.path)
    }

    @Test(arguments: [
        "", "abc", "-1", "count", "count=", "count=x", "count=-1",
        "cpus=0", "cpus=-2", "cpus=x", "memory=0", "memory=x", "memory=9999999999999999999999p",
        "color=red", "count=1,count=2", "count=1,,cpus=2", "count=0,cpus=2", "count=0,memory=4g",
        "memory=199m", "cpus=99999", "count=1025", "count=99999999999999999999",
        "virtualization", "virtualization=", "virtualization=yes", "virtualization=1", "kernel=",
        "virtualization=true,virtualization=false", "count=0,virtualization=true", "count=0,kernel=/opt/vmlinux",
    ])
    func invalidValuesAreRejected(_ value: String) {
        #expect(throws: ValidationError.self) {
            try WorkerGroup(parsing: value)
        }
    }

    @Test func zeroCountWithoutSizingIsAllowed() throws {
        #expect(try WorkerGroup(parsing: "count=0") == WorkerGroup(count: 0))
        #expect(try WorkerGroup(parsing: "count=0,virtualization=false") == WorkerGroup(count: 0))
    }

    @Test func initRejectsInvalidFields() {
        #expect(throws: ValidationError.self) { try WorkerGroup(count: ClusterConfiguration.maxWorkers + 1) }
        #expect(throws: ValidationError.self) { try WorkerGroup(count: 0, cpus: 1) }
        #expect(throws: ValidationError.self) { try WorkerGroup(count: 1, cpus: 0) }
        #expect(throws: ValidationError.self) { try WorkerGroup(count: 1, cpus: Int64(ContainerConfiguration.Resources.maximumCPUs) + 1) }
        #expect(throws: ValidationError.self) { try WorkerGroup(count: 1, memory: "1m") }
        #expect(throws: ValidationError.self) { try WorkerGroup(count: 0, virtualization: true) }
        #expect(throws: ValidationError.self) { try WorkerGroup(count: 0, kernel: "/opt/vmlinux") }
    }

    @Test func initAcceptsLimits() throws {
        _ = try WorkerGroup(count: ClusterConfiguration.maxWorkers)
        _ = try WorkerGroup(count: 1, cpus: Int64(ContainerConfiguration.Resources.maximumCPUs))
        _ = try WorkerGroup(count: 1, memory: "200m")
    }

    @Test func parseErrorNamesTheOffendingValue() {
        do {
            _ = try WorkerGroup(parsing: "count=1,memory=1m")
            Issue.record("expected an error")
        } catch let error as ValidationError {
            #expect(error.message.contains("count=1,memory=1m"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func invalidMemoryErrorNamesTheField() {
        do {
            _ = try WorkerGroup(parsing: "memory=x")
            Issue.record("expected an error")
        } catch let error as ValidationError {
            #expect(error.message.contains("invalid memory 'x'"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func bareNumberErrorNamesTheValue() {
        do {
            _ = try WorkerGroup(parsing: "99999")
            Issue.record("expected an error")
        } catch let error as ValidationError {
            #expect(error.message.contains("in '99999'"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
