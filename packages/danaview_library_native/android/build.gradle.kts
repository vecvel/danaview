// OWNER: HOM-02A
//
// The Android build of danaview_library_native (ARCH v1.2 §8): MediaStore photo library (HOM-02A),
// thumbnailers (HOM-04A), pickers (HOM-20A), save out / share / open in (HOM-22A) and incoming
// intents (HOM-21A), with the toolchain of the 1.1 plugins (AGP 9.0.1 with its built-in Kotlin
// 2.3.20, compileSdk 36, minSdk 24, Java 17). Dependencies are the owner-approved androidx group
// (2026-10-22: activity, exifinterface, core, the androidx.test libraries) at the versions the
// editor engine already resolves, so nothing new is downloaded. No network library (rule 21).
//
// Tests (built through the app's Gradle project, android/ at the repo root):
//   ./gradlew :danaview_library_native:testDebugUnitTest :danaview_library_native:lintDebug
//   ./gradlew :danaview_library_native:connectedDebugAndroidTest   (emulator, API 35 and 29)

group = "com.vecvel.danaview.library"
version = "1.2.0"

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

android {
    namespace = "com.vecvel.danaview.library"

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

    testOptions {
        // JVM tests compile against android.jar stubs; return defaults instead of throwing
        // "Method ... not mocked". The pure helpers need no Robolectric.
        unitTests.isReturnDefaultValues = true
    }

    lint {
        abortOnError = true
        checkDependencies = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // EXIF basics from a content stream (assetDetail). androidx.core (FileProvider, HOM-22A) and
    // androidx.activity (PickVisualMedia, HOM-20A) come with their tickets.
    implementation("androidx.exifinterface:exifinterface:1.3.6")

    testImplementation("junit:junit:4.13.2")

    androidTestImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:core:1.6.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
