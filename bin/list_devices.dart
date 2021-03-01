import 'dart:async';
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

  var parser = ArgParser();
  parser.addOption(
    'app',
    abbr: 'a',
    help: 'Application identifier.',
  );
  parser.addOption(
    'driver',
    abbr: 'd',
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
    help: 'URL for the server.',
  );
  var results = parser.parse(args);

  var appIdentifier =
      results['app'] ?? Platform.environment['ATF_APP_IDENTIFIER'] ?? 'default';

  var driverName = results['driver'] ??
      Platform.environment['ATF_DRIVER_NAME'] ??
      Platform.localHostname;

  var secret = results['secret'] ?? Platform.environment['ATF_DRIVER_SECRET'];
  if (secret?.isNotEmpty != true) {
    logger.severe(
      'Environment variable "ATF_DRIVER_SECRET" not found, and [secret] arg not set.',
    );
    exit(1);
  }

  var url = results['url'] ?? Platform.environment['ATF_WEBSOCKET_URL'];
  if (url?.isNotEmpty != true) {
    logger.severe(
      'Environment variable "ATF_WEBSOCKET_URL" not found, and [url] arg not set.',
    );
    exit(1);
  }

  var comm = WebSocketTestDriverCommunicator(
    appIdentifier: appIdentifier ?? 'default',
    driverName: driverName,
    secret: secret,
    url: url,
  );

  comm.onConnectionChanged =
      (connected) async => logger.info('[CONNECTED]: $connected');
  await comm.activate();
  logger.info('[ACTIVATED]');

  var cmd = ListDevicesCommand();
  var completer = Completer();
  comm.commandStream.listen((command) {
    if (command is CommandAck && command.commandId == cmd.id) {
      var response = command.response;
      if (response is ListDevicesResponse) {
        var devices = response.devices;
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
          '[ERROR]: unknown response type: ${response?.runtimeType?.toString()}',
        );
      }
    }
  });
  await comm.sendCommand(cmd);

  var timer = Timer(Duration(seconds: 10), () {
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
