plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
}

// llama.cpp 源码不入库。只有源码就位（或显式 -PwithLocalInference=true 触发拉取）时才编译原生库；
// 否则跳过原生构建，端侧推理在运行时报告「原生库不可用」，其余功能不受影响。
val llamaSourceDir = file("src/main/cpp/llama.cpp")
val withLocalInference = providers.gradleProperty("withLocalInference").orNull == "true"
val nativeReady = llamaSourceDir.resolve("CMakeLists.txt").exists()

android {
    namespace = "com.agentroundtable.app"
    compileSdk = 37
    ndkVersion = "29.0.14206865"

    defaultConfig {
        applicationId = "com.agentroundtable.app"
        minSdk = 26
        targetSdk = 37
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
        buildConfigField(
            "String",
            "BACKEND_BASE_URL",
            "\"${project.findProperty("backendBaseUrl") ?: "http://10.0.2.2:8000"}\"",
        )
        if (nativeReady) {
            externalNativeBuild {
                cmake {
                    arguments += listOf(
                        "-DCMAKE_BUILD_TYPE=Release",
                        "-DANDROID_STL=c++_shared",
                    )
                }
            }
        }
    }

    if (nativeReady) {
        externalNativeBuild {
            cmake {
                path = file("src/main/cpp/CMakeLists.txt")
                version = "3.31.6"
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    androidResources {
        // ONNX Runtime 直接读取 assets 中的模型字节；不压缩可避免二次解压开销。
        noCompress += "onnx"
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    implementation(project(":core"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.okhttp)
    implementation(libs.pdfbox.android)
    implementation(libs.onnxruntime.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.androidx.room.runtime)
    implementation(libs.androidx.room.ktx)
    ksp(libs.androidx.room.compiler)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)

    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.kotlinx.coroutines.test)
}

// 模型文件不入库；发布包必须带上模型，debug 包允许缺失并降级为无检索。
val embeddingModelDir =
    layout.projectDirectory.dir("src/main/assets/models/bge-small-zh-v1.5-int8")

val verifyEmbeddingModel by tasks.registering {
    group = "verification"
    description = "Ensures the on-device embedding model ships with release builds."
    doLast {
        val missing = listOf("model_int8.onnx", "vocab.txt")
            .filterNot { embeddingModelDir.file(it).asFile.isFile }
        if (missing.isEmpty()) return@doLast
        // 模型不入库：CI 与普通克隆没有这两个文件也必须能构建。
        // 只有显式要求随包分发时（-PrequireLocalAssets=true）才视为失败。
        val requireAssets = providers.gradleProperty("requireLocalAssets").orNull == "true"
        val message = "缺少端侧嵌入模型：${missing.joinToString()}。运行 scripts/fetch_embedding_model.sh 可补齐。"
        if (requireAssets) error(message) else logger.lifecycle("跳过端侧嵌入模型校验：$message")
    }
}

tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    dependsOn(verifyEmbeddingModel)
}

/**
 * llama.cpp 源码不入库。首次构建时由脚本拉取固定版本；已存在时脚本立即返回，
 * Gradle 也会根据 outputs 跳过任务。
 */
val fetchLlamaCpp = tasks.register<Exec>("fetchLlamaCpp") {
    workingDir = rootProject.projectDir
    commandLine("bash", "scripts/fetch_llama_cpp.sh")
    inputs.file(rootProject.file("scripts/fetch_llama_cpp.sh"))
    outputs.dir(file("src/main/cpp/llama.cpp"))
}

// 只有显式要求时才联网拉取源码：默认构建与 CI 不依赖任何大文件下载。
if (withLocalInference) {
    tasks.matching { it.name == "preBuild" }.configureEach {
        dependsOn(fetchLlamaCpp)
    }
    tasks.matching { it.name.startsWith("configureCMake") }.configureEach {
        dependsOn(fetchLlamaCpp)
    }
}