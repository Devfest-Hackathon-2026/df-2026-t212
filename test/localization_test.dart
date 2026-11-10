import 'package:afterhue/main.dart';
import 'package:afterhue/l10n/cloud_ai_errors.dart';
import 'package:afterhue/ui/import_sheet.dart';
import 'package:afterhue/ui/onboarding.dart';
import 'package:afterhue/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

Widget localized(Widget child, Locale locale) => MaterialApp(
  locale: locale,
  supportedLocales: const [Locale('en'), Locale('ja')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  theme: buildTheme(),
  home: child,
);

void main() {
  testWidgets('the app stays English on a Japanese device', (tester) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('ja');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    await tester.pumpWidget(const AfterHue());
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).locale, const Locale('en'));
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).supportedLocales, [const Locale('en')]);
    expect(Localizations.localeOf(tester.element(find.byType(Onboarding))), const Locale('en'));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('onboarding uses Japanese and falls back to English', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(localized(const Onboarding(), const Locale('ja')));
    await tester.pump();
    expect(find.text('続ける'), findsOneWidget);
    expect(find.textContaining('写真の被写体'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(localized(const Onboarding(), const Locale('fr')));
    await tester.pump();
    expect(find.text('Continue'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('Japanese onboarding fits through the final page on a small phone', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getPermissionState' || call.method == 'requestPermissionExtend') return PermissionState.denied.index;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(localized(const Onboarding(), const Locale('ja')));
    await tester.tap(find.text('続ける'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('写真を選ぶ'));
    await tester.pumpAndSettle();
    expect(find.text('はじめる'), findsOneWidget);
    expect(find.text('自動で現像'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('known Cloud AI limit errors are Japanese and unknown errors stay private', (tester) async {
    const errors = [
      'Cloud AI has reached its daily service limit. Please try again after the daily reset.',
      'You have reached your daily Cloud AI limit. Please try again after the daily reset.',
      'Too many Cloud AI requests. Please wait a moment and try again.',
      'Cloud AI cannot check its usage limits. Please try again later; contact the developer if this continues.',
    ];
    await tester.pumpWidget(localized(Builder(builder: (context) => Scaffold(body: Column(children: [
      for (final error in errors) Text(cloudAiErrorText(context, error)!),
      Text(cloudAiErrorText(context, 'unknown private details') ?? 'hidden'),
    ]))), const Locale('ja')));
    expect(find.textContaining('サービス利用上限'), findsOneWidget);
    expect(find.textContaining('本日の利用上限'), findsOneWidget);
    expect(find.textContaining('リクエストが集中'), findsOneWidget);
    expect(find.textContaining('利用上限を確認できません'), findsOneWidget);
    expect(find.text('hidden'), findsOneWidget);
  });

  testWidgets('Japanese import permission guidance fits a phone screen', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('com.fluttercandies/photo_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getPermissionState' || call.method == 'requestPermissionExtend') return PermissionState.denied.index;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(localized(const Scaffold(body: ImportSheet()), const Locale('ja')));
    await tester.pumpAndSettle();
    expect(find.text('写真を選ぶ'), findsOneWidget);
    expect(find.text('設定を開く'), findsOneWidget);
    expect(find.text('写真を選ぶにはアクセスを許可してください。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
