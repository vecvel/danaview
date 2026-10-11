// OWNER: ENG-06 [INTEGRATION] (order ENG-01 placeholder -> ENG-08 -> ENG-06). FROZEN 2026-10-11 (D-42):
// later changes need a new lead-approved [INTEGRATION] ticket (BUILD_PLAN §2).
//
// Android build of the editor engine plugin (ARCH §3.2, §4.4, §13.3). Spike outcomes from AND-01
// (docs/editor/spikes/AND-01.md §6.3, R1 no-go -> AND-16 contingency preview engine) applied here:
//
// - minSdk stays 24, the app's floor (ARCH §3.2, D-29). AND-01 §6.3 proposed 29; ENG-06 keeps 24
//   because the app (minSdk = flutter.minSdkVersion = 24) cannot merge a library manifest with a
//   higher minSdk, and the player must keep working on API 24-28. The editor gates on API 29 +
//   GLES 3 + 2 GB at runtime (core/Capabilities.kt, AND-02); code that needs API 29+ is annotated
//   @RequiresApi(29) and lint's NewApi check (abortOnError) enforces it.
// - Media3 1.11.1 is pinned (R1): common, exoplayer (AND-16 slot decks), effect, transformer
//   (export, GO in AND-01), muxer, inspector (MediaExtractorCompat rule-frame PTS, V-N16) and
//   inspector-frame (FrameExtractor EXACT, AND-17). Upgrading means rerunning the AND-01 spike tests
//   (each R1 reproduction turns red with "rerun AND-01" once Media3 fixes it).
// - lint.xml makes Media3's UnstableApi and ExperimentalApi opt-in-required errors, so every file that
//   touches them starts with `@file:OptIn(UnstableApi::class, ExperimentalApi::class)` using
//   androidx.annotation.OptIn (imported; lint ignores kotlin.OptIn for androidx markers, see lint.xml).
//   Negative check (the build must FAIL):
//     ./gradlew :danaview_editor_engine:lintDebug -PdanaviewLintNegativeFixture=true
//   It compiles src/test/kotlin/.../glue/lint/{MissingOptIn,WithOptIn}.kt.txt (without / with the opt-in) into
//   the main source set for that one invocation only (never shipped); every error must be in MissingOptIn.kt.
//   Kotlin's own RequiresOptIn markers are opted into module-wide (kotlin.RequiresOptIn, AND-01 §6.3).
// - AND-16 JNI shim (AND-01 §6.3, §7): HardwareBuffer -> EGLImage -> OES texture import for the
//   slot decks' ImageReader frames (API 29 has no SDK HardwareBuffer -> EGLClientBuffer call). It is
//   built with the Android SDK's CMake 3.22.1 from src/main/cpp/CMakeLists.txt (AND-16's, ≈ 60 lines
//   of C++; links EGL, GLESv2, android, nativewindow, log) for every ABI the app ships
//   (arm64-v8a, armeabi-v7a, x86_64: the editor itself runs on armeabi-v7a; only Auto captions
//   don't, D-43(b)). The native build is declared here and switches on when AND-16 adds
//   src/main/cpp/CMakeLists.txt, so the frozen file needs no further edit.
// - Every dependency the Android lane (AND-02..AND-17) needs is declared here now (BUILD_PLAN §2).
// - JVM and instrumented tests run through the example host
//   (packages/danaview_editor_engine/example/android, danaview_test_harness.gradle, ENG-09).

group = "com.vecvel.danaview.editor.engine"
version = "1.1.0"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

/** Media3, pinned (ARCH §3.2, R1). */
val media3Version = "1.11.1"

android {
    namespace = "com.vecvel.danaview.editor.engine"

    compileSdk = 36

    // Flutter 3.44's flutter.ndkVersion (also danaview_whisper's and the AND-01 spike's). Used only once
    // the AND-16 JNI shim exists; must be installed, AGP never downloads it here.
    ndkVersion = "28.2.13676358"

    defaultConfig {
        minSdk = 24
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    // AND-16 JNI shim (see the header). Declared now, active once src/main/cpp/CMakeLists.txt exists.
    val jniShim = file("src/main/cpp/CMakeLists.txt")
    if (jniShim.isFile) {
        defaultConfig {
            externalNativeBuild {
                cmake {
                    abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
                    arguments += listOf(
                        "-DANDROID_STL=c++_static",
                        // The shim uses API 26+/29 NDK symbols (AHardwareBuffer_fromHardwareBuffer,
                        // eglGetNativeClientBufferANDROID, libnativewindow), so it is compiled for the
                        // editor gate, not the library's minSdk 24. AND-16 calls System.loadLibrary
                        // only behind the API 29 editor gate.
                        "-DANDROID_PLATFORM=android-29",
                        // 16 KB pages (default on NDK r28; explicit for r27 hosts).
                        "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON",
                    )
                }
            }
        }
        externalNativeBuild {
            cmake {
                path = jniShim
                // The Android SDK's CMake 3.22.1 (with its Ninja), as AND-01 and danaview_whisper (V-A8).
                version = "3.22.1"
                // Keep AGP's CMake staging tree under build/ (the default .cxx/ is not gitignored).
                buildStagingDirectory = layout.buildDirectory.dir("cxx-staging").get().asFile
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
        getByName("androidTest") {
            java.srcDirs("src/androidTest/kotlin")
        }
    }

    // Media fixtures packed into the androidTest APK (ENG-09 harness) stay uncompressed so tests can
    // open them with AssetFileDescriptor / MediaExtractor.
    androidResources {
        noCompress += listOf("mp4", "mov", "m4a", "mkv", "webm", "wav", "png", "jpg", "json", "dnproj", "cube", "vlut")
    }

    testOptions {
        // JVM tests compile against android.jar stubs; return defaults (Log, Build fields) instead
        // of throwing "Method ... not mocked". Pure-Kotlin logic stays testable without Robolectric.
        unitTests.isReturnDefaultValues = true
    }

    lint {
        lintConfig = file("lint.xml")
        abortOnError = true
        checkDependencies = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        // Kotlin-level opt-in markers (AND-01 §6.3). Media3's androidx markers are NOT covered by
        // this: they stay file-level androidx.annotation.OptIn, enforced by lint.xml.
        optIn.add("kotlin.RequiresOptIn")
    }
}

// Lint negative fixture (see the header). Only active with -PdanaviewLintNegativeFixture=true.
if (project.hasProperty("danaviewLintNegativeFixture")) {
    val fixtureRoot = layout.buildDirectory.dir("generated/danaviewLintNegativeFixture/kotlin").get().asFile
    // MissingOptIn (negative, must be flagged) and WithOptIn (positive control, must stay clean).
    for (name in listOf("MissingOptIn", "WithOptIn")) {
        val source = file("src/test/kotlin/com/vecvel/danaview/editor/engine/glue/lint/$name.kt.txt")
        val target = File(fixtureRoot, "com/vecvel/danaview/editor/engine/lintfixture/$name.kt")
        target.parentFile.mkdirs()
        source.copyTo(target, overwrite = true)
    }
    android.sourceSets.getByName("main").java.srcDir(fixtureRoot)
    // The copy lives under build/, which lint treats as generated sources and skips by default.
    android.lint.checkGeneratedSources = true
}

dependencies {
    // Media3 (ARCH §3.2, §13.3, §14.3, §15; AND-01 §6.3).
    implementation("androidx.media3:media3-common:$media3Version")
    implementation("androidx.media3:media3-exoplayer:$media3Version") // AND-16 slot players, AND-10
    implementation("androidx.media3:media3-effect:$media3Version") // AND-09 GL effects
    implementation("androidx.media3:media3-transformer:$media3Version") // AND-05/07/11
    implementation("androidx.media3:media3-muxer:$media3Version") // AND-07 reverse audio, AND-11
    implementation("androidx.media3:media3-inspector:$media3Version") // MediaExtractorCompat, MetadataRetriever (AND-02/04/07)
    implementation("androidx.media3:media3-inspector-frame:$media3Version") // FrameExtractor (AND-03/06/17)

    // V-N14: checked against AGP 9.0.1 + Kotlin 2.3.20 + compileSdk 36 (ENG-08 commit body).
    implementation("androidx.concurrent:concurrent-futures:1.2.0") // CallbackToFutureAdapter (Media3 ListenableFuture glue)
    implementation("androidx.activity:activity:1.10.1") // PickVisualMedia / OpenMultipleDocuments contracts (AND-14)
    implementation("androidx.core:core:1.13.1") // FileProvider, NotificationCompat, ServiceCompat, ContextCompat (AND-12/13/14)

    // JVM unit tests (src/test). org.json replaces the android.jar stubs (AND-08 plan decoding).
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")

    // Instrumented tests (src/androidTest).
    androidTestImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:core:1.6.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1") // GrantPermissionRule (AND-13, AND-14)
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0") // AND-12 swipe-from-recents, AND-14 picker
}
