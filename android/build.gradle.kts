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

// Some plugins (e.g. flutter_secure_storage 11) declare `compileSdk = 37`.
// API 37 ships under the new minor-versioned scheme and installs with the hash
// "android-37.0"; AGP 8.11.1 predates minor-SDK support and looks for a plain
// "android-37", so the build fails with "Failed to find target with hash string
// 'android-37'". Pin any such subproject back to 36 (their sources don't use
// API-37 symbols). Remove this once AGP is upgraded to 8.13+.
subprojects {
    if (project.name == "app") return@subprojects
    afterEvaluate {
        val androidExt = project.extensions.findByName("android") ?: return@afterEvaluate
        val current = androidExt.withGroovyBuilder { getProperty("compileSdkVersion") } as? String
            ?: return@afterEvaluate
        val level = current.removePrefix("android-")
        val major = level.substringBefore('.').toIntOrNull() ?: return@afterEvaluate
        if (major > 36 || level.contains('.')) {
            logger.lifecycle("Pinning ${project.name} compileSdk $current -> 36 (AGP 8.11 cannot resolve minor-versioned SDKs)")
            androidExt.withGroovyBuilder { "compileSdkVersion"(36) }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
