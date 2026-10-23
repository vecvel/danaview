// VED-33A spike host app. Throwaway: one product flavour per candidate runtime so each AAB measures
// that runtime alone, plus `all` (every runtime in one APK) for the on-device latency and parity
// runs. Models are NOT bundled (ARCH V2-14: the Beauty pack downloads them); tool/run_bench.sh pushes
// them to the app's external files dir for the run and deletes them after.

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val mediapipeVersion = "0.10.35"
val mediapipeLatest = "1.1.1"
val litertVersion = "2.3.0"
val ortVersion = "1.31.0"

android {
    namespace = "com.vecvel.danaview.spike.face"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.vecvel.danaview.spike.face"
        minSdk = 24 // the app's floor (flutter.minSdkVersion)
        targetSdk = 36
        versionCode = 1
        versionName = "0.1-spike"
        // The ABIs the Flutter app ships.
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }

    flavorDimensions += "runtime"
    productFlavors {
        create("none") { dimension = "runtime" }      // harness only: the size baseline
        create("mp") { dimension = "runtime" }        // MediaPipe Tasks Vision 0.10.35
        create("mp11") { dimension = "runtime" }      // MediaPipe Tasks Vision 1.1.1 (newest)
        create("litert") { dimension = "runtime" }    // LiteRT Interpreter, same .tflite files
        create("ort") { dimension = "runtime" }       // ONNX Runtime, converted .onnx files
        create("all") { dimension = "runtime" }       // mp + litert + ort for the device runs
    }

    sourceSets {
        getByName("main") { java.srcDirs("src/main/kotlin") }
        getByName("none") { java.srcDirs("src/none/kotlin") }
        getByName("mp") { java.srcDirs("src/impl_mp/kotlin", "src/mp/kotlin") }
        getByName("mp11") { java.srcDirs("src/impl_mp/kotlin", "src/mp/kotlin") }
        getByName("litert") { java.srcDirs("src/impl_litert/kotlin", "src/litert/kotlin") }
        getByName("ort") { java.srcDirs("src/impl_ort/kotlin", "src/ort/kotlin") }
        getByName("all") {
            java.srcDirs("src/impl_mp/kotlin", "src/impl_litert/kotlin", "src/impl_ort/kotlin", "src/all/kotlin")
        }
    }

    signingConfigs {
        getByName("debug")
    }

    buildTypes {
        getByName("release") {
            isMinifyEnabled = true
            isShrinkResources = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    packaging {
        // Store native libraries uncompressed and page-aligned, as AGP does for the app (minSdk >= 23).
        jniLibs.useLegacyPackaging = false
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    "mpImplementation"("com.google.mediapipe:tasks-vision:$mediapipeVersion")
    "mp11Implementation"("com.google.mediapipe:tasks-vision:$mediapipeLatest")
    // LiteRT 2.x drags in Play AI delivery (asset-delivery, WorkManager, Room, play-services) for its
    // optional model-download path; the Interpreter does not need it and its WorkManager initializer
    // crashes under R8 here. Excluded, as the product would.
    "litertImplementation"("com.google.ai.edge.litert:litert:$litertVersion") { exclude(group = "com.google.android.play") }
    "ortImplementation"("com.microsoft.onnxruntime:onnxruntime-android:$ortVersion")
    "allImplementation"("com.google.mediapipe:tasks-vision:$mediapipeVersion")
    "allImplementation"("com.google.ai.edge.litert:litert:$litertVersion") { exclude(group = "com.google.android.play") }
    "allImplementation"("com.microsoft.onnxruntime:onnxruntime-android:$ortVersion")
}
