import 'package:flutter/widgets.dart';

/// Copy is authored for each language at the call site; unsupported locales
/// use English. Keep user-generated content and color values unchanged.
extension AfterHueStrings on BuildContext {
  bool get isJapanese => Localizations.localeOf(this).languageCode == 'ja';

  String tr(String english, String japanese) => isJapanese ? japanese : english;
}
