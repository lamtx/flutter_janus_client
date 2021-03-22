import 'package:net/net.dart';

class ErrorResponse {
  const ErrorResponse({
    required this.errorCode,
    required this.error,
  });

  final int errorCode;
  final String error;

  static final DataParser<ErrorResponse> parser = (reader) => ErrorResponse(
        errorCode: reader.readInt("error_code"),
        error: reader.readString("error"),
      );

  @override
  String toString() => 'ErrorResponse(errorCode: $errorCode, error: $error)';
}
