import Foundation
import Testing
@testable import AlmanacAuth

private actor CallCounter {
    private(set) var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

private struct RefreshFailed: Error, Equatable {}

@Suite struct RefreshCoalescerTests {
    @Test func concurrentCallsShareOneRun() async throws {
        let coalescer = RefreshCoalescer()
        let counter = CallCounter()
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await coalescer.run("a@example.com") {
                        let n = await counter.increment()
                        try await Task.sleep(for: .milliseconds(300))
                        return "token-\(n)"
                    }
                }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(await counter.count == 1)
        #expect(results == Array(repeating: "token-1", count: 10))
    }

    @Test func laterCallRunsAgain() async throws {
        let coalescer = RefreshCoalescer()
        let counter = CallCounter()
        let operation: @Sendable () async throws -> String = { "token-\(await counter.increment())" }
        #expect(try await coalescer.run("a@example.com", operation) == "token-1")
        #expect(try await coalescer.run("a@example.com", operation) == "token-2")
    }

    @Test func differentKeysRunSeparately() async throws {
        let coalescer = RefreshCoalescer()
        let counter = CallCounter()
        async let a = coalescer.run("a@example.com") {
            _ = await counter.increment()
            try await Task.sleep(for: .milliseconds(200))
            return "a"
        }
        async let b = coalescer.run("b@example.com") {
            _ = await counter.increment()
            try await Task.sleep(for: .milliseconds(200))
            return "b"
        }
        #expect(try await [a, b] == ["a", "b"])
        #expect(await counter.count == 2)
    }

    @Test func errorReachesEveryWaiterAndIsNotCached() async throws {
        let coalescer = RefreshCoalescer()
        let counter = CallCounter()
        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        _ = try await coalescer.run("a@example.com") {
                            _ = await counter.increment()
                            try await Task.sleep(for: .milliseconds(300))
                            throw RefreshFailed()
                        }
                        return false
                    } catch {
                        return error is RefreshFailed
                    }
                }
            }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(failures == Array(repeating: true, count: 5))
        #expect(await counter.count == 1)
        #expect(try await coalescer.run("a@example.com") { "ok" } == "ok")
    }
}
