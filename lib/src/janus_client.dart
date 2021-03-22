import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/io.dart';

import '../janus_client.dart';
import 'janus_message.dart';
import 'obtain_transaction_id.dart';
import 'plugin.dart';
import 'rtc_ice_server.dart';
import 'utils.dart';
import 'web_rtc_handle.dart';

/// Main Class for setting up janus server connection details and important methods for interacting with janus server
class JanusClient {
  /// Instance of JanusClient is Starting point of any WebRTC operations with janus WebRTC gateway
  /// refreshInterval is by default 50, make sure this value is less than session_timeout in janus configuration
  /// value greater than session_timeout might lead to session being destroyed and can cause general functionality to fail
  /// maxEvent property is an optional value whose function is to specify maximum number of events fetched using polling in rest/http mechanism by default it fetches 10 events in a single api call
  JanusClient({
    required this.server,
    required this.iceServers,
    this.refreshInterval = 50,
    this.apiSecret,
    this.token,
    this.maxEvent = 10,
    this.withCredentials = false,
  });

  final String server;
  final String? apiSecret;
  final String? token;
  final bool withCredentials;
  final int maxEvent;
  final List<RtcIceServer> iceServers;
  final int refreshInterval;

  static const _tag = "Janus";

  Timer? _keepAliveTimer;
  bool _connected = false;
  int? _sessionId;

  final _obtainTransactionId = ObtainTransactionId();
  final _transactions = <String, void Function(JanusMessage)>{};
  final _pluginHandles = <int, Plugin>{};

  Map<String, Object?> get _apiMap => withCredentials
      ? apiSecret != null
          ? {"apisecret": apiSecret}
          : const {}
      : const {};

  Map<String, Object?> get _tokenMap => withCredentials
      ? token != null
          ? {"token": token}
          : const {}
      : const {};

  IOWebSocketChannel? _webSocketChannel;

  bool get isConnected => _connected;

  int? get sessionId => _sessionId;

  /// Generates sessionId and returns it as callback value in onSuccess Function, whereas in case of any connection errors is thrown in onError callback if provided.
  Future<void> connect() async {
    if (!server.startsWith('ws') && !server.startsWith('wss')) {
      throw UnsupportedError('Only supports ws/wss interface');
    }
    _connected = false;
    final transaction = _obtainTransactionId.next();
    final webSocketChannel = IOWebSocketChannel.connect(
      server,
      protocols: ['janus-protocol'],
      pingInterval: const Duration(seconds: 2),
    );
    _webSocketChannel = webSocketChannel;
    final completer = Completer<void>();
    webSocketChannel.stream.listen((dynamic s) {
      assert(log(_tag, "Event: $s"));
      final data = parse(s as String);
      _handleEvent(JanusMessage(data));
    });
    _transactions[transaction] = (data) {
      if (data.janus == "success") {
        _sessionId = data.data["data"]["id"] as int;
        _connected = true;
        _keepAlive();
        completer.complete();
      } else {
        assert(log(_tag, "Janus exception: $data"));
        completer.completeError(JanusResponseException(data));
      }
    };

    webSocketChannel.sink.add(stringify({
      "janus": "create",
      "transaction": transaction,
      ..._apiMap,
      ..._tokenMap
    }));
    return completer.future;
  }

  /// cleans up rest polling timer or WebSocket connection if used.
  void destroy() {
    _keepAliveTimer?.cancel();
    _webSocketChannel?.sink.close();
    _pluginHandles.clear();
    _transactions.clear();
    _sessionId = null;
    _connected = false;
  }

  void _keepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(
      Duration(seconds: refreshInterval),
      (timer) async {
        try {
          _webSocketChannel?.sink.add(stringify({
            "janus": "keepalive",
            "session_id": _sessionId,
            "transaction": _obtainTransactionId.next(),
            ..._apiMap,
            ..._tokenMap
          }));
        } on Exception catch (e) {
          assert(log(_tag, "Keep alive error", e));
          timer.cancel();
        }
      },
    );
  }

  /*
  * // According to this [Issue](https://github.com/meetecho/janus-gateway/issues/124) we cannot change Data channel Label
  * */
  static const dataChannelDefaultLabel = "JanusDataChannel";

  /// Attach Plugin to janus instance, for any project you need single janus instance to which you can attach any number of supported plugin
  Future<Plugin> attach({
    required String name,
    OnMessageReceived? onMessage,
    Function(dynamic, bool)? onLocalTrack,
    Function(dynamic, dynamic, dynamic, bool)? onRemoteTrack,
    OnLocalStreamReceived? onLocalStream,
    OnRemoteStreamReceived? onRemoteStream,
    OnDataChannelStatusChanged? onDataOpen,
    OnDataMessageReceived? onData,
    OnIceConnectionState? onIceConnectionState,
    OnWebRTCStateChanged? onWebRTCState,
    VoidCallback? onDetached,
    VoidCallback? onDestroy,
    OnMediaState? onMediaState,
  }) async {
    final channel = _webSocketChannel;
    if (channel == null) {
      throw StateError("Janus client has not been initialized");
    }
    final transaction = _obtainTransactionId.next();
    final request = <String, Object?>{
      "janus": "attach",
      "plugin": name,
      "transaction": transaction,
      "token": token,
      "apisecret": apiSecret,
      "session_id": sessionId,
    };
    final configuration = <String, Object?>{
      "iceServers": iceServers.map((e) => e.toMap()).toList(),
      'sdpSemantics': 'plan-b',
    };
    final peerConnection =
        await createPeerConnection(configuration, const <String, Object?>{});
    final webRTCHandle = WebRTCHandle(peerConnection: peerConnection);
    final plugin = Plugin(
      plugin: name,
      webRTCHandle: webRTCHandle,
      obtainTransactionId: _obtainTransactionId,
      apiSecret: apiSecret,
      sessionId: _sessionId!,
      token: token,
      pluginHandles: _pluginHandles,
      transactions: _transactions,
      sink: channel.sink,
      onMessage: onMessage,
      onDataChannelStatus: onDataOpen,
      onDataMessage: onData,
      onMediaState: onMediaState,
      onRemoteTrack: onRemoteTrack,
      onDetached: onDetached,
      onDestroy: onDestroy,
    );

    onLocalStream?.call(peerConnection.getLocalStreams());

    peerConnection.onAddStream = (stream) {
      onRemoteStream?.call(stream);
    };

    peerConnection.onConnectionState = (state) {
      onWebRTCState?.call(state);
    };

    peerConnection.onIceCandidate = (candidate) async {
      if (!name.contains('textroom')) {
        assert(log(_tag, 'sending trickle'));
        final request = <String, Object?>{
          "janus": "trickle",
          "candidate": candidate.toMap(),
          "transaction": _obtainTransactionId.next(),
          "session_id": sessionId,
          "handle_id": plugin.handleId,
          "apisecret": apiSecret,
          "token": token,
        };
        channel.sink.add(stringify(request));
      }
    };

    final completer = Completer<Plugin>();
    _transactions[transaction] = (data) {
      if (data.janus != "success") {
        completer.completeError(JanusResponseException(data));
      } else {
        final handleId = (data.data["data"] as Map)["id"] as int;
        assert(log(_tag, "Created handle: $handleId"));
        plugin.handleId = handleId;
        _pluginHandles[handleId] = plugin;
        completer.complete(plugin);
      }
    };

    channel.sink.add(stringify(request));
    return completer.future;
  }

  void _handleEvent(JanusMessage message) {
    final janus = message.janus;
    if (janus == "ack" || janus == "keepalive") {
      assert(log(_tag, "always ignore $janus"));
      return;
    }
    if (janus == "timeout") {
      assert(log(_tag, "ETimeout on session $sessionId"));
      _webSocketChannel?.sink.close(3504, "Gateway timeout");
      return;
    }
    if (message.transaction != null) {
      final callback = _transactions.remove(message.transaction);
      assert(callback != null, "no transaction ${message.transaction}");
      callback?.call(message);
      return;
    }
    if (janus == "success" || janus == "error") {
      assert(false, "Got $janus event but lacks transaction somewhere");
      return;
    }
    if (message.sender == null) {
      assert(log(_tag, "missing sender ${message.sender}"));
      return;
    }
    final plugin = _pluginHandles[message.sender];
    if (plugin == null) {
      assert(log(_tag, "no plugin handle for ${message.sender}"));
      return;
    }
    assert(log(_tag, "forward event $janus to ${plugin.plugin}"));

    switch (janus) {
      case "trickle":
        // We got a trickle candidate from Janus
        final candidate = message.data["candidate"] as Map;
        assert(log(_tag, "Got a trickled candidate on session $sessionId"));
        final config = plugin.webRTCHandle;
        if (!plugin.plugin.contains('textroom')) {
          // Add candidate right now
          assert(log(_tag, "adding remote candidate: $candidate"));
          if (candidate.containsKey("sdpMid") &&
              candidate.containsKey("sdpMLineIndex") &&
              !plugin.plugin.contains('textroom')) {
            config.peerConnection.addCandidate(RTCIceCandidate(
              candidate["candidate"] as String,
              candidate["sdpMid"] as String,
              candidate["sdpMLineIndex"] as int,
            ));
          }
        } else {
          assert(false,
              "We didn't do setRemoteDescription (trickle got here before the offer?), caching candidate");
        }
        break;
      case "webrtcup":
      case "slowlink":
        break;
      case "hangup":
        _pluginHandles.remove(message.sender);
        plugin.onDestroy?.call();
        break;
      case "detached":
        // A plugin asked the core to detach one of our handles
        plugin.onDetached?.call();
        break;
      case "media":
        // Media started/stopped flowing
        assert(log(_tag, "got a media event on session $sessionId"));
        plugin.onMediaState?.call(message.data["type"],
            message.data["receiving"], message.data["mid"]);
        break;
      case "event":
        final plugindata = message.pluginData;
        if (plugindata == null) {
          assert(log(_tag, "missing plugindata..."));
          return;
        }
        final callback = plugin.onMessage;
        if (callback == null) {
          assert(log(_tag, "No provided notification callback"));
          return;
        }
        callback(plugindata.data, message.jsep);
        break;
      default:
        assert(log(_tag, "unknown event $janus"));
        break;
    }
  }
}
