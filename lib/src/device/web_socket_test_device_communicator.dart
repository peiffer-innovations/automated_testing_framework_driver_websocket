import 'dart:async';
import 'dart:convert';

import 'package:automated_testing_framework_models/automated_testing_framework_models.dart';
import 'package:logging/logging.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class WebSocketTestDeviceCommunicator extends TestDeviceCommunicator {
  WebSocketTestDeviceCommunicator({
    this.maxConnectionTime = const Duration(minutes: 30),
    this.pingTime = const Duration(seconds: 30),
    this.reconnectDelay = const Duration(seconds: 1),
    required String secret,
    required TestControllerState testControllerState,
    required this.url,
  })   : assert(secret.isNotEmpty == true),
        _secret = secret,
        _testControllerState = testControllerState;

  static final Logger _logger = Logger('WebSocketTestDeviceCommunicator');

  final Duration maxConnectionTime;
  final Duration pingTime;
  final Duration reconnectDelay;
  final String url;

  final List<DeviceCommand> _commandQueue = [];
  final String _secret;
  final TestControllerState _testControllerState;

  bool _active = false;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSubscription;
  StreamController<DeviceCommand>? _commandStreamController;
  Timer? _commandTimer;
  late Future<TestDeviceInfo> Function() _testDeviceInfoBuilder;
  bool _online = false;
  ConnectionChangedCallback? _onConnectionChanged;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  Timer? _timer;

  @override
  bool get active => _active == true;

  @override
  Stream<DeviceCommand> get commandStream => _commandStreamController!.stream;

  @override
  bool get connected => _channel != null;

  @override
  set onConnectionChanged(ConnectionChangedCallback onConnectionChanged) =>
      _onConnectionChanged = onConnectionChanged;

  @override
  Future<void> activate(
    Future<TestDeviceInfo> Function() testDeviceInfoBuilder,
  ) async {
    _testDeviceInfoBuilder = testDeviceInfoBuilder;
    _active = true;

    _commandTimer?.cancel();
    _commandTimer = null;

    _pingTimer?.cancel();

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    await _channelSubscription?.cancel();
    _channelSubscription = null;

    await _commandStreamController?.close();
    _commandQueue.clear();
    _commandStreamController = StreamController<DeviceCommand>.broadcast();

    await _connect();
  }

  @override
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
      await _onConnectionChanged!(this, false);
    }
  }

  @override
  Future<void> sendCommand(DeviceCommand command) async {
    if (_active == true) {
      _commandQueue.add(command);

      _sendCommands();
    }
  }

  Future<void> _authenticate() async {
    Completer? completer = Completer<void>();
    var device = await _testDeviceInfoBuilder();

    var salt = DriverSignatureHelper().createSalt();
    AnnounceDeviceCommand? challenge = AnnounceDeviceCommand(
      device: device,
      salt: salt,
      testControllerState: _testControllerState,
    );

    var challengeResponded = false;
    var signatureVerified = false;

    var sub = _channel?.stream.listen(
      (data) {
        try {
          var cmd = DeviceCommand.fromDynamic(json.decode(data));

          if (cmd is ChallengeCommand) {
            var signature = DriverSignatureHelper().createSignature(_secret, [
              cmd.salt,
              cmd.timestamp.millisecondsSinceEpoch.toString(),
            ]);

            _channel?.sink.add(
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
                          challenge!.timestamp.millisecondsSinceEpoch)
                  .inSeconds >=
              120) {
            throw Exception('Timeout waiting for challenge response');
          } else if (cmd is ChallengeResponseCommand &&
              cmd.commandId == challenge!.id) {
            var signature = DriverSignatureHelper().createSignature(_secret, [
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
              _onConnectionChanged!(this, true);
            }
            _pingTimer?.cancel();
            _pingTimer = Timer.periodic(pingTime, (timer) {
              if (_online == true) {
                sendCommand(
                  PingCommand(
                    testControllerState: _testControllerState,
                    testDeviceInfo: TestDeviceInfo.instance,
                  ),
                );
              }
            });

            completer?.complete();
            completer = null;
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
        _online = false;
        _channel = null;
        _pingTimer?.cancel();
        _pingTimer = null;
        completer?.complete();
        completer = null;

        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(reconnectDelay, () {
          if (active == true) {
            _logger.info('[RECONNECT]: attempting to reconnect to the server');
            _connect();
          }
        });
      },
      onError: (e, stack) {
        completer?.completeError(e, stack);
        completer = null;
        _online = false;
        _channel = null;
        _pingTimer?.cancel();
        _pingTimer = null;
        _logger.severe('Error attempting to connect / authenticate.', e, stack);
      },
    );
    _channelSubscription = sub;

    Timer? timer;
    try {
      var startTime = DateTime.now();
      timer = Timer.periodic(Duration(seconds: 60), (_) {
        if (Duration(
                    milliseconds: DateTime.now().millisecondsSinceEpoch -
                        startTime.millisecondsSinceEpoch)
                .inSeconds >=
            120) {
          timer?.cancel();
          timer = null;

          _connect();
        }
      });
      _channel!.sink.add(challenge.toString());
    } catch (e) {
      await sub?.cancel();
      _channel = null;
      await Future.delayed(reconnectDelay).then((value) {
        if (active == true) {
          _connect();
        }
      });
    } finally {
      timer?.cancel();
    }

    return completer!.future;
  }

  Future<void> _connect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _online = false;
    try {
      if (_channel != null) {
        _logger.info('[CLOSE]: closing due to reconnect');
      }
      await _channel?.sink.close();
    } catch (e) {
      // no-op
    }

    await _channelSubscription?.cancel();
    _channelSubscription = null;
    _channel = null;

    if (_onConnectionChanged != null) {
      await _onConnectionChanged!(this, false);
    }

    if (active == true) {
      try {
        var uri = Uri.parse(url);
        var channel = await WebSocketChannel.connect(uri);
        _channel = channel;
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(maxConnectionTime, () => _connect());

        await _authenticate();
        if (_channel != null) {
          _online = true;
          _sendCommands();
        }
      } catch (e, stack) {
        _logger.severe('[ERROR]: connection error', e, stack);
        _online = false;
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(Duration(seconds: 1), () => _connect());
      }
    }
  }

  void _sendCommands() {
    if (active == true && _commandQueue.isNotEmpty == true) {
      var delay = Duration(seconds: 1);
      if (_channel?.closeCode == null) {
        delay = Duration.zero;

        var command = _commandQueue.removeAt(0);
        _channel?.sink.add(command.toString());
        if (command is! CommandAck) {
          // Don't log out ACK's because if the log streaming is active, this
          // will actually create an infinite loop because we'd be logging that
          // we logged the sent and repeat.
          _logger.info('[SEND COMMAND]: command sent: [${command.type}]');
        }
      } else {
        _logger.info('[SEND COMMAND]: offline, waiting.');
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
