import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRTCHandle {
  WebRTCHandle({
    required this.peerConnection,
  });

  final RTCPeerConnection peerConnection;

  MediaStream? remoteStream;
  MediaStream? localStream;
  RTCDataChannel? dataChannel;
}
