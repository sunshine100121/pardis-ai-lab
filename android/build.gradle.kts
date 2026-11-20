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
// Desktop-only plugins (desktop_drop) still ship an Android module compiled
// against an old SDK, which fails the AAR metadata check of their androidx
// dependencies. Raise any plugin below the app's level to it. Registered
// before evaluationDependsOn below so the hook exists when each plugin
// project is evaluated.
subprojects {
    afterEvaluate {
        extensions.findByType(com.android.build.api.dsl.LibraryExtension::class.java)?.let {
            if ((it.compileSdk ?: 0) < 36) it.compileSdk = 36
            // Only the separately installable Pocket diagnostic must carry
            // the Microsoft ORT 1.31.1 native library used by its Java API.
            // The existing signed PALA distribution is NOT changed.
            // Sherpa's JNI companion is retained; only its older copy of
            // the shared ORT runtime is omitted for this diagnostic build.
            if (System.getenv("PALA_POCKET_TEST_APK") == "true" &&
                project.name == "sherpa_onnx_android_arm64") {
                it.packaging.jniLibs.excludes.add("**/libonnxruntime.so")
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
