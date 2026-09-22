plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.io.FileInputStream
import java.util.Properties

android {
    namespace = "com.taucity.stickerpants"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // Release signing from android/key.properties (gitignored, never
    // committed). Without it, release falls back to debug keys for local
    // `flutter run --release` only — store uploads always use release.
    val keystoreProps = Properties()
    val keystorePropsFile = rootProject.file("key.properties")
    if (keystorePropsFile.exists()) {
        keystoreProps.load(FileInputStream(keystorePropsFile))
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications: java.time & friends on
        // API < 26 run through the desugar ladder.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.taucity.stickerpants"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // No Chromebooks: the only ABIs worth shipping. Debug adds
        // x86_64 back below so emulator testing keeps working.
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    buildTypes {
        debug {
            // Emulators are x86_64; release stays phone-only.
            ndk {
                abiFilters += "x86_64"
            }
        }
        release {
            // Smaller downloads: R8 strips unused Java/Kotlin code and
            // resources (plugin entry points are pinned in
            // proguard-rules.pro; the Dart AOT lib is unaffected).
            // Debug builds keep everything so emulator testing works.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            if (keystorePropsFile.exists()) {
                signingConfigs {
                    create("release") {
                        storeFile = file(keystoreProps["storeFile"] as String)
                        storePassword = keystoreProps["storePassword"] as String
                        keyAlias = keystoreProps["keyAlias"] as String
                        keyPassword = keystoreProps["keyPassword"] as String
                    }
                }
                signingConfig = signingConfigs.getByName("release")
            } else {
                // Local dev only: debug keys so `flutter run --release` works.
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }

    dependencies {
        coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// AGP 9 hides the legacy android-DSL implementations (android.newDsl is
// false via the Flutter template), so new-DSL-only settings go through
// the public ApplicationExtension interface, which stays available.
configure<com.android.build.api.dsl.ApplicationExtension> {
    androidResources {
        // English-only app: drop every other locale's strings from the
        // support libraries instead of shipping them.
        localeFilters += "en"
    }
    packaging {
        jniLibs {
            // tflite_flutter bundles the GPU-delegate .so per ABI, but the
            // app only ever creates a CPU Interpreter (see
            // MulticlassBackend._load) — ~2.5MB/ABI of dead weight.
            excludes += "**/libtensorflowlite_gpu_jni.so"
        }
    }
}
