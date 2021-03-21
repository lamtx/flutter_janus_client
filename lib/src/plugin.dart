import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:net/net.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'error_response.dart';
import 'janus_client.dart';
import 'janus_response_exception.dart';
import 'unknow_janus_response_exception.dart';
import 'utils.dart';
import 'web_rtc_handle.dart';

typedef OnMessageReceived = void Function(
    Map message, RTCSessionDescription? jesp);
typedef OnLocalStreamReceived = void Function(List<MediaStream> streams);
typedef OnRemoteStreamReceived = void Function(MediaStream stream);
typedef OnDataChannelStatusChanged = void Function(RTCDataChannelState state);
typedef OnDataReceived = void Function(RTCDataChannelMessage data);
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
    this.opaqueId,
    required this.webRTCHandle,
    required this.sessionId,
    required this.transactions,
    required this.pluginHandles,
    required this.webSocketStream,
    required this.webSocketSink,
    required this.token,
    required this.apiSecret,
    required this.onMessage,
    required this.onDataOpen,
    required this.onData,
    required this.onDetached,
    required this.onDestroy,
    required this.onRemoteTrack,
    required this.onMediaState,
  });

  final String plugin;
  final String? opaqueId;
  late final int handleId;
  final int sessionId;
  final Map<String, void Function(Map data)> transactions;
  final Map<int, Plugin> pluginHandles;
  final String? token;
  final String? apiSecret;
  final Stream<String> webSocketStream;
  final WebSocketSink webSocketSink;
  static const _uuid = Uuid();

  final WebRTCHandle webRTCHandle;
  final OnMessageReceived? onMessage;
  final OnDataChannelStatusChanged? onDataOpen;
  final OnDataReceived? onData;
  final VoidCallback? onDetached;
  final VoidCallback? onDestroy;
  final OnRemoteTrack? onRemoteTrack;
  final OnMediaState? onMediaState;

  static const _tag = "JanusRoom";

  Future<T> sendAsync<T>(
    JsonObject message, {
    RTCSessionDescription? jesp,
    required DataParser<T> waitFor,
  }) {
    final transaction = _uuid.v4() + _uuid.v1() + _uuid.v4();
    final request = {
      "janus": "message",
      "body": message.toJson(),
      "transaction": transaction,
      "session_id": sessionId,
      "handle_id": handleId,
      if (token != null) "token": token,
      if (apiSecret != null) "apisecret": apiSecret,
      if (jesp != null) "jsep": jesp.toMap() as Map,
    };
    assert(log(_tag, "send: ${request.serializeAsJson()}"));
    webSocketSink.add(json.encode(request));
    final completer = Completer<T>();
    transactions[transaction] = (json) {
      _handleResponse(json, completer, waitFor);
    };
    return completer.future;
  }

  Future<T> sendDataAsync<T>(
    JsonObject message, {
    required DataParser<T> waitFor,
  }) async {
    final transaction = _uuid.v4() + _uuid.v1() + _uuid.v4();
    final json = message.toJson() as Map<String, Object>;
    final request = {...json, "transaction": transaction};
    final completer = Completer<T>();
    transactions[transaction] = (dynamic json) {
      final data = json as Map;
      if (data.containsKey("error")) {
        completer.completeError(
            JanusResponseException(ErrorResponse.parser.parseJson(data)));
      } else {
        completer.complete(waitFor.parseJson(data));
      }
    };
    await sendData(message: request.serializeAsJson());
    return completer.future;
  }

  void _handleResponse<T>(
    Map json,
    Completer<T> completer,
    DataParser<T> parser,
  ) {
    assert(log(_tag, "get: ${stringify(json)}"));
    final janus = json["janus"] as String?;
    if (janus == "ack") {
      assert(log(_tag, "skip ACK"));
      return;
    }
    if (janus != "success" && janus != "event") {
      throw UnimplementedError("Unimplemented Janus message: $json");
    }
    final pluginData = json["plugindata"] as Map?;
    assert(pluginData != null);
    if (pluginData == null) {
      completer.completeError(UnknownJanusResponseException(json));
      return;
    }
    assert(pluginData["plugin"] == plugin,
        "Seem likes got a response from other plugin ${pluginData["plugin"]}.");
    if (pluginData["plugin"] != plugin) {
      completer.completeError(UnknownJanusResponseException(json));
      return;
    }
    final data = pluginData["data"] as Map?;
    assert(data != null);
    if (data == null) {
      completer.completeError(UnknownJanusResponseException(json));
      return;
    }
    try {
      if (data.containsKey("error")) {
        completer.completeError(
            JanusResponseException(ErrorResponse.parser.parseJson(data)));
      } else {
        completer.complete(parser.parseJson(data));
      }
    } on Exception catch (e) {
      completer.completeError(e);
    }
  }

  /// It allows you to set Remote Description on internal peer connection, Received from janus server
  Future<void> handleRemoteJsep(RTCSessionDescription jsep) {
    return webRTCHandle.peerConnection.setRemoteDescription(jsep);
  }

  /// method that generates MediaStream from your device camera that will be automatically added to peer connection instance internally used by janus client
  ///
  /// you can use this method to get the stream and show live preview of your camera to RTCVideoRendererView
  Future<MediaStream> initializeMediaDevices({
    Map<String, Object?> mediaConstraints = const <String, Object?>{
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
    await webSocketSink.close();
    pluginHandles.remove(handleId);
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
    try {
      final offer =
          await webRTCHandle.peerConnection.createAnswer(offerOptions);
      await webRTCHandle.peerConnection.setLocalDescription(offer);
      return offer;
    } catch(e) {
      // TODO: why we try twice?
      assert(log(_tag, "We create answer twice", e));
      final offer =
          await webRTCHandle.peerConnection.createAnswer(offerOptions);
      await webRTCHandle.peerConnection.setLocalDescription(offer);
      return offer;
    }
  }

  Future prepareTranscievers(bool offer) async {
    RTCRtpTransceiver? audioTransceiver;
    RTCRtpTransceiver? videoTransceiver;
    final List<RTCRtpTransceiver>? transceivers =
        await webRTCHandle.peerConnection.transceivers;
    if (transceivers != null && transceivers.isNotEmpty) {
      transceivers.forEach((t) {
        if ((t.sender != null &&
                t.sender.track != null &&
                t.sender.track.kind == "audio") ||
            (t.receiver != null &&
                t.receiver.track != null &&
                t.receiver.track.kind == "audio")) {
          if (audioTransceiver == null) {
            audioTransceiver = t;
          }
        }
        if ((t.sender != null &&
                t.sender.track != null &&
                t.sender.track.kind == "video") ||
            (t.receiver != null &&
                t.receiver.track != null &&
                t.receiver.track.kind == "video")) {
          if (videoTransceiver == null) {
            videoTransceiver = t;
          }
        }
      });
    }
    if (audioTransceiver?.setDirection != null) {
      await audioTransceiver!.setDirection(TransceiverDirection.RecvOnly);
    } else {
      audioTransceiver = await webRTCHandle.peerConnection.addTransceiver(
          track: null,
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(
            direction: offer
                ? TransceiverDirection.SendOnly
                : TransceiverDirection.RecvOnly,
            streams: [],
          ));
    }
    if (videoTransceiver != null) {
      // TODO: why not promoted
      await videoTransceiver!.setDirection(TransceiverDirection.RecvOnly);
    } else {
      videoTransceiver = await webRTCHandle.peerConnection.addTransceiver(
          track: null,
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(
            direction: offer
                ? TransceiverDirection.SendOnly
                : TransceiverDirection.RecvOnly,
            streams: [],
          ));
    }
  }

  Future<void> initDataChannel({RTCDataChannelInit? rtcDataChannelInit}) async {
    if (rtcDataChannelInit == null) {
      rtcDataChannelInit = RTCDataChannelInit();
      rtcDataChannelInit.ordered = true;
      rtcDataChannelInit.protocol = 'janus-protocol';
    }
    assert(onDataOpen != null, "onDataOpen must be registered");
    assert(onData != null, "onData must be registered");
    final channel = await webRTCHandle.peerConnection.createDataChannel(
        JanusClient.dataChannelDefaultLabel, rtcDataChannelInit);
    webRTCHandle.dataChannel[JanusClient.dataChannelDefaultLabel] = channel;
    channel.onDataChannelState = (state) {
      onDataOpen!.call(state);
    };
    channel.onMessage = (message) {
      onData!.call(message);
    };
  }

  /// Send text message on existing text room using data channel with same label as specified during initDataChannel() method call.
  ///
  /// for now janus text room only supports text as string although with normal data channel api we can send blob or Uint8List if we want.
  Future<void> sendData({required String message}) {
    return webRTCHandle.dataChannel[JanusClient.dataChannelDefaultLabel]!
        .send(RTCDataChannelMessage(message));
  }
}
