import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:automated_testing_framework_driver_websocket/driver.dart';
import 'package:automated_testing_framework_models/automated_testing_framework_models.dart';
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
    help: 'The application identifier.',
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
    'url',
    abbr: 'u',
    help: 'Websocket URL for the server.',
  );

  parser.addFlag('help', abbr: 'h');
  final results = parser.parse(args);

  if (results['help'] == true) {
    // ignore: avoid_print
    print('''
Usage: run [<options>]

Starts the websocket server for the testing framework.

-a, --app=<app-identifier>     The application identifier.
-d, --driver=<driver-name>     The name of the driver.
-h, --help                     Display this help message.
-s, --secret=<port>            Secret text for communicating with the server.
-u, --url                      Websocket URL for the server.

Optionally, environmental variables can be used to set the following args:

ATF_APP_IDENTIFIER             The application identifier
ATF_DRIVER_NAME                The name of the driver.
ATF_WEBSOCKET_URL              Websocket URL for the server.
''');

    exit(0);
  }

  var secrets = {};
  final secretsFile = File('secret/keys.json');
  if (secretsFile.existsSync() == true) {
    try {
      final data = json.decode(secretsFile.readAsStringSync());
      secrets = data;
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

  final url = results['url'] ??
      secrets['url'] ??
      Platform.environment['ATF_WEBSOCKET_URL'];
  if (url?.isNotEmpty != true) {
    logger.severe(
      'Environment variable "ATF_WEBSOCKET_URL" not found, and [url] arg not set.',
    );
    exit(1);
  }

  logger.info('''
Parameters:
  * app: [$appIdentifier]
  * driverName: [$driverName]
  * url: [$url]

''');

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

  final cmd = ListDevicesCommand();
  final completer = Completer();
  comm.commandStream.listen((command) {
    if (command is CommandAck && command.commandId == cmd.id) {
      final response = command.response;
      if (response is ListDevicesResponse) {
        final devices = response.devices;
        var count = 0;
        for (var device in devices) {
          count++;
          logger.info(
            '$count: ${device.device.id} | ${device.device.device} | ${device.device.model} | ${device.device.os} | <${device.driverName}>',
          );
        }

        if (count == 0) {
          logger.info('No devices available');
        }

        completer.complete();
      } else {
        completer.completeError(
          '[ERROR]: unknown response type: ${response?.runtimeType.toString()}',
        );
      }
    }
  });
  await comm.sendCommand(cmd);

  final timer = Timer(const Duration(seconds: 10), () {
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
