/// Runs at most one operation per key at a time. Callers that arrive while one is running
/// wait for it and get its result instead of starting another.
actor RefreshCoalescer {
    private var running: [String: Task<String, any Error>] = [:]

    func run(_ key: String, _ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        if let task = running[key] {
            return try await task.value
        }
        // Unstructured so that a cancelled caller doesn't cancel the refresh for everyone else waiting.
        let task = Task { try await operation() }
        running[key] = task
        defer { running[key] = nil }
        return try await task.value
    }
}
