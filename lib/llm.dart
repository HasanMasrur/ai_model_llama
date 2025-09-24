// lib/llm.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Native-first LLM wrapper.
/// - Android এ সাধারণত Java/Kotlin দিক থেকে `System.loadLibrary("llama_android")` লোড হয়,
///   তাই আমরা আগে `DynamicLibrary.process()` থেকে symbols resolve করার চেষ্টা করি।
/// - না পেলে: Android → `libllama_android.so`, ডেস্কটপ টেস্টে → `libllama.so` ওপেন করি.
/// - resolve না হলে mock fallback চালু হবে।
class LLM {
  DynamicLibrary? _lib;
  late final int Function(Pointer<Utf8>, int, int, int, int) _init;
  // C: int llm_infer(const char* prompt, const char* paramsJson, char* outBuf, int outBufSize)
  late final int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int) _infer;
  late final void Function() _dispose;

  bool _ready = false;
  bool _mock = false;

  bool get isMock => _mock;

  /// Loads native symbols. Android/iOS/mac: first try process(), then fallback by name.
  Future<void> load() async {
    DynamicLibrary? lib;

    bool _tryResolve(DynamicLibrary candidate) {
      try {
        _init = candidate
            .lookup<NativeFunction<Int32 Function(Pointer<Utf8>, Int32, Int32, Int32, Int32)>>('llm_init')
            .asFunction();
        _infer = candidate
            .lookup<NativeFunction<Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32)>>('llm_infer')
            .asFunction();
        _dispose = candidate
            .lookup<NativeFunction<Void Function()>>('llm_dispose')
            .asFunction();
        return true;
      } catch (_) {
        return false;
      }
    }

    // 1) আগে process() চেষ্টা
    try { lib = DynamicLibrary.process(); } catch (_) {}

    var resolved = false;
    if (lib != null) {
      resolved = _tryResolve(lib);
    }

    // 2) symbol না পেলে — ANDROID হলে লাইব্রেরি সরাসরি ওপেন করুন
    if (!resolved && Platform.isAndroid) {
      try {
        final cand = DynamicLibrary.open('libllama_android.so');
        if (_tryResolve(cand)) {
          lib = cand;
          resolved = true;
        }
      } catch (_) {}
    }

    // 3) ডেস্কটপ টেস্টিংয়ের fallback
    if (!resolved && !Platform.isAndroid) {
      try {
        final cand = DynamicLibrary.open('libllama.so');
        if (_tryResolve(cand)) {
          lib = cand;
          resolved = true;
        }
      } catch (_) {}
    }

    if (!resolved) {
      _lib = null;
      _mock = true;
      return;
    }

    _lib = lib;
    _mock = false;
  }

  Future<void> init({
    required String modelPath,
    int ctx = 2048,
    int gpuLayers = 0,
    int threads = 4,
    int seed = 0,
  }) async {
    if (_mock) { _ready = true; return; }

    final mp = modelPath.toNativeUtf8();
    try {
      final rc = _init(mp, ctx, gpuLayers, threads, seed);
      if (rc != 0) {
        // native init failed → fallback (so app doesn’t crash)
        _mock = true;
      }
      _ready = true;
    } finally {
      malloc.free(mp);
    }
  }

  Future<String> infer({
    required String prompt,
    required Map<String, dynamic> params,
  }) async {
    if (!_ready) throw StateError('LLM not initialized');

    if (_mock) {
      final ans = _shortAnswer(prompt);
      return jsonEncode({"answer": ans, "mode": "mock"});
    }

    final p  = prompt.toNativeUtf8();
    final pj = const JsonEncoder().convert(params).toNativeUtf8();

    // বড় আউটপুটের জন্য 1 MiB বাফার (native side null-terminate করতে হবে)
    const outSize = 1024 * 1024;
    final outBufBytes = malloc.allocate<Uint8>(outSize);
    try {
      final rc = _infer(p, pj, outBufBytes.cast<Utf8>(), outSize);
      final out = outBufBytes.cast<Utf8>().toDartString();
      if (rc != 0) {
        throw Exception('llm_infer failed (rc=$rc)');
      }
      return out;
    } finally {
      malloc
        ..free(p)
        ..free(pj)
        ..free(outBufBytes);
    }
  }

  void dispose() {
    if (_mock) return;
    if (_ready) {
      _dispose();
      _ready = false;
    }
  }

  String _shortAnswer(String prompt) {
    final lower = prompt.toLowerCase();
    if (lower.contains('what is flutter')) {
      return 'Flutter is a UI toolkit by Google for building natively compiled apps from a single Dart codebase.';
    }
    return 'This is a mock local response. Native lib not available.';
    }
}
