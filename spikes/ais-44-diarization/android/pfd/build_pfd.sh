#!/usr/bin/env bash
# AIS-44 Android half: Play Feature Delivery probe. Copies the "sherpa" size app to
# build/size_app/pfd, moves the sherpa-onnx + ONNX Runtime .so files out of the base
# module into an on-demand dynamic feature module ":diarization", builds the AAB and
# a --local-testing APK set with bundletool (build/tools/bundletool-all-1.17.2.jar).
# Needs android/size/measure_size.sh first. Adds com.google.android.play:feature-delivery
# 2.1.0 (spike-only, Google Maven).
set -euo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/../.."
R=build/size_app/pfd
PUB=${PUB_CACHE:-$(cygpath -u "$LOCALAPPDATA")/Pub/Cache}/hosted/pub.dev
if [ ! -d $R ]; then
  mkdir -p $R
  cp -r build/size_app/sherpa/lib build/size_app/sherpa/android build/size_app/sherpa/pubspec.yaml \
    build/size_app/sherpa/pubspec.lock build/size_app/sherpa/.metadata $R/
  rm -rf $R/android/.gradle $R/android/app/build $R/android/local.properties
fi
cp android/pfd/main_pfd.dart $R/lib/main.dart
cp android/pfd/MainActivity.kt $R/android/app/src/main/kotlin/com/vecvel/ais44size/MainActivity.kt
F=$R/android/diarization
mkdir -p $F/src/main
cp android/pfd/diarization/build.gradle.kts $F/
cp android/pfd/diarization/AndroidManifest.xml $F/src/main/
echo '<resources><string name="diarization_title">Speaker detection</string></resources>' \
  > $R/android/app/src/main/res/values/ais44_strings.xml  # module titles live in base
for a in arm64:arm64-v8a armeabi:armeabi-v7a x86_64:x86_64; do
  p=${a%%:*}; abi=${a##*:}
  mkdir -p $F/src/main/jniLibs/$abi
  cp $PUB/sherpa_onnx_android_$p-1.13.8/android/src/main/jniLibs/$abi/*.so $F/src/main/jniLibs/$abi/
done
S=$R/android/settings.gradle.kts
if ! grep -q diarization $S; then
  echo 'include(":diarization")' >> $S
  sed -i 's/id("com.android.application") version "\([0-9.]*\)" apply false/&\n    id("com.android.dynamic-feature") version "\1" apply false/' $S
fi
G=$R/android/app/build.gradle.kts
if ! grep -q dynamicFeatures $G; then
  sed -i 's/^android {/android {\n    dynamicFeatures += setOf(":diarization")\n    packaging { jniLibs { excludes += setOf("**\/libonnxruntime.so", "**\/libsherpa-onnx-c-api.so", "**\/libsherpa-onnx-cxx-api.so") } }/' $G
  printf '\ndependencies {\n    implementation("com.google.android.play:feature-delivery:2.1.0")\n}\n' >> $G
fi
sed -i 's/org.gradle.jvmargs=-Xmx8G/org.gradle.jvmargs=-Xmx3G/' $R/android/gradle.properties
sed -i 's/android:name="${applicationName}"/android:name="com.google.android.play.core.splitcompat.SplitCompatApplication"/' \
  $R/android/app/src/main/AndroidManifest.xml
(cd $R && flutter pub get >/dev/null && flutter build appbundle --release)
AAB=$R/build/app/outputs/bundle/release/app-release.aab
unzip -l $AAB | grep '\.so$'
BT="java -jar build/tools/bundletool-all-1.17.2.jar"
$BT build-apks --bundle=$AAB --output=build/size_app/pfd.apks --overwrite
$BT build-apks --bundle=$AAB --output=build/size_app/pfd-local.apks --local-testing --overwrite
echo "== all modules"; $BT get-size total --apks=build/size_app/pfd.apks --dimensions=ABI
echo "== base"; $BT get-size total --apks=build/size_app/pfd.apks --dimensions=ABI --modules=base
echo "== diarization"; $BT get-size total --apks=build/size_app/pfd.apks --dimensions=ABI --modules=diarization
