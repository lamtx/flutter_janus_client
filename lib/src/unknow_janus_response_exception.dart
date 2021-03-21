import 'dart:convert';

class UnknownJanusResponseException implements Exception {
  const UnknownJanusResponseException(this.data);

  final Map data;

  @override
  String toString() => "Unknown Janus response: ${json.encode(data)}";
}
