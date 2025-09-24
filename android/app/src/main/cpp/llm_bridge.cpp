// llm_bridge.cpp
// Minimal JNI + llama.cpp bridge for Android
// - Clean structure, safe token-to-piece, simple JSON param parsing,
// - Thread-safe (single global model/context guarded by mutex).

#include <jni.h>
#include <android/log.h>

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

// llama.cpp headers (include path must point to your submodule)
#include "llama.h"

// ---------- logging ----------
#ifndef LLOG_TAG
#define LLOG_TAG "LLM_BRIDGE"
#endif

#define LLOGI(...) __android_log_print(ANDROID_LOG_INFO,  LLOG_TAG, __VA_ARGS__)
#define LLOGW(...) __android_log_print(ANDROID_LOG_WARN,  LLOG_TAG, __VA_ARGS__)
#define LLOGE(...) __android_log_print(ANDROID_LOG_ERROR, LLOG_TAG, __VA_ARGS__)

// ---------- export visibility (Android/clang) ----------
#if defined(__GNUC__)
  #define LLM_EXPORT __attribute__((visibility("default")))
#else
  #define LLM_EXPORT
#endif

// ---------- globals ----------
static std::mutex        g_mutex;
static llama_model*      g_model = nullptr;
static llama_context*    g_ctx   = nullptr;

// ---------- tiny JSON helpers (very naive) ----------
static double jgetd(const char* json, const char* key, double defv) {
    if (!json || !key) return defv;
    // looks for:  "key": <number>
    std::string pat = std::string("\"") + key + "\"";
    const char* p = strstr(json, pat.c_str());
    if (!p) return defv;
    p = strchr(p, ':');
    if (!p) return defv;
    return atof(p + 1);
}

static int jgeti(const char* json, const char* key, int defi) {
    return static_cast<int>(jgetd(json, key, static_cast<double>(defi)));
}

// ---------- lifecycle ----------
extern "C" LLM_EXPORT
int llm_init(const char* modelPath, int n_ctx, int n_gpu_layers, int n_threads, int seed) {
    std::lock_guard<std::mutex> lock(g_mutex);

    if (g_ctx) {
        LLOGW("llm_init: context already initialized");
        return 0;
    }
    if (!modelPath || !*modelPath) {
        LLOGE("llm_init: invalid modelPath");
        return -3;
    }

    llama_backend_init();

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = n_gpu_layers;
    mparams.use_mmap     = true;
    mparams.use_mlock    = false;

    g_model = llama_load_model_from_file(modelPath, mparams);
    if (!g_model) {
        LLOGE("llm_init: failed to load model: %s", modelPath);
        return -1;
    }

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx     = (n_ctx > 0) ? n_ctx : 2048;
    cparams.n_batch   = 256;
    cparams.seed      = seed;
    cparams.n_threads = (n_threads > 0) ? n_threads : 4;

    g_ctx = llama_new_context_with_model(g_model, cparams);
    if (!g_ctx) {
        LLOGE("llm_init: failed to create context");
        llama_free_model(g_model);
        g_model = nullptr;
        return -2;
    }

    LLOGI("llm_init: success (ctx=%d, gpu_layers=%d, threads=%d)", cparams.n_ctx, n_gpu_layers, cparams.n_threads);
    return 0;
}

extern "C" LLM_EXPORT
int llm_infer(const char* prompt, const char* paramsJson, char* outBuf, int outBufSize) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_ctx) {
        LLOGE("llm_infer: context not initialized");
        return -10;
    }
    if (!outBuf || outBufSize <= 1) {
        LLOGE("llm_infer: invalid output buffer");
        return -30;
    }

    // sampling params (defaults)
    const float temperature    = paramsJson ? (float)jgetd(paramsJson, "temperature",    0.4) : 0.4f;
    const float top_p          = paramsJson ? (float)jgetd(paramsJson, "top_p",          0.9) : 0.9f;
    const int   top_k          = paramsJson ?        jgeti(paramsJson, "top_k",            40) : 40;
    const float repeat_penalty = paramsJson ? (float)jgetd(paramsJson, "repeat_penalty", 1.1) : 1.1f;
    const int   max_tokens     = paramsJson ?        jgeti(paramsJson, "max_tokens",     128) : 128;

    llama_sampler* smpl = llama_sampler_chain_init(
        llama_sampler_init_repetition_penalty(repeat_penalty, /* last_n */ 64, /* penalty_type */ 0, /* freq_penalty */ -1),
        llama_sampler_init_top_k(top_k),
        llama_sampler_init_top_p(top_p, /* min_keep */ 1),
        llama_sampler_init_temp(temperature),
        llama_sampler_init_dist(nullptr) // terminator
    );

    std::string p = prompt ? prompt : "";

    // tokenize (add_bos = true, parse_special = true)
    std::vector<llama_token> tokens = llama_tokenize(g_ctx, p, /* add_special */ true, /* parse_special */ true);

    // evaluate prompt
    if (llama_decode(g_ctx, llama_batch_get_one(tokens.data(), (int)tokens.size())) != 0) {
        LLOGE("llama_decode(prompt) failed");
        llama_sampler_free(smpl);
        return -20;
    }

    std::string result;
    result.reserve(2048);

    for (int i = 0; i < max_tokens; ++i) {
        llama_token tok = llama_sampler_sample(smpl, g_ctx, /* idx */ -1);
        llama_sampler_accept(smpl, tok);

        if (tok == llama_token_eos(g_ctx) || tok == -1) break;

        // safe token -> piece (API expects buffer out)
        char piece[512];
        int  plen = llama_token_to_piece(g_ctx, tok, piece, (int)sizeof(piece));
        if (plen > 0) result.append(piece, (size_t)plen);

        if ((int)result.size() >= outBufSize - 1) break;

        // feed the sampled token back
        llama_token tlist[1] = { tok };
        if (llama_decode(g_ctx, llama_batch_get_one(tlist, 1)) != 0) {
            LLOGW("llama_decode(step) failed, stopping early");
            break;
        }
    }

    // write to output (UTF-8)
    const int n = std::min((int)result.size(), outBufSize - 1);
    memcpy(outBuf, result.data(), (size_t)n);
    outBuf[n] = '\0';

    llama_sampler_free(smpl);
    return 0;
}

extern "C" LLM_EXPORT
void llm_dispose(void) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_ctx)   { llama_free(g_ctx);        g_ctx   = nullptr; }
    if (g_model) { llama_free_model(g_model); g_model = nullptr; }
    llama_backend_free();
    LLOGI("llm_dispose: freed");
}

// ---------- simple JNI probe ----------
extern "C"
JNIEXPORT jstring JNICALL
Java_com_example_llm_1model_NativeBridge_isAlive(JNIEnv* env, jclass) {
    return env->NewStringUTF("llama JNI OK");
}
