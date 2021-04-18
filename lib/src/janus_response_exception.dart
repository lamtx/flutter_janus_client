import 'janus_error.dart';
import 'janus_message.dart';

class JanusResponseException implements Exception {
  const JanusResponseException(this.response);

  final JanusMessage response;

  JanusError? get innerError {
    if (response.error != null) {
      return response.error;
    }
    final data = response.pluginData?.data;
    if (data != null) {
      if (data.containsKey("error_code")) {
        return JanusError(
          code: data["error_code"] as int,
          reason: data["error"] as String?,
        );
      }
    }
  }
}
