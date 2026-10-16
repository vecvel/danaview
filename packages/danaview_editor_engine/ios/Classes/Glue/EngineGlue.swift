// OWNER: ENG-07 (frozen by ENG-06)
//
// Installs the glue of one Flutter engine (ARCH §12.6): the six host APIs generated in
// Pigeon/EngineApi.g.swift, the `EngineEventsApi.engineEvents` stream handler (EventHub) and the
// system signal observers. `uninstall` clears every handler (plugin detach). INT-07 adds the
// recording bridge (`recordingChanged` events and the preview mute while recording).

import Flutter
import Foundation

final class EngineGlue {
    let context: EngineContext
    let services: EngineServices
    let engineApi: EngineHostApiImpl
    let previewApi: PreviewHostApiImpl
    let jobsApi: JobsHostApiImpl
    let exportApi: ExportHostApiImpl
    let recorderApi: RecorderHostApiImpl
    let platformApi: PlatformHostApiImpl
    let signals: SystemSignals
    let recordingMute: RecordingMuteBridge

    init(context: EngineContext, services: EngineServices) {
        self.context = context
        self.services = services
        engineApi = EngineHostApiImpl(context: context, services: services)
        previewApi = PreviewHostApiImpl(context: context, services: services)
        jobsApi = JobsHostApiImpl(context: context, services: services)
        exportApi = ExportHostApiImpl(context: context, services: services)
        recorderApi = RecorderHostApiImpl(context: context, services: services)
        platformApi = PlatformHostApiImpl(context: context, services: services)
        signals = SystemSignals(context: context, services: services)
        recordingMute = RecordingMuteBridge(context: context, services: services)
    }

    /// Registers every host API and the event stream on the context's messenger (main thread).
    func install() {
        let messenger = context.messenger
        EngineHostApiSetup.setUp(binaryMessenger: messenger, api: engineApi)
        PreviewHostApiSetup.setUp(binaryMessenger: messenger, api: previewApi)
        JobsHostApiSetup.setUp(binaryMessenger: messenger, api: jobsApi)
        ExportHostApiSetup.setUp(binaryMessenger: messenger, api: exportApi)
        RecorderHostApiSetup.setUp(binaryMessenger: messenger, api: recorderApi)
        PlatformHostApiSetup.setUp(binaryMessenger: messenger, api: platformApi)
        EngineEventsStreamHandler.register(with: messenger, streamHandler: context.events)
        signals.start()
        recordingMute.start()
        Log.debug(.glue, "installed")
    }

    /// Removes every handler (main thread).
    func uninstall() {
        let messenger = context.messenger
        EngineHostApiSetup.setUp(binaryMessenger: messenger, api: nil)
        PreviewHostApiSetup.setUp(binaryMessenger: messenger, api: nil)
        JobsHostApiSetup.setUp(binaryMessenger: messenger, api: nil)
        ExportHostApiSetup.setUp(binaryMessenger: messenger, api: nil)
        RecorderHostApiSetup.setUp(binaryMessenger: messenger, api: nil)
        PlatformHostApiSetup.setUp(binaryMessenger: messenger, api: nil)
        // The generated register() keeps no channel object, and FlutterEventChannel.setStreamHandler(nil)
        // only cleans up its own connection, so the handler is removed on the messenger directly.
        _ = messenger.setMessageHandlerOnChannel(EngineGlue.eventChannelName, binaryMessageHandler: nil)
        context.events.onCancel(withArguments: nil)
        signals.stop()
        recordingMute.stop()
        Log.debug(.glue, "uninstalled")
    }

    /// Channel of `EngineEventsApi.engineEvents` (generated name, no instance suffix).
    static let eventChannelName = "dev.flutter.pigeon.danaview_editor_engine.EngineEventsApi.engineEvents"
}
