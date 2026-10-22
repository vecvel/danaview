// OWNER: QA-05 D9
//
// CodecHandover on the JVM: it opens when every part reported (each part counts once) or when the
// bound passes, and its callback runs exactly once, whichever order the parts, the bound and the
// callback arrive in.

package com.vecvel.danaview.editor.engine.export

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CodecHandoverTest {
    @Test
    fun opensWhenEveryPartReported() {
        val h = CodecHandover(2)
        val a = h.part()
        val b = h.part()
        var ready = 0
        h.whenOpen { ready++ }
        a()
        a() // counts once
        assertEquals(0, ready)
        assertFalse(h.isOpen)
        b()
        assertEquals(1, ready)
        assertTrue(h.allReported)
        h.timeout()
        b()
        assertEquals(1, ready)
    }

    @Test
    fun theBoundOpensAGateWithAPartMissing() {
        val h = CodecHandover(2)
        val a = h.part()
        h.part()
        var ready = 0
        h.whenOpen { ready++ }
        a()
        h.timeout()
        assertEquals(1, ready)
        assertFalse(h.allReported)
    }

    @Test
    fun aCallbackAddedAfterTheGateOpenedRunsAtOnce() {
        val h = CodecHandover(1)
        h.part()()
        var ready = 0
        h.whenOpen { ready++ }
        assertEquals(1, ready)
        h.whenOpen { ready += 10 } // only the first callback is kept
        assertEquals(1, ready)
    }

    @Test
    fun noPartsIsOpen() {
        val h = CodecHandover(0)
        var ready = 0
        h.whenOpen { ready++ }
        assertEquals(1, ready)
        assertTrue(h.allReported)
    }
}
