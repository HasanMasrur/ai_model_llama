plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Kotlin/JVM toolchain
kotlin {
    // তুমি JDK 21 ব্যবহার করছ, তাই 21-ই রাখলাম
    jvmToolchain(21)
}

android {
    namespace = "com.example.llm_model"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        // JDK 21 টার্গেট (তোমার মেশিনে 21 আছে)
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
    kotlinOptions { jvmTarget = "21" }

    defaultConfig {
        applicationId = "com.example.llm_model"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk { abiFilters += listOf("arm64-v8a") }

        // CMake arguments এখানেই (Kotlin DSL)
        externalNativeBuild {
            cmake {
                // llama.h যেখানে আছে: .../native/llama/include
                // ggml.h সাধারণত থাকে: .../native/llama/ggml/include
                arguments(
                    "-DLLAMA_HEADERS_DIR=/Users/hasanmasrur/Desktop/office/ai_model/llm_model/native/llama/include",
                    "-DGGML_HEADERS_DIR=/Users/hasanmasrur/Desktop/office/ai_model/llm_model/native/llama/ggml/include"
                )
                // চাইলে CPP ফ্ল্যাগ:
                // cppFlags += listOf("-std=c++17")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packaging { jniLibs { useLegacyPackaging = true } }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter { source = "../.." }
