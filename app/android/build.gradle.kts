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
// desktop_drop 0.8.0 (desktop-only plugin that still ships an android/ stub)
// uses the `kotlin {}` block without applying the Kotlin plugin, which breaks
// every Android build. Apply it for that project as soon as AGP is applied.
subprojects {
    if (project.name == "desktop_drop") {
        project.plugins.withId("com.android.library") {
            project.pluginManager.apply("org.jetbrains.kotlin.android")
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
