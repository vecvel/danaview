// OWNER: HOM-02A
//
// Placeholder (D-33) created by INT-101. HOM-02A replaces this file: the Android build of
// danaview_library_native (photo library, pickers, save out, share, open in, Quick Look, thumbnails, inbox). Until then it builds the empty plugin class only, with the toolchain of
// the 1.1 plugins (AGP 9.0.1, Kotlin 2.3.20, compileSdk 36, minSdk 24, Java 17).

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
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}
