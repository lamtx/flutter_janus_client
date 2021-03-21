import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRTCHandle {
  MediaStream? remoteStream;
  MediaStream? localStream;
  final RTCPeerConnection peerConnection;
  final Map<String, RTCDataChannel> dataChannel = {};

  WebRTCHandle({
    required this.peerConnection,
  });
}
