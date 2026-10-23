// OWNER: QA-05 D9
//
// A barrier behind the work queued on Media3's process-wide FrameExtractorInternal
// (media3-inspector-frame 1.11.1), for FrameExtractorDrain. This file sits in Media3's package
// because FrameExtractorInternal and its getInstance()/getDecoderCounters() are package-private.
// The calls are direct (no reflection), so R8 in a minified release build sees them and keeps or
// renames them together with Media3's own code; the app and its libraries share one class loader,
// so the package-private access holds at runtime.
//
// getInstance() returns the process-wide singleton (created on first use without threads or
// codecs, never cleared). getDecoderCounters() submits a task to the instance's ExecutionSequencer
// that runs on the player's (main) looper after every task queued before it: getFrame work and the
// release queued by FrameExtractor.close(). Its future therefore completes once that work is done.

package androidx.media3.inspector.frame

import com.google.common.util.concurrent.ListenableFuture

internal object DanaviewExtractorBarrier {
    /** Queues a no-op behind the extractor's queued work; the future completes when it has run. */
    fun submit(): ListenableFuture<*> = FrameExtractorInternal.getInstance().decoderCounters
}
