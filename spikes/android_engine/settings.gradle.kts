// AND-01 throwaway spike host (not shipped, not part of any package). See README.md.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    // Same versions as the app (android/settings.gradle.kts) and the engine plugin.
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

rootProject.name = "danaview_android_engine_spike"
include(":app")
