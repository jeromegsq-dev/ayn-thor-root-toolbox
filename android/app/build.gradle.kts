import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing credentials, kept out of the repository at the root of it —
// one level above this Gradle project, which is now `android/`. Without the file
// the project still builds; the release APK comes out signed with the debug key.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("../keystore.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.jeromegsq.thortoolbox"
    // 36 because video_player's Android half asks for it. targetSdk stays where
    // it was: compiling against newer APIs is not the same as opting in to the
    // runtime behaviour of a new release, and the tools here are tuned to 35.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.jeromegsq.thortoolbox"
        // The Flutter engine needs 24+; the tools themselves were written for 29.
        minSdk = 29
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    sourceSets {
        getByName("main") {
            // AutoDim's Installer reads bottom-autodim.sh out of the assets to
            // put its root service in place, so scripts/ has to be an asset
            // directory — and pointing at the folder keeps one copy of the
            // script rather than a second to keep in sync.
            assets.srcDir("../../scripts")
        }
    }

    androidResources {
        // ...but a source directory ships whole, and the rest of scripts/ is
        // documentation you push over adb yourself. The app never opens either
        // of these, and an APK asking for root should carry nothing it does not
        // use. Excluded at merge time, which is where AGP 9 allows an asset set
        // to be narrowed.
        ignoreAssetsPatterns += listOf("adb-wireless.sh", "media-vol-steps.sh")
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                // minSdk 29, so the JAR signature is dead weight; v3 allows key
                // rotation later.
                enableV1Signing = false
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
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
