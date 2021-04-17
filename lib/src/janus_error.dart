class JanusError {
  JanusError({
    required this.code,
    required this.reason,
  });

  @override
  String toString() {
    return 'JanusError{code: $code, reason: $reason}';
  }

  final int code;
  final String reason;


  static const int codeSessionNotFound = 458;
}
