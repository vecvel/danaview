// OWNER: IOS-15
//
// Shared helpers of the IOS-14/15/16 native tests: an engine context with temporary roots whose
// event hub records every delivered event, and synchronous service calls.

import Flutter
import XCTest

@testable import danaview_editor_engine

/// An engine context over fresh temporary roots; [events] collects what the hub delivers.
final class RecordingEngineFixture {
    let roots: TempRoots
    let context: EngineContext
    private let lock = NSLock()
    private var delivered: [EngineEventMsg] = []

    init() throws {
        roots = try TempRoots()
        context = EngineContext(messenger: FakeMessenger(), textures: nil)
        try context.configure(cacheRoot: roots.cache.path, supportRoot: roots.support.path)
        let listen = {
            self.context.events.onListen(withArguments: nil, sink: PigeonEventSink<EngineEventMsg> { [weak self] value in
                guard let self = self, let event = value as? EngineEventMsg else { return }
                self.lock.lock()
                self.delivered.append(event)
                self.lock.unlock()
            })
        }
        if Thread.isMainThread { listen() } else { DispatchQueue.main.sync(execute: listen) }
    }

    var paths: Paths { context.paths! }

    /// Events delivered so far.
    var events: [EngineEventMsg] {
        lock.lock()
        defer { lock.unlock() }
        return delivered
    }

    func remove() { roots.remove() }
}

/// Calls a reply-style service method and waits for the reply.
func awaitReply<T>(
    _ test: XCTestCase, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
    _ call: (@escaping EngineReply<T>) -> Void
) throws -> T {
    let done = test.expectation(description: "reply")
    var result: Result<T, Error>?
    call { value in
        result = value
        done.fulfill()
    }
    test.wait(for: [done], timeout: timeout)
    return try XCTUnwrap(result, file: file, line: line).get()
}

/// The EngineError a reply-style call fails with.
func awaitFailure<T>(_ test: XCTestCase, _ call: (@escaping EngineReply<T>) -> Void) -> EngineError? {
    do {
        _ = try awaitReply(test, call)
        return nil
    } catch {
        return EngineError.from(error)
    }
}

/// Spins the main run loop until [condition] holds or [timeout] passes.
func spin(until condition: () -> Bool, timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

/// Writes a file of [size] bytes with the core quickHash fixture pattern.
func writePatternFile(_ url: URL, size: Int) throws {
    var bytes = [UInt8](repeating: 0, count: size)
    for i in 0..<size { bytes[i] = UInt8((i &* 31 &+ (i >> 8) &* 7 &+ 5) & 0xff) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes).write(to: url)
}
