// OWNER: ENG-07 (frozen with the glue by ENG-06)
//
// Shared engine state of one Flutter engine (ARCH §12.6, §18.1): the Flutter registries, the
// engine queues, the event hub and the Dart-supplied roots. Every service class takes it in
// `init(context:)`.
//
// Queues (ARCH §18.1). Host handlers run on the platform main thread, validate, then hop to one of
// these queues and reply asynchronously; they never block on media work:
//
//   engine          capabilities, compatibility, probe, freeBytes, cache trims
//   previewControl  every PreviewHostApi call (`previewControlQueue`; compositors own their
//                   `renderQueue`s)
//   jobs            thumbnails, media jobs, proxy status (`jobQueue`; long work runs on the
//                   services' own queues)
//   export          ExportHostApi (export pumps are the services' own queues)
//   recorder        recording start/stop/cancel
//   io              media access: bookmarks, stat, quickHash, backup exclusion, Photos saves
//   main            UIKit work: pickers, Files/share sheets, settings, drop target, leases

import Flutter
import Foundation
import UIKit

/// The engine's dispatch queues (ARCH §18.1).
final class EngineQueues {
    /// Key whose value names the engine queue the current code runs on (tests, assertions).
    static let labelKey = DispatchSpecificKey<String>()

    let engine: DispatchQueue
    let previewControl: DispatchQueue
    let jobs: DispatchQueue
    let export: DispatchQueue
    let recorder: DispatchQueue
    let io: DispatchQueue

    init() {
        engine = EngineQueues.make("engine", qos: .userInitiated)
        previewControl = EngineQueues.make("previewControl", qos: .userInteractive)
        jobs = EngineQueues.make("jobs", qos: .utility)
        export = EngineQueues.make("export", qos: .userInitiated)
        recorder = EngineQueues.make("recorder", qos: .userInitiated)
        io = EngineQueues.make("io", qos: .userInitiated)
    }

    private static func make(_ name: String, qos: DispatchQoS) -> DispatchQueue {
        let queue = DispatchQueue(label: "com.vecvel.danaview.editor.\(name)", qos: qos)
        queue.setSpecific(key: labelKey, value: name)
        return queue
    }

    /// The short name of the engine queue running the caller ("main" on the main thread).
    static var currentName: String? {
        if let name = DispatchQueue.getSpecific(key: labelKey) { return name }
        return Thread.isMainThread ? "main" : nil
    }
}

/// Engine-wide state shared by the glue and the services.
final class EngineContext {
    /// Messenger of the Flutter engine the plugin is registered with.
    let messenger: FlutterBinaryMessenger
    /// Texture registry for preview textures (registration on the main thread, ARCH §12.7).
    let textures: FlutterTextureRegistry?
    let queues: EngineQueues
    let events: EventHub
    /// The view controller to present system UI from (pickers, sheets); main thread only.
    let presentingViewController: () -> UIViewController?

    private let lock = NSLock()
    private var currentPaths: Paths?

    init(
        messenger: FlutterBinaryMessenger,
        textures: FlutterTextureRegistry?,
        queues: EngineQueues = EngineQueues(),
        events: EventHub = EventHub(),
        presentingViewController: @escaping () -> UIViewController? = EngineContext.keyWindowRootViewController
    ) {
        self.messenger = messenger
        self.textures = textures
        self.queues = queues
        self.events = events
        self.presentingViewController = presentingViewController
    }

    /// The roots handed over by `initialize`, or nil before it.
    var paths: Paths? {
        lock.lock()
        defer { lock.unlock() }
        return currentPaths
    }

    /// The roots, or `EngineError.notInitialized`.
    func requirePaths() throws -> Paths {
        guard let paths = paths else { throw EngineError.notInitialized }
        return paths
    }

    /// Installs the Dart-supplied roots. Idempotent: a Dart hot restart sends the same roots again.
    /// Returns true when the roots were installed or changed.
    @discardableResult
    func configure(cacheRoot: String, supportRoot: String) throws -> Bool {
        let next = try Paths(cacheRoot: cacheRoot, supportRoot: supportRoot)
        lock.lock()
        defer { lock.unlock() }
        if let existing = currentPaths, existing == next { return false }
        currentPaths = next
        return true
    }

    /// Presenter fallback: the root view controller of the foreground key window.
    static func keyWindowRootViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.filter { $0.activationState == .foregroundActive }.flatMap { $0.windows }
            + scenes.flatMap { $0.windows }
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
