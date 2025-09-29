// lib/visited_map_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:llm_model/location_service.dart';


class VisitedMapScreen extends StatelessWidget {
  const VisitedMapScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // রিয়েল-টাইম ম্যাপ চাইলে ValueListenableBuilder ব্যবহার করা হচ্ছে
    return Scaffold(
      appBar: AppBar(title: const Text('Visited Map')),
      body: ValueListenableBuilder<List<Coord>>(
        valueListenable: LocationPolicyService.I.coords,
        builder: (_, list, __) {
          final latlngs = list.map((c) => LatLng(c.lat, c.lng)).toList();
          final center = latlngs.isNotEmpty
              ? latlngs.first
              : const LatLng(23.7806, 90.4070); // Dhaka fallback

          return FlutterMap(
            options: MapOptions(
              initialCenter: center,
              initialZoom: 12,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.llm_model',
              ),
              if (latlngs.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(points: latlngs, strokeWidth: 3.0),
                  ],
                ),
              MarkerLayer(
                markers: [
                  for (final p in latlngs)
                    Marker(
                      point: p,
                      width: 28,
                      height: 28,
                      child: const Icon(Icons.place, size: 20),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
