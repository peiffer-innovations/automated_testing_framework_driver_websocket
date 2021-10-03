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

  var parser = ArgParser();
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
  var results = parser.parse(args);

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

  var device = results['device'];
  if (device?.isNotEmpty != true) {
    logger.severe(
      'No device set.',
    );
    exit(1);
  }

  var secrets = {};
  var secretsFile = File('secret/keys.json');
  if (secretsFile.existsSync() == true) {
    try {
      var data = json.decode(secretsFile.readAsStringSync());
      secrets['driver'] = data['driver'];
    } catch (e) {
      // no-op
    }
  }

  var appIdentifier = results['app'] ??
      secrets['app'] ??
      Platform.environment['ATF_APP_IDENTIFIER'] ??
      'default';

  var driverName = results['driver'] ??
      Platform.environment['ATF_DRIVER_NAME'] ??
      Platform.localHostname;

  var secret = results['secret'] ??
      secrets['driver'] ??
      Platform.environment['ATF_DRIVER_SECRET'];
  if (secret?.isNotEmpty != true) {
    logger.severe(
      'Environment variable "ATF_DRIVER_SECRET" not found, and [secret] arg not set.',
    );
    exit(1);
  }

  var testPath = results['test'];
  if (testPath?.isNotEmpty != true) {
    logger.severe('No test set');
    exit(1);
  }

  var tests = <Test>[];
  if (FileSystemEntity.isDirectorySync(testPath)) {
    var dir = Directory(testPath);
    for (var file in dir.listSync()) {
      if (file is File) {
        tests.add(Test.fromDynamic(json.decode(file.readAsStringSync())));
      }
    }
  } else if (FileSystemEntity.isFileSync(testPath)) {
    var file = File(testPath);
    tests.add(Test.fromDynamic(json.decode(file.readAsStringSync())));
  } else {
    logger.severe('Unable to locate test file: $testPath');
    exit(1);
  }

  if (tests.isNotEmpty != true) {
    logger.severe('Unable to load data for test(s): $testPath');
    exit(1);
  }

  var url = results['url'] ??
      secrets['url'] ??
      Platform.environment['ATF_WEBSOCKET_URL'];
  if (url?.isNotEmpty != true) {
    logger.severe(
      'Environment variable "ATF_WEBSOCKET_URL" not found, and [url] arg not set.',
    );
    exit(1);
  }

  var output = Directory('output/$device');
  try {
    output.deleteSync(recursive: true);
  } catch (e) {
    // no-op
  }
  output.createSync(recursive: true);

  var comm = WebSocketTestDriverCommunicator(
    appIdentifier: appIdentifier ?? 'default',
    driverName: driverName,
    secret: secret,
    url: url,
  );

  comm.onConnectionChanged =
      (connected) async => logger.fine('[CONNECTED]: $connected');
  await comm.activate();
  logger.info('[ACTIVATED]');

  var reserveCmd = ReserveDeviceCommand(
    deviceId: device,
    driverName: driverName,
  );
  var logCmd = StartLogStreamCommand();
  var ssCmd = StartScreenshotStreamCommand();
  var testCmd = RunTestCommand(sendScreenshots: false, test: tests.removeAt(0));
  var releaseCmd = ReleaseDeviceCommand(deviceId: device);

  var completer = Completer();
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
        var response = command.response;
        if (response is LogResponse) {
          var file = File(
            'output/${device}/${hex.encode(utf8.encode(testCmd.test.id))}.log',
          );
          file.createSync(recursive: true);

          var record = response.record;
          file.writeAsString(
            '${record.level.name}: ${record.time}: [${record.loggerName}]: ${record.message}\n',
            mode: FileMode.append,
          );
        }
      } else if (command.commandId == testCmd.id) {
        var response = command.response;
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
          var hash = sha256.convert(response.image).toString();
          var file = File(
            'output/${device}/${hex.encode(utf8.encode(testCmd.test.id))}/screenshots/$hash.png',
          );

          file.createSync(recursive: true);
          file.writeAsBytesSync(response.image);
        }
      } else if (command.commandId == ssCmd.id) {
        var response = command.response;
        if (response is ScreenshotResponse) {
          var dt = DateTime.now().millisecondsSinceEpoch;
          var file = File(
            'output/${device}/${hex.encode(utf8.encode(testCmd.test.id))}/screens/$dt.png',
          );

          file.createSync(recursive: true);
          file.writeAsBytesSync(response.image);
        }
      }
    }
  });
  await comm.sendCommand(reserveCmd);

  var timer = Timer(Duration(minutes: 10), () {
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
