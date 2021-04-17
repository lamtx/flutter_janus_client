import 'package:flutter/foundation.dart';

bool log(String tagOrMessage, [String? message, Object? exception]) {
  final msg = message == null ? tagOrMessage : "$tagOrMessage: $message";
  // ignore: avoid_print
  debugPrint(msg);
  if (exception != null) {
    // ignore: avoid_print
    print(exception);
  }
  return true;
}
