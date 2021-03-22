import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:net/net.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'janus_client.dart';
import 'janus_message.dart';
import 'janus_response_exception.dart';
import 'obtain_transaction_id.dart';
import 'utils.dart';
import 'web_rtc_handle.dart';

typedef OnMessageReceived = void Function(
    Map message, RTCSessionDescription? jsep);
typedef OnLocalStreamReceived = void Function(List<MediaStream> streams);
typedef OnRemoteStreamReceived = void Function(MediaStream stream);
typedef OnDataChannelStatusChanged = void Function(RTCDataChannelState state);
typedef OnDataMessageReceived = void Function(JanusMessage message);
typedef OnIceConnectionState = void Function(dynamic);
typedef OnWebRTCStateChanged = void Function(RTCPeerConnectionState state);
typedef OnMediaState = void Function(dynamic, dynamic, dynamic);
typedef OnRemoteTrack = void Function(
    MediaStream stream, MediaStreamTrack track, String trackId, bool);

void nothing(JsonReader _) {}

/// This Class exposes methods and utility function necessary for directly interacting with plugin.
class Plugin {
  Plugin({
    required this.plugin,
    required this.webRTCHandle,
    required int sessionId,
    required ObtainTransactionId obtainTransactionId,
    required Map<String, void Function(JanusMessage message)> transactions,
    required Map<int, Plugin> pluginHandles,
    required WebSocketSink sink,
    required String? token,
    required String? apiSecret,
    required this.onMessage,
    required this.onDataChannelStatus,
    required this.onDataMessage,
    required this.onDetached,
    required this.onDestroy,
    required this.onMediaState,
  })   : _sink = sink,
        _obtainTransactionId = obtainTransactionId,
        _apiSecret = apiSecret,
        _token = token,
        _transactions = transactions,
        _pluginHandles = pluginHandles,
        _sessionId = sessionId;

  final String plugin;
  late final int handleId;
  final int _sessionId;
  final Map<String, void Function(JanusMessage message)> _transactions;
  final Map<int, Plugin> _pluginHandles;
  final String? _token;
  final String? _apiSecret;
  final WebSocketSink _sink;
  final ObtainTransactionId _obtainTransactionId;

  final WebRTCHandle webRTCHandle;
  final OnMessageReceived? onMessage;
  final OnDataChannelStatusChanged? onDataChannelStatus;
  final OnDataMessageReceived? onDataMessage;
  final VoidCallback? onDetached;
  final VoidCallback? onDestroy;
  final OnMediaState? onMediaState;

  var _dataChannelState = RTCDataChannelState.RTCDataChannelClosed;
  static const _tag = "Janus";

  Future<JanusMessage> send(
    JsonObject message, {
    RTCSessionDescription? jesp,
  }) {
    final transaction = _obtainTransactionId.next();
    final request = {
      "janus": "message",
      "body": message.toJson(),
      "transaction": transaction,
      "session_id": _sessionId,
      "handle_id": handleId,
      if (_token != null) "token": _token,
      if (_apiSecret != null) "apisecret": _apiSecret,
      if (jesp != null) "jsep": jesp.toMap() as Map,
    };
    final body = json.encode(request);
    final completer = Completer<JanusMessage>();
    _transactions[transaction] = (data) async {
      if (data.jsep != null) {
        await handleRemoteJsep(data.jsep!);
      }
      completer.complete(data);
    };
    assert(log(_tag, "send: $body"));
    _sink.add(body);
    return completer.future;
  }

  Future<T> sendAsync<T>(
    JsonObject message, {
    RTCSessionDescription? jesp,
    required DataParser<T> waitFor,
  }) async {
    final json = await send(message, jesp: jesp);
    final janus = json.janus;
    if (janus == "ack") {
      throw StateError("No ACK forwarded here");
    }
    if (janus != "success" && janus != "event") {
      throw UnimplementedError("Unimplemented Janus message: $json");
    }
    final pluginData = json.pluginData;
    assert(pluginData != null);
    if (pluginData == null) {
      throw StateError("plugindata is null");
    }
    if (pluginData.plugin != plugin) {
      throw StateError(
          "Received a response from other plugin ${pluginData.plugin}");
    }
    if (pluginData.data.isEmpty || pluginData.data.containsKey("error")) {
      throw JanusResponseException(json);
    } else {
      return waitFor.parseJson(pluginData.data);
    }
  }

  Future<T> sendDataAsync<T>(
    JsonObject message, {
    required DataParser<T> waitFor,
  }) async {
    final dataChannel = webRTCHandle.dataChannel;
    if (dataChannel == null) {
      throw StateError("Please call initDataChannel to create data channel");
    }
    if (_dataChannelState != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError("DataChannel has not been opened yet.");
    }
    final transaction = _obtainTransactionId.next();
    final msg = message.toJson() as Map<String, Object>;
    final request = {...msg, "transaction": transaction};
    final completer = Completer<T>();
    _transactions[transaction] = (data) async {
      if (data.jsep != null) {
        await handleRemoteJsep(data.jsep!);
      }
      if (data.isError) {
        completer.completeError(JanusResponseException(data));
      } else {
        completer.complete(waitFor.parseJson(data.data));
      }
    };
    final body = json.encode(request);
    assert(log(_tag, "sendData: $body"));
    await dataChannel.send(RTCDataChannelMessage(body));
    return completer.future;
  }

  Future<void> initDataChannel({RTCDataChannelInit? rtcDataChannelInit}) async {
    assert(webRTCHandle.dataChannel == null,
        "initDataChannel cannot be called twice");
    assert(onDataChannelStatus != null, "onDataOpen must be registered");
    assert(onDataMessage != null, "onData must be registered");
    assert(_dataChannelState == RTCDataChannelState.RTCDataChannelClosed,
        "Invalid data channel state $_dataChannelState");
    final init = rtcDataChannelInit ?? RTCDataChannelInit()
      ..ordered = true
      ..protocol = 'janus-protocol';
    final channel = await webRTCHandle.peerConnection
        .createDataChannel(JanusClient.dataChannelDefaultLabel, init);
    channel.onDataChannelState = (state) {
      _dataChannelState = state;
      onDataChannelStatus!.call(state);
    };
    channel.onMessage = (data) {
      if (data.isBinary) {
        throw UnsupportedError("Unsupported binary data");
      } else {
        assert(log(_tag, "Data: ${data.text}"));
        final obj = json.decode(data.text) as Map;
        final message = JanusMessage(obj);
        if (message.transaction != null) {
          final handler = _transactions.remove(message.transaction);
          if (handler != null) {
            handler(message);
          } else {
            throw StateError(
                "No handler for transaction ${message.transaction}");
          }
        } else {
          onDataMessage!.call(message);
        }
      }
    };
    webRTCHandle.dataChannel = channel;
  }

  /// It allows you to set Remote Description on internal peer connection, Received from janus server
  Future<void> handleRemoteJsep(RTCSessionDescription jsep) {
    return webRTCHandle.peerConnection.setRemoteDescription(jsep);
  }

  /// method that generates MediaStream from your device camera that will be automatically added to peer connection instance internally used by janus client
  ///
  /// you can use this method to get the stream and show live preview of your camera to RTCVideoRendererView
  Future<MediaStream> initializeMediaDevices({
    Map<String, Object?> mediaConstraints = const {
      "audio": true,
      "video": {
        "mandatory": {
          "minWidth":
              '1280', // Provide your own width, height and frame rate here
          "minHeight": '720',
          "minFrameRate": '60',
        },
        "facingMode": "user",
        "optional": <Object>[],
      }
    },
  }) async {
    webRTCHandle.localStream =
        await navigator.mediaDevices.getUserMedia(mediaConstraints);
    await webRTCHandle.peerConnection.addStream(webRTCHandle.localStream);
    return webRTCHandle.localStream!;
  }

  /// a utility method which can be used to switch camera of user device if it has more than one camera
  Future<bool> switchCamera() async {
    if (webRTCHandle.localStream != null) {
      final videoTrack = webRTCHandle.localStream!
          .getVideoTracks()
          .firstWhere((track) => track.kind == "video");
      return Helper.switchCamera(videoTrack);
    } else {
      throw StateError(
          "Media devices and stream not initialized,try calling initializeMediaDevices()");
    }
  }

  /// Cleans Up everything related to individual plugin handle
  Future<void> destroy() async {
    await webRTCHandle.localStream?.dispose();
    await webRTCHandle.peerConnection.dispose();
    _pluginHandles.remove(handleId);
  }

  Future<RTCSessionDescription> createOffer({
    bool offerToReceiveAudio = true,
    bool offerToReceiveVideo = true,
  }) async {
    final offerOptions = {
      "offerToReceiveAudio": offerToReceiveAudio,
      "offerToReceiveVideo": offerToReceiveVideo
    };
    final offer = await webRTCHandle.peerConnection.createOffer(offerOptions);
    await webRTCHandle.peerConnection.setLocalDescription(offer);
    return offer;
  }

  Future<RTCSessionDescription> createAnswer({
    Map<String, Object?> offerOptions = const {
      "offerToReceiveAudio": true,
      "offerToReceiveVideo": true,
    },
  }) async {
    // try {
    final offer = await webRTCHandle.peerConnection.createAnswer(offerOptions);
    await webRTCHandle.peerConnection.setLocalDescription(offer);
    return offer;
    // } catch (e) {
    //   // TODO: why we try twice?
    //   assert(log(_tag, "We create answer twice", e));
    //   final offer =
    //       await webRTCHandle.peerConnection.createAnswer(offerOptions);
    //   await webRTCHandle.peerConnection.setLocalDescription(offer);
    //   return offer;
    // }
  }
}
