import java.io.FileInputStream
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing comes from android/key.properties (git-ignored), which points at app/release.jks.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) FileInputStream(file).use { load(it) }
}

// EXTENDED: INT-104/HOM-21A, Windows lane. The 1.2 flags are Dart --dart-define values; the Flutter
// tool hands them to Gradle as the `dart-defines` project property, a comma-separated list of
// base64-encoded "KEY=value" entries. A flag is on only for the exact value "true", as in Dart's
// bool.fromEnvironment; anything else, a missing define or an undecodable entry is off.
fun dartDefineFlag(key: String): Boolean {
    val raw = project.findProperty("dart-defines") as String? ?: return false
    return raw.split(',').filter { it.isNotBlank() }.any { entry ->
        val decoded = runCatching { String(Base64.getDecoder().decode(entry.trim()), Charsets.UTF_8) }.getOrNull()
        decoded == "$key=true"
    }
}

// DANAVIEW_FILES_HOME (Pillar 1). Off by default: the HOM-21A document/photo/text share filters
// (the IncomingDocumentsAlias in AndroidManifest.xml) are then disabled, as in 1.1.
val danaviewFilesHome = dartDefineFlag("DANAVIEW_FILES_HOME")

android {
    namespace = "com.vecvel.danaview"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.vecvel.danaview"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        manifestPlaceholders["danaviewFilesHome"] = danaviewFilesHome.toString()
        buildConfigField("boolean", "DANAVIEW_FILES_HOME", danaviewFilesHome.toString())
    }

    buildFeatures {
        buildConfig = true
    }

    signingConfigs {
        if (keystoreProperties.containsKey("storeFile")) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Without key.properties (e.g. a fresh clone) release builds fall back to the debug key.
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Instrumented tests (src/androidTest): FocusHighlightTest (FIX-QA02-POLISH-1). Versions match
    // what a plugin already puts on the app's runtime classpath (Gradle consistent resolution).
    androidTestImplementation("junit:junit:4.12")
    androidTestImplementation("androidx.test:runner:1.3.0")
}
