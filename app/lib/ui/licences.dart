/// The in-app open-source licence page.
///
/// ## Why this exists
///
/// The release audit (`analysis/63` §7.2 / §12.3 item 15) found that nothing in the
/// app told the user what it is built from: `showLicensePage`, `LicensePage`,
/// `LicenseRegistry` and `AboutDialog` had **zero** occurrences under `lib/`. A
/// released APK bundles Apache-2.0 (`rxdart`, `material_color_utilities`,
/// `marionette_flutter`), MIT (`permission_handler`) and BSD-3-Clause
/// (`flutter_blue_plus`, the Dart/Flutter packages) code, and those licences require
/// their notices to travel with the binary. Shipping the repository's `NOTICE` file
/// satisfies the letter of that for a source reader; it does nothing for someone who
/// installed an APK.
///
/// `showLicensePage` is the whole fix: the Flutter tool writes every package's
/// licence into a `NOTICES` asset at build time and the framework's `LicenseRegistry`
/// reads it back, so the page lists the real, build-specific set — not a list
/// somebody remembered to update.
///
/// ## What it cannot show, and what covers that
///
/// `NOTICES` only carries **pub packages**. Two things are therefore named
/// explicitly here:
///
/// * this app's own licence, registered through [LicenseRegistry] below;
/// * the unofficial-third-party position, which is a trademark statement rather than
///   a licence one, and which the store policies in `analysis/63` §7.4 ask to be
///   visible in the app rather than only in the README.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// The public repository, which is also where the full `LICENSE` and `NOTICE` live.
///
/// Kept as a Dart constant rather than an ARB message on purpose: it is an address,
/// not prose, and an address that is translated is an address that 404s. The ARB
/// parity test (`test/l10n_arb_test.dart`) would also reject a value that is
/// identical in both languages, and the fix for that would be the wrong fix.
const String kReleaseRepoUrl =
    'https://github.com/xiaobaiwud12/yi-m1-controller-app';

/// This app's own notice, shown alongside the bundled packages.
///
/// The Apache-2.0 text itself is not duplicated here. It is already on the page —
/// several bundled packages ship under it — and the repository carries `LICENSE`
/// (the full, verbatim text) and `NOTICE` (the attributions) in full. What this adds
/// is the part no package can state: who this app is, and that it is not the
/// manufacturer's.
const String _ownLicenceText = '''
yi-m1-controller-app — an unofficial, third-party controller for the YI M1 (C59Y1)
mirrorless camera.

Copyright 2026 the yi-m1-controller-app authors.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this
file except in compliance with the License. You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under
the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, either express or implied. See the License for the specific language governing
permissions and limitations under the License.

Third-party components bundled in this build are listed below, each under its own
licence (BSD-3-Clause, MIT and Apache-2.0). Full attributions, and the exact source
this build came from:

    $kReleaseRepoUrl

Not affiliated with, authorised by, or endorsed by YI Technology. "YI", "小蚁" and
"YI M1" are the trademarks of their respective owners and are used only to say which
camera this software works with.
''';

/// Registers [kReleaseRepoUrl]'s notice exactly once.
///
/// `LicenseRegistry.addLicense` appends, so calling it per page open would list this
/// app once per visit. The flag is the guard, and a widget test asserts the entry
/// appears once after opening the page twice.
bool _ownLicenceRegistered = false;

void _registerOwnLicence() {
  if (_ownLicenceRegistered) return;
  _ownLicenceRegistered = true;
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      <String>['yi-m1-controller-app'],
      _ownLicenceText,
    );
  });
}

/// Opens the licence page. Wired to the app bar's `btn-licences`.
void showAppLicences(BuildContext context) {
  _registerOwnLicence();
  final l = l10nOf(context);
  showLicensePage(
    context: context,
    applicationName: l.appTitle,
    // The same compile-time identity the app bar draws, so the page and the badge
    // cannot disagree about which build is installed. `tools/task.ps1 build` asserts
    // this string is present in the shipped `libapp.so`, and
    // `app/tool/verify_apk.dart` re-asserts it against the artifact.
    applicationVersion:
        const String.fromEnvironment('BUILD_STAMP', defaultValue: 'dev'),
    applicationLegalese: l.licencesLegalese,
  );
}
