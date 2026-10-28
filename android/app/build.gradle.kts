plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
}

android {
    namespace = "com.agentroundtable.app"
    compileSdk = 37

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
        check(missing.isEmpty()) {
            "缺少端侧嵌入模型：${missing.joinToString()}。先运行 " +
                "scripts/fetch_embedding_model.sh。"
        }
    }
}

tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    dependsOn(verifyEmbeddingModel)
}
