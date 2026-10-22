# R8 rules for the HOM-27 route (b) size probe (release-like shrinking of PdfBox-Android).
-keep class dev.danaview.spike.hom27b.Hom27PdfBox { *; }
# PdfBox-Android references desktop/optional classes it never loads on Android.
-dontwarn javax.**
-dontwarn java.awt.**
-dontwarn org.bouncycastle.**
-dontwarn com.gemalto.jp2.**
-dontwarn org.apache.**
