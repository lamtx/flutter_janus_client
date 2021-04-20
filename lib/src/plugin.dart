import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:net/net.dart';

import 'janus_client.dart';
import 'janus_message.dart';
import 'janus_response_exception.dart';
import 'obtain_transaction_id.dart';
import 'utils.dart';
import 'web_rtc_handle.dart';

typedef OnMessageReceived = void Function(
    Map message, RTCSessionDescription? jsep);
typedef OnLocalStreamReceived = void Function(List<MediaStream> streams);
typedef OnDataChannelStatusChanged = void Function(RTCDataChannelState state);
typedef OnDataMessageReceived = void Function(JanusMessage message);
typedef OnMediaState = void Function(dynamic, dynamic, dynamic);
typedef OnRemoteTrack = void Function(
    MediaStream stream, MediaStreamTrack track, String trackId, bool);

void nothing(JsonReader _) {}

/// This Class exposes methods and utility function necessary for directly interacting with plugin.
class Plugin {
  Plugin({
    required this.plugin,
    required this.webRTCHandle,
    required JanusClient client,
    required this.onMessage,
    required this.onDataChannelStatus,
    required this.onDataMessage,
    required this.onDetached,
    required this.onDestroy,
    required this.onMediaState,
  }) : _client = client;

  final String plugin;
  late final int handleId;
  final JanusClient _client;

  final WebRTCHandle webRTCHandle;
  final OnMessageReceived? onMessage;
  final OnDataChannelStatusChanged? onDataChannelStatus;
  final OnDataMessageReceived? onDataMessage;
  final VoidCallback? onDetached;
  final VoidCallback? onDestroy;
  final OnMediaState? onMediaState;

  var _dataChannelState = RTCDataChannelState.RTCDataChannelClosed;
  final _obtainDataTransactionId = ObtainTransactionId();
  final _dataTransactions = <String, void Function(JanusMessage)>{};
  static const _tag = "Janus";

  Future<JanusMessage> send(
    JsonObject message, {
    RTCSessionDescription? jesp,
  }) async {
    final data = await _client.addTransaction({
      "janus": "message",
      "body": message.toJson(),
      "handle_id": handleId,
      if (jesp != null) "jsep": jesp.toMap() as Map,
    });
    if (data.jsep != null) {
      await handleRemoteJsep(data.jsep!);
    }
    return data;
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
    final transaction = _obtainDataTransactionId.next();
    final msg = message.toJson() as Map<String, Object>;
    final request = {...msg, "transaction": transaction};
    final completer = Completer<T>();
    _dataTransactions[transaction] = (data) async {
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
          final handler = _dataTransactions.remove(message.transaction);
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
          // Provide your own width, height and frame rate here
          // "minWidth": '1280',
          // "minHeight": '720',
          // "minFrameRate": '60',
        },
        "facingMode": "user",
        "optional": <Object>[],
      }
    },
  }) async {
    final localStream =
        await navigator.mediaDevices.getUserMedia(mediaConstraints);
    webRTCHandle.localStream = localStream;
    await webRTCHandle.peerConnection.addStream(localStream);
    return localStream;
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
    _dataTransactions.clear();
    await webRTCHandle.localStream?.dispose();
    await webRTCHandle.remoteStream?.dispose();
    await webRTCHandle.peerConnection.dispose();
  }

  Future<RTCSessionDescription> createOffer([
    Map<String, Object?> offerOptions = const {
      "offerToReceiveAudio": true,
      "offerToReceiveVideo": true,
    },
  ]) async {
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
    final offer = await webRTCHandle.peerConnection.createAnswer(offerOptions);
    await webRTCHandle.peerConnection.setLocalDescription(offer);
    return offer;
  }

  Future<void> restartIce() {
    return createOffer(const {
      "mandatory": {
        "IceRestart": true,
      }
    });
  }
}
