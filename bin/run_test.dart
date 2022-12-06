import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:automated_testing_framework_driver_websocket/driver.dart';
import 'package:automated_testing_framework_models/automated_testing_framework_models.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';

Future<void> main(List<String> args) async {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.message}');
    if (record.error != null) {
      // ignore: avoid_print
      print('${record.error}');
    }
    if (record.stackTrace != null) {
      // ignore: avoid_print
      print('${record.stackTrace}');
    }
  });
  final logger = Logger('main');

  final parser = ArgParser();
  parser.addOption(
    'app',
    abbr: 'a',
    help: 'Application identifier.',
  );
  parser.addOption(
    'device',
    abbr: 'd',
    help: 'Identifier of the device to be driven.',
  );
  parser.addOption(
    'driver',
    abbr: 'n',
    help: 'Name of the driver.',
  );
  parser.addOption(
    'secret',
    abbr: 's',
    help: 'Secret text for communicating with the server.',
  );
  parser.addOption(
    'test',
    abbr: 't',
    help: 'Path to the test to run',
  );
  parser.addOption(
    'url',
    abbr: 'u',
    help: 'URL for the server.',
  );
  parser.addFlag('help', abbr: 'h');
  final results = parser.parse(args);

  if (results['help'] == true) {
    // ignore: avoid_print
    print('''
Usage: run [<options>]

Starts the websocket server for the testing framework.

-a, --app=<app-identifier>     The application identifier.
-d, --device=<device-id>       Identifier of the device to be driven.
-h, --help                     Display this help message.
-n, --driver=<driver-name>     Identifier of the device to be driven.
-s, --secret=<port>            Secret text for communicating with the server.
-t, --test                     Path to the test to run
-u, --url                      Websocket URL for the server.

Optionally, environmental variables can be used to set the following args:

ATF_APP_IDENTIFIER             The application identifier
ATF_DRIVER_NAME                The name of the driver.
ATF_WEBSOCKET_URL              Websocket URL for the server.
''');

    exit(0);
  }

  final device = results['device'];
  if (device?.isNotEmpty != true) {
    logger.severe(
      'No device set.',
    );
    exit(1);
  }

  final secrets = {};
  final secretsFile = File('secret/keys.json');
  if (secretsFile.existsSync() == true) {
    try {
      final data = json.decode(secretsFile.readAsStringSync());
      secrets['driver'] = data['driver'];
    } catch (e) {
      // no-op
    }
  }

  final appIdentifier = results['app'] ??
      secrets['app'] ??
      Platform.environment['ATF_APP_IDENTIFIER'] ??
      'default';

  final driverName = results['driver'] ??
      Platform.environment['ATF_DRIVER_NAME'] ??
      Platform.localHostname;

  final secret = results['secret'] ??
      secrets['driver'] ??
      Platform.environment['ATF_DRIVER_SECRET'];
  if (secret?.isNotEmpty != true) {
    logger.severe(
      'Environment variable "ATF_DRIVER_SECRET" not found, and [secret] arg not set.',
    );
    exit(1);
  }

  final testPath = results['test'];
  if (testPath?.isNotEmpty != true) {
    logger.severe('No test set');
    exit(1);
  }

  final tests = <Test>[];
  if (FileSystemEntity.isDirectorySync(testPath)) {
    final dir = Directory(testPath);
    for (var file in dir.listSync()) {
      if (file is File) {
        tests.add(Test.fromDynamic(json.decode(file.readAsStringSync())));
      }
    }
  } else if (FileSystemEntity.isFileSync(testPath)) {
    final file = File(testPath);
    tests.add(Test.fromDynamic(json.decode(file.readAsStringSync())));
  } else {
    logger.severe('Unable to locate test file: $testPath');
    exit(1);
  }

  if (tests.isNotEmpty != true) {
    logger.severe('Unable to load data for test(s): $testPath');
    exit(1);
  }

  final url = results['url'] ??
      secrets['url'] ??
      Platform.environment['ATF_WEBSOCKET_URL'];
  if (url?.isNotEmpty != true) {
    logger.severe(
      'Environment variable "ATF_WEBSOCKET_URL" not found, and [url] arg not set.',
    );
    exit(1);
  }

  final output = Directory('output/$device');
  try {
    output.deleteSync(recursive: true);
  } catch (e) {
    // no-op
  }
  output.createSync(recursive: true);

  final comm = WebSocketTestDriverCommunicator(
    appIdentifier: appIdentifier ?? 'default',
    driverName: driverName,
    secret: secret,
    url: url,
  );

  comm.onConnectionChanged =
      (connected) async => logger.fine('[CONNECTED]: $connected');
  await comm.activate();
  logger.info('[ACTIVATED]');

  final reserveCmd = ReserveDeviceCommand(
    deviceId: device,
    driverName: driverName,
  );
  final logCmd = StartLogStreamCommand();
  final ssCmd = StartScreenshotStreamCommand();
  var testCmd = RunTestCommand(sendScreenshots: false, test: tests.removeAt(0));
  final releaseCmd = ReleaseDeviceCommand(deviceId: device);

  final completer = Completer();
  comm.commandStream.listen((command) {
    if (command is CommandAck) {
      if (command.commandId == reserveCmd.id) {
        if (command.success == true) {
          comm.sendCommand(logCmd);
          comm.sendCommand(ssCmd);
          comm.sendCommand(testCmd);
        } else {
          completer.completeError('Unable to reserve device');
        }
      } else if (command.commandId == logCmd.id) {
        final response = command.response;
        if (response is LogResponse) {
          final file = File(
            'output/${device}/${hex.encode(utf8.encode(testCmd.test.id))}.log',
          );
          file.createSync(recursive: true);

          final record = response.record;
          file.writeAsString(
            '${record.level.name}: ${record.time}: [${record.loggerName}]: ${record.message}\n',
            mode: FileMode.append,
          );
        }
      } else if (command.commandId == testCmd.id) {
        final response = command.response;
        if (response is TestStatusResponse) {
          logger.info('[TEST STATUS]: ${command.message}');
          if (response.complete == true) {
            logger.info('[TEST COMPLETE]: ${command.success}');
            if (tests.isNotEmpty == true) {
              testCmd = RunTestCommand(
                sendScreenshots: false,
                test: tests.removeAt(0),
              );
              comm.sendCommand(testCmd);
            } else {
              comm.sendCommand(releaseCmd);
              completer.complete();
            }
          }
        } else if (response is ScreenshotResponse) {
          final hash = sha256.convert(response.image).toString();
          final file = File(
            'output/${device}/${hex.encode(utf8.encode(testCmd.test.id))}/screenshots/$hash.png',
          );

          file.createSync(recursive: true);
          file.writeAsBytesSync(response.image);
        }
      } else if (command.commandId == ssCmd.id) {
        final response = command.response;
        if (response is ScreenshotResponse) {
          final dt = DateTime.now().millisecondsSinceEpoch;
          final file = File(
            'output/${device}/${hex.encode(utf8.encode(testCmd.test.id))}/screens/$dt.png',
          );

          file.createSync(recursive: true);
          file.writeAsBytesSync(response.image);
        }
      }
    }
  });
  await comm.sendCommand(reserveCmd);

  final timer = Timer(const Duration(minutes: 10), () {
    completer.completeError('TIMEOUT');
  });

  try {
    await completer.future;
    timer.cancel();
    exit(0);
  } catch (e) {
    logger.severe(e);
    exit(1);
  }
}
