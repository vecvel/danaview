package com.vecvel.danaview.spike.face

/** Every candidate in one APK, so parity is computed on the device and no landmarks leave it. */
object Registry {
    fun candidates(ctx: android.content.Context): List<Candidate> =
        listOf(MediaPipeCandidate(ctx), RawPipeline("litert", LiteRtModel.Factory), RawPipeline("ort", OrtModel.Factory))
}
