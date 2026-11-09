import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../core/renderer.dart';
import 'agent.dart';

/// Apple's on-device model (Foundation Models, iOS 27) as the judge: free,
/// private, no network. Null from [judge] means it is not usable here.
class AppleJudge {
  static const _ch = MethodChannel('afterhue/apple_judge');
  static String? _status;

  /// "ok", or why not: os, noVision, deviceNotEligible,
  /// appleIntelligenceNotEnabled, modelNotReady.
  static Future<String> status() async {
    if (!Platform.isIOS) return 'os';
    final cached = _status;
    if (cached == 'ok' || cached == 'os' || cached == 'deviceNotEligible' || cached == 'noVision') return cached!;
    try {
      return _status = await _ch.invokeMethod<String>('status') ?? 'unavailable';
    } on MissingPluginException {
      return _status = 'os';
    }
  }

  static Future<Verdict?> judge(Rgba photo) async {
    if (await status() != 'ok') return null;
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/judge_${DateTime.now().microsecondsSinceEpoch}.jpg');
    await f.writeAsBytes(await plainJpeg(photo));
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('judge', {'path': f.path, 'instructions': judgeInstructions});
      if (m == null) return null;
      return Verdict(m['develop'] as bool, subject: m['subject'] as String?, reason: m['reason'] as String?);
    } finally {
      unawaitedDelete(f);
    }
  }

  static void unawaitedDelete(File f) => f.delete().catchError((_) => f);
}
