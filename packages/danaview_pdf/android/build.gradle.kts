// OWNER: HOM-25
//
// The Android build of danaview_pdf (ARCH v1.2 §4.3, §8): the PdfRenderer viewer and text
// (HOM-25), later the page tools (HOM-28A..HOM-31A), with the toolchain of the 1.1 plugins (AGP
// 9.0.1 with its built-in Kotlin 2.3.20, compileSdk 36, minSdk 24, Java 17).
//
// PdfBox-Android 2.0.27.0 (Apache-2.0; BouncyCastle 1.72 comes with it, MIT-style) is the accepted
// Android PDF engine (HOM-27, lead d9872042, D-98j). HOM-25 uses it read-only: document facts
// (title, encryption, permissions, page rotation) and the outline on every API level, and the text
// layer before API 35 (the platform's PdfRenderer text from 35). Writing with it starts with
// HOM-28A. It is pure Java: about 2.0 MB per ABI after R8 (HOM-27 report). No network library
// (rule 21). Licences: LICENSE-THIRD-PARTY.md.
//
// Tests (built through the app's Gradle project, android/ at the repo root; until the app depends on
// danaview_pdf, add it to the root pubspec locally for the run):
//   ./gradlew :danaview_pdf:testDebugUnitTest :danaview_pdf:lintDebug
//   ./gradlew :danaview_pdf:connectedDebugAndroidTest   (emulator, API 35, 29 and 28)
// The instrumented tests read the HOM-27 fixtures (spikes/android_pdf/fixtures/) as test assets.

group = "com.vecvel.danaview.pdf"
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
    namespace = "com.vecvel.danaview.pdf"

    compileSdk = 36

    defaultConfig {
        minSdk = 24
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // PdfBox-Android's own keep rules ship in its AAR; these add the -dontwarn lines HOM-27 needed.
        consumerProguardFiles("proguard-rules.pro")
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
            // The generated HOM-27 fixtures (text_200p, merge_partner_3p with /Rotate 90,
            // annotated_2p, image_only_2p), shared with the spike rather than copied.
            assets.srcDirs("../../../spikes/android_pdf/fixtures")
        }
    }

    testOptions {
        // JVM tests compile against android.jar stubs; the pure helpers need no Robolectric.
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
    // The accepted Android PDF engine (HOM-27); read-only use in HOM-25.
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")

    testImplementation("junit:junit:4.13.2")

    androidTestImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:core:1.6.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
