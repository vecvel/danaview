// OWNER: IOS-10
//
// DVInstruction (ARCH §13.2 'Composition'): the compositor instruction of one layer-boundary interval
// built by IOS-08's InstructionBuilder (`CMTime(k, gridFps)` range, active layers bottom → top, the
// composition video track of each active media layer as required source tracks). It also carries the
// `DVRenderSession` the compositor renders with: AVFoundation instantiates `DVCompositor` itself, so
// the instruction is how a composition hands its session (ParamSnapshot store, CIContext, stores,
// redraw cache, editing mode) to the compositor instance.
//
// Usage: `session.configure(&options)` before `CompositionBuilder.build` sets
// `compositorClass = DVCompositor.self` and `makeInstruction = { DVInstruction(spec: $0, session: session) }`.

import AVFoundation
import Foundation

final class DVInstruction: LayerInstruction, @unchecked Sendable {
    /// The session this instruction renders with (nil only when built without one: the compositor then
    /// fails the request with `internal`).
    let session: DVRenderSession?

    init(spec: InstructionSpec, session: DVRenderSession) {
        self.session = session
        super.init(spec: spec)
    }

    required init(spec: InstructionSpec) {
        self.session = nil
        super.init(spec: spec)
    }

    /// The composition video track of an active media layer.
    func trackID(forLayer id: String) -> CMPersistentTrackID? { spec.trackIDByLayer[id] }

    /// The instruction factory for `CompositionBuildOptions.makeInstruction`.
    static func factory(_ session: DVRenderSession) -> (InstructionSpec) -> AVVideoCompositionInstructionProtocol {
        { [weak session] spec in
            guard let session else { return DVInstruction(spec: spec) }
            return DVInstruction(spec: spec, session: session)
        }
    }
}
