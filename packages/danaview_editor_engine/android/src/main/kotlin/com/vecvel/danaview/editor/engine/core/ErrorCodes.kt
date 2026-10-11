// OWNER: ENG-08
//
// Engine error codes and their mapping to Pigeon errors and event failures (ARCH §12.5, §12.6,
// §19). Every error that leaves the engine is `FlutterError(code = EngineErrorCode.name, message
// without paths, details = {itemId?, mediaFingerprint?, retryable})`; error_mapper.dart turns it
// into an `EngineFailure`. Messages are scrubbed of paths and URIs here (ARCH §20.1, BUILD_PLAN §1
// rule 4); error_mapper.dart scrubs again as defence in depth.

package com.vecvel.danaview.editor.engine.core

import com.vecvel.danaview.editor.engine.pigeon.EnginePigeonError
import com.vecvel.danaview.editor.engine.pigeon.FailureMsg
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.CancellationException

/**
 * The engine error codes. Names equal the Dart `EngineErrorCode` values exactly (ARCH §12.5);
 * `ErrorCodesTest` checks them against packages/danaview_editor_engine_api/lib/src/failures.dart.
 */
@Suppress("EnumEntryName")
enum class EngineErrorCode {
    mediaOffline,
    permissionDenied,
    unsupportedMedia,
    decoderInitFailed,
    decodeFailed,
    encoderUnavailable,
    encoderSizeLimit,
    encodingFailed,
    diskFull,
    io,
    planInvalid,
    planOutOfSync,
    gpuUnavailable,
    surfaceLost,
    interrupted,
    cancelled,
    busy,
    notSupportedOnDevice,
    internal,
}

/**
 * A typed engine failure (ARCH §12.5). Services throw it or pass it to a [Completion]; the glue turns
 * it into an [EnginePigeonError] and the event hub into a [FailureMsg]. [message] must not contain
 * paths, URIs or user content (it is scrubbed anyway).
 */
class EngineException(
    val code: EngineErrorCode,
    message: String,
    val itemId: String? = null,
    val mediaFingerprint: String? = null,
    val retryable: Boolean = false,
    cause: Throwable? = null,
) : RuntimeException(message, cause)

/** Constructors and conversions for engine errors (ARCH §12.5, §19). */
object EngineErrors {
    private val pathLike = Regex("""(file|content)://\S+|(?<![\w.])/(?:[^\s/'"]+/)+[^\s'"]*""")

    /** Removes anything that looks like a file path or URI from [text] (same rule as error_mapper.dart). */
    fun scrub(text: String): String = text.replace(pathLike, "<path>")

    /** The D-33 placeholder failure: [what] is not built on this device yet. */
    fun notSupported(what: String): EngineException =
        EngineException(EngineErrorCode.notSupportedOnDevice, "$what is not available on this device yet")

    /** A Dart-side argument error (a caller bug): `internal`, surfaced as UnknownFailure + debug assert (ARCH §19). */
    fun invalidArgument(name: String, why: String): EngineException =
        EngineException(EngineErrorCode.internal, "invalid argument $name: $why")

    /** The plan or patch payload is malformed (`planInvalid`, ARCH §11.3). */
    fun invalidPlan(why: String): EngineException = EngineException(EngineErrorCode.planInvalid, why)

    /** The engine has not received its roots yet (`EngineHostApi.initialize`). */
    fun notInitialized(): EngineException = EngineException(EngineErrorCode.internal, "engine not initialized")

    /**
     * Converts any [Throwable] to an [EngineException]:
     * [EngineException] as is; [EnginePigeonError] by its code; [CancellationException] →
     * `cancelled`; [SecurityException] → `permissionDenied`; [FileNotFoundException] → `mediaOffline`;
     * an [IOException] whose message says ENOSPC → `diskFull`, any other → `io`; [InterruptedException]
     * → `interrupted`; anything else → `internal` with the exception's class name only.
     */
    fun from(error: Throwable): EngineException = when (error) {
        is EngineException -> error
        is EnginePigeonError -> {
            val code = EngineErrorCode.entries.firstOrNull { it.name == error.code } ?: EngineErrorCode.internal
            EngineException(code, error.message ?: error.code, cause = error)
        }
        is CancellationException -> EngineException(EngineErrorCode.cancelled, "cancelled", cause = error)
        is SecurityException -> EngineException(EngineErrorCode.permissionDenied, "access denied", cause = error)
        is FileNotFoundException -> EngineException(EngineErrorCode.mediaOffline, "file not found", cause = error)
        is IOException -> {
            val text = error.message.orEmpty()
            if (text.contains("ENOSPC") || text.contains("No space left", ignoreCase = true)) {
                EngineException(EngineErrorCode.diskFull, "no space left on device", cause = error)
            } else {
                EngineException(EngineErrorCode.io, "I/O error (${error.javaClass.simpleName})", cause = error)
            }
        }
        is InterruptedException -> EngineException(EngineErrorCode.interrupted, "interrupted", cause = error)
        else -> EngineException(EngineErrorCode.internal, "unexpected ${error.javaClass.simpleName}", cause = error)
    }

    /** The Pigeon error for [error]: code = `EngineErrorCode.name`, scrubbed message, details map. */
    fun toPigeon(error: Throwable): EnginePigeonError {
        val e = from(error)
        return EnginePigeonError(
            e.code.name,
            scrub(e.message.orEmpty()),
            mapOf("itemId" to e.itemId, "mediaFingerprint" to e.mediaFingerprint, "retryable" to e.retryable),
        )
    }

    /** The event payload for [error] (job and session failures, ARCH §12.6). */
    fun toFailureMsg(error: Throwable): FailureMsg {
        val e = from(error)
        return FailureMsg(
            code = e.code.name,
            message = scrub(e.message.orEmpty()),
            itemId = e.itemId,
            mediaFingerprint = e.mediaFingerprint,
            retryable = e.retryable,
        )
    }
}
