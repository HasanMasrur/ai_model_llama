import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'llm.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LLMApp());
}

class LLMApp extends StatefulWidget {
  const LLMApp({super.key});
  @override
  State<LLMApp> createState() => _LLMAppState();
}

class _LLMAppState extends State<LLMApp> {
  final LLM _llm = LLM();
  final TextEditingController _prompt = TextEditingController(
    text: 'Return strictly JSON: {"answer":"<short>"}.\nQuestion: What is Flutter?',
  );

  String _status = 'Booting...';
  String _output = '';
  bool _ready = false;
  double _progress = 0.0;
  String? _modelPath;

  // Default: TinyLlama 1.1B Chat Q4_K_M (~668MB)
  static const modelUrl =
      'https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      _modelPath = '${docs.path}/model-q4k.gguf';
      final f = File(_modelPath!);
      if (!await f.exists()) {
        await _downloadModel(Uri.parse(modelUrl), f);
      }

      // Android: libllama.so must be in android/app/src/main/jniLibs/arm64-v8a/
      await _llm.load(libPath: 'libllama.so');

      await _llm.init(
        modelPath: _modelPath!,
        ctx: 2048,
        gpuLayers: 0,
        threads: Platform.isAndroid ? 6 : 4,
      );

      setState(() {
        _ready = true;
        _status = _llm.isMock ? 'Ready (mock mode)' : 'Ready (native)';
      });
    } catch (e) {
      setState(() => _status = 'Init error: $e');
    }
  }

  Future<void> _downloadModel(Uri url, File dest) async {
    setState(() {
      _status = 'Downloading model...';
      _progress = 0;
    });

    final client = http.Client();
    try {
      final req = http.Request('GET', url);
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        throw Exception('Model download failed: HTTP ${resp.statusCode}');
      }
      final sink = dest.openWrite();
      final total = resp.contentLength ?? 0;
      var received = 0;
      await for (final chunk in resp.stream) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0) {
          setState(() => _progress = received / total);
        }
      }
      await sink.flush();
      await sink.close();
      setState(() => _status = 'Download complete');
    } finally {
      client.close();
    }
  }

  Future<void> _run() async {
    if (!_ready) return;
    setState(() => _status = 'Running...');
    try {
      final raw = await _llm.infer(
        prompt: _prompt.text,
        params: {
          "temperature": 0.4,
          "top_p": 0.9,
          "top_k": 40,
          "repeat_penalty": 1.1,
          "max_tokens": 128
        },
      );
      var pretty = raw;
      try {
        pretty = const JsonEncoder.withIndent('  ').convert(json.decode(raw));
      } catch (_) {}
      setState(() {
        _status = 'Done';
        _output = pretty;
      });
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  @override
  void dispose() {
    _llm.dispose();
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'LLM Offline Demo',
      home: Scaffold(
        appBar: AppBar(title: const Text('Tiny LLM (Offline)')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Status: $_status'),
              if (_status.startsWith('Downloading'))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(
                    value: _progress == 0 ? null : _progress,
                  ),
                ),
              TextField(
                controller: _prompt,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Prompt',
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _ready ? _run : null,
                child: const Text('Generate'),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    _output.isEmpty
                        ? 'Output will appear here...'
                        : _output,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
