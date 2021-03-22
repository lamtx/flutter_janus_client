class RtcIceServer {
  RtcIceServer({
    required this.username,
    required this.credential,
    required this.url,
  });

  factory RtcIceServer.fromMap(Map<String, dynamic> map) {
    return RtcIceServer(
      username: map['username'] as String,
      credential: map['credential'] as String,
      url: map['url'] as String,
    );
  }

  final String username;
  final String credential;
  final String url;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RtcIceServer &&
          runtimeType == other.runtimeType &&
          username == other.username &&
          credential == other.credential &&
          url == other.url);

  @override
  int get hashCode => username.hashCode ^ credential.hashCode ^ url.hashCode;

  @override
  String toString() =>
      'RTCIceServer{${' username: $username,'}${' credential: $credential,'}${' url: $url,'}}';

  RtcIceServer copyWith({
    String? username,
    String? credential,
    String? url,
  }) =>
      RtcIceServer(
        username: username ?? this.username,
        credential: credential ?? this.credential,
        url: url ?? this.url,
      );

  Map<String, Object?> toMap() {
    return {
      'username': username,
      'credential': credential,
      'url': url,
    };
  }
}
