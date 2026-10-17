// OWNER: ENG-08
//
// An app that attaches the plugin but never opens the editor (a player-only session) starts no
// engine lanes and creates no services (EngineThreads, ARCH §18.1): cache trims before `initialize`
// and detaching an engine that never opened a preview do nothing.

package com.vecvel.danaview.editor.engine.glue

import android.content.ContextWrapper
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.view.TextureRegistry
import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
import org.junit.Test

class GlueIdleTest {
    private val fake = FakeThreads()
    private val ctx = EngineContext(ContextWrapper(null), fake.threads)

    private inline fun <reified T> nullProxy(): T =
        Proxy.newProxyInstance(T::class.java.classLoader, arrayOf(T::class.java)) { _, _, _ -> null } as T

    @Test
    fun cacheTrimsBeforeInitializeStartNoLane() {
        val root = ContextEngineRootPort(ctx)
        CacheTrimLevelMsg.entries.forEach { root.trimCaches(it) }
        fake.settle()
        assertEquals(emptyList<Any>(), fake.threads.started())
    }

    @Test
    fun attachAndDetachWithoutAPreviewStartNoLane() {
        val glue = GlueRegistrar.attach(ctx, nullProxy<BinaryMessenger>(), nullProxy<TextureRegistry>())
        fake.main.onMain { glue.detach() }
        fake.settle()
        assertEquals(emptyList<Any>(), fake.threads.started())
    }
}
