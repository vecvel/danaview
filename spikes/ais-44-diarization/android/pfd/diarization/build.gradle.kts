plugins {
    id("com.android.dynamic-feature")
}

android {
    namespace = "com.vecvel.ais44size.diarization"
    compileSdk = 36
    defaultConfig { minSdk = 24 }
}

dependencies {
    implementation(project(":app"))
}
