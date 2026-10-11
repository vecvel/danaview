// OWNER: IOS-16
//
// External drop target (D-18, ARCH §15): a UIDropInteraction on the Flutter view while the editor
// enables it (`setDropTargetEnabled(true)`); disabling removes the interaction, so nothing can be
// dropped outside the editor.
//
// Accepted items: movies, audio, images and `.cube` LUTs (any representation whose suggested name
// or type extension is `cube`). Other items are ignored; a session with no accepted item is
// refused (`.forbidden`). On drop, each accepted provider is loaded with
// `loadFileRepresentation` and cloned (clonefile, copy fallback) into
// `<cache>/vwish/editor/work/drops/<uuid>/<name>` inside the completion handler
// (ItemProviderImport, shared with IOS-15). One `drop` event carries the items (file URI,
// name, `origin = drop`, `isTemporaryCopy = true`) and the drop position in logical px (UIKit
// points of the Flutter view, which are Flutter's logical pixels). Dart imports them as managed
// copies and moves them out of `work/drops/` (MediaPoolService); leftovers older than 24 h are
// wiped by DiskCache.

import Flutter
import Foundation
import UIKit

final class DropTarget: NSObject, DropTargeting, UIDropInteractionDelegate {
    /// Kinds a drop accepts (D-18).
    static let acceptedKinds: Set<MediaPickKindMsg> = [.video, .audio, .image, .lut]

    private let context: EngineContext
    /// The view drops land on: the Flutter view by default (main thread).
    var hostView: () -> UIView? = DropTarget.flutterView
    /// The installed interaction while enabled (main thread).
    private(set) var interaction: UIDropInteraction?
    /// The view [interaction] is installed on.
    private weak var installedView: UIView?
    /// Called after a drop event was emitted or a drop produced no item (tests).
    var onDropHandled: ((DropMsg?) -> Void)?

    init(context: EngineContext) {
        self.context = context
    }

    func setEnabled(_ enabled: Bool, reply: @escaping EngineReply<Void>) {
        if enabled {
            guard let view = hostView() else {
                reply(.failure(EngineError(.internal, "no Flutter view for the drop target")))
                return
            }
            if interaction != nil, installedView === view {
                reply(.success(()))
                return
            }
            removeInteraction()
            let interaction = UIDropInteraction(delegate: self)
            view.addInteraction(interaction)
            self.interaction = interaction
            installedView = view
            Log.debug(.platform, "drop target enabled")
        } else {
            removeInteraction()
        }
        reply(.success(()))
    }

    private func removeInteraction() {
        if let interaction = interaction {
            interaction.view?.removeInteraction(interaction)
            Log.debug(.platform, "drop target disabled")
        }
        interaction = nil
        installedView = nil
    }

    // MARK: UIDropInteractionDelegate

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        accepts(session)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: accepts(session) ? .copy : .forbidden)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        let view = interaction.view ?? installedView
        let point = view.map { session.location(in: $0) } ?? .zero
        handleDrop(providers: session.items.map(\.itemProvider), at: point)
    }

    /// Whether [session] holds at least one accepted item and the target is enabled.
    func accepts(_ session: UIDropSession) -> Bool {
        guard interaction != nil else { return false }
        return session.items.contains { ItemProviderImport.classify($0.itemProvider, kinds: DropTarget.acceptedKinds) != nil }
    }

    /// Copies the accepted providers into `work/drops/` and emits one `drop` event at [point]
    /// (logical px of the Flutter view).
    func handleDrop(providers: [NSItemProvider], at point: CGPoint) {
        guard let paths = context.paths else {
            Log.error(.platform, "drop before initialize ignored")
            onDropHandled?(nil)
            return
        }
        ItemProviderImport.load(providers, kinds: DropTarget.acceptedKinds, into: paths.workDrops, origin: .drop) {
            [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let items) where !items.isEmpty:
                    // A drop that finished copying after the editor closed is still delivered; Dart
                    // drops it when its target is disabled (and the copies expire with work/drops).
                    let drop = DropMsg(items: items, x: Double(point.x), y: Double(point.y))
                    self.context.events.emitDrop(drop)
                    self.onDropHandled?(drop)
                case .success:
                    self.onDropHandled?(nil)
                case .failure(let error):
                    Log.error(.platform, "drop failed: \(EngineError.from(error).code.rawValue)")
                    self.onDropHandled?(nil)
                }
            }
        }
    }

    // MARK: Flutter view lookup

    /// The view of the app's FlutterViewController (the key window's root or one of its children).
    static func flutterView() -> UIView? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        let ordered = windows.filter { $0.isKeyWindow } + windows.filter { !$0.isKeyWindow }
        for window in ordered {
            if let flutter = findFlutter(window.rootViewController) { return flutter.view }
        }
        return ordered.first?.rootViewController?.view
    }

    private static func findFlutter(_ controller: UIViewController?) -> FlutterViewController? {
        guard let controller = controller else { return nil }
        if let flutter = controller as? FlutterViewController { return flutter }
        for child in controller.children {
            if let flutter = findFlutter(child) { return flutter }
        }
        return nil
    }
}
