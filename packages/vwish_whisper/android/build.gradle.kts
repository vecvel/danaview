// OWNER: AI-04 (skeleton by AI-02; AI-06 added the JUnit dependency)
//
// Android library of the vwish_whisper FFI plugin (ai.md §4.3). externalNativeBuild compiles the C
// shim + vendored whisper.cpp/ggml through ../src/CMakeLists.txt, which includes src/cmake/android.cmake:
//   arm64-v8a  libvwish_whisper.so (armv8-a) + libvwish_whisper_v82.so (armv8.2-a+fp16+dotprod)
//   x86_64     libvwish_whisper.so
// c++_static, 16 KB page alignment, only vw_* exported (src/vw_exports.map), -O3, no OpenMP.
// No armeabi-v7a (owner default D-43(b)). scripts/ci/editor/check_native_libs.sh verifies an AAB/APK.

group = "com.vecvel.vwish.whisper"
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

android {
    namespace = "com.vecvel.vwish.whisper"

    compileSdk = 36

    // Flutter 3.44's flutter.ndkVersion (also the spike's). Must be installed; AGP never downloads it here.
    ndkVersion = "28.2.13676358"

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
    }

    defaultConfig {
        minSdk = 24

        externalNativeBuild {
            cmake {
                // D-43(b): 64-bit only. android.cmake refuses any other ABI.
                abiFilters += listOf("arm64-v8a", "x86_64")
                arguments += listOf(
                    "-DANDROID_STL=c++_static",
                    "-DVW_ANDROID=ON",
                    // 16 KB pages on NDK r27 too (default on r28); android.cmake also links with
                    // -z max-page-size=16384 explicitly.
                    "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON",
                    // Cap on parallel native compile jobs (whisper/ggml are CPU-heavy).
                    "-DVW_NATIVE_JOBS=8",
                )
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("../src/CMakeLists.txt")
            // The Android SDK's CMake 3.22.1 (with its Ninja) is sufficient (V-A8): ggml asks for 3.14...3.28.
            version = "3.22.1"
            // Keep AGP's CMake staging tree under build/ (the default .cxx/ next to this file is not
            // gitignored). Flutter relocates build/ for plugins to <app>/build/vwish_whisper.
            buildStagingDirectory = layout.buildDirectory.dir("cxx-staging").get().asFile
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // AI-06: JVM unit tests of the pure device helpers (thermal mapping, cpuinfo parsing, trim levels).
    testImplementation("junit:junit:4.13.2")
}
