// llm_bridge.cpp — Android JNI + FFI bridge for newer llama.cpp (vocab-based API)
#include <jni.h>
#include <android/log.h>

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>
#include <algorithm> // std::min

#include "llama.h"

// ---------- logging ----------
#ifndef LLOG_TAG
#define LLOG_TAG "LLM_BRIDGE"
#endif
#define LLOGI(...) __android_log_print(ANDROID_LOG_INFO,  LLOG_TAG, __VA_ARGS__)
#define LLOGW(...) __android_log_print(ANDROID_LOG_WARN,  LLOG_TAG, __VA_ARGS__)
#define LLOGE(...) __android_log_print(ANDROID_LOG_ERROR, LLOG_TAG, __VA_ARGS__)

// ---------- export visibility ----------
#if defined(__GNUC__)
  // keep symbol emitted and globally visible (avoid dead strip)
  #define LLM_EXPORT_ATTR __attribute__((visibility("default"))) __attribute__((used))
#else
  #define LLM_EXPORT_ATTR
#endif
#if defined(__cplusplus)
  #define LLM_EXTERN_C extern "C"
#else
  #define LLM_EXTERN_C
#endif

// ---------- globals ----------
static std::mutex     g_mutex;
static llama_model*   g_model   = nullptr;
static llama_context* g_ctx     = nullptr;
static int            g_threads = 4;

// ---------- tiny JSON helpers ----------
static double jgetd(const char* json, const char* key, double defv) {
    if (!json || !key) return defv;
    std::string pat = std::string("\"") + key + "\"";
    const char* p = strstr(json, pat.c_str());
    if (!p) return defv;
    p = strchr(p, ':');
    if (!p) return defv;
    return atof(p + 1);
}
static int jgeti(const char* json, const char* key, int defi) {
    return (int) jgetd(json, key, (double)defi);
}

// ---------- helpers for vocab-based API ----------
static inline const llama_vocab* get_vocab() {
    return llama_model_get_vocab(g_model);
}

static inline std::vector<llama_token> tok_prompt(const std::string& s, bool add_special, bool parse_special) {
    const llama_vocab* vocab = get_vocab();
    const char*  text = s.c_str();
    const int32_t len = (int32_t)s.size();

    int32_t need = llama_tokenize(vocab, text, len, nullptr, 0, add_special, parse_special);
    if (need < 0) need = -need;

    std::vector<llama_token> out;
    if (need <= 0) return out;
    out.resize(need);

    int32_t wrote = llama_tokenize(vocab, text, len, out.data(), need, add_special, parse_special);
    if (wrote < 0) wrote = -wrote;
    if (wrote < need) out.resize(wrote);
    return out;
}

static inline llama_token eos_token() {
    return llama_vocab_eos(get_vocab());
}
static inline int vocab_size() {
    return (int) llama_vocab_n_tokens(get_vocab());
}
static inline void append_piece(llama_token tok, std::string& out) {
    char buf[512];
    // lstrip=0, special=false
    int n = llama_token_to_piece(get_vocab(), tok, buf, (int)sizeof(buf), 0, false);
    if (n > 0) out.append(buf, (size_t)n);
}

static bool decode_tokens(const llama_token* data, int n, int& n_past) {
    llama_batch batch = llama_batch_get_one((llama_token*)data, n);
    if (llama_decode(g_ctx, batch) != 0) return false;
    n_past += n;
    return true;
}

// ---------- API (C symbols) ----------
LLM_EXTERN_C LLM_EXPORT_ATTR
int llm_init(const char* modelPath, int n_ctx, int n_gpu_layers, int n_threads, int /*seed*/) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_ctx) { LLOGW("llm_init: already initialized"); return 0; }
    if (!modelPath || !*modelPath) { LLOGE("llm_init: invalid modelPath"); return -3; }

    llama_backend_init();

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = n_gpu_layers;
    mparams.use_mmap     = true;
    mparams.use_mlock    = false;

    g_model = llama_model_load_from_file(modelPath, mparams);
    if (!g_model) {
        LLOGE("llm_init: failed to load model: %s", modelPath);
        return -1;
    }

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx     = (n_ctx > 0) ? n_ctx : 2048;
    cparams.n_batch   = 256;
    cparams.n_threads = (n_threads > 0) ? n_threads : 4;
    g_threads         = cparams.n_threads;

    g_ctx = llama_init_from_model(g_model, cparams);
    if (!g_ctx) {
        LLOGE("llm_init: failed to create context");
        llama_model_free(g_model); g_model = nullptr;
        return -2;
    }

    LLOGI("llm_init: ok (ctx=%d, gpu_layers=%d, threads=%d)", cparams.n_ctx, n_gpu_layers, g_threads);
    return 0;
}

LLM_EXTERN_C LLM_EXPORT_ATTR
int llm_infer(const char* prompt, const char* paramsJson, char* outBuf, int outBufSize) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_ctx) { LLOGE("llm_infer: ctx not init"); return -10; }
    if (!outBuf || outBufSize <= 1) { LLOGE("llm_infer: bad outBuf"); return -30; }

    const int   max_tokens = paramsJson ? jgeti(paramsJson, "max_tokens", 128) : 128;
    std::string p = prompt ? prompt : "";

    std::vector<llama_token> toks = tok_prompt(p, /*add_special*/true, /*parse_special*/true);
    int n_past = 0;
    if (!toks.empty()) {
        if (!decode_tokens(toks.data(), (int)toks.size(), n_past)) {
            LLOGE("llama: decode(prompt) failed");
            return -20;
        }
    }

    std::string result;
    result.reserve(4096);

    for (int i = 0; i < max_tokens; ++i) {
        const float* logits = llama_get_logits(g_ctx);
        const int n_vocab   = vocab_size();

        int best_id = 0; float best_v = -1e30f;
        for (int t = 0; t < n_vocab; ++t) {
            float v = logits[t];
            if (v > best_v) { best_v = v; best_id = t; }
        }

        const llama_token tok = (llama_token)best_id;
        if (tok == eos_token() || tok == -1) break;

        append_piece(tok, result);
        if ((int)result.size() >= outBufSize - 1) break;

        if (!decode_tokens(&tok, 1, n_past)) {
            LLOGW("llama: decode(step) failed; stop");
            break;
        }
    }

    const int n = std::min((int)result.size(), outBufSize - 1);
    memcpy(outBuf, result.data(), (size_t)n);
    outBuf[n] = '\0';
    return 0;
}

LLM_EXTERN_C LLM_EXPORT_ATTR
void llm_dispose(void) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_ctx)   { llama_free(g_ctx);         g_ctx   = nullptr; }
    if (g_model) { llama_model_free(g_model); g_model = nullptr; }
    llama_backend_free();
    LLOGI("llm_dispose: freed");
}

// ---------- JNI sanity probe ----------
extern "C"
JNIEXPORT jstring JNICALL
Java_com_example_llm_1model_NativeBridge_isAlive(JNIEnv* env, jclass) {
    return env->NewStringUTF("llama JNI OK");
}

// ---------- shared library load hook ----------
__attribute__((constructor))
static void on_load() {
    __android_log_print(ANDROID_LOG_INFO, "LLM_BRIDGE", ">>>> libllama_android.so loaded");
}
