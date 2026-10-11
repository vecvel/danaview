// OWNER: ENG-07 (frozen by ENG-06)
//
// iOS entry point of the editor engine plugin (ARCH §4.4, §12.6). Registration builds the engine
// core of this Flutter engine (EngineContext: queues, EventHub, Dart-supplied roots), the ARCH §4.4
// services (EngineServices; D-33 placeholders until their tickets land) and installs the glue: the
// six Pigeon host APIs and the multiplexed `EngineEventsApi.engineEvents` stream. Until IOS-02
// lands, `capabilities()` answers `supported: false` (`engine_not_available`) and every media call
// fails with `notSupportedOnDevice`, so the editor shows its unsupported state.

import Flutter
import UIKit

public final class VwishEditorEnginePlugin: NSObject, FlutterPlugin {
    private let glue: EngineGlue

    init(glue: EngineGlue) {
        self.glue = glue
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let context = EngineContext(
            messenger: registrar.messenger(),
            textures: registrar.textures(),
            presentingViewController: { [weak registrar] in
                registrar?.viewController ?? EngineContext.keyWindowRootViewController()
            })
        let glue = EngineGlue(context: context, services: EngineServices.make(context: context))
        glue.install()
        let instance = VwishEditorEnginePlugin(glue: glue)
        // Keeps the instance alive for the engine's lifetime and delivers detachFromEngine(for:).
        registrar.publish(instance)
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        glue.uninstall()
    }
}
