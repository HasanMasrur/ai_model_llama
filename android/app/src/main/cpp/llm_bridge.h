#pragma once
#ifdef __cplusplus
extern "C" {
#endif

// Returns 0 on success
int llm_init(const char* modelPath, int n_ctx, int n_gpu_layers, int n_threads, int seed);

// paramsJson supports keys: temperature, top_p, top_k, repeat_penalty, max_tokens
// Writes UTF-8 into outBuf (NUL-terminated) up to outBufSize bytes.
// Returns 0 on success
int llm_infer(const char* prompt, const char* paramsJson, char* outBuf, int outBufSize);

// Free global context/model
void llm_dispose(void);

#ifdef __cplusplus
}
#endif
