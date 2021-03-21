import 'dart:convert';
import 'dart:developer';
import 'dart:math';

import 'package:flutter/foundation.dart';

String stringify(Object? dynamic) {
  return const JsonEncoder().convert(dynamic);
}

Map parse(String dynamic) {
  return const JsonDecoder().convert(dynamic) as Map;
}

String randomString({
  int len = 10,
  String charSet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@#\$%^&*()_+',
}) {
  final randomString = StringBuffer();
  for (var i = 0; i < len; i++) {
    final randomPoz = (Random().nextInt(charSet.length - 1)).floor();
    randomString.write(charSet.substring(randomPoz, randomPoz + 1));
  }
  randomString.write(Timeline.now.toString());
  return randomString.toString();
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
