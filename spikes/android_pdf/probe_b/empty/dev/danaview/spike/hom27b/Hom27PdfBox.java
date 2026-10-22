// Size baseline: the same instrumentation APK with no PDF library (APK size delta = route (b) cost).
package dev.danaview.spike.hom27b;

import android.app.Instrumentation;
import android.os.Bundle;

public final class Hom27PdfBox extends Instrumentation {
    @Override
    public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        start();
    }

    @Override
    public void onStart() {
        finish(0, new Bundle());
    }
}
