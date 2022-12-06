import 'dart:async';
import 'dart:convert';

import 'package:automated_testing_framework_models/automated_testing_framework_models.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Communicator suited for test drivers to be able to communicate with devices
/// via the command and control server provided by the
/// https://pub.dev/packages/automated_testing_framework_server_websocket
/// package.
///
/// Once constructed, the communicator must then be activated through the
/// [activate] function.
class WebSocketTestDriverCommunicator {
  /// The communicator that can be used by applications to drive test devices
  /// via the websocket server.
  ///
  /// The [appIdentifier] must match either the application's build time package
  /// identifier, or more ideally, the value past into the application at
  /// startup via [TestAppSettings.initialize].
  ///
  /// The [driverId] is optional and will default to a random UUID if not set.
  ///
  /// The [driverName] is intended to be a human readable display value to allow
  /// members of a team to see who is utilizing which devices.
  ///
  /// The [logger] is an optional logger that an application may pass in to have
  /// the log events go via a custom logger rather than a class default one.
  ///
  /// The [maxConnectionTime] describes the maxiumum amount of time the
  /// communicator may remain connected to the server before it should
  /// disconnect and reconnect.  Many hosted websocket servers only allow a
  /// limited amount of time that a websocket can be open before requiring a
  /// reconnect.  Use an arbitrarily large value to effectively mean "forever".
  ///
  /// The [pingTime] describes how long to wait between pings to the server.
  ///
  /// The [secret] is the driver secret or pre-shared-key that has been loaded
  /// on the server.  This key will be used to generate and respond to HMAC
  /// based authentication challenges to authenticate with the server.
  ///
  /// The [url] is the websocket based URL of the server.
  WebSocketTestDriverCommunicator({
    required this.appIdentifier,
    String? driverId,
    required this.driverName,
    Logger? logger,
    this.maxConnectionTime = const Duration(minutes: 30),
    this.pingTime = const Duration(seconds: 30),
    required String secret,
    required this.url,
  })  : assert(secret.isNotEmpty == true),
        driverId = driverId ?? const Uuid().v4(),
        _logger = logger ?? Logger('WebSocketTestDriverCommunicator'),
        _secret = secret;

  /// The app identifier.  This may or may not be the "package" used by the
  /// build.  Ideally as apps may have multiple packages for testing though, it
  /// is a specific unique identifier for the application that is passed in to
  /// the application via [TestAppSettings.initialize].
  final String appIdentifier;

  /// The unique identifier of the driver.  This defaults to being a UUID value
  /// but may be specified by the driving application.
  final String driverId;

  /// The human readable name of the driver.  This is not used by the system
  /// directly but is rather provided by the system for team members to be able
  /// to see who is currently utilizing which connected device.
  final String driverName;

  /// The maximum amount of time the communicator can be connected to the
  /// server for each connected sessions.  After this time expires, the
  /// communicator will disconnect from the server and immediately attempt to
  /// reconnect to resume the session.
  final Duration maxConnectionTime;

  /// The amount of time between sending ping commands to inform the server that
  /// this driver is still active and processing commands.
  final Duration pingTime;

  /// The websocket URL for the backend server.
  final String url;

  final List<DeviceCommand> _commandQueue = [];
  final Logger _logger;
  final String _secret;

  bool _active = false;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubscription;
  StreamController<DeviceCommand>? _commandStreamController;
  Timer? _commandTimer;
  bool deactivated = false;
  bool _online = false;
  Future<void> Function(bool)? _onConnectionChanged;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  Timer? _timer;

  /// Returns whether or not the communicator is currently active.
  bool get active => _active == true;

  /// Provides a stream of commands that an application can listen to in order
  /// to provide their own handlers or actions based off of commands received.
  Stream<DeviceCommand> get commandStream => _commandStreamController!.stream;

  /// Returns whether the communicator is currently connected to the back end.
  /// A communicator may be [active] but not connected either because the back
  /// end is refusing connections or the connection is being (re-)established.
  bool get connected => _channel != null;

  /// A callback that the application may set in order to receive noticies of
  /// when the communication's connectivity status changes.
  set onConnectionChanged(Future<void> Function(bool) onConnectionChanged) =>
      _onConnectionChanged = onConnectionChanged;

  /// Activates the communicator and begins trying to connect to and communicate
  /// with the backend server.
  Future<void> activate() async {
    if (deactivated == true) {
      throw Exception('Communicator has already been deactivated');
    }
    _active = true;

    _commandTimer?.cancel();
    _commandTimer = null;

    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(pingTime, (timer) {
      if (_online == true) {
        sendCommand(PingCommand());
      }
    });

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    await _channelSubscription?.cancel();
    _channelSubscription = null;

    await _commandStreamController?.close();
    _commandQueue.clear();
    _commandStreamController = StreamController<DeviceCommand>.broadcast();

    _connect();
  }

  /// Deactivates the communicator.  Once deactivated
  Future<void> deactivate() async {
    if (!deactivated) {
      deactivated = true;

      try {
        _channel?.sink.add(GoodbyeCommand(complete: true).toString());
      } catch (_) {}

      _active = false;
      await _commandStreamController?.close();
      _commandStreamController = null;
      _commandQueue.clear();

      await _channelSubscription?.cancel();
      _channelSubscription = null;

      _commandTimer?.cancel();
      _commandTimer = null;

      _pingTimer?.cancel();
      _pingTimer = null;

      _reconnectTimer?.cancel();
      _reconnectTimer = null;

      _timer?.cancel();
      _timer = null;

      if (_onConnectionChanged != null) {
        await _onConnectionChanged!(false);
      }
    }
  }

  /// Sends the given [command] to the back end server.  By default the command
  /// will be inserted into the queue and sent after all other previously queued
  /// commands.  Setting the [instant] flag to true will bypass the queue and
  /// send the command immediately.  Howver, instant commands will also be lost
  /// if the communicator is not currently connected.
  Future<void> sendCommand(
    DeviceCommand command, {
    bool instant = false,
  }) async {
    if (_active == true) {
      if (instant == true && _channel != null) {
        _channel!.sink.add(command.toJson());
      } else {
        _commandQueue.add(command);

        await _sendCommands();
      }
    }
  }

  Future<void> _authenticate() async {
    final completer = Completer<void>();

    final salt = DriverSignatureHelper().createSalt();
    AnnounceDriverCommand? challenge = AnnounceDriverCommand(
      appIdentifier: appIdentifier,
      driverId: driverId,
      driverName: driverName,
      salt: salt,
    );

    var challengeResponded = false;
    var signatureVerified = false;

    final sub = _channel!.stream.listen(
      (data) {
        try {
          final cmd = DeviceCommand.fromDynamic(json.decode(data));

          if (cmd is ChallengeCommand) {
            final signature = DriverSignatureHelper().createSignature(_secret, [
              cmd.salt,
              cmd.timestamp.millisecondsSinceEpoch.toString(),
            ]);

            _channel!.sink.add(
              ChallengeResponseCommand(
                commandId: cmd.id,
                signature: signature,
              ).toString(),
            );
            _logger.fine('[CONNECTED]: challenge response sent');
            challengeResponded = true;
          } else if (challenge == null) {
            _commandStreamController?.add(cmd);
          } else if (Duration(
                      milliseconds: DateTime.now().millisecondsSinceEpoch -
                          challenge!.timestamp.millisecondsSinceEpoch)
                  .inSeconds >=
              120) {
            throw Exception('Timeout waiting for challenge response');
          } else if (cmd is ChallengeResponseCommand &&
              cmd.commandId == challenge!.id) {
            final signature = DriverSignatureHelper().createSignature(_secret, [
              challenge!.salt,
              challenge!.timestamp.millisecondsSinceEpoch.toString(),
            ]);

            if (signature == cmd.signature) {
              challenge = null;
              signatureVerified = true;
            }
          }

          if (signatureVerified == true &&
              challengeResponded == true &&
              _online == false) {
            _online = true;
            if (_onConnectionChanged != null) {
              _onConnectionChanged!(true);
            }
          }
        } catch (e, stack) {
          _logger.severe(
            'Error attempting to connect / authenticate.',
            e,
            stack,
          );
          _channelSubscription?.cancel();
          _channelSubscription = null;
          _connect();
        }
      },
      onDone: () {
        _logger.info('[CLOSE]: onDone called');
        if (_online == true && active == true) {
          _connect();
        }
      },
      onError: (e, stack) {
        _logger.severe('Error attempting to connect / authenticate.', e, stack);
        if (_online == true && active == true) {
          _connect();
        }
      },
    );
    await _channelSubscription?.cancel();
    _channelSubscription = sub;

    Timer? timer;
    try {
      final startTime = DateTime.now();
      timer = Timer.periodic(const Duration(seconds: 60), (_) {
        if (Duration(
                    milliseconds: DateTime.now().millisecondsSinceEpoch -
                        startTime.millisecondsSinceEpoch)
                .inSeconds >=
            300) {
          timer?.cancel();
          timer = null;

          _connect();
        } else {
          final salt = DriverSignatureHelper().createSalt();
          challenge = AnnounceDriverCommand(
            appIdentifier: appIdentifier,
            driverId: driverId,
            driverName: driverName,
            salt: salt,
          );

          _channel?.sink.add(challenge.toString());
        }
      });
      _channel?.sink.add(challenge.toString());
    } catch (e) {
      await sub.cancel();
      _channel = null;
      _connect();
    } finally {
      timer?.cancel();
    }

    return completer.future;
  }

  void _connect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _online = false;
    try {
      await _channel?.sink.close();
    } catch (e) {
      // no-op
    }
    _channel = null;
    await _channelSubscription?.cancel();
    _channelSubscription = null;

    if (_onConnectionChanged != null) {
      await _onConnectionChanged!(false);
    }

    if (active == true) {
      try {
        final uri = Uri.parse(url);
        final channel = await WebSocketChannel.connect(uri);
        _channel = channel;
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(maxConnectionTime, () {
          try {
            _channel!.sink.add(GoodbyeCommand(complete: false).toString());
            _logger.info('[RECONNECT]: sent goodbye');
          } catch (e) {
            _logger.info('[RECONNECT]: unable to say goodbye');
          }

          _connect();
        });

        await _authenticate();
        if (_channel != null) {
          _online = true;
          await _sendCommands();
        }
      } catch (e, stack) {
        _logger.severe('[ERROR]: connection error', e, stack);
        _online = false;
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(const Duration(seconds: 1), () => _connect());
      }
    }
  }

  Future<void> _sendCommands() async {
    if (active == true && _commandQueue.isNotEmpty == true) {
      var delay = const Duration(milliseconds: 100);
      if (_online == true) {
        delay = Duration.zero;

        final command = _commandQueue.removeAt(0);
        try {
          _channel!.sink.add(command.toString());
          _logger.finer('[SEND COMMAND]: command sent: [${command.type}]');
        } catch (e) {
          _logger.fine(
            '[SEND COMMAND]: error sending command, retrying in 1 second.',
          );
          delay = const Duration(seconds: 1);
        }
      }

      if (_commandQueue.isNotEmpty == true) {
        _commandTimer?.cancel();
        _commandTimer = Timer(delay, () {
          _sendCommands();
        });
      }
    } else {
      _commandTimer?.cancel();
      _commandTimer = null;
    }
  }
}
