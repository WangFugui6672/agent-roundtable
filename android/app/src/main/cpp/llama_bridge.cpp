// JNI bridge for llama.cpp on Android.
//
// The state machine and chat loop below are adapted from llama.cpp's official
// examples/llama.android/lib/src/main/cpp/ai_chat.cpp (MIT License, commit b11966),
// rewritten against the public llama.h API without depending on llama-common.
// Source: https://github.com/ggml-org/llama.cpp
// Copyright (c) 2023-2026 The ggml authors. Licensed under the MIT License.

#include <jni.h>
#include <android/log.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <mutex>
#include <string>
#include <unistd.h>
#include <vector>

#include "llama.h"

namespace {

constexpr char kTag[] = "llama_bridge";
constexpr int kBatchSize = 512;
constexpr int kThreadMin = 2;
constexpr int kThreadMax = 4;
constexpr int kThreadHeadroom = 2;
constexpr int kContextHeadroom = 8;

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, kTag, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, kTag, __VA_ARGS__)

llama_model *g_model = nullptr;
llama_context *g_context = nullptr;
llama_sampler *g_sampler = nullptr;
const llama_vocab *g_vocab = nullptr;
llama_batch g_batch{};
int g_batch_capacity = 0;
int g_context_size = 0;
int g_position = 0;
int g_max_tokens = 0;
int g_generated_tokens = 0;
std::string g_pending_utf8;
std::mutex g_mutex;
std::atomic<bool> g_cancel{false};

void android_log_callback(ggml_log_level level, const char *text, void *) {
    if (text == nullptr) return;
    if (level >= GGML_LOG_LEVEL_ERROR) {
        __android_log_write(ANDROID_LOG_ERROR, kTag, text);
    } else if (level == GGML_LOG_LEVEL_WARN) {
        __android_log_write(ANDROID_LOG_WARN, kTag, text);
    } else {
        __android_log_write(ANDROID_LOG_DEBUG, kTag, text);
    }
}

std::string from_java(JNIEnv *env, jstring value) {
    if (value == nullptr) return {};
    const char *chars = env->GetStringUTFChars(value, nullptr);
    std::string result(chars == nullptr ? "" : chars);
    if (chars != nullptr) env->ReleaseStringUTFChars(value, chars);
    return result;
}

jstring to_java(JNIEnv *env, const std::string &value) {
    return env->NewStringUTF(value.c_str());
}

jstring error(JNIEnv *env, const std::string &message) {
    LOGE("%s", message.c_str());
    return to_java(env, message);
}

int thread_count() {
    const long cpus = sysconf(_SC_NPROCESSORS_ONLN);
    return std::max(kThreadMin, std::min(kThreadMax, static_cast<int>(cpus) - kThreadHeadroom));
}

bool ensure_batch(int n_tokens) {
    if (g_batch_capacity >= n_tokens && g_batch.token != nullptr) return true;
    if (g_batch.token != nullptr) llama_batch_free(g_batch);
    g_batch = llama_batch_init(std::max(n_tokens, kBatchSize), 0, 1);
    g_batch_capacity = std::max(n_tokens, kBatchSize);
    return g_batch.token != nullptr;
}

void reset_generation_state() {
    g_cancel = false;
    g_position = 0;
    g_max_tokens = 0;
    g_generated_tokens = 0;
    g_pending_utf8.clear();
}

void free_runtime() {
    if (g_sampler != nullptr) {
        llama_sampler_free(g_sampler);
        g_sampler = nullptr;
    }
    if (g_context != nullptr) {
        llama_free(g_context);
        g_context = nullptr;
    }
    if (g_model != nullptr) {
        llama_model_free(g_model);
        g_model = nullptr;
    }
    g_vocab = nullptr;
}

std::vector<llama_token> tokenize(const std::string &text, bool add_special, bool parse_special) {
    if (g_vocab == nullptr) return {};
    int n = llama_tokenize(
        g_vocab,
        text.data(),
        static_cast<int32_t>(text.size()),
        nullptr,
        0,
        add_special,
        parse_special);
    if (n < 0) n = -n;
    std::vector<llama_token> tokens(static_cast<size_t>(n));
    n = llama_tokenize(
        g_vocab,
        text.data(),
        static_cast<int32_t>(text.size()),
        tokens.data(),
        n,
        add_special,
        parse_special);
    if (n < 0) return {};
    tokens.resize(static_cast<size_t>(n));
    return tokens;
}

bool decode_tokens(const std::vector<llama_token> &tokens, bool want_logits) {
    for (size_t offset = 0; offset < tokens.size(); offset += kBatchSize) {
        const int chunk = static_cast<int>(std::min(tokens.size() - offset, static_cast<size_t>(kBatchSize)));
        if (!ensure_batch(chunk)) return false;
        g_batch.n_tokens = chunk;
        for (int i = 0; i < chunk; ++i) {
            const bool is_last = want_logits && offset + i + 1 == tokens.size();
            g_batch.token[i] = tokens[offset + i];
            g_batch.pos[i] = g_position + static_cast<int>(offset) + i;
            g_batch.n_seq_id[i] = 1;
            g_batch.seq_id[i][0] = 0;
            g_batch.logits[i] = is_last ? 1 : 0;
        }
        if (llama_decode(g_context, g_batch) != 0) {
            LOGE("llama_decode failed while processing %d prompt tokens", chunk);
            return false;
        }
        g_position += chunk;
    }
    return true;
}

bool is_valid_utf8(const std::string &text) {
    const auto *bytes = reinterpret_cast<const unsigned char *>(text.c_str());
    int remaining = 0;
    for (size_t i = 0; bytes[i] != 0; ++i) {
        const unsigned char byte = bytes[i];
        if (remaining == 0) {
            if ((byte & 0x80) == 0x00) {
                continue;
            } else if ((byte & 0xE0) == 0xC0) {
                remaining = 1;
            } else if ((byte & 0xF0) == 0xE0) {
                remaining = 2;
            } else if ((byte & 0xF8) == 0xF0) {
                remaining = 3;
            } else {
                return false;
            }
        } else {
            if ((byte & 0xC0) != 0x80) return false;
            --remaining;
        }
    }
    return remaining == 0;
}

std::string token_piece(llama_token token) {
    char buffer[256];
    const int n = llama_token_to_piece(g_vocab, token, buffer, sizeof(buffer), 0, false);
    if (n <= 0) return {};
    return std::string(buffer, static_cast<size_t>(n));
}

llama_sampler *build_sampler() {
    auto params = llama_sampler_chain_default_params();
    llama_sampler *chain = llama_sampler_chain_init(params);
    if (chain == nullptr) return nullptr;
    llama_sampler_chain_add(chain, llama_sampler_init_penalties(
        llama_vocab_n_tokens(g_vocab), 64, 1.1f, 0.0f, 0.0f));
    llama_sampler_chain_add(chain, llama_sampler_init_top_k(40));
    llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95f, 1));
    llama_sampler_chain_add(chain, llama_sampler_init_temp(0.7f));
    llama_sampler_chain_add(chain, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    return chain;
}

}  // namespace

extern "C" {

JNIEXPORT jstring JNICALL
Java_com_agentroundtable_app_local_LlamaBridge_init(JNIEnv *env, jobject) {
    std::lock_guard<std::mutex> lock(g_mutex);
    llama_log_set(android_log_callback, nullptr);
    llama_backend_init();
    LOGI("llama.cpp backend initialized");
    return nullptr;
}

JNIEXPORT jstring JNICALL
Java_com_agentroundtable_app_local_LlamaBridge_loadModel(
    JNIEnv *env, jobject, jstring j_path, jint context_size) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_context != nullptr) {
        return error(env, "已有模型处于加载状态。");
    }
    const std::string path = from_java(env, j_path);
    if (path.empty()) return error(env, "模型路径为空。");

    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = 0;
    model_params.load_mode = LLAMA_LOAD_MODE_MMAP;
    g_model = llama_model_load_from_file(path.c_str(), model_params);
    if (g_model == nullptr) {
        return error(env, "无法加载 GGUF 模型，请确认文件完整且架构受支持。");
    }
    g_vocab = llama_model_get_vocab(g_model);

    llama_context_params context_params = llama_context_default_params();
    context_params.n_ctx = static_cast<uint32_t>(context_size);
    context_params.n_batch = kBatchSize;
    context_params.n_ubatch = kBatchSize;
    context_params.n_threads = thread_count();
    context_params.n_threads_batch = context_params.n_threads;
    g_context = llama_init_from_model(g_model, context_params);
    if (g_context == nullptr) {
        free_runtime();
        return error(env, "无法创建推理上下文，设备内存可能不足。");
    }
    g_context_size = static_cast<int>(llama_n_ctx(g_context));
    g_sampler = build_sampler();
    if (g_sampler == nullptr) {
        free_runtime();
        return error(env, "无法初始化采样器。");
    }
    if (!ensure_batch(kBatchSize)) {
        free_runtime();
        return error(env, "无法分配推理批次。");
    }
    reset_generation_state();
    LOGI("model loaded, n_ctx=%d, threads=%d", g_context_size, context_params.n_threads);
    return nullptr;
}

JNIEXPORT jstring JNICALL
Java_com_agentroundtable_app_local_LlamaBridge_beginGeneration(
    JNIEnv *env, jobject, jstring j_prompt, jint max_tokens) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_context == nullptr || g_vocab == nullptr || g_sampler == nullptr) {
        return error(env, "模型尚未加载。");
    }
    const std::string prompt = from_java(env, j_prompt);
    if (prompt.empty()) return error(env, "prompt 为空。");

    reset_generation_state();
    llama_memory_clear(llama_get_memory(g_context), true);
    llama_sampler_reset(g_sampler);

    const std::vector<llama_token> tokens = tokenize(prompt, false, true);
    if (tokens.empty()) return error(env, "无法对 prompt 分词。");
    if (static_cast<int>(tokens.size()) + max_tokens + kContextHeadroom > g_context_size) {
        return error(env, "prompt 超出上下文窗口，请缩短输入或增大上下文。");
    }
    if (!decode_tokens(tokens, true)) {
        return error(env, "prompt 预填充失败。");
    }
    g_max_tokens = max_tokens;
    g_generated_tokens = 0;
    LOGI("prompt tokens=%zu, max_tokens=%d", tokens.size(), max_tokens);
    return nullptr;
}

JNIEXPORT jstring JNICALL
Java_com_agentroundtable_app_local_LlamaBridge_nextToken(JNIEnv *env, jobject) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_context == nullptr || g_sampler == nullptr) return nullptr;
    if (g_cancel.load() || g_generated_tokens >= g_max_tokens) return nullptr;

    const llama_token token = llama_sampler_sample(g_sampler, g_context, -1);
    if (llama_vocab_is_eog(g_vocab, token)) {
        return nullptr;
    }
    llama_sampler_accept(g_sampler, token);

    if (!ensure_batch(1)) return nullptr;
    g_batch.n_tokens = 1;
    g_batch.token[0] = token;
    g_batch.pos[0] = g_position;
    g_batch.n_seq_id[0] = 1;
    g_batch.seq_id[0][0] = 0;
    g_batch.logits[0] = 1;
    if (llama_decode(g_context, g_batch) != 0) {
        LOGE("llama_decode failed for generated token");
        return nullptr;
    }
    ++g_position;
    ++g_generated_tokens;

    g_pending_utf8 += token_piece(token);
    if (!is_valid_utf8(g_pending_utf8)) {
        return to_java(env, "");
    }
    std::string piece = g_pending_utf8;
    g_pending_utf8.clear();
    return to_java(env, piece);
}

JNIEXPORT void JNICALL
Java_com_agentroundtable_app_local_LlamaBridge_cancelGeneration(JNIEnv *, jobject) {
    g_cancel.store(true);
}

JNIEXPORT jint JNICALL
Java_com_agentroundtable_app_local_LlamaBridge_generatedTokenCount(JNIEnv *, jobject) {
    return g_generated_tokens;
}

JNIEXPORT jlong JNICALL
Java_com_agentroundtable_app_local_LlamaBridge_modelBytes(JNIEnv *, jobject) {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_model == nullptr ? 0 : static_cast<jlong>(llama_model_size(g_model));
}

JNIEXPORT jlong JNICALL
Java_com_agentroundtable_app_local_LlamaBridge_parameterCount(JNIEnv *, jobject) {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_model == nullptr ? 0 : static_cast<jlong>(llama_model_n_params(g_model));
}

JNIEXPORT jstring JNICALL
Java_com_agentroundtable_app_local_LlamaBridge_systemInfo(JNIEnv *env, jobject) {
    return to_java(env, llama_print_system_info());
}

JNIEXPORT void JNICALL
Java_com_agentroundtable_app_local_LlamaBridge_unload(JNIEnv *, jobject) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_cancel.store(true);
    reset_generation_state();
    if (g_batch.token != nullptr) {
        llama_batch_free(g_batch);
        g_batch = llama_batch{};
        g_batch_capacity = 0;
    }
    free_runtime();
}

JNIEXPORT void JNICALL
Java_com_agentroundtable_app_local_LlamaBridge_shutdown(JNIEnv *, jobject) {
    std::lock_guard<std::mutex> lock(g_mutex);
    free_runtime();
    llama_backend_free();
}

}  // extern "C"
