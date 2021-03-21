import 'error_response.dart';

class JanusResponseException implements Exception {
  const JanusResponseException(this.response);

  final ErrorResponse response;

  @override
  String toString() => "${response.error} - Janus:${response.errorCode}";
}
