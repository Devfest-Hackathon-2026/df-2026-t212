import 'package:flutter/services.dart';

/// Reads permission for the GPS already stored in a photo. This never asks for
/// the phone's current location and is independent of library read permission.
class AndroidPhotoLocation {
  static const _channel = MethodChannel('afterhue/photo_location');

  static Future<bool> granted() async {
    try { return await _channel.invokeMethod<bool>('granted') ?? false; }
    on PlatformException { return false; }
    on MissingPluginException { return false; }
  }

  static Future<bool> request() async {
    try { return await _channel.invokeMethod<bool>('request') ?? false; }
    on PlatformException { return false; }
    on MissingPluginException { return false; }
  }
}
