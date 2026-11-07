import java.io.FileInputStream
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------- release signing
// The release key comes from android/key.properties (local, never committed):
//   storeFile=/path/to/lumora-release.jks
//   storePassword=…
//   keyAlias=lumora
//   keyPassword=…
// or from environment variables (CI): ANDROID_KEYSTORE_PATH (a .jks file) or
// ANDROID_KEYSTORE_BASE64 (the .jks, base64), plus ANDROID_KEYSTORE_PASSWORD,
// ANDROID_KEY_ALIAS and ANDROID_KEY_PASSWORD. Guide: docs/src/ops/release.md.
// Without a release key, release builds fall back to the debug key so local
// `flutter run --release` keeps working; such APKs are for local testing only and
// LUMORA_REQUIRE_RELEASE_SIGNING=1 (set by CI on version tags) turns that into an error.
val keyProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) FileInputStream(f).use { load(it) }
}

fun signingValue(prop: String, env: String): String? =
    (keyProperties.getProperty(prop) ?: System.getenv(env))?.trim()?.takeIf { it.isNotEmpty() }

val releaseKeystore: File? = signingValue("storeFile", "ANDROID_KEYSTORE_PATH")?.let { rootProject.file(it) }
    ?: System.getenv("ANDROID_KEYSTORE_BASE64")?.trim()?.takeIf { it.isNotEmpty() }?.let { b64 ->
        layout.buildDirectory.file("signing/release.jks").get().asFile.apply {
            parentFile.mkdirs()
            writeBytes(Base64.getMimeDecoder().decode(b64))
        }
    }
val releaseStorePassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
val hasReleaseKey = releaseKeystore != null && releaseStorePassword != null && releaseKeyAlias != null && releaseKeyPassword != null

if (releaseKeystore != null && !releaseKeystore.isFile) {
    throw GradleException("Android release keystore not found: $releaseKeystore")
}
if (!hasReleaseKey && System.getenv("LUMORA_REQUIRE_RELEASE_SIGNING") == "1") {
    throw GradleException(
        "Release signing is required but incomplete: set key.properties or ANDROID_KEYSTORE_BASE64/" +
            "ANDROID_KEYSTORE_PATH, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD",
    )
}

android {
    namespace = "vn.lumora.lumora"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Never change: Android treats another ID as another app (no update path).
        applicationId = "vn.lumora.lumora"
        // 26: the media core links AAudio (cpal) and libc++_shared.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // CI passes --build-name/--build-number from the tag (docs/src/ops/release.md).
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // `flutter build apk --target-platform android-arm64` (one ABI): package only that
        // ABI's native libraries. src/main/jniLibs holds the Lumora core for every ABI and
        // Flutter's flag doesn't filter it — the "64-bit" APK carried all three (2x size).
        val abis = mapOf("android-arm64" to "arm64-v8a", "android-arm" to "armeabi-v7a", "android-x64" to "x86_64")
        val only = abis[project.findProperty("target-platform") as String?]
        logger.lifecycle("Lumora: target-platform=${project.findProperty("target-platform")} → native libs: ${only ?: "all ABIs"}")
        if (only != null) {
            // (Flutter resets ndk.abiFilters; exclusions at packaging time always apply)
            packaging { jniLibs { excludes += abis.values.filter { it != only }.map { "lib/$it/**" } } }
        }
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("Lumora: no Android release key, signing the release build with the DEBUG key (local testing only)")
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Video-call camera (CameraCapture.kt): ImageAnalysis hands YUV planes
    // straight to the Rust core over JNI; no preview surface, no Dart copies.
    val camerax = "1.4.2"
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")
    // ProcessCameraProvider.getInstance() returns a Guava ListenableFuture; the
    // interface-only artifact loses to Guava's empty placeholder in dependency
    // resolution, so take Guava itself (R8 strips what is unused in release).
    implementation("com.google.guava:guava:33.3.1-android")
}
