# VED-33A spike: R8 shrinks every runtime the way a release app build would. Only the entry point is kept;
# the runtimes' own consumer rules (shipped in their AARs) keep what their JNI needs.
-keep class com.vecvel.danaview.spike.face.FaceBench { <init>(); *; }
-dontwarn com.google.auto.value.**
-dontwarn javax.annotation.**
-dontwarn com.google.errorprone.annotations.**
-dontwarn org.checkerframework.**

# MediaPipe Tasks ships no consumer rules for its protobuf-lite options and JNI callbacks (found on the
# device run: "Field platform_ ... not found" under R8). The product would need the same two rules.
-keep class * extends com.google.protobuf.GeneratedMessageLite { <fields>; }
-keep class com.google.mediapipe.framework.** { *; }
-dontwarn com.google.mediapipe.proto.**
-keep class com.google.common.flogger.** { *; }
# ONNX Runtime's JNI looks its Java classes up by name; the AAR has no consumer rules.
-keep class ai.onnxruntime.** { *; }
