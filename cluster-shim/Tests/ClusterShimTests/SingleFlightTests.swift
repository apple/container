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

import Synchronization
import Testing

@testable import ClusterShim

/// Counts the runs of an operation.
final class RunCount: Sendable {
    let value = Mutex(0)
}

struct SingleFlightTests {
    @Test func callerJoinsTheRunningOperation() async throws {
        let flight = SingleFlight()
        let runs = RunCount()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let operation: @Sendable () async throws -> Void = {
            runs.value.withLock { $0 += 1 }
            startedContinuation.yield()
            for await _ in release {}
        }

        async let first: Void = flight.run(key: "image", operation)
        for await _ in started {
            break
        }
        async let second: Void = flight.run(key: "image", operation)
        while await flight.callers(for: "image") < 2 {
            await Task.yield()
        }
        releaseContinuation.finish()
        try await first
        try await second

        #expect(runs.value.withLock { $0 } == 1)
    }

    @Test func runsOneAfterAnotherEachRunTheOperation() async throws {
        let flight = SingleFlight()
        let runs = RunCount()
        let operation: @Sendable () async throws -> Void = {
            runs.value.withLock { $0 += 1 }
        }

        try await flight.run(key: "image", operation)
        try await flight.run(key: "image", operation)

        #expect(runs.value.withLock { $0 } == 2)
    }

    @Test func joinedCallerGetsTheError() async throws {
        let flight = SingleFlight()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let operation: @Sendable () async throws -> Void = {
            startedContinuation.yield()
            for await _ in release {}
            throw CancellationError()
        }

        let first = Task { try await flight.run(key: "image", operation) }
        for await _ in started {
            break
        }
        let second = Task { try await flight.run(key: "image", operation) }
        while await flight.callers(for: "image") < 2 {
            await Task.yield()
        }
        releaseContinuation.finish()

        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
    }

    @Test func cancelledCallerStopsWaitingWhileTheOthersWait() async throws {
        let flight = SingleFlight()
        let runs = RunCount()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let operation: @Sendable () async throws -> Void = {
            runs.value.withLock { $0 += 1 }
            startedContinuation.yield()
            for await _ in release {}
            try Task.checkCancellation()
        }

        let first = Task { try await flight.run(key: "image", operation) }
        for await _ in started {
            break
        }
        let second = Task { try await flight.run(key: "image", operation) }
        while await flight.callers(for: "image") < 2 {
            await Task.yield()
        }
        second.cancel()

        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(await flight.callers(for: "image") == 1)
        releaseContinuation.finish()
        try await first.value
        #expect(runs.value.withLock { $0 } == 1)
    }

    @Test func cancellingTheLastCallerCancelsTheOperation() async throws {
        let flight = SingleFlight()
        let runs = RunCount()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (cancelled, cancelledContinuation) = AsyncStream<Void>.makeStream()
        let operation: @Sendable () async throws -> Void = {
            runs.value.withLock { $0 += 1 }
            startedContinuation.yield()
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                cancelledContinuation.yield()
                throw error
            }
        }

        let first = Task { try await flight.run(key: "image", operation) }
        for await _ in started {
            break
        }
        first.cancel()

        await #expect(throws: CancellationError.self) { try await first.value }
        for await _ in cancelled {
            break
        }
        #expect(await flight.callers(for: "image") == 0)

        let next = Task { try await flight.run(key: "image", operation) }
        for await _ in started {
            break
        }
        next.cancel()
        await #expect(throws: CancellationError.self) { try await next.value }
        #expect(runs.value.withLock { $0 } == 2)
    }
}
