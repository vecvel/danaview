// OWNER: AI-06

package com.vecvel.danaview.whisper

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ThermalMapperTest {
    @Test
    fun mapsPowerManagerStatusesToTheFourLevels() {
        assertEquals("nominal", ThermalMapper.map(0)) // THERMAL_STATUS_NONE
        assertEquals("nominal", ThermalMapper.map(1)) // LIGHT
        assertEquals("fair", ThermalMapper.map(2)) // MODERATE
        assertEquals("serious", ThermalMapper.map(3)) // SEVERE
        assertEquals("critical", ThermalMapper.map(4)) // CRITICAL
        assertEquals("critical", ThermalMapper.map(5)) // EMERGENCY
        assertEquals("critical", ThermalMapper.map(6)) // SHUTDOWN
    }

    @Test
    fun unknownFutureStatusesAreCriticalAndNegativeMeansNoSignal() {
        assertEquals("critical", ThermalMapper.map(7))
        assertEquals("critical", ThermalMapper.map(Int.MAX_VALUE))
        assertNull(ThermalMapper.map(-1))
        assertNull(ThermalMapper.map(Int.MIN_VALUE))
    }

    @Test
    fun theLevelNamesAreExactlyTheDartEnumNames() {
        val names = (0..6).mapNotNull { ThermalMapper.map(it) }.toSet()
        assertEquals(setOf("nominal", "fair", "serious", "critical"), names)
    }

    @Test
    fun eventMapsCarryTypeAndValue() {
        assertEquals(mapOf("type" to "thermal", "value" to "serious"), DeviceEvents.thermal(3))
        assertNull(DeviceEvents.thermal(-1))
        assertEquals(mapOf("type" to "memoryWarning"), DeviceEvents.memoryWarning())
        assertEquals(mapOf("type" to "lowPower", "value" to true), DeviceEvents.lowPower(true))
        assertEquals(mapOf("type" to "lifecycle", "value" to "background"), DeviceEvents.lifecycle(true))
        assertEquals(mapOf("type" to "lifecycle", "value" to "foreground"), DeviceEvents.lifecycle(false))
    }
}

class TrimLevelsTest {
    @Test
    fun runningLowAndCriticalAreWarnings() {
        assertTrue(TrimLevels.isMemoryWarning(TrimLevels.RUNNING_LOW))
        assertTrue(TrimLevels.isMemoryWarning(TrimLevels.RUNNING_CRITICAL))
    }

    @Test
    fun uiHiddenAndRunningModerateAreNot() {
        assertFalse(TrimLevels.isMemoryWarning(TrimLevels.UI_HIDDEN))
        assertFalse(TrimLevels.isMemoryWarning(TrimLevels.RUNNING_MODERATE))
        assertFalse(TrimLevels.isMemoryWarning(0))
    }

    @Test
    fun lruListLevelsAreWarnings() {
        assertTrue(TrimLevels.isMemoryWarning(TrimLevels.BACKGROUND))
        assertTrue(TrimLevels.isMemoryWarning(TrimLevels.MODERATE))
        assertTrue(TrimLevels.isMemoryWarning(TrimLevels.COMPLETE))
    }
}

class MemoryMathTest {
    @Test
    fun headroomIsAvailMinusThreshold() {
        assertEquals(500L, MemoryMath.headroom(1500L, 1000L, false))
    }

    @Test
    fun noHeadroomStaysPositiveSoDartDoesNotReadItAsUnknown() {
        assertEquals(1L, MemoryMath.headroom(900L, 1000L, false))
        assertEquals(1L, MemoryMath.headroom(1000L, 1000L, false))
        assertEquals(1L, MemoryMath.headroom(10_000L, 1000L, true))
    }
}

class CpuInfoTest {
    @Test
    fun primeGoldSilverDesignCountsPrimeAndGold() {
        // 1 prime 3.36 GHz, 4 gold 2.8 GHz, 3 silver 2.0 GHz
        val freqs = listOf(3360000L, 2800000L, 2800000L, 2800000L, 2800000L, 2000000L, 2000000L, 2000000L)
        assertEquals(5, CpuInfo.perfCoreCount(freqs))
    }

    @Test
    fun bigLittleDesignCountsTheBigCluster() {
        assertEquals(4, CpuInfo.perfCoreCount(listOf(2000000L, 2000000L, 2000000L, 2000000L, 1500000L, 1500000L, 1500000L, 1500000L)))
    }

    @Test
    fun tensorStyleThreeClusters() {
        // 2 x 2.85, 2 x 2.35, 4 x 1.80
        assertEquals(4, CpuInfo.perfCoreCount(listOf(2850000L, 2850000L, 2350000L, 2350000L, 1800000L, 1800000L, 1800000L, 1800000L)))
    }

    @Test
    fun homogeneousChipCountsEveryCore() {
        assertEquals(8, CpuInfo.perfCoreCount(List(8) { 2200000L }))
    }

    @Test
    fun missingOrZeroFrequenciesAreUnknown() {
        assertEquals(0, CpuInfo.perfCoreCount(emptyList()))
        assertEquals(0, CpuInfo.perfCoreCount(listOf(0L, -1L)))
        assertEquals(2, CpuInfo.perfCoreCount(listOf(0L, 2000000L, 2000000L)))
    }

    private val pixelFeatures = "fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm lrcpc dcpop asimddp i8mm bf16"

    @Test
    fun parsesDotprodFp16I8mmAndBf16() {
        val text = "processor\t: 0\nFeatures\t: $pixelFeatures\nCPU implementer\t: 0x41\n"
        assertEquals(listOf("dotprod", "fp16", "i8mm", "bf16"), CpuInfo.featuresFromCpuInfo(text))
    }

    @Test
    fun scalarFp16AloneIsNotFp16() {
        val text = "Features\t: fp asimd fphp asimddp\n"
        assertEquals(listOf("dotprod"), CpuInfo.featuresFromCpuInfo(text))
    }

    @Test
    fun aFeatureMustBePresentOnEveryCore() {
        val text = """
            processor	: 0
            Features	: fp asimd asimdhp asimddp
            processor	: 1
            Features	: fp asimd asimdhp asimddp
            processor	: 2
            Features	: fp asimd asimdhp
        """.trimIndent()
        assertEquals(listOf("fp16"), CpuInfo.featuresFromCpuInfo(text))
    }

    @Test
    fun x86AndEmptyInputHaveNoFeatures() {
        assertEquals(emptyList<String>(), CpuInfo.featuresFromCpuInfo("flags\t: fpu sse sse2 avx2\n"))
        assertEquals(emptyList<String>(), CpuInfo.featuresFromCpuInfo(""))
        assertEquals(emptyList<String>(), CpuInfo.featuresFromCpuInfo("Features"))
    }
}
