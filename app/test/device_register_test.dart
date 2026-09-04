import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' show MockClient;
import 'package:relic_app/data/device_directory.dart';
import 'package:relic_app/data/recovery.dart';
import 'package:relic_app/onboarding/add_device.dart';
import 'package:relic_app/theme/relic_theme.dart';
import 'package:relic_app/theme/tokens.dart';

/// Regression tests for the 2026-09 device-registry hole: registration was a
/// single unretried shot at connect, and the desktop create flow lost even
/// that one — its recovery-kit push went through a context with no Navigator
/// above it, throwing before the register call. Live accounts synced for
/// weeks with an empty "Your devices" screen and no recovery kit ever shown.
/// These tests lock in both halves of the fix: the self-healing register
/// (ensureDeviceRegistered) and the kit route pushed through the shell's
/// navigator key (showRecoveryKitOnce).
void main() {
  group('ensureDeviceRegistered', () {
    final requests = <http.Request>[];
    setUp(requests.clear);

    Future<String> ownId() async => 'dev-under-test';

    // devices: the GET /account/devices payload; null makes the list read
    // fail with a 500. registerStatus/registerBody shape the POST reply.
    MockClient server({
      List<Map<String, dynamic>>? devices,
      int registerStatus = 200,
      String registerBody = '{"ok":true}',
    }) =>
        MockClient((req) async {
          requests.add(req);
          if (req.method == 'GET') {
            if (devices == null) return http.Response('boom', 500);
            return http.Response(jsonEncode({'devices': devices}), 200);
          }
          return http.Response(registerBody, registerStatus);
        });

    List<http.Request> posts() =>
        requests.where((r) => r.method == 'POST').toList();
    String? auth(http.Request r) =>
        r.headers['Authorization'] ?? r.headers['authorization'];

    test('registers when the device has no row', () async {
      await ensureDeviceRegistered(
        baseUrl: 'https://api.test',
        bearer: () async => 'tok-1',
        label: 'My Box',
        onlyIfMissing: true,
        deviceId: ownId,
        client: server(devices: [
          {'device_id': 'some-other-device', 'label': 'Phone'},
        ]),
      );
      expect(posts(), hasLength(1));
      final post = posts().single;
      expect(post.url.path, '/account/devices');
      expect(auth(post), 'Bearer tok-1');
      final body = jsonDecode(post.body) as Map<String, dynamic>;
      expect(body['device_id'], 'dev-under-test');
      expect(body['label'], 'My Box');
      expect(body['platform'], isNotEmpty);
    });

    test('leaves an existing row alone, so a renamed label survives',
        () async {
      await ensureDeviceRegistered(
        baseUrl: 'https://api.test',
        bearer: () async => 'tok-1',
        label: 'My Box',
        onlyIfMissing: true,
        deviceId: ownId,
        client: server(devices: [
          {'device_id': 'dev-under-test', 'label': 'The name Jordan chose'},
        ]),
      );
      expect(posts(), isEmpty);
    });

    test('does nothing when the registry cannot be read', () async {
      // An empty list and a failed read look the same to a naive check; the
      // heal must treat the failure as "unknown" and not risk re-registering
      // (which resets the label) over a row it could not see.
      await ensureDeviceRegistered(
        baseUrl: 'https://api.test',
        bearer: () async => 'tok-1',
        label: 'My Box',
        onlyIfMissing: true,
        deviceId: ownId,
        client: server(devices: null),
      );
      expect(posts(), isEmpty);
    });

    test('connect mode registers without reading the list first', () async {
      await ensureDeviceRegistered(
        baseUrl: 'https://api.test',
        bearer: () async => 'tok-1',
        label: 'My Box',
        deviceId: ownId,
        client: server(),
      );
      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
    });

    test('a device-cap 409 reaches onDeviceCap and nothing throws', () async {
      DeviceCapException? seen;
      await ensureDeviceRegistered(
        baseUrl: 'https://api.test',
        bearer: () async => 'tok-1',
        label: 'My Box',
        deviceId: ownId,
        client: server(
          registerStatus: 409,
          registerBody: jsonEncode({
            'error': 'device_cap',
            'devices': [
              {'device_id': 'a', 'label': 'One'},
              {'device_id': 'b', 'label': 'Two'},
            ],
          }),
        ),
        onDeviceCap: (dir, e) async => seen = e,
      );
      expect(seen, isNotNull);
      expect(seen!.devices, hasLength(2));
    });

    test('a dead network is swallowed', () async {
      await ensureDeviceRegistered(
        baseUrl: 'https://api.test',
        bearer: () async => 'tok-1',
        label: 'My Box',
        deviceId: ownId,
        client: MockClient((req) async {
          requests.add(req);
          throw http.ClientException('no route to host');
        }),
      );
      expect(requests, hasLength(1)); // it tried, and failing was fine
    });

    test('no sync configured means no traffic at all', () async {
      await ensureDeviceRegistered(
        baseUrl: null,
        bearer: () async => 'tok-1',
        label: 'My Box',
        deviceId: ownId,
        client: server(),
      );
      expect(requests, isEmpty);
    });
  });

  group('showRecoveryKitOnce', () {
    testWidgets('pushes through the shell navigator key and completes',
        (tester) async {
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_Shell(navKey: navKey));

      // The trap that caused the regression, locked in as a fact: the shell
      // State's own context sits above the MaterialApp it builds, so
      // Navigator.of finds nothing there. Routes must use the key.
      final shellContext = tester.state<_ShellState>(find.byType(_Shell)).context;
      expect(() => Navigator.of(shellContext), throwsFlutterError);

      final mk = Uint8List.fromList(List.generate(32, (i) => i * 7 % 251));
      final kit = RecoveryKit.fromMk(mk, 'jordan@example.com');
      var done = false;
      final fut = showRecoveryKitOnce(navKey.currentState, kit)
          .whenComplete(() => done = true);
      await tester.pumpAndSettle();
      expect(find.byType(RecoveryKitScreen), findsOneWidget);
      expect(done, isFalse); // waits for the user, exactly like production

      // Complete the saved-it proof: each field's hint names the group to
      // re-type ("Type group N", 1-based).
      final groups = RecoveryKit.groups(kit);
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(2));
      for (var i = 0; i < 2; i++) {
        final tf = tester.widget<TextField>(fields.at(i));
        final hint = tf.decoration!.hintText!;
        final n = int.parse(RegExp(r'\d+').firstMatch(hint)!.group(0)!);
        await tester.enterText(fields.at(i), groups[n - 1]);
      }
      await tester.pump();
      await tester.ensureVisible(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      await fut;
      expect(done, isTrue);
      expect(find.byType(RecoveryKitScreen), findsNothing);
    });

    testWidgets('a null navigator state skips the kit instead of hanging',
        (tester) async {
      await showRecoveryKitOnce(null, 'RELIC RECOVERY KIT');
    });
  });
}

/// Mirrors the desktop shell's structure: the root State BUILDS the
/// MaterialApp, so the State's own context has no Navigator above it and
/// every route must travel through the navigator key. This is the exact
/// constraint desktop.dart lives under.
class _Shell extends StatefulWidget {
  final GlobalKey<NavigatorState> navKey;
  const _Shell({required this.navKey});
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: widget.navKey,
        theme: materialThemeFor(RelicColors.light),
        builder: (context, child) => RelicTheme(
            colors: RelicColors.light,
            child: child ?? const SizedBox.shrink()),
        home: const Scaffold(body: SizedBox()),
      );
}
