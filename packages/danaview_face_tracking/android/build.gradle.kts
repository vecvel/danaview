// OWNER: VED-16A
//
// Placeholder (D-33) created by INT-101. VED-16A replaces this file: the Android build of
// danaview_face_tracking (face mesh, pose and segmentation trackers, video sampling). Until then it builds the empty plugin class only, with the toolchain of
// the 1.1 plugins (AGP 9.0.1, Kotlin 2.3.20, compileSdk 36, minSdk 24, Java 17).

group = "com.vecvel.danaview.face"
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
    namespace = "com.vecvel.danaview.face"

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
