// OWNER: ENG-09
//
// Root build of the editor engine example host. Besides the Flutter template it applies the
// native test harness (danaview_test_harness.gradle) to the plugin module `:danaview_editor_engine`, so
// the plugin's JVM tests (src/test) and instrumented tests (src/androidTest) run from here:
//
//   ./gradlew :danaview_editor_engine:testDebugUnitTest               (scripts/ci/editor/android_unit.sh)
//   ./gradlew :danaview_editor_engine:connectedDebugAndroidTest       (scripts/ci/editor/android_emulator.sh)

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}
subprojects {
    if (name == "danaview_editor_engine") {
        pluginManager.withPlugin("com.android.library") {
            apply(from = rootProject.file("danaview_test_harness.gradle"))
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
