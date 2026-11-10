import 'package:flutter/material.dart';

import '../data/bundled_licenses.dart';
import '../l10n/strings.dart';
import 'theme.dart';

class LicenseSettingsTile extends StatelessWidget {
  const LicenseSettingsTile({super.key});

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Neutral.hairline, width: 0.6)),
    ),
    child: ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        context.tr('Licenses', 'ライセンス'),
        style: Txt.label.copyWith(fontWeight: FontWeight.w400),
      ),
      trailing: const Icon(
        Icons.chevron_right,
        color: Neutral.secondary,
        size: 20,
      ),
      onTap: () {
        registerBundledLicenses();
        showLicensePage(
          context: context,
          applicationName: 'After Hue',
          applicationVersion: '0.1.0',
        );
      },
    ),
  );
}
