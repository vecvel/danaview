// OWNER: HOM-25
//
// Errors of the PDF surface (pigeons/pdf_api.dart, "Errors") on Android: the Flutter-free core
// throws [PdfFailure] with a [PdfErrorCode]; the host APIs answer `PdfPigeonError(code: <name>,
// message: debug text without names, paths or document text (rule 30), details: null)`. Native
// exceptions map to typed failures here (ARCH v1.2 §11: no PDF action can crash the app).

package com.vecvel.danaview.pdf.glue

import com.vecvel.danaview.pdf.pigeon.PdfPigeonError
import java.io.IOException

/** The error codes of the frozen surface (Dart `PdfErrorCode`); the names are the wire codes. */
@Suppress("EnumEntryName")
enum class PdfErrorCode {
    notSupportedOnDevice,
    passwordRequired,
    unsupported,
    damaged,
    cancelled,
    noSpace,
    notFound,
    invalidArgument,
    ioError,
    internal,
}

/** A failure of a PDF operation; [message] is debug text without names, paths or document text. */
class PdfFailure(val code: PdfErrorCode, message: String) : Exception(message) {
    companion object {
        fun notFound(message: String) = PdfFailure(PdfErrorCode.notFound, message)
        fun invalid(message: String) = PdfFailure(PdfErrorCode.invalidArgument, message)
        fun damaged(message: String) = PdfFailure(PdfErrorCode.damaged, message)
        fun locked() = PdfFailure(PdfErrorCode.passwordRequired, "document is locked")
        fun cancelled() = PdfFailure(PdfErrorCode.cancelled, "cancelled")
    }
}

object PdfErrors {
    /** The error a host method answers with [code]. */
    fun error(code: PdfErrorCode, message: String): PdfPigeonError = PdfPigeonError(code.name, message, null)

    /**
     * `notSupportedOnDevice`: the capability does not exist on this device, or the ticket that
     * implements it ([owner]) has not landed yet.
     */
    fun notSupported(owner: String): PdfPigeonError =
        error(PdfErrorCode.notSupportedOnDevice, "not supported on this device ($owner)")

    /** Any failure as a Pigeon error: PDF errors keep their code, the rest are mapped by kind. */
    fun from(t: Throwable, what: String): PdfPigeonError = when (t) {
        is PdfPigeonError -> t
        is PdfFailure -> error(t.code, t.message ?: t.code.name)
        is OutOfMemoryError -> error(PdfErrorCode.internal, "$what: out of memory")
        is IOException -> if (isNoSpace(t)) error(PdfErrorCode.noSpace, "$what: out of space") else error(PdfErrorCode.ioError, "$what: i/o error")
        is SecurityException -> error(PdfErrorCode.ioError, "$what: access denied")
        else -> error(PdfErrorCode.internal, "$what failed (${t.javaClass.simpleName})")
    }

    /** ENOSPC anywhere in the cause chain. */
    fun isNoSpace(t: Throwable): Boolean {
        var c: Throwable? = t
        var depth = 0
        while (c != null && depth < 8) {
            if (c.message?.contains("ENOSPC") == true || c.message?.contains("No space left") == true) return true
            c = c.cause
            depth++
        }
        return false
    }
}
