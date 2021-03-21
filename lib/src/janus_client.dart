import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';

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

  static const _uuid = Uuid();
  static const _tag = "Janus";

  Timer? _keepAliveTimer;
  bool _connected = false;
  int? _sessionId;

  final _transactions = <String, void Function(Map data)>{};
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
  Stream<String>? _webSocketStream;

  bool get isConnected => _connected;

  int? get sessionId => _sessionId;

  Future<int> _attemptWebSocket() async {
    _connected = false;
    final transaction = _uuid.v4().replaceAll('-', '');
    final webSocketChannel = IOWebSocketChannel.connect(
      server,
      protocols: ['janus-protocol'],
      pingInterval: const Duration(seconds: 2),
    );
    _webSocketChannel = webSocketChannel;
    // TODO: check type of stream
    _webSocketStream = webSocketChannel.stream.asBroadcastStream().cast();

    webSocketChannel.sink.add(stringify({
      "janus": "create",
      "transaction": transaction,
      ..._apiMap,
      ..._tokenMap
    }));

    final data = parse(await _webSocketStream!.first);
    if (data["janus"] == "success") {
      final sessionId = data["data"]["id"] as int;
      _connected = true;
      _keepAlive();
      _sessionId = sessionId;
      return sessionId;
    } else {
      assert(log(_tag, "Janus exception: $data"));
      // TODO: Make Janus exception
      throw StateError("TODO: ");
    }
  }

  /// Generates sessionId and returns it as callback value in onSuccess Function, whereas in case of any connection errors is thrown in onError callback if provided.
  Future<int> connect() {
    if (server.startsWith('ws') || server.startsWith('wss')) {
      return _attemptWebSocket();
    } else {
      return Future.error(UnsupportedError('Unsupported http/https interface'));
    }
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
            "transaction": _uuid.v4(),
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
  void attach({
    required String name,
    void Function(Plugin plugin)? onSuccess,
    void Function(Object e)? onError,
    OnMessageReceived? onMessage,
    Function(dynamic, bool)? onLocalTrack,
    Function(dynamic, dynamic, dynamic, bool)? onRemoteTrack,
    OnLocalStreamReceived? onLocalStream,
    OnRemoteStreamReceived? onRemoteStream,
    OnDataChannelStatusChanged? onDataOpen,
    OnDataReceived? onData,
    OnIceConnectionState? onIceConnectionState,
    OnWebRTCStateChanged? onWebRTCState,
    VoidCallback? onDetached,
    VoidCallback? onDestroy,
    OnMediaState? onMediaState,
  }) async {
    final stream = _webSocketStream;
    final channel = _webSocketChannel;
    if (stream == null || channel == null) {
      throw StateError("Janus client has not been initialized");
    }
    final transaction = _uuid.v4() + _uuid.v1();
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
      apiSecret: apiSecret,
      sessionId: _sessionId!,
      token: token,
      pluginHandles: _pluginHandles,
      transactions: _transactions,
      webSocketStream: stream,
      webSocketSink: channel.sink,
      onMessage: onMessage,
      onDataOpen: onDataOpen,
      onData: onData,
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
      if (!plugin.plugin.contains('textroom')) {
        debugPrint('sending trickle');
        final request = <String, Object?>{
          "janus": "trickle",
          "candidate": candidate.toMap(),
          "transaction": _uuid.v4(),
          "session_id": plugin.sessionId,
          "handle_id": plugin.handleId,
          "apisecret": plugin.apiSecret,
          "token": plugin.token,
        };
        plugin.webSocketSink.add(stringify(request));
      }
    };

    final opaqueId = plugin.opaqueId;
    if (plugin.opaqueId != null) {
      request["opaque_id"] = opaqueId;
    }
    channel.sink.add(stringify(request));
    _transactions[transaction] = (data) {
      if (data["janus"] != "success") {
        // TODO: post error
        // plugin.onError(
        //     "Ooops: " + data["error"].code + " " + data["error"]["reason"]);
        return null;
      }
      print('attaching plugin success');
      print(data);
      final handleId = (data["data"] as Map)["id"] as int;
      debugPrint("Created handle: " + handleId.toString());
      plugin.handleId = handleId;
      _pluginHandles[handleId] = plugin;
      onSuccess?.call(plugin);
    };

    stream.listen((event) {
      assert(log(_tag, "Event (1): $event"));
      final data = parse(event);
      if (data["janus"] == "ack") {
        // TODO: ignore ACK
        return;
      }
      final transaction = data["transaction"] as String?;
      if (transaction != null) {
        final callback = _transactions.remove(transaction);
        if (callback == null) {
          //throw StateError("No transaction");
        }
        callback?.call(data);
      }
    });

    // It's very strange when we listen every attaching
    stream.listen((event) {
      assert(log(_tag, "Event (2): $event"));
      _handleEvent(plugin, parse(event));
    });
  }

  //counter to try reconnecting in event of network failure
  int _pollingRetries = 0;

  void _handleEvent(Plugin plugin, Map json) {
    if (json["janus"] == "keepalive") {
      // Nothing happened
      debugPrint("Got a keepalive on session " + sessionId.toString());
    } else if (json["janus"] == "ack") {
      // Just an ack, we can probably ignore
      debugPrint("Got an ack on session " + sessionId.toString());
      debugPrint(json.toString());
      final transaction = json["transaction"] as String?;
      if (transaction != null) {
        _transactions[transaction]?.call(json);
//          delete transactions[transaction];
      }
    } else if (json["janus"] == "success") {
      // Success!
      debugPrint("Got a success on session " + sessionId.toString());
      debugPrint(json.toString());
      var transaction = json["transaction"] as String?;
      if (transaction != null) {
        var reportSuccess = _transactions[transaction];
        if (reportSuccess != null) reportSuccess(json);
//          delete transactions[transaction];
      }
    } else if (json["janus"] == "trickle") {
      // We got a trickle candidate from Janus
      var sender = json["sender"] as int?;

      if (sender == null) {
        debugPrint("WMissing sender...");
        return;
      }
      var pluginHandle = _pluginHandles[sender];
      if (pluginHandle == null) {
        debugPrint("This handle is not attached to this session");
        return;
      }
      var candidate = json["candidate"] as Map;
      debugPrint("Got a trickled candidate on session " + sessionId.toString());
      debugPrint(candidate.toString());
      var config = pluginHandle.webRTCHandle;
      if (!plugin.plugin.contains('textroom')) {
        // Add candidate right now
        debugPrint("Adding remote candidate:" + candidate.toString());
        if (candidate.containsKey("sdpMid") &&
            candidate.containsKey("sdpMLineIndex") &&
            !pluginHandle.plugin.contains('textroom')) {
          config.peerConnection.addCandidate(RTCIceCandidate(
            candidate["candidate"] as String,
            candidate["sdpMid"] as String,
            candidate["sdpMLineIndex"] as int,
          ));
        }
      } else {
        // We didn't do setRemoteDescription (trickle got here before the offer?)
        debugPrint(
            "We didn't do setRemoteDescription (trickle got here before the offer?), caching candidate");
      }
    } else if (json["janus"] == "webrtcup") {
      // The PeerConnection with the server is up! Notify this
      debugPrint("Got a webrtcup event on session " + sessionId.toString());
      debugPrint(json.toString());
      var sender = json["sender"] as int?;
      if (sender == null) {
        debugPrint("WMissing sender...");
      }
      var pluginHandle = _pluginHandles[sender];
      if (pluginHandle == null) {
        debugPrint("This handle is not attached to this session");
      }
    } else if (json["janus"] == "hangup") {
      // A plugin asked the core to hangup a PeerConnection on one of our handles
      debugPrint("Got a hangup event on session " + sessionId.toString());
      debugPrint(json.toString());
      var sender = json["sender"] as int?;
      if (sender != null) {
        debugPrint("WMissing sender...");
      }
      var pluginHandle = _pluginHandles[sender];
      if (pluginHandle == null) {
        debugPrint("This handle is not attached to this session");
      } else {
        pluginHandle.onDestroy?.call();
        _pluginHandles.remove(sender);
      }
    } else if (json["janus"] == "detached") {
      // A plugin asked the core to detach one of our handles
      debugPrint("Got a detached event on session " + sessionId.toString());
      debugPrint(json.toString());
      var sender = json["sender"] as int?;
      if (sender == null) {
        debugPrint("WMissing sender...");
      }
      var pluginHandle = _pluginHandles[sender];
      if (pluginHandle == null) {
        plugin.onDetached?.call();
      }
    } else if (json["janus"] == "media") {
      // Media started/stopped flowing
      debugPrint("Got a media event on session " + sessionId.toString());
      debugPrint(json.toString());
      var sender = json["sender"] as int?;
      if (sender == null) {
        debugPrint("WMissing sender...");
      }
      var pluginHandle = _pluginHandles[sender];
      if (pluginHandle == null) {
        debugPrint("This handle is not attached to this session");
      } else {
        pluginHandle.onMediaState
            ?.call(json["type"], json["receiving"], json["mid"]);
      }
    } else if (json["janus"] == "slowlink") {
      debugPrint("Got a slowlink event on session " + sessionId.toString());
      debugPrint(json.toString());
      // Trouble uplink or downlink
      var sender = json["sender"] as int?;
      if (sender == null) {
        debugPrint("WMissing sender...");
      }
      var pluginHandle = _pluginHandles[sender];
      if (pluginHandle == null) {
        debugPrint("This handle is not attached to this session");
      } else {
        // TODO
        // pluginHandle.slowLink(json["uplink"], json["lost"], json["mid"]);
      }
    } else if (json["janus"] == "error") {
      // Oops, something wrong happened
      debugPrint("EOoops: " +
          json["error"]["code"].toString() +
          " " +
          json["error"]["reason"].toString()); // FIXME
      var transaction = json["transaction"] as String?;
      if (transaction != null) {
        var reportSuccess = _transactions[transaction];
        if (reportSuccess != null) {
          reportSuccess(json);
        }
      }
    } else if (json["janus"] == "event") {
      debugPrint("Got a plugin event on session " + sessionId.toString());
      var sender = json["sender"] as int?;
      if (sender == null) {
        debugPrint("WMissing sender...");
        return;
      }
      var plugindata = json["plugindata"] as Map?;
      if (plugindata == null) {
        debugPrint("WMissing plugindata...");
        return;
      }
      debugPrint("  -- Event is coming from " +
          sender.toString() +
          " (" +
          plugindata["plugin"].toString() +
          ")");
      var data = plugindata["data"] as Map;
//      debugPrint(data.toString());
      var pluginHandle = _pluginHandles[sender];
      if (pluginHandle == null) {
        debugPrint("WThis handle is not attached to this session");
      }
      var jsep = json["jsep"] as Map?;
      if (jsep != null) {
        debugPrint("Handling SDP as well...");
      }
      final callback = pluginHandle != null ? pluginHandle.onMessage : null;
      if (callback != null && jsep != null) {
        debugPrint("Notifying application...");
        // Send to callback specified when attaching plugin handle
        callback(
            data,
            RTCSessionDescription(
              jsep["sdp"] as String,
              jsep["type"] as String,
            ));
      } else {
        // Send to generic callback (?)
        debugPrint("No provided notification callback");
      }
    } else if (json["janus"] == "timeout") {
      debugPrint("ETimeout on session " + sessionId.toString());
      _webSocketChannel?.sink.close(3504, "Gateway timeout");
    } else {
      // TODO
      // debugPrint("WUnknown message/event  '" +
      //     json["janus"] +
      //     "' on session " +
      //     _sessionId.toString());
      // debugPrint(json.toString());
    }
  }
}
