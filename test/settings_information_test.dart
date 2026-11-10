import 'package:afterhue/ui/licenses.dart';
import 'package:afterhue/ui/privacy.dart';
import 'package:afterhue/ui/terms.dart';
import 'package:afterhue/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget app(Widget child, {String language = 'en'}) => MaterialApp(
  theme: buildTheme(),
  locale: Locale(language),
  supportedLocales: const [Locale('en'), Locale('ja')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: child,
);

void main() {
  testWidgets('license entry opens bundled notices and returns to its screen', (
    tester,
  ) async {
    await tester.pumpWidget(app(const Scaffold(body: LicenseSettingsTile())));
    await tester.tap(find.text('Licenses'));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('After Hue'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Material Icons'), 200);
    await tester.tap(find.text('Material Icons'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Attribution 4.0 International'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(LicenseSettingsTile), findsOneWidget);
  });

  testWidgets('Japanese terms opens privacy without clipping at phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(const TermsScreen(), language: 'ja'));
    expect(find.text('テスト版の利用について'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('プライバシーについて読む'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('プライバシーについて読む'));
    await tester.pumpAndSettle();
    expect(find.byType(PrivacyScreen), findsOneWidget);
    expect(find.text('プライバシー'), findsOneWidget);
    expect(find.textContaining('縮小した写真'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('戻る'));
    await tester.pumpAndSettle();
    expect(find.byType(TermsScreen), findsOneWidget);
  });
}
