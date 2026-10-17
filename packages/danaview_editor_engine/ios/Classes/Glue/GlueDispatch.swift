// OWNER: ENG-07 (frozen by ENG-06)
//
// The queue hop every host handler uses (ARCH §12.6): the Pigeon handler runs on the platform main
// thread, validates its arguments there, posts the service call to an engine queue and returns at
// once; the service's reply is mapped (`EngineError.from` → `EnginePigeonError` with the
// `EngineErrorCode` name, a path-free message and `{itemId?, mediaFingerprint?, retryable}`) and
// delivered to Dart exactly once, on the main thread.

import Foundation

enum GlueDispatch {
    /// Validates on the caller (main) thread, then runs [body] with the validated value on [queue]
    /// and a reply that answers [completion] once on the main thread. A validation error answers
    /// at once (still asynchronously on main, so a handler never re-enters the messenger).
    static func hop<V, T>(
        _ method: String,
        on queue: DispatchQueue,
        completion: @escaping (Result<T, Error>) -> Void,
        validate: () throws -> V,
        _ body: @escaping (_ value: V, _ reply: @escaping EngineReply<T>) throws -> Void
    ) {
        let reply = once(method, completion)
        let value: V
        do {
            value = try validate()
        } catch {
            DispatchQueue.main.async { reply(.failure(error)) }
            return
        }
        queue.async {
            do {
                try body(value, reply)
            } catch {
                reply(.failure(error))
            }
        }
    }

    /// [hop] without arguments to validate.
    static func hop<T>(
        _ method: String,
        on queue: DispatchQueue,
        completion: @escaping (Result<T, Error>) -> Void,
        _ body: @escaping (_ reply: @escaping EngineReply<T>) throws -> Void
    ) {
        hop(method, on: queue, completion: completion, validate: { () }) { (_: Void, reply: @escaping EngineReply<T>) in
            try body(reply)
        }
    }

    /// Fire-and-forget form for synchronous Pigeon methods: validation errors are thrown back to
    /// the caller (the generated code replies with them), the work runs later on [queue].
    static func post<V>(
        _ method: String,
        on queue: DispatchQueue,
        validate: () throws -> V,
        _ body: @escaping (_ value: V) -> Void
    ) throws {
        let value: V
        do {
            value = try validate()
        } catch {
            let mapped = EngineError.from(error)
            Log.error(.glue, "\(method) refused: \(mapped.code.rawValue) \(mapped.message)")
            throw mapped.pigeonError
        }
        queue.async { body(value) }
    }

    /// Wraps [completion] so it runs once, on the main thread, with errors mapped for the channel.
    static func once<T>(_ method: String, _ completion: @escaping (Result<T, Error>) -> Void) -> EngineReply<T> {
        let gate = OnceGate()
        return { result in
            guard gate.enter() else {
                Log.fault(.glue, "\(method): duplicate reply ignored")
                return
            }
            let mapped: Result<T, Error> = result.mapError { error in
                let engineError = EngineError.from(error)
                switch engineError.code {
                case .internal:
                    Log.error(.glue, "\(method) failed: \(engineError.message)")
                case .cancelled, .notSupportedOnDevice:
                    Log.debug(.glue, "\(method): \(engineError.code.rawValue)")
                default:
                    Log.info(.glue, "\(method) failed: \(engineError.code.rawValue) \(engineError.message)")
                }
                return engineError.pigeonError
            }
            if Thread.isMainThread {
                completion(mapped)
            } else {
                DispatchQueue.main.async { completion(mapped) }
            }
        }
    }
}

/// A thread-safe one-shot flag.
final class OnceGate {
    private let lock = NSLock()
    private var entered = false

    /// True the first time only.
    func enter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if entered { return false }
        entered = true
        return true
    }
}
