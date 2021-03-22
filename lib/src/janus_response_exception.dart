import 'janus_message.dart';

class JanusResponseException implements Exception {
  const JanusResponseException(this.response);

  final JanusMessage response;

  @override
  String toString() {
    if (response.data.containsKey("error")) {
      final dynamic error = response.data["error"];
      if (error is String) {
        return error;
      } else if (error is Map) {
        return error["reason"] as String;
      }
    } else {
      final pluginData = response.pluginData;
      if (pluginData != null) {
        if (pluginData.data.containsKey("error")) {
          return pluginData.data["error"] as String;
        }
      }
    }
    return "JanusResponseException";
  }
}
