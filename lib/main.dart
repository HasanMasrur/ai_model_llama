// lib/main.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:llm_model/location_service.dart';
import 'package:llm_model/map_screen.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';

import 'llm.dart';


const _ch = MethodChannel('llama/native');

Future<String?> _jniPing() async {
  try {
    final msg = await _ch.invokeMethod<String>('isAlive');
    return msg;
  } catch (_) {
    return null;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocationPolicyService.I.init();
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
    text:
        'Return strictly JSON: {"answer":"<short>"}.\nQuestion: What is Flutter?',
  );

  String _status = 'Booting...';
  String _output = '';
  bool _ready = false;
  double _progress = 0.0;
  String? _modelPath;

  // guards
  bool _bootStarted = false;
  bool _llmInitialized = false;

  static const modelUrl =
      'https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf';

  @override
  void initState() {
    super.initState();
    // UI first → then heavy work
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _boot();
    });
  }

  Future<void> _boot() async {
    if (_bootStarted) return;
    _bootStarted = true;

    setState(() => _status = 'Initializing...');

    try {
      final jniMsg = await _jniPing();
      if (jniMsg != null) debugPrint('JNI ping: $jniMsg');

      final docs = await getApplicationDocumentsDirectory();
      _modelPath = '${docs.path}/model-q4k.gguf';
      final f = File(_modelPath!);

      // Download model (non-blocking UI)
      if (!await f.exists()) {
        await _downloadModelInIsolate(
          modelUrl,
          _modelPath!,
          onProgress: (p) {
            if (mounted) {
              setState(() {
                _status = 'Downloading model...';
                _progress = p;
              });
            }
          },
        );
      }

      if (!_llmInitialized) {
        setState(() => _status = 'Loading LLM...');
        await _llm.load();
        await _llm.init(
          modelPath: _modelPath!,
          ctx: 2048,
          gpuLayers: 0,
          threads: Platform.isAndroid ? 6 : 4,
        );
        _llmInitialized = true;
      }

      if (!mounted) return;
      setState(() {
        _ready = true;
        _status = _llm.isMock ? 'Ready (mock mode)' : 'Ready (native)';
        _progress = 1.0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Init error: $e');
    }
  }

  /// Streamed download + file write; reports onProgress 0..1
  Future<void> _downloadModelInIsolate(
    String url,
    String destPath, {
    required void Function(double) onProgress,
  }) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        throw Exception('Model download failed: HTTP ${resp.statusCode}');
      }
      final file = File(destPath);
      final sink = file.openWrite();
      final total = resp.contentLength ?? 0;
      var received = 0;

      await for (final chunk in resp.stream) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0) onProgress(received / total);
      }
      await sink.flush();
      await sink.close();
      onProgress(1.0);
    } finally {
      client.close();
    }
  }

  /// DB → CSV → LLM (লোকেশন সামারি/সার্চ)
Future<void> _run() async {
    if (!_ready) return;
    setState(() => _status = 'Running...');
    try {
      final raw = await _llm.infer(
        prompt: _prompt.text,
        params: {
          "temperature": 0.4, "top_p": 0.9, "top_k": 40,
          "repeat_penalty": 1.1, "max_tokens": 128
        },
      );
      var pretty = raw;
      try {
        pretty = const JsonEncoder.withIndent('  ').convert(json.decode(raw));
      } catch (_) {}
      setState(() { _status = 'Done'; _output = pretty; });
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  void _openSavedLocations(BuildContext ctx) {
    Navigator.of(ctx).push(
      MaterialPageRoute(builder: (_) => const SavedLocationsScreen()),
    );
  }

  void _openVisitedMap(BuildContext ctx) {
    Navigator.of(ctx).push(
      MaterialPageRoute(builder: (_) => const VisitedMapScreen()),
    );
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
      home: Builder(
        builder: (ctx) => Scaffold(
          appBar: AppBar(
            title: const Text('Tiny LLM (Offline)'),
            actions: [
              IconButton(
                onPressed: () => _openVisitedMap(ctx),
                icon: const Icon(Icons.map_outlined),
                tooltip: 'Visited Map',
              ),
              IconButton(
                onPressed: () => _openSavedLocations(ctx),
                icon: const Icon(Icons.list_alt),
                tooltip: 'Saved Locations',
              ),
            ],
          ),
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
                    labelText: 'Prompt / Query (optional)',
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _ready ? _run : null,
                  child: const Text('Analyze My Trips (LLM)'),
                ),
                const SizedBox(height: 12),

                // Tracking control shortcuts (optional)
                ValueListenableBuilder<bool>(
                  valueListenable: LocationPolicyService.I.isTracking,
                  builder: (_, tracking, __) {
                    return Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: tracking
                                ? null
                                : () async {
                                    final ok = await LocationPolicyService.I
                                        .showDisclosureAndRequestPermissions(ctx);
                                    if (!ok) return;
                                    await LocationPolicyService.I
                                        .startBackgroundTracking();
                                  },
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Start 1-min tracking'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: tracking
                                ? () =>
                                    LocationPolicyService.I.stopBackgroundTracking()
                                : null,
                            icon: const Icon(Icons.stop),
                            label: const Text('Stop'),
                          ),
                        ),
                      ],
                    );
                  },
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
                      _output.isEmpty ? 'Output will appear here...' : _output,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Simple Saved Locations screen (reactive না চাইলে এইটাই যথেষ্ট)
class SavedLocationsScreen extends StatelessWidget {
  const SavedLocationsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Saved Locations')),
      body: ValueListenableBuilder<List<Coord>>(
        valueListenable: LocationPolicyService.I.coords,
        builder: (_, data, __) {
          if (data.isEmpty) {
            return const Center(child: Text('No saved locations yet.'));
          }
          return ListView.separated(
            itemCount: data.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final c = data[i];
              final tsLocal = c.ts.toLocal().toString();
              return ListTile(
                leading: const Icon(Icons.place),
                title: Text(
                  'Lat: ${c.lat.toStringAsFixed(6)} | Lng: ${c.lng.toStringAsFixed(6)}',
                ),
                subtitle: Text('Saved at: $tsLocal'),
                trailing: IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    final text =
                        '${c.lat.toStringAsFixed(6)}, ${c.lng.toStringAsFixed(6)} @ $tsLocal';
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied to clipboard')),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
