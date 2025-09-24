plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.llm_model"

    // Flutter-managed compile SDK, min/target, version info
    compileSdk = flutter.compileSdkVersion

    // Keep NDK pinned (works with path_provider_android & others)
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.example.llm_model"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // We only ship arm64 .so
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    // <-- Added: CMake integration for your native/llm bridge -->
    // externalNativeBuild {
    //     cmake {
    //         // Point to your CMakeLists.txt (adjust path if it's different)
    //         path = file("src/main/cpp/CMakeLists.txt")
    //         version = "3.22.1"
    //     }
    // }
        externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
           // arguments("-DLLAMA_HEADERS_DIR=${rootDir}/native/llama.cpp")
            // dev warnings -> error এ কনভার্ট হওয়া ঠেকাতে:
          //  arguments("-Wno-dev")
            // (optional) স্পষ্টভাবে STL/Platform দিতে চাইলে:
            // arguments("-DANDROID_STL=c++_shared", "-DANDROID_PLATFORM=android-24")
        }
    }

    // <-- Added: Keep legacy jniLibs packaging so your prebuilt .so is picked up as-is -->
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // Use your own signingConfig for Play-ready builds
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
