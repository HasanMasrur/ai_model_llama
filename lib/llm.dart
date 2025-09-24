import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// LLM wrapper with graceful fallback:
/// - If native lib (libllama.so / static iOS) is available, uses FFI.
/// - Otherwise runs a fast Dart-only mock so the app is RUNNABLE end-to-end.
class LLM {
  DynamicLibrary? _lib;
  late final int Function(Pointer<Utf8>, int, int, int, int) _init;
  late final int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int) _infer;
  late final void Function() _dispose;

  bool _ready = false;
  bool _mock = false;

  /// Expose mock/native state to UI
  bool get isMock => _mock;

  Future<void> load({String libPath = 'libllama.so'}) async {
    // Android expects libllama.so inside jniLibs/<abi> and dlopen by filename works.
    if (Platform.isAndroid) {
      try {
        _lib = DynamicLibrary.open(libPath);
      } catch (_) {
        _lib = null;
      }
    } else {
      // If statically linked on iOS/macOS, we can resolve from the current process.
      try {
        _lib = DynamicLibrary.process();
      } catch (_) {
        _lib = null;
      }
    }

    if (_lib == null) {
      _mock = true; // fallback so the app runs without native lib
      return;
    }

    _init = _lib!
        .lookup<NativeFunction<
            Int32 Function(Pointer<Utf8>, Int32, Int32, Int32, Int32)>>('llm_init')
        .asFunction();
    _infer = _lib!
        .lookup<NativeFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32)>>('llm_infer')
        .asFunction();
    _dispose = _lib!.lookup<NativeFunction<Void Function()>>('llm_dispose').asFunction();
  }

  Future<void> init({
    required String modelPath,
    int ctx = 2048,
    int gpuLayers = 0,
    int threads = 4,
    int seed = 0,
  }) async {
    if (_mock) {
      _ready = true;
      return;
    }
    final mp = modelPath.toNativeUtf8();
    final rc = _init(mp, ctx, gpuLayers, threads, seed);
    malloc.free(mp);
    if (rc != 0) {
      throw Exception('llm_init failed ($rc)');
    }
    _ready = true;
  }

  Future<String> infer({
    required String prompt,
    required Map<String, dynamic> params,
  }) async {
    if (!_ready) {
      throw Exception('LLM not initialized');
    }

    if (_mock) {
      final answer = _shortAnswer(prompt);
      return jsonEncode({"answer": answer, "mode": "mock"});
    }

    final p = prompt.toNativeUtf8();
    final pj = const JsonEncoder().convert(params).toNativeUtf8();
    const outSize = 1024 * 1024; // 1 MB
    final outBuf = malloc.allocate<Utf8>(outSize);
    final rc = _infer(p, pj, outBuf, outSize);
    final out = outBuf.cast<Utf8>().toDartString();
    malloc.free(p);
    malloc.free(pj);
    malloc.free(outBuf);
    if (rc != 0) {
      throw Exception('llm_infer failed ($rc)');
    }
    return out;
  }

  void dispose() {
    if (_mock) return;
    if (_ready) {
      _dispose();
      _ready = false;
    }
  }

  // Very small mock so the app still works end-to-end without native lib.
  String _shortAnswer(String prompt) {
    final lower = prompt.toLowerCase();
    if (lower.contains('what is flutter')) {
      return 'Flutter is a UI toolkit by Google for building natively compiled apps from a single Dart codebase.';
    }
    if (lower.contains('classify')) {
      return 'label: demo, confidence: 0.73';
    }
    return 'This is a mock local response. Add libllama.so (Android) or link libllama.a (iOS) for real LLM output.';
    }
}
