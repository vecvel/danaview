// OWNER: AND-08
//
// The streaming token source PlanReader decodes from (ARCH §11.1 rule 4: plans are UTF-8 JSON
// decoded natively off the main thread with android.util.JsonReader). Production wraps
// android.util.JsonReader ([AndroidJsonTokens]); the plan reader only sees this interface, so the
// pure decoding logic also runs in JVM unit tests (where android.jar's JsonReader is a stub) on a
// test token source.

package com.vecvel.danaview.editor.engine.plan

import android.util.JsonReader
import java.io.ByteArrayInputStream
import java.io.Closeable
import java.io.InputStreamReader

/** Token kinds (the subset of JSON the plan reader needs). */
enum class JsonTokenKind { BEGIN_ARRAY, END_ARRAY, BEGIN_OBJECT, END_OBJECT, NAME, STRING, NUMBER, BOOLEAN, NULL, END_DOCUMENT }

/**
 * A pull-style JSON token source. Numbers are handed out as their literal text so the reader can
 * tell integers from reals exactly; strings and numbers are never coerced into each other.
 * Implementations throw [java.io.IOException] or [IllegalStateException] on malformed input.
 */
interface JsonTokens : Closeable {
    fun peek(): JsonTokenKind
    fun beginObject()
    fun endObject()
    fun beginArray()
    fun endArray()
    fun hasNext(): Boolean
    fun nextName(): String

    /** The next STRING token. */
    fun nextString(): String

    /** The next NUMBER token's literal text (e.g. `"12"`, `"0.5"`, `"1e-7"`). */
    fun nextNumberLiteral(): String
    fun nextBoolean(): Boolean
    fun nextNull()
    fun skipValue()
}

/** [JsonTokens] over android.util.JsonReader (strict mode). */
class AndroidJsonTokens(private val reader: JsonReader) : JsonTokens {
    override fun peek(): JsonTokenKind = when (reader.peek()) {
        android.util.JsonToken.BEGIN_ARRAY -> JsonTokenKind.BEGIN_ARRAY
        android.util.JsonToken.END_ARRAY -> JsonTokenKind.END_ARRAY
        android.util.JsonToken.BEGIN_OBJECT -> JsonTokenKind.BEGIN_OBJECT
        android.util.JsonToken.END_OBJECT -> JsonTokenKind.END_OBJECT
        android.util.JsonToken.NAME -> JsonTokenKind.NAME
        android.util.JsonToken.STRING -> JsonTokenKind.STRING
        android.util.JsonToken.NUMBER -> JsonTokenKind.NUMBER
        android.util.JsonToken.BOOLEAN -> JsonTokenKind.BOOLEAN
        android.util.JsonToken.NULL -> JsonTokenKind.NULL
        android.util.JsonToken.END_DOCUMENT -> JsonTokenKind.END_DOCUMENT
        null -> JsonTokenKind.END_DOCUMENT
    }

    override fun beginObject() = reader.beginObject()
    override fun endObject() = reader.endObject()
    override fun beginArray() = reader.beginArray()
    override fun endArray() = reader.endArray()
    override fun hasNext(): Boolean = reader.hasNext()
    override fun nextName(): String = reader.nextName()
    override fun nextString(): String = reader.nextString()

    // JsonReader.nextString() returns a NUMBER token's literal text.
    override fun nextNumberLiteral(): String = reader.nextString()
    override fun nextBoolean(): Boolean = reader.nextBoolean()
    override fun nextNull() = reader.nextNull()
    override fun skipValue() = reader.skipValue()
    override fun close() = reader.close()

    companion object {
        /** Tokens of UTF-8 JSON [bytes]. */
        fun of(bytes: ByteArray): AndroidJsonTokens =
            AndroidJsonTokens(JsonReader(InputStreamReader(ByteArrayInputStream(bytes), Charsets.UTF_8)))
    }
}
