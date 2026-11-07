import 'dart:math' as math;

/// A small, hand-picked gazetteer. The map draws these as quiet spaced
/// capitals instead of using a tile style's labels, and photos borrow the
/// nearest name for their caption. Works offline, needs no key.
class Place {
  const Place(this.name, this.lat, this.lng, this.minZoom, this.maxZoom, {this.size = 1});
  final String name;
  final double lat, lng;
  final double minZoom, maxZoom;

  /// 0 = neighborhood, 1 = city, 2 = metropolis shown large.
  final int size;
}

const places = <Place>[
  // World, when zoomed far out.
  Place('Tokyo', 35.6812, 139.7671, 3, 8.5, size: 1),
  Place('Seoul', 37.5665, 126.9780, 3, 8),
  Place('Taipei', 25.0330, 121.5654, 3, 8),
  Place('Shanghai', 31.2304, 121.4737, 3, 8),
  Place('Hong Kong', 22.3193, 114.1694, 3, 8),
  Place('Singapore', 1.3521, 103.8198, 3, 8),
  Place('Bangkok', 13.7563, 100.5018, 3, 8),
  Place('Sydney', -33.8688, 151.2093, 3, 8),
  Place('London', 51.5072, -0.1276, 3, 8),
  Place('Paris', 48.8566, 2.3522, 3, 8),
  Place('Reykjavik', 64.1466, -21.9426, 3, 8),
  Place('New York', 40.7128, -74.0060, 3, 8),
  Place('San Francisco', 37.7749, -122.4194, 3, 8),
  Place('Los Angeles', 34.0522, -118.2437, 3, 8),
  // Japan.
  Place('Sapporo', 43.0618, 141.3545, 5, 11),
  Place('Sendai', 38.2682, 140.8694, 5.5, 11),
  Place('Nagoya', 35.1815, 136.9066, 5.5, 11),
  Place('Kyoto', 35.0116, 135.7681, 5.5, 11),
  Place('Osaka', 34.6937, 135.5023, 5.5, 11),
  Place('Kobe', 34.6901, 135.1955, 6.5, 11),
  Place('Hiroshima', 34.3853, 132.4553, 5.5, 11),
  Place('Fukuoka', 33.5904, 130.4017, 5.5, 11),
  Place('Naha', 26.2124, 127.6809, 5.5, 11),
  Place('Yokohama', 35.4437, 139.6380, 8, 11.5),
  Place('Kawasaki', 35.5308, 139.7030, 9.5, 11.5),
  Place('Saitama', 35.8617, 139.6455, 8, 11.5),
  Place('Chiba', 35.6074, 140.1065, 8, 11.5),
  Place('Tokyo', 35.6812, 139.7671, 8.5, 11.4, size: 2),
  // Tokyo neighborhoods.
  Place('Shinjuku', 35.6909, 139.7003, 11.4, 22, size: 0),
  Place('Shibuya', 35.6580, 139.7016, 11.4, 22, size: 0),
  Place('Ikebukuro', 35.7295, 139.7109, 11.4, 22, size: 0),
  Place('Ueno', 35.7138, 139.7773, 11.4, 22, size: 0),
  Place('Asakusa', 35.7148, 139.7967, 11.4, 22, size: 0),
  Place('Ginza', 35.6717, 139.7650, 11.4, 22, size: 0),
  Place('Roppongi', 35.6628, 139.7314, 11.8, 22, size: 0),
  Place('Shinagawa', 35.6285, 139.7387, 11.8, 22, size: 0),
  Place('Toyosu', 35.6550, 139.7964, 11.8, 22, size: 0),
  Place('Odaiba', 35.6268, 139.7753, 11.8, 22, size: 0),
  Place('Akihabara', 35.6984, 139.7731, 12.4, 22, size: 0),
  Place('Harajuku', 35.6702, 139.7027, 12.4, 22, size: 0),
  Place('Ebisu', 35.6467, 139.7101, 12.4, 22, size: 0),
  Place('Nakameguro', 35.6440, 139.6986, 12.8, 22, size: 0),
  Place('Shimokitazawa', 35.6613, 139.6680, 12.4, 22, size: 0),
  Place('Kagurazaka', 35.7020, 139.7405, 12.8, 22, size: 0),
  Place('Ochanomizu', 35.6995, 139.7650, 12.8, 22, size: 0),
  Place('Nihonbashi', 35.6840, 139.7745, 12.8, 22, size: 0),
  Place('Marunouchi', 35.6812, 139.7671, 12.8, 22, size: 0),
  Place('Tsukiji', 35.6655, 139.7707, 13.2, 22, size: 0),
  Place('Shiba', 35.6560, 139.7480, 13.2, 22, size: 0),
  Place('Hakusan', 35.7210, 139.7520, 13.2, 22, size: 0),
  Place('Yanaka', 35.7266, 139.7690, 12.8, 22, size: 0),
  Place('Nezu', 35.7174, 139.7660, 13.2, 22, size: 0),
  Place('Kiyosumi', 35.6812, 139.7988, 12.8, 22, size: 0),
  Place('Oshiage', 35.7101, 139.8107, 12.8, 22, size: 0),
  Place('Kameido', 35.6977, 139.8263, 12.8, 22, size: 0),
  Place('Meguro', 35.6339, 139.7157, 12.8, 22, size: 0),
];

double _km(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180, dLng = (lng2 - lng1) * math.pi / 180;
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) * math.pow(math.sin(dLng / 2), 2);
  return 2 * r * math.asin(math.sqrt(a));
}

/// The closest neighborhood within walking distance, else the closest city.
String? placeNear(double? lat, double? lng) {
  if (lat == null || lng == null) return null;
  Place? best;
  var bestKm = double.infinity;
  for (final p in places.where((p) => p.size == 0)) {
    final d = _km(lat, lng, p.lat, p.lng);
    if (d < bestKm) {
      bestKm = d;
      best = p;
    }
  }
  if (best != null && bestKm < 2.2) return best.name;
  best = null;
  bestKm = double.infinity;
  for (final p in places.where((p) => p.size != 0)) {
    final d = _km(lat, lng, p.lat, p.lng);
    if (d < bestKm) {
      bestKm = d;
      best = p;
    }
  }
  return best != null && bestKm < 40 ? best.name : null;
}
