import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';

import 'data/store.dart';
import 'ui/onboarding.dart';
import 'ui/cloud_ai_consent.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(systemBarsLight);
  await Store.instance.init();
  runApp(const AfterHue());
}

class AfterHue extends StatelessWidget {
  const AfterHue({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'After Hue',
      supportedLocales: const [Locale('en'), Locale('ja')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: ListenableBuilder(
        listenable: Store.instance,
        builder: (context, _) {
          final s = Store.instance;
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            switchInCurve: Motion.settle,
            switchOutCurve: Curves.easeInCubic,
            child: s.onboarded ? const CloudAiConsentGate(key: ValueKey('shell'), child: Shell()) : const Onboarding(key: ValueKey('onboarding')),
          );
        },
      ),
    );
  }
}
