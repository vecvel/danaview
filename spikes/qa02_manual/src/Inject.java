// QA-02 manual tablet checklist (M1-M4), route (b): system-level input injection.
//
// Not part of the app. Runs as the adb shell user through app_process and injects
// real InputEvents into the system input pipeline (InputManager.injectInputEvent, the
// same path as UiAutomation.injectInputEvent and `adb shell input`), so the app sees
// them exactly as it sees events from a hardware keyboard, a mouse or a touch screen.
//
// Build: see build.sh. Run:
//   adb shell CLASSPATH=/data/local/tmp/qa02_inject.dex app_process /system/bin Inject <cmd> ...
//
// Commands (coordinates in device pixels):
//   devices                                list input devices
//   key <KEYCODE> [ctrl] [shift] [alt]     modifier downs, key down/up with meta, modifier ups
//   hover x1 y1 x2 y2 [steps]              mouse HOVER_MOVE path (no button)
//   mclick x y                             mouse primary click
//   rclick x y                             mouse secondary (right) click
//   mdrag x1 y1 x2 y2 [steps]              mouse primary-button drag
//   scroll x y v h [ctrl] [shift]          mouse wheel (AXIS_VSCROLL v, AXIS_HSCROLL h) with
//                                          the modifier key held (key down before, up after)
//   tdrag x1 y1 x2 y2 holdMs moveMs pauseMs  touch long-press drag; pauses pauseMs before lift
//   ttap x y                               touch tap

import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;
import java.lang.reflect.Method;

public class Inject {
  static Object im;
  static Method inject;
  static int kbdId = KeyCharacterMap.VIRTUAL_KEYBOARD;
  static int mouseId = 0;
  static int touchId = 0;

  public static void main(String[] a) throws Exception {
    init();
    String c = a[0];
    switch (c) {
      case "devices": devices(); break;
      case "key": key(a); break;
      case "hover": hover(f(a[1]), f(a[2]), f(a[3]), f(a[4]), a.length > 5 ? Integer.parseInt(a[5]) : 10); break;
      case "mclick": click(f(a[1]), f(a[2]), MotionEvent.BUTTON_PRIMARY); break;
      case "rclick": click(f(a[1]), f(a[2]), MotionEvent.BUTTON_SECONDARY); break;
      case "mdrag": mdrag(f(a[1]), f(a[2]), f(a[3]), f(a[4]), a.length > 5 ? Integer.parseInt(a[5]) : 20); break;
      case "scroll": scroll(a); break;
      case "tdrag": tdrag(f(a[1]), f(a[2]), f(a[3]), f(a[4]), Long.parseLong(a[5]), Long.parseLong(a[6]), Long.parseLong(a[7])); break;
      case "ttap": ttap(f(a[1]), f(a[2])); break;
      default: throw new IllegalArgumentException("unknown command " + c);
    }
  }

  static float f(String s) { return Float.parseFloat(s); }

  static void init() throws Exception {
    Class<?> cls;
    try {
      cls = Class.forName("android.hardware.input.InputManagerGlobal");
    } catch (ClassNotFoundException e) {
      cls = Class.forName("android.hardware.input.InputManager");
    }
    im = cls.getMethod("getInstance").invoke(null);
    inject = cls.getMethod("injectInputEvent", InputEvent.class, int.class);
    // Use the emulator's real devices' ids when they exist (hw.keyboard=yes, virtio mouse).
    for (int id : InputDevice.getDeviceIds()) {
      InputDevice d = InputDevice.getDevice(id);
      if (d == null || d.isVirtual()) continue;
      if (kbdId == KeyCharacterMap.VIRTUAL_KEYBOARD && d.getKeyboardType() == InputDevice.KEYBOARD_TYPE_ALPHABETIC) kbdId = id;
      if (mouseId == 0 && d.supportsSource(InputDevice.SOURCE_MOUSE)) mouseId = id;
      if (touchId == 0 && d.supportsSource(InputDevice.SOURCE_TOUCHSCREEN)) touchId = id;
    }
  }

  static void send(InputEvent e) throws Exception {
    Object ok = inject.invoke(im, e, 2 /* WAIT_FOR_FINISH */);
    if (!Boolean.TRUE.equals(ok)) System.out.println("inject returned " + ok + " for " + e);
  }

  static void devices() {
    for (int id : InputDevice.getDeviceIds()) {
      InputDevice d = InputDevice.getDevice(id);
      if (d == null) continue;
      System.out.println(id + " '" + d.getName() + "' sources=0x" + Integer.toHexString(d.getSources())
          + " kbdType=" + d.getKeyboardType() + " virtual=" + d.isVirtual());
    }
    System.out.println("using kbd=" + kbdId + " mouse=" + mouseId + " touch=" + touchId);
  }

  // ---- keyboard ----
  static void keyEv(long down, int action, int code, int meta) throws Exception {
    long now = SystemClock.uptimeMillis();
    send(new KeyEvent(down, now, action, code, 0, meta, kbdId, 0,
        KeyEvent.FLAG_FROM_SYSTEM, InputDevice.SOURCE_KEYBOARD));
  }

  static void key(String[] a) throws Exception {
    String name = a[1].startsWith("KEYCODE_") ? a[1] : "KEYCODE_" + a[1];
    int code = KeyEvent.keyCodeFromString(name);
    if (code == KeyEvent.KEYCODE_UNKNOWN) throw new IllegalArgumentException("bad key " + a[1]);
    boolean ctrl = false, shift = false, alt = false;
    for (int i = 2; i < a.length; i++) {
      if (a[i].equals("ctrl")) ctrl = true;
      if (a[i].equals("shift")) shift = true;
      if (a[i].equals("alt")) alt = true;
    }
    long t = SystemClock.uptimeMillis();
    int meta = 0;
    if (ctrl) { meta |= KeyEvent.META_CTRL_ON | KeyEvent.META_CTRL_LEFT_ON; keyEv(t, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_CTRL_LEFT, meta); }
    if (shift) { meta |= KeyEvent.META_SHIFT_ON | KeyEvent.META_SHIFT_LEFT_ON; keyEv(t, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_SHIFT_LEFT, meta); }
    if (alt) { meta |= KeyEvent.META_ALT_ON | KeyEvent.META_ALT_LEFT_ON; keyEv(t, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ALT_LEFT, meta); }
    long d = SystemClock.uptimeMillis();
    keyEv(d, KeyEvent.ACTION_DOWN, code, meta);
    SystemClock.sleep(60);
    keyEv(d, KeyEvent.ACTION_UP, code, meta);
    SystemClock.sleep(30);
    if (alt) { meta &= ~(KeyEvent.META_ALT_ON | KeyEvent.META_ALT_LEFT_ON); keyEv(t, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ALT_LEFT, meta); }
    if (shift) { meta &= ~(KeyEvent.META_SHIFT_ON | KeyEvent.META_SHIFT_LEFT_ON); keyEv(t, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_SHIFT_LEFT, meta); }
    if (ctrl) { meta &= ~(KeyEvent.META_CTRL_ON | KeyEvent.META_CTRL_LEFT_ON); keyEv(t, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_CTRL_LEFT, meta); }
  }

  // ---- mouse ----
  static long mDown;

  static void mouse(int action, float x, float y, int buttons, int actionButton, int meta, float v, float h) throws Exception {
    long now = SystemClock.uptimeMillis();
    if (action == MotionEvent.ACTION_DOWN) mDown = now;
    MotionEvent.PointerProperties[] pp = { new MotionEvent.PointerProperties() };
    pp[0].id = 0;
    pp[0].toolType = MotionEvent.TOOL_TYPE_MOUSE;
    MotionEvent.PointerCoords[] pc = { new MotionEvent.PointerCoords() };
    pc[0].x = x; pc[0].y = y;
    pc[0].pressure = (buttons != 0) ? 1f : 0f;
    pc[0].size = 1f;
    if (v != 0) pc[0].setAxisValue(MotionEvent.AXIS_VSCROLL, v);
    if (h != 0) pc[0].setAxisValue(MotionEvent.AXIS_HSCROLL, h);
    long down = (action == MotionEvent.ACTION_HOVER_MOVE || action == MotionEvent.ACTION_HOVER_ENTER
        || action == MotionEvent.ACTION_HOVER_EXIT || action == MotionEvent.ACTION_SCROLL) ? now : mDown;
    MotionEvent e = MotionEvent.obtain(down, now, action, 1, pp, pc, meta, buttons, 1f, 1f, mouseId, 0,
        InputDevice.SOURCE_MOUSE, 0);
    if (actionButton != 0) {
      Method m = MotionEvent.class.getMethod("setActionButton", int.class);
      m.invoke(e, actionButton);
    }
    send(e);
    e.recycle();
  }

  static void hover(float x1, float y1, float x2, float y2, int steps) throws Exception {
    // Only HOVER_MOVE: the dispatcher synthesizes window enter/exit itself. A second
    // HOVER_ENTER from the same device while already hovering aborts system_server's
    // InputDispatcher on API 35 ("Expected ACTION_HOVER_MOVE"), seen 2026-10-22.
    for (int i = 0; i <= steps; i++) {
      float t = (float) i / steps;
      mouse(MotionEvent.ACTION_HOVER_MOVE, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, 0, 0, 0, 0, 0);
      SystemClock.sleep(16);
    }
  }

  static void click(float x, float y, int button) throws Exception {
    mouse(MotionEvent.ACTION_HOVER_MOVE, x, y, 0, 0, 0, 0, 0);
    SystemClock.sleep(50);
    mouse(MotionEvent.ACTION_DOWN, x, y, button, 0, 0, 0, 0);
    mouse(MotionEvent.ACTION_BUTTON_PRESS, x, y, button, button, 0, 0, 0);
    SystemClock.sleep(80);
    mouse(MotionEvent.ACTION_BUTTON_RELEASE, x, y, 0, button, 0, 0, 0);
    mouse(MotionEvent.ACTION_UP, x, y, 0, 0, 0, 0, 0);
    mouse(MotionEvent.ACTION_HOVER_MOVE, x, y, 0, 0, 0, 0, 0);
  }

  static void mdrag(float x1, float y1, float x2, float y2, int steps) throws Exception {
    int b = MotionEvent.BUTTON_PRIMARY;
    mouse(MotionEvent.ACTION_HOVER_MOVE, x1, y1, 0, 0, 0, 0, 0);
    SystemClock.sleep(50);
    mouse(MotionEvent.ACTION_DOWN, x1, y1, b, 0, 0, 0, 0);
    mouse(MotionEvent.ACTION_BUTTON_PRESS, x1, y1, b, b, 0, 0, 0);
    for (int i = 1; i <= steps; i++) {
      float t = (float) i / steps;
      mouse(MotionEvent.ACTION_MOVE, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, b, 0, 0, 0, 0);
      SystemClock.sleep(20);
    }
    SystemClock.sleep(150);
    mouse(MotionEvent.ACTION_BUTTON_RELEASE, x2, y2, 0, b, 0, 0, 0);
    mouse(MotionEvent.ACTION_UP, x2, y2, 0, 0, 0, 0, 0);
  }

  static void scroll(String[] a) throws Exception {
    float x = f(a[1]), y = f(a[2]), v = f(a[3]), h = f(a[4]);
    boolean ctrl = false, shift = false;
    for (int i = 5; i < a.length; i++) {
      if (a[i].equals("ctrl")) ctrl = true;
      if (a[i].equals("shift")) shift = true;
    }
    long t = SystemClock.uptimeMillis();
    int meta = 0;
    mouse(MotionEvent.ACTION_HOVER_MOVE, x, y, 0, 0, 0, 0, 0);
    SystemClock.sleep(50);
    if (ctrl) { meta |= KeyEvent.META_CTRL_ON | KeyEvent.META_CTRL_LEFT_ON; keyEv(t, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_CTRL_LEFT, meta); }
    if (shift) { meta |= KeyEvent.META_SHIFT_ON | KeyEvent.META_SHIFT_LEFT_ON; keyEv(t, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_SHIFT_LEFT, meta); }
    SystemClock.sleep(50);
    mouse(MotionEvent.ACTION_SCROLL, x, y, 0, 0, meta, v, h);
    SystemClock.sleep(80);
    if (shift) { meta &= ~(KeyEvent.META_SHIFT_ON | KeyEvent.META_SHIFT_LEFT_ON); keyEv(t, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_SHIFT_LEFT, meta); }
    if (ctrl) { meta &= ~(KeyEvent.META_CTRL_ON | KeyEvent.META_CTRL_LEFT_ON); keyEv(t, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_CTRL_LEFT, meta); }
  }

  // ---- touch ----
  static long tDown;

  static void touch(int action, float x, float y) throws Exception {
    long now = SystemClock.uptimeMillis();
    if (action == MotionEvent.ACTION_DOWN) tDown = now;
    MotionEvent.PointerProperties[] pp = { new MotionEvent.PointerProperties() };
    pp[0].id = 0;
    pp[0].toolType = MotionEvent.TOOL_TYPE_FINGER;
    MotionEvent.PointerCoords[] pc = { new MotionEvent.PointerCoords() };
    pc[0].x = x; pc[0].y = y; pc[0].pressure = 1f; pc[0].size = 1f;
    MotionEvent e = MotionEvent.obtain(tDown, now, action, 1, pp, pc, 0, 0, 1f, 1f, touchId, 0,
        InputDevice.SOURCE_TOUCHSCREEN, 0);
    send(e);
    e.recycle();
  }

  static void ttap(float x, float y) throws Exception {
    touch(MotionEvent.ACTION_DOWN, x, y);
    SystemClock.sleep(60);
    touch(MotionEvent.ACTION_UP, x, y);
  }

  static void tdrag(float x1, float y1, float x2, float y2, long holdMs, long moveMs, long pauseMs) throws Exception {
    touch(MotionEvent.ACTION_DOWN, x1, y1);
    long end = SystemClock.uptimeMillis() + holdMs;
    while (SystemClock.uptimeMillis() < end) { touch(MotionEvent.ACTION_MOVE, x1, y1); SystemClock.sleep(50); }
    int steps = (int) Math.max(10, moveMs / 16);
    for (int i = 1; i <= steps; i++) {
      float t = (float) i / steps;
      touch(MotionEvent.ACTION_MOVE, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
      SystemClock.sleep(16);
    }
    System.out.println("tdrag: holding at target");
    end = SystemClock.uptimeMillis() + pauseMs;
    // small wiggle keeps DRAG_LOCATION events flowing while the screenshot is taken
    int k = 0;
    while (SystemClock.uptimeMillis() < end) { touch(MotionEvent.ACTION_MOVE, x2 + ((k++ & 1) == 0 ? 1 : 0), y2); SystemClock.sleep(50); }
    touch(MotionEvent.ACTION_MOVE, x2, y2);
    SystemClock.sleep(50);
    touch(MotionEvent.ACTION_UP, x2, y2);
    System.out.println("tdrag: released");
  }
}
