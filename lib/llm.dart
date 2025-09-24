// lib/llm.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

class LLM {
  DynamicLibrary? _lib;
  late final int Function(Pointer<Utf8>, int, int, int, int) _init;
  late final int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int) _infer;
  late final void Function() _dispose;

  bool _mock = false;
  String? lastError;

  bool get isMock => _mock;

  Future<void> load({String libPath = 'libllama_android.so'}) async {
    lastError = null;
    DynamicLibrary? lib;

    if (Platform.isAndroid) {
      // 1) try direct open
      try {
        lib = DynamicLibrary.open(libPath);
      } catch (e1) {
        // 2) fallback: if JNI already loaded it, symbols are in the process
        try {
          lib = DynamicLibrary.process();
        } catch (e2) {
          lastError = 'open("$libPath") failed: $e1; process() failed: $e2';
        }
      }
    } else {
      try {
        lib = DynamicLibrary.process();
      } catch (e) {
        lastError = 'process() failed: $e';
      }
    }

    if (lib == null) {
      _mock = true;
      return;
    }

    try {
      _init = lib
          .lookup<NativeFunction<
              Int32 Function(Pointer<Utf8>, Int32, Int32, Int32, Int32)>>('llm_init')
          .asFunction();

      _infer = lib
          .lookup<NativeFunction<
              Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32)>>('llm_infer')
          .asFunction();

      _dispose = lib
          .lookup<NativeFunction<Void Function()>>('llm_dispose')
          .asFunction();

      _lib = lib;
    } catch (e) {
      lastError = 'symbol lookup failed: $e';
      _mock = true;
    }
  }

  Future<void> init({
    required String modelPath,
    int ctx = 2048,
    int gpuLayers = 0,
    int threads = 4,
    int seed = 0,
  }) async {
    if (_mock) return;
    final mp = modelPath.toNativeUtf8();
    final rc = _init(mp, ctx, gpuLayers, threads, seed);
    malloc.free(mp);
    if (rc != 0) {
      throw Exception('llm_init failed ($rc)');
    }
  }

  Future<String> infer({
    required String prompt,
    required Map<String, dynamic> params,
  }) async {
    if (_mock) {
      // minimal mock so UI works
      final lower = prompt.toLowerCase();
      String ans = 'This is a mock local response.';
      if (lower.contains('what is flutter')) {
        ans = 'Flutter is a UI toolkit by Google for building apps from one codebase.';
      }
      return jsonEncode({"answer": ans, "mode": "mock"});
    }

    final p = prompt.toNativeUtf8();
    final pj = const JsonEncoder().convert(params).toNativeUtf8();
    const outSize = 1024 * 1024;
    final outBuf = malloc.allocate<Utf8>(outSize);

    final rc = _infer(p, pj, outBuf, outSize);
    final out = outBuf.cast<Utf8>().toDartString();

    malloc
      ..free(p)
      ..free(pj)
      ..free(outBuf);

    if (rc != 0) {
      throw Exception('llm_infer failed ($rc)');
    }
    return out;
  }

  void dispose() {
    if (_mock) return;
    try {
      _dispose();
    } catch (_) {}
  }
}
