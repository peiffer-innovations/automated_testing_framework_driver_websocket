import 'dart:async';

import 'dart:convert';

import 'package:automated_testing_framework_models/automated_testing_framework_models.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class WebSocketTestDriverCommunicator {
  WebSocketTestDriverCommunicator({
    @required this.appIdentifier,
    String driverId,
    @required this.driverName,
    this.maxConnectionTime = const Duration(minutes: 30),
    this.pingTime = const Duration(seconds: 15),
    @required String secret,
    @required this.url,
  })  : assert(appIdentifier != null),
        assert(driverName != null),
        assert(secret?.isNotEmpty == true),
        assert(url != null),
        driverId = driverId ?? Uuid().v4(),
        _secret = secret;

  static final Logger _logger = Logger('WebSocketTestDriverCommunicator');

  final String appIdentifier;
  final String driverId;
  final String driverName;
  final Duration maxConnectionTime;
  final Duration pingTime;
  final String url;

  final List<DeviceCommand> _commandQueue = [];
  final String _secret;

  bool _active = false;
  WebSocketChannel _channel;
  StreamSubscription<dynamic> _channelSubscription;
  StreamController<DeviceCommand> _commandStreamController;
  Timer _commandTimer;
  bool _online = false;
  Future<void> Function(bool) _onConnectionChanged;
  Timer _pingTimer;
  Timer _reconnectTimer;
  Timer _timer;

  bool get active => _active == true;

  Stream<DeviceCommand> get commandStream => _commandStreamController?.stream;

  bool get connected => _channel != null;

  set onConnectionChanged(Future<void> Function(bool) onConnectionChanged) =>
      _onConnectionChanged = onConnectionChanged;

  Future<void> activate() async {
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

  Future<void> deactivate() async {
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
      await _onConnectionChanged(false);
    }
  }

  Future<void> sendCommand(DeviceCommand command) async {
    if (_active == true) {
      _commandQueue.add(command);

      await _sendCommands();
    }
  }

  Future<void> _authenticate() async {
    var completer = Completer<void>();

    var salt = DriverSignatureHelper().createSalt();
    var challenge = AnnounceDriverCommand(
      appIdentifier: appIdentifier,
      driverId: driverId,
      driverName: driverName,
      salt: salt,
    );

    var challengeResponded = false;
    var signatureVerified = false;

    var sub = _channel.stream.listen(
      (data) {
        try {
          var cmd = DeviceCommand.fromDynamic(json.decode(data));

          if (cmd is ChallengeCommand) {
            var signature = DriverSignatureHelper().createSignature(_secret, [
              cmd.salt,
              cmd.timestamp.millisecondsSinceEpoch.toString(),
            ]);

            _channel.sink.add(
              ChallengeResponseCommand(
                commandId: cmd.id,
                signature: signature,
              ).toString(),
            );
            _logger.info('[CONNECTED]: challenge response sent');
            challengeResponded = true;
          } else if (challenge == null) {
            _commandStreamController?.add(cmd);
          } else if (Duration(
                      milliseconds: DateTime.now().millisecondsSinceEpoch -
                          challenge.timestamp.millisecondsSinceEpoch)
                  .inSeconds >=
              120) {
            throw Exception('Timeout waiting for challenge response');
          } else if (cmd is ChallengeResponseCommand &&
              cmd.commandId == challenge.id) {
            var signature = DriverSignatureHelper().createSignature(_secret, [
              challenge.salt,
              challenge.timestamp.millisecondsSinceEpoch.toString(),
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
              _onConnectionChanged(true);
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

    Timer timer;
    try {
      var startTime = DateTime.now();
      timer = Timer.periodic(Duration(seconds: 60), (_) {
        if (Duration(
                    milliseconds: DateTime.now().millisecondsSinceEpoch -
                        startTime.millisecondsSinceEpoch)
                .inSeconds >=
            300) {
          timer?.cancel();
          timer = null;

          _connect();
        } else {
          var salt = DriverSignatureHelper().createSalt();
          challenge = AnnounceDriverCommand(
            appIdentifier: appIdentifier,
            driverId: driverId,
            driverName: driverName,
            salt: salt,
          );

          _channel.sink.add(challenge.toString());
        }
      });
      _channel.sink.add(challenge.toString());
    } catch (e) {
      await sub.cancel();
      _channel = null;
      await _connect();
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
      await _channel?.sink?.add(GoodbyeCommand().toString());
    } catch (e) {
      // no-op
    }
    try {
      await _channel?.sink?.close(200);
    } catch (e) {
      // no-op
    }
    await _channelSubscription?.cancel();
    _channelSubscription = null;
    _channel = null;

    if (_onConnectionChanged != null) {
      await _onConnectionChanged(false);
    }

    if (active == true) {
      try {
        var uri = Uri.parse(url);
        var channel = await WebSocketChannel.connect(uri);
        if (channel != null) {
          _channel = channel;
          _reconnectTimer?.cancel();
          _reconnectTimer = Timer(maxConnectionTime, () => _connect());

          await _authenticate();
          if (_channel != null) {
            _online = true;
            await _sendCommands();
          }
        }
      } catch (e, stack) {
        _logger.severe('[ERROR]: connection error', e, stack);
        _online = false;
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(Duration(seconds: 1), () => _connect());
      }
    }
  }

  Future<void> _sendCommands() async {
    if (active == true && _commandQueue?.isNotEmpty == true) {
      var delay = Duration(milliseconds: 100);
      if (_online == true) {
        delay = Duration.zero;

        var command = _commandQueue.removeAt(0);
        _channel.sink.add(command.toString());
        _logger.info('[SEND COMMAND]: command sent: [${command.type}]');
      }

      if (_commandQueue?.isNotEmpty == true) {
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
