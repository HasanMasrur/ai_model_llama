import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// -------------------------------
/// Data Model
/// -------------------------------
class Coord {
  final int id;
  final double lat;
  final double lng;
  final DateTime ts;

  Coord({
    required this.id,
    required this.lat,
    required this.lng,
    required this.ts,
  });

  @override
  String toString() =>
      'Coord(id:$id, lat:$lat, lng:$lng, ts:${ts.toIso8601String()})';
}

/// -------------------------------
/// Service (FLP + DB + Permissions)
/// -------------------------------
class LocationPolicyService {
  LocationPolicyService._();
  static final LocationPolicyService I = LocationPolicyService._();

  final FlutterLocalNotificationsPlugin _fln =
      FlutterLocalNotificationsPlugin();

  Database? _db;
  StreamSubscription<Position>? _sub;

  /// Tracking state (UI bind)
  final ValueNotifier<bool> isTracking = ValueNotifier<bool>(false);

  /// Latest coordinate for "live" section (UI bind)
  final ValueNotifier<Coord?> latest = ValueNotifier<Coord?>(null);

  /// 🔥 NEW: reactive full list for UI (auto refresh without back/refresh)
  final ValueNotifier<List<Coord>> coords =
      ValueNotifier<List<Coord>>(<Coord>[]);

  /// Throttle guard: সর্বশেষ সেভড টাইম (১ মিনিটে ১টা)
  DateTime? _lastSavedAt;

  /// Initialize notifications & local DB
  Future<void> init() async {
    await _initNotifications();
    await _initDb();
    // আগের মতো latest সেট
    final last = await _getLastCoord();
    latest.value = last;
    // 🔥 NEW: প্রথমে DB থেকে লিস্ট এনে reactive coords priming
    coords.value = await _safeList(limit: 200);
  }

  /// Prominent disclosure + permissions (Play policy)
  Future<bool> showDisclosureAndRequestPermissions(BuildContext context) async {
    final agreed = await _showProminentDisclosureDialog(context);
    if (agreed != true) return false;

    // Android 13+: notifications permission (FG notification দেখাতে)
    await _requestNotificationPermissionIfNeeded(context);

    // Location permission + services on + optional battery optimization relax
    final ok = await _ensureLocationPermissions(context);
    if (!ok) return false;

    // Optional but helpful: ask to ignore battery optimizations on aggressive OEMs
    await _maybeAskIgnoreBatteryOptimizations(context);

    return true;
  }

  /// Start FLP stream (1 minute interval) + save to DB
  Future<void> startBackgroundTracking() async {
    if (isTracking.value) return;

    // If services off, don't start
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) return;

    // Base fallback settings
    const base = LocationSettings(
      accuracy: LocationAccuracy.medium,
      distanceFilter: 0,
    );

    // Android: FLP stream as Foreground Service with persistent notification
    final android = AndroidSettings(
      accuracy: LocationAccuracy.medium,
      distanceFilter: 0,
      intervalDuration: const Duration(minutes: 1), // <-- প্রতি ১ মিনিটে
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'Location tracking active',
        notificationText: 'Saving location every 1 minute…',
        enableWakeLock: false, // (true করলে WAKE_LOCK দরকার)
        setOngoing: true,
      ),
    );

    // iOS: foreground only unless BG mode enabled in Xcode
    var apple = AppleSettings(
      accuracy: LocationAccuracy.best,
      allowBackgroundLocationUpdates: false,
      pauseLocationUpdatesAutomatically: true,
      showBackgroundLocationIndicator: false,
    );

    final settings =
        Platform.isAndroid ? android : (Platform.isIOS ? apple : base);

    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      (pos) async {
        try {
          // ১ মিনিট থ্রটল
          final now = DateTime.now();
          if (_lastSavedAt != null &&
              now.difference(_lastSavedAt!).inSeconds < 55) {
            return;
          }
          _lastSavedAt = now;

          final id = await _insertRaw(pos.latitude, pos.longitude, now);
          final c =
              Coord(id: id, lat: pos.latitude, lng: pos.longitude, ts: now);

          // আগের মতো live update
          latest.value = c;

          // 🔥 NEW: reactive list prepend (auto UI refresh)
          final current = List<Coord>.from(coords.value);
          current.insert(0, c);
          if (current.length > 500) current.removeRange(500, current.length);
          coords.value = current;

          // 🔥 NEW: pop-up notification on each save from stream
          await showLocalNotification(
            title: 'Location saved',
            body:
                'Lat: ${pos.latitude.toStringAsFixed(6)}, Lng: ${pos.longitude.toStringAsFixed(6)}',
          );
        } catch (e) {
          // ignore DB errors to keep stream alive
          // debugPrint('DB insert error: $e');
        }
      },
      onError: (e) {
        // ignore: avoid_print
        print('position stream error: $e');
      },
      cancelOnError: false,
    );

    isTracking.value = true;
  }

  /// Stop FLP stream
  Future<void> stopBackgroundTracking() async {
    if (_sub == null) return;

    try {
      await _sub?.cancel();
    } catch (e) {
      debugPrint('Error cancelling stream: $e');
    } finally {
      _sub = null;
      isTracking.value = false;
    }
  }

  /// One-time get + save (manual)
  Future<Position?> captureAndStoreLocation({bool notify = true}) async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      final ts = DateTime.now();
      final id = await _insertRaw(pos.latitude, pos.longitude, ts);
      final c = Coord(id: id, lat: pos.latitude, lng: pos.longitude, ts: ts);

      // live update
      latest.value = c;

      // 🔥 NEW: reactive list prepend
      final current = List<Coord>.from(coords.value);
      current.insert(0, c);
      if (current.length > 500) current.removeRange(500, current.length);
      coords.value = current;

      if (notify) {
        await showLocalNotification(
          title: 'Location saved',
          body:
              'Lat: ${pos.latitude.toStringAsFixed(6)}, Lng: ${pos.longitude.toStringAsFixed(6)}',
        );
      }
      return pos;
    } catch (e) {
      // ignore: avoid_print
      print('capture error: $e');
      return null;
    }
  }

  /// List last [limit] coords (latest first) — (older API kept for reuse)
  Future<List<Coord>> listSavedCoordinates({int limit = 200}) async {
    return _safeList(limit: limit);
  }

  Future<List<Coord>> _safeList({int limit = 200}) async {
    try {
      final rows =
          await _db!.query('coords', orderBy: 'ts DESC', limit: limit);
      return rows
          .map((r) => Coord(
                id: r['id'] as int,
                lat: (r['lat'] as num).toDouble(),
                lng: (r['lng'] as num).toDouble(),
                ts: DateTime.parse(r['ts'] as String),
              ))
          .toList();
    } catch (_) {
      return const <Coord>[];
    }
  }

  /// Heads-up local notification (optional UX)
  Future<void> showLocalNotification({
    required String title,
    required String body,
  }) async {
    const android = AndroidNotificationDetails(
      'loc_channel',
      'Location Updates',
      channelDescription: 'Notifies when location is saved',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      ongoing: false,
    );
    const details = NotificationDetails(android: android);
    await _fln.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
    );
  }

  // -------- Internals: DB / Permissions / Disclosure / Notifications --------

  Future<void> _initNotifications() async {
    const initAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: initAndroid);
    await _fln.initialize(initSettings);
  }

  Future<void> _initDb() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'location_db.sqlite');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE coords(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            lat REAL NOT NULL,
            lng REAL NOT NULL,
            ts TEXT NOT NULL
          )
        ''');
      },
    );
  }

  Future<int> _insertRaw(double lat, double lng, DateTime ts) async {
    return await _db!.insert('coords', {
      'lat': lat,
      'lng': lng,
      'ts': ts.toUtc().toIso8601String(),
    });
  }

  Future<Coord?> _getLastCoord() async {
    final rows = await _db!.query('coords', orderBy: 'ts DESC', limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Coord(
      id: r['id'] as int,
      lat: (r['lat'] as num).toDouble(),
      lng: (r['lng'] as num).toDouble(),
      ts: DateTime.parse(r['ts'] as String),
    );
  }

  Future<bool> _showProminentDisclosureDialog(BuildContext context) async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('Location usage (Important)'),
            content: const Text(
              'আমরা প্রতি ১ মিনিটে আপনার লোকেশন সংগ্রহ করি লাইভ ট্র্যাকিং ফিচার চালাতে। '
              'Android এ ট্র্যাকিং চলাকালীন একটি স্থায়ী নোটিফিকেশন দেখা যাবে। '
              'আপনি যেকোনো সময় বন্ধ করতে পারবেন।',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Not now'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('I Agree'),
              ),
            ],
          ),
        ) ??
        false;
  }

  /// Android 13+ notification permission (foreground notification দেখাতে)
  Future<void> _requestNotificationPermissionIfNeeded(
      BuildContext context) async {
    if (!Platform.isAndroid) return;
    final status = await Permission.notification.status;
    if (!status.isGranted) {
      final res = await Permission.notification.request();
      if (!res.isGranted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Notification permission is required for background tracking.'),
        ));
      }
    }
  }

  Future<bool> _ensureLocationPermissions(BuildContext context) async {
    // Services ON?
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (context.mounted) {
        final go = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Turn on Location'),
                content: const Text(
                    'Location services are off. Enable GPS/Location from settings.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('Cancel'),
                  ),
                  ElevatedButton(
                    onPressed: () async {
                      await Geolocator.openLocationSettings();
                      if (ctx.mounted) Navigator.of(ctx).pop(true);
                    },
                    child: const Text('Open Settings'),
                  ),
                ],
              ),
            ) ??
            false;
        if (!go) return false;
      }
      if (!await Geolocator.isLocationServiceEnabled()) return false;
    }

    // Runtime permission flow
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }

    if (perm == LocationPermission.deniedForever) {
      if (context.mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Permission required'),
            content: const Text(
                'Location permission is permanently denied. Enable it from app settings.'),
            actions: [
              TextButton(
                onPressed: () {
                  Geolocator.openAppSettings();
                  Navigator.of(ctx).pop();
                },
                child: const Text('Open Settings'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
      }
      return false;
    }

    // Android 12+ approximate/precise toggle: force করা যায় না

    return perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
  }

  /// Aggressive OEM (Vivo/OPPO/MIUI) – battery optimization ignore prompt
  Future<void> _maybeAskIgnoreBatteryOptimizations(
      BuildContext context) async {
    if (!Platform.isAndroid) return;
    // permission_handler এ ignoreBatteryOptimizations আছে
    final p = await Permission.ignoreBatteryOptimizations.status;
    if (!p.isGranted) {
      await Permission.ignoreBatteryOptimizations.request();
      // Info only; deny হলে fail করবো না
    }
  }
}

/// -------------------------------
/// UI Screen (Start/Stop + Live + List)
/// -------------------------------
class LocationTrackerScreen extends StatefulWidget {
  const LocationTrackerScreen({super.key});

  @override
  State<LocationTrackerScreen> createState() => _LocationTrackerScreenState();
}

class _LocationTrackerScreenState extends State<LocationTrackerScreen> {
  @override
  void initState() {
    super.initState();
    // service priming (permissions flow unaffected)
    LocationPolicyService.I.init();
  }

  Future<void> _start() async {
    final ok = await LocationPolicyService.I
        .showDisclosureAndRequestPermissions(context);
    if (!ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Permission or settings not satisfied.'),
      ));
      return;
    }

    await LocationPolicyService.I.startBackgroundTracking();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Started 1-min tracking'),
    ));
  }

  Future<void> _stop() async {
    await LocationPolicyService.I.stopBackgroundTracking();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Stopped tracking'),
    ));
  }

  Future<void> _saveOnce() async {
    final ok =
        await LocationPolicyService.I.showDisclosureAndRequestPermissions(context);
    if (!ok) return;
    await LocationPolicyService.I.captureAndStoreLocation();
  }

  @override
  Widget build(BuildContext context) {
    final svc = LocationPolicyService.I;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Location (FLP, 1-min)'),
        actions: [
          IconButton(
            tooltip: 'Save once',
            onPressed: _saveOnce,
            icon: const Icon(Icons.my_location),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Live status + latest coord (Reactive)
            Row(
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: svc.isTracking,
                  builder: (_, tracking, __) {
                    return Chip(
                      label: Text(tracking ? 'Tracking ON' : 'Tracking OFF'),
                      backgroundColor:
                          tracking ? Colors.green.shade100 : Colors.grey.shade200,
                    );
                  },
                ),
                const SizedBox(width: 12),
                const Icon(Icons.location_on_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: ValueListenableBuilder<Coord?>(
                    valueListenable: svc.latest,
                    builder: (_, c, __) {
                      if (c == null) {
                        return const Text('No location yet');
                      }
                      final ts = c.ts.toLocal().toString();
                      return Text(
                        'Lat: ${c.lat.toStringAsFixed(6)}, '
                        'Lng: ${c.lng.toStringAsFixed(6)}\n$ts',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      );
                    },
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Start / Stop buttons
            ValueListenableBuilder<bool>(
              valueListenable: svc.isTracking,
              builder: (_, tracking, __) {
                return Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: tracking ? null : _start,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Start (every 1 min)'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: tracking ? _stop : null,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                      ),
                    ),
                  ],
                );
              },
            ),

            const SizedBox(height: 12),

            // 🔥 NEW: Saved list (Reactive — no refresh/back needed)
            Expanded(
              child: ValueListenableBuilder<List<Coord>>(
                valueListenable: svc.coords,
                builder: (_, list, __) {
                  if (list.isEmpty) {
                    return const Center(child: Text('No saved locations yet.'));
                  }
                  return ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final c = list[i];
                      final tsLocal = c.ts.toLocal().toString();
                      return ListTile(
                        leading: const Icon(Icons.place),
                        title: Text(
                          'Lat: ${c.lat.toStringAsFixed(6)} | '
                          'Lng: ${c.lng.toStringAsFixed(6)}',
                        ),
                        subtitle: Text('Saved at: $tsLocal'),
                        trailing: IconButton(
                          tooltip: 'Copy',
                          icon: const Icon(Icons.copy),
                          onPressed: () {
                            final text =
                                '${c.lat.toStringAsFixed(6)}, '
                                '${c.lng.toStringAsFixed(6)} @ $tsLocal';
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
            ),
          ],
        ),
      ),
    );
  }
}
