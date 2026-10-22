// OWNER: HOM-02A
//
// Pigeon errors of the library surface (pigeons/library_api.dart, "Errors"): the code is a
// LibraryErrorCode name, the message debug text without names or paths (rule 30), no details.

package com.vecvel.danaview.library.glue

import com.vecvel.danaview.library.pigeon.LibraryPigeonError

/** The error codes of the frozen surface (Dart `LibraryNativeErrorCode`). */
enum class LibraryErrorCode {
    notSupportedOnDevice,
    permissionDenied,
    notFound,
    cancelled,
    unavailableOffline,
    ioError,
    invalidArgument,
    busy,
    internal,
}

object LibraryErrors {
    /** The error a host method answers with [code]; [message] never names a file or an asset. */
    fun error(code: LibraryErrorCode, message: String): LibraryPigeonError =
        LibraryPigeonError(code.name, message, null)

    /**
     * `notSupportedOnDevice`: the capability does not exist on Android, or the ticket that
     * implements it ([owner]) has not landed yet.
     */
    fun notSupported(owner: String): LibraryPigeonError =
        error(LibraryErrorCode.notSupportedOnDevice, "not supported on this device ($owner)")

    /** Any failure as a Pigeon error: library errors pass through, the rest become `internal`. */
    fun wrap(t: Throwable, what: String): LibraryPigeonError = when (t) {
        is LibraryPigeonError -> t
        is SecurityException -> error(LibraryErrorCode.permissionDenied, "$what: access denied")
        else -> error(LibraryErrorCode.internal, "$what failed (${t.javaClass.simpleName})")
    }
}
