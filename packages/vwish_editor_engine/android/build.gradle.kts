// OWNER: ENG-08 (order ENG-01 placeholder -> ENG-08 -> ENG-06 [INTEGRATION], then frozen; D-42)
//
// Android build of the editor engine plugin (ARCH §3.2, §4.4, BUILD_PLAN ENG-08).
//
// - minSdk 24 (the app's floor, ARCH §3.2); the editor itself gates on API 29 + GLES 3 + 2 GB at
//   runtime (core/Capabilities.kt, AND-02). AND-01 §6.3 proposes minSdk 29: ENG-06 decides.
// - Media3 1.11.1 is pinned (R1). Upgrading means rerunning the AND-01 spike tests.
// - lint.xml makes Media3's UnstableApi and ExperimentalApi opt-in-required errors, so every file that
//   touches them starts with `@file:OptIn(UnstableApi::class, ExperimentalApi::class)` using
//   androidx.annotation.OptIn (imported; lint ignores kotlin.OptIn for androidx markers, see lint.xml).
//   Negative check (the build must FAIL):
//     ./gradlew :vwish_editor_engine:lintDebug -PvwishLintNegativeFixture=true
//   It compiles src/test/kotlin/.../glue/lint/{MissingOptIn,WithOptIn}.kt.txt (without / with the opt-in) into
//   the main source set for that one invocation only (never shipped); every error must be in MissingOptIn.kt.
// - The build freezes at ENG-06, so every dependency the Android lane (AND-02..AND-17) needs is
//   declared here now (BUILD_PLAN §2). Later needs go through a lead-approved [INTEGRATION] ticket.
// - The JNI shim of AND-16 (externalNativeBuild, ndk abiFilters) is ENG-06's to add (AND-01 §6.3).
// - JVM and instrumented tests run through the example host
//   (packages/vwish_editor_engine/example/android, vwish_test_harness.gradle, ENG-09).

group = "com.vecvel.vwish.editor.engine"
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
    namespace = "com.vecvel.vwish.editor.engine"

    compileSdk = 36

    defaultConfig {
        minSdk = 24
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
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
        noCompress += listOf("mp4", "mov", "m4a", "mkv", "webm", "wav", "png", "jpg", "json", "vwproj", "cube", "vlut")
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
    }
}

// Lint negative fixture (see the header). Only active with -PvwishLintNegativeFixture=true.
if (project.hasProperty("vwishLintNegativeFixture")) {
    val fixtureRoot = layout.buildDirectory.dir("generated/vwishLintNegativeFixture/kotlin").get().asFile
    // MissingOptIn (negative, must be flagged) and WithOptIn (positive control, must stay clean).
    for (name in listOf("MissingOptIn", "WithOptIn")) {
        val source = file("src/test/kotlin/com/vecvel/vwish/editor/engine/glue/lint/$name.kt.txt")
        val target = File(fixtureRoot, "com/vecvel/vwish/editor/engine/lintfixture/$name.kt")
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
