# OWNER: HOM-25
# Consumer R8 rules of danaview_pdf, applied to the app's release build. PdfBox-Android's AAR ships
# its own keep rules (security handlers); it also references desktop and optional classes it never
# loads on Android (HOM-27 report, probe_b/proguard-rules.pro).
-dontwarn javax.**
-dontwarn java.awt.**
-dontwarn org.bouncycastle.**
-dontwarn com.gemalto.jp2.**
-dontwarn org.apache.**
