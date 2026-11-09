import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Achromatic tokens. The only color on screen belongs to the user's photos.
class Neutral {
  static const bg = Color(0xFFF3F3F2);
  static const surface = Color(0xFFFAFAF9);
  static const primary = Color(0xFF161616);
  static const secondary = Color(0xAD000000);
  static const tertiary = Color(0x85000000);
  static const hairline = Color(0xFFE2E2E0);
  static const scrim = Color(0xFF0C0C0C);
  static const glass = Color(0xB8FAFAF9);
  static const glassBorder = Color(0x66FFFFFF);
}

bool get _isApple => !kIsWeb && (Platform.isIOS || Platform.isMacOS);

/// iOS: Helvetica Neue from the system (it cannot be bundled).
String? get uiFamily => _isApple ? 'Helvetica Neue' : null;
String get monoFamily => _isApple ? 'Menlo' : 'monospace';

class Txt {
  static TextStyle get display => TextStyle(
    fontFamily: uiFamily,
    fontSize: 30,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.6,
    color: Neutral.primary,
    height: 1.1,
  );
  static TextStyle get title => TextStyle(
    fontFamily: uiFamily,
    fontSize: 20,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.3,
    color: Neutral.primary,
  );
  static TextStyle get body => TextStyle(
    fontFamily: uiFamily,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.1,
    color: Neutral.primary,
    height: 1.45,
  );
  static TextStyle get label => TextStyle(
    fontFamily: uiFamily,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.1,
    color: Neutral.primary,
  );
  static TextStyle get small =>
      TextStyle(fontFamily: uiFamily, fontSize: 13, fontWeight: FontWeight.w400, color: Neutral.secondary);
  static TextStyle get mono =>
      TextStyle(fontFamily: monoFamily, fontSize: 11, letterSpacing: 0.2, color: Neutral.secondary, height: 1.4);
}

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: Neutral.bg,
    colorScheme: const ColorScheme.light(
      primary: Neutral.primary,
      onPrimary: Neutral.surface,
      surface: Neutral.bg,
      onSurface: Neutral.primary,
      secondary: Neutral.secondary,
    ),
    fontFamily: uiFamily,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
  return base.copyWith(
    textSelectionTheme: const TextSelectionThemeData(cursorColor: Neutral.primary),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Neutral.primary : Neutral.hairline,
      ),
      thumbColor: const WidgetStatePropertyAll(Neutral.surface),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
  );
}

const systemBarsLight = SystemUiOverlayStyle(
  statusBarBrightness: Brightness.light,
  statusBarIconBrightness: Brightness.dark,
  statusBarColor: Colors.transparent,
);

const systemBarsDark = SystemUiOverlayStyle(
  statusBarBrightness: Brightness.dark,
  statusBarIconBrightness: Brightness.light,
  statusBarColor: Colors.transparent,
);

/// The two curves every eased motion uses, so the app moves as one thing.
class Motion {
  /// Answers at once and settles at length, with no bounce: for things that
  /// appear, respond, or change state.
  static const settle = Cubic(0.22, 1, 0.36, 1);

  /// Leaves softly and arrives softly: for things that travel from one place
  /// to another, such as the map's camera.
  static const travel = Cubic(0.65, 0, 0.35, 1);
}

/// Springs used everywhere, so motion feels like one material.
class Springs {
  static const snappy = SpringDescription(mass: 1, stiffness: 420, damping: 36);
  static const gentle = SpringDescription(mass: 1, stiffness: 180, damping: 24);
}

/// One vocabulary of touch for the whole app, so the same kind of moment
/// always feels the same:
///
/// - [tick]: a value moved one step (a dial, a slider, a segment).
/// - [light]: something opened, closed or was picked up.
/// - [firm]: a choice was made or reset.
/// - [snap]: a value landed on a mark (a lens, a default).
/// - [shutter]: a photo was taken.
/// - [success] / [warning]: something finished, or could not.
///
/// On iOS these come from the system's prepared generators, so they are
/// on time and as crisp as the system camera's; elsewhere Flutter's own.
class Haptics {
  static const _ch = MethodChannel('afterhue/haptics');
  static final bool _native = !kIsWeb && Platform.isIOS;

  static void _play(String kind, VoidCallback fallback) {
    if (_native) {
      _ch.invokeMethod('play', kind).catchError((_) => fallback());
    } else {
      fallback();
    }
  }

  static void tick() => _play('tick', HapticFeedback.selectionClick);
  static void light() => _play('light', HapticFeedback.lightImpact);
  static void firm() => _play('firm', HapticFeedback.mediumImpact);
  static void snap() => _play('snap', HapticFeedback.heavyImpact);
  static void shutter() => _play('shutter', HapticFeedback.mediumImpact);
  static void success() => _play('success', HapticFeedback.mediumImpact);
  static void warning() => _play('warning', HapticFeedback.heavyImpact);
}
