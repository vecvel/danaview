// OWNER: INT-07
//
// Localized texts of the export and background-work notifications (INT-07, ARCH §12.4, §14.3).
// Dart owns all user-facing copy: `EngineHostApi.initialize` (EngineConfigMsg.exportTexts) sets the
// process-wide texts and `ExportHostApi.start` may replace them for that job on (a language change).
// ExportNotification reads [current]; before Dart sent any, the English defaults below apply (the
// same strings as the Dart `ExportNotificationTexts` defaults). Channel names are applied when the
// channels are (re)created, so a later language change renames them too.

package com.vecvel.danaview.editor.engine.export

import com.vecvel.danaview.editor.engine.pigeon.ExportNotificationTextsMsg

/** The notification texts in use (file header). Thread-safe. */
object ExportNotificationTexts {
    /** The English defaults (Dart `ExportNotificationTexts()`). */
    val DEFAULTS = ExportNotificationTextsMsg(
        exportTitle = "Exporting video",
        workTitle = "Working in the background",
        exporting = "Exporting",
        exportingProgress = "Exporting · {percent}%",
        working = "Working",
        workingProgress = "Working · {percent}%",
        cancel = "Cancel",
        savedToGallery = "Saved to Gallery",
        exportFinished = "Export finished",
        more = "+{count} more",
        progressChannelName = "Video export",
        progressChannelDescription = "Progress of video exports and background work",
        doneChannelName = "Finished exports",
        doneChannelDescription = "Exports that finished while the app was closed",
    )

    @Volatile
    private var texts: ExportNotificationTextsMsg = DEFAULTS

    /** The texts in use. */
    val current: ExportNotificationTextsMsg get() = texts

    /** Replaces the texts (initialize, or an export start that carried texts). */
    fun set(value: ExportNotificationTextsMsg) {
        texts = value
    }

    /** Back to the defaults (tests). */
    fun reset() {
        texts = DEFAULTS
    }

    /** [template] with `{percent}` replaced. */
    fun withPercent(template: String, percent: Int): String = template.replace("{percent}", percent.toString())

    /** [template] with `{count}` replaced. */
    fun withCount(template: String, count: Int): String = template.replace("{count}", count.toString())
}
