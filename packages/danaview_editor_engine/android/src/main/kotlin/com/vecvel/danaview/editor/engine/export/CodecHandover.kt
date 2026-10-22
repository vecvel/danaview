// OWNER: QA-05 D9
//
// The codec handover at an export's start. When an export starts, the preview sessions release
// their decoders (weak tiers, ARCH §14.3) and the job registry stops background and proxy jobs.
// Both happen asynchronously. Before this gate, the export created its decoders and encoders at
// the same moment, so a burst of codec releases met a burst of codec creations. In QA-05 run b
// (op #166) that is where the codec system wedged: the export thread waited in
// MediaCodec.createByCodecName → reclaimResourcesFromClientsPendingRemoval → MediaCodec::reclaim
// of a codec of our own process whose release never finished, and the dropped decks' playback
// threads stayed in MediaCodec.release.
//
// [CodecHandover] opens when every part it was given has reported (each part counts once) or when
// its bound passes, whichever is first. The export then starts its codecs. Its callback runs at most
// once. The bound keeps a part that never reports (a session disposed while queued, a stuck release)
// from holding the export: the export then starts as it did before, and the log says so.

package com.vecvel.danaview.editor.engine.export

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class CodecHandover(parts: Int) {
    private val left = AtomicInteger(parts)
    private val opened = AtomicBoolean(false)
    private val fired = AtomicBoolean(false)

    @Volatile
    private var onOpen: (() -> Unit)? = null

    /** How the gate opened: true when every part reported, false when the bound passed first. */
    @Volatile
    var allReported: Boolean = false
        private set

    init {
        if (parts <= 0) {
            allReported = true
            opened.set(true)
        }
    }

    /** A one-shot reporter for one part (calling it twice counts once). */
    fun part(): () -> Unit {
        val once = AtomicBoolean(false)
        return {
            if (once.compareAndSet(false, true) && left.decrementAndGet() == 0) {
                allReported = true
                open()
            }
        }
    }

    /** The bound passed: open whatever is still outstanding. */
    fun timeout() = open()

    /** Runs [ready] once the gate is open (at once when it already is). Only the first call is kept. */
    fun whenOpen(ready: () -> Unit) {
        if (onOpen != null) return
        onOpen = ready
        if (opened.get()) fire()
    }

    val isOpen: Boolean get() = opened.get()

    private fun open() {
        if (opened.compareAndSet(false, true)) fire()
    }

    private fun fire() {
        val cb = onOpen ?: return
        if (fired.compareAndSet(false, true)) cb()
    }

    companion object {
        /** The longest an export waits for the previews and pre-empted jobs to release their codecs. */
        const val BOUND_MS = 5_000L
    }
}
