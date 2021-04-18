import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'janus_error.dart';
import 'plugin_data.dart';

class JanusMessage {
  JanusMessage(this.data);

  final Map data;

  String? _janus;
  int? _sender;
  String? _transaction;
  RTCSessionDescription? _jsep;
  int _initializedFields = 0;
  PluginData? _pluginData;
  JanusError? _error;

  void _set(int index) {
    _initializedFields |= 0x01 << 0;
  }

  bool _unset(int index) {
    return _initializedFields & (0x1 << index) == 0;
  }

  String get janus {
    return _janus ??= data["janus"] as String;
  }

  bool get isError => data.containsKey("error");

  String? get transaction {
    if (_unset(0)) {
      _set(0);
      _transaction = data["transaction"] as String?;
    }
    return _transaction;
  }

  int? get sender {
    if (_unset(1)) {
      _set(1);
      _sender = data["sender"] as int?;
    }
    return _sender;
  }

  RTCSessionDescription? get jsep {
    if (_unset(2)) {
      _set(2);
      final json = data["jsep"] as Map?;
      if (json != null) {
        _jsep = RTCSessionDescription(
          json["sdp"] as String,
          json["type"] as String,
        );
      }
    }
    return _jsep;
  }

  PluginData? get pluginData {
    if (_unset(3)) {
      _set(3);
      final json = data["plugindata"] as Map?;
      if (json != null) {
        _pluginData = PluginData(json);
      }
    }
    return _pluginData;
  }

  JanusError? get error {
    if (_unset(4)) {
      _set(4);
      final json = data["error"] as Map?;
      if (json != null) {
        _error = JanusError(
          code: json["code"] as int,
          reason: json["reason"] as String?,
        );
      }
    }
    return _error;
  }
}
