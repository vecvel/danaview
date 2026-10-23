package com.vecvel.danaview.spike.face

object Registry {
    fun candidates(ctx: android.content.Context): List<Candidate> = listOf(RawPipeline("ort", OrtModel.Factory))
}
