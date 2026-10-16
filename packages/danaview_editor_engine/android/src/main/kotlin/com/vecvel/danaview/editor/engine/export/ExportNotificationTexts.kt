// OWNER: INT-07
//
// Localized texts of the export and background-work notifications (INT-07, ARCH §12.4, §14.3).
// Dart owns all user-facing copy: `EngineHostApi.initialize` (EngineConfigMsg.exportTexts) sets the
// process-wide texts and `ExportHostApi.start` may replace them for that job on (a language change).
// ExportNotification reads [current]; before Dart sent any, the English defaults below apply (the
// same strings as the Dart `ExportNotificationTexts` defaults). Channel names are applied when the
// channels are (re)created, so a later language change renames them too.
// M-19: texts are cosmetic and never fail a call. A string that is blank or longer than
// [MAX_LENGTH] chars falls back to its English default, for that string only ([withFallbacks]).
// The texts are process-wide while every Flutter engine sends its own config, so an `initialize`
// whose texts equal the English defaults (a second engine started with the default config) does
// not replace localized texts another engine set ([setFromInitialize]); an export `start` that
// carries texts always replaces them (its own job uses them).

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

    /** Longest accepted string (chars); longer ones fall back to the default. */
    const val MAX_LENGTH = 256

    /** [value] with every blank or over-[MAX_LENGTH] string replaced by its English default. */
    fun withFallbacks(value: ExportNotificationTextsMsg): ExportNotificationTextsMsg {
        val d = DEFAULTS
        fun pick(text: String, default: String) = if (text.isBlank() || text.length > MAX_LENGTH) default else text
        return ExportNotificationTextsMsg(
            exportTitle = pick(value.exportTitle, d.exportTitle),
            workTitle = pick(value.workTitle, d.workTitle),
            exporting = pick(value.exporting, d.exporting),
            exportingProgress = pick(value.exportingProgress, d.exportingProgress),
            working = pick(value.working, d.working),
            workingProgress = pick(value.workingProgress, d.workingProgress),
            cancel = pick(value.cancel, d.cancel),
            savedToGallery = pick(value.savedToGallery, d.savedToGallery),
            exportFinished = pick(value.exportFinished, d.exportFinished),
            more = pick(value.more, d.more),
            progressChannelName = pick(value.progressChannelName, d.progressChannelName),
            progressChannelDescription = pick(value.progressChannelDescription, d.progressChannelDescription),
            doneChannelName = pick(value.doneChannelName, d.doneChannelName),
            doneChannelDescription = pick(value.doneChannelDescription, d.doneChannelDescription),
        )
    }

    /** Replaces the texts (an export start that carried texts), with per-string fallbacks. */
    fun set(value: ExportNotificationTextsMsg) {
        texts = withFallbacks(value)
    }

    /**
     * The texts of an `initialize` (with per-string fallbacks). English defaults do not replace
     * localized texts already set by another engine (file header). Returns whether they applied.
     */
    fun setFromInitialize(value: ExportNotificationTextsMsg): Boolean {
        val clean = withFallbacks(value)
        synchronized(this) {
            if (clean == DEFAULTS && texts != DEFAULTS) return false
            texts = clean
            return true
        }
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
