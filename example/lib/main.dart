import 'dart:convert';
import 'dart:io';

import 'package:automated_testing_framework/automated_testing_framework.dart';
import 'package:automated_testing_framework_driver_websocket/device.dart';
import 'package:automated_testing_framework_example/automated_testing_framework_example.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

void main() {
  TestAppSettings.initialize(appIdentifier: 'ATF Websocket');
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: ${record.time}: ${record.message}');
    if (record.error != null) {
      // ignore: avoid_print
      print('${record.error}');
    }
    if (record.stackTrace != null) {
      // ignore: avoid_print
      print('${record.stackTrace}');
    }
  });

  var gestures = TestableGestures();
  if (kIsWeb ||
      Platform.isFuchsia ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isWindows) {
    gestures = TestableGestures(
      widgetLongPress: null,
      widgetSecondaryLongPress: TestableGestureAction.open_test_actions_page,
      widgetSecondaryTap: TestableGestureAction.open_test_actions_dialog,
    );
  }

  runApp(App(
    options: TestExampleOptions(
      autorun: kProfileMode,
      enabled: true,
      gestures: gestures,
      onInitComplete: (controller) async {
        var config = json.decode(
          await rootBundle.loadString('assets/config/config.json'),
        );
        var communicator = WebSocketTestDeviceCommunicator(
          secret: config['secret'],
          testControllerState: controller.state,
          url: config['url'],
        );
        await communicator.activate(
          () => TestDeviceInfoHelper.initialize(null),
        );
        var testDriver = TestDriver(
          communicator: communicator,
          testController: controller,
        );

        testDriver.activate();
      },
      suiteName: 'Core',
      testReader: AssetTestStore(
        testAssetIndex:
            'packages/automated_testing_framework_example/assets/all_tests.json',
      ).testReader,
      testWidgetsEnabled: true,
      testWriter: ClipboardTestStore.testWriter,
    ),
  ));
}
