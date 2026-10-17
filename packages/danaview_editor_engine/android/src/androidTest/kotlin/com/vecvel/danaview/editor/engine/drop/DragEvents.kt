// OWNER: AND-15
//
// Synthesized DragEvents for the drop target tests. DragEvent has no public constructor (obtain()
// is hidden), but it is Parcelable: the event is written in the platform's own parcel layout and
// read back with DragEvent.CREATOR, which needs no hidden API. The layout changed across releases
// (API 31 added offsets and the drag surface, API 34 flags), so every known layout is tried and the
// one that round-trips exactly (action, position, result, clip data, description, and the whole
// parcel consumed) is used.
//
// The event carries a fake IDragAndDropPermissions binder (FakePermissionsBinder) so that
// Activity.requestDragAndDropPermissions(event) returns a real DragAndDropPermissions whose take()
// and release() calls reach the test as binder transactions.

package com.vecvel.danaview.editor.engine.drop

import android.content.ClipData
import android.content.ClipDescription
import android.os.Binder
import android.os.Parcel
import android.view.DragEvent
import java.util.Collections

/** Records the transactions of the IDragAndDropPermissions AIDL proxy (take = 1, release = 3 on API 29..36). */
class FakePermissionsBinder : Binder() {
    val codes: MutableList<Int> = Collections.synchronizedList(ArrayList())

    override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
        if (code == INTERFACE_TRANSACTION) return super.onTransact(code, data, reply, flags)
        codes += code
        reply?.writeNoException()
        return true
    }

    val took: Boolean get() = codes.contains(TAKE)
    val released: Boolean get() = codes.contains(RELEASE)

    companion object {
        const val TAKE = 1
        const val RELEASE = 3
    }
}

object DragEvents {
    private data class Layout(val offsets: Boolean, val flags: Boolean, val surface: Boolean)

    private val layouts = listOf(
        Layout(offsets = true, flags = true, surface = true), // API 34+
        Layout(offsets = true, flags = false, surface = true), // API 31..33
        Layout(offsets = false, flags = false, surface = false), // API 24..30
    )

    @Volatile private var chosen: Layout? = null

    /** A DragEvent with the given fields. */
    fun obtain(
        action: Int,
        x: Float,
        y: Float,
        description: ClipDescription?,
        data: ClipData?,
        permissions: Binder? = null,
        result: Boolean = false,
    ): DragEvent {
        chosen?.let { return build(it, action, x, y, description, data, permissions, result)!! }
        for (layout in layouts) {
            val event = build(layout, action, x, y, description, data, permissions, result) ?: continue
            chosen = layout
            return event
        }
        error("no known DragEvent parcel layout round-trips on this API level")
    }

    private fun build(
        layout: Layout,
        action: Int,
        x: Float,
        y: Float,
        description: ClipDescription?,
        data: ClipData?,
        permissions: Binder?,
        result: Boolean,
    ): DragEvent? {
        val p = Parcel.obtain()
        try {
            p.writeInt(action)
            p.writeFloat(x)
            p.writeFloat(y)
            if (layout.offsets) {
                p.writeFloat(0f)
                p.writeFloat(0f)
            }
            if (layout.flags) p.writeInt(0)
            p.writeInt(if (result) 1 else 0)
            if (data == null) p.writeInt(0) else {
                p.writeInt(1)
                data.writeToParcel(p, 0)
            }
            if (description == null) p.writeInt(0) else {
                p.writeInt(1)
                description.writeToParcel(p, 0)
            }
            if (layout.surface) p.writeInt(0)
            if (permissions == null) p.writeInt(0) else {
                p.writeInt(1)
                p.writeStrongBinder(permissions)
            }
            val size = p.dataSize()
            p.setDataPosition(0)
            val event = try {
                DragEvent.CREATOR.createFromParcel(p)
            } catch (e: RuntimeException) {
                return null
            }
            val ok = p.dataPosition() == size &&
                event.action == action && event.x == x && event.y == y && event.result == result &&
                (event.clipData?.itemCount ?: -1) == (data?.itemCount ?: -1) &&
                event.clipDescription?.label?.toString() == description?.label?.toString() &&
                (event.clipDescription?.mimeTypeCount ?: -1) == (description?.mimeTypeCount ?: -1)
            return if (ok) event else null
        } finally {
            p.recycle()
        }
    }
}
