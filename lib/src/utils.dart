import 'dart:convert';

import 'package:flutter/foundation.dart';

String stringify(Object? dynamic) {
  return const JsonEncoder().convert(dynamic);
}

Map parse(String s) {
  return const JsonDecoder().convert(s) as Map;
}

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
