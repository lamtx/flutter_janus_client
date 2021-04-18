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
  final String? reason;

  static const int sessionNotFound = 458;
  static const int janusVideoRoomErrorNoSuchFeed = 428;
  static const int janusVideoRoomErrorNoSuchRoom = 426;
}
