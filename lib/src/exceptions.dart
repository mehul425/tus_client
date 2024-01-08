/// This exception is thrown if the server sends a request with an unexpected
/// status code or missing/invalid headers.
class ProtocolException implements Exception {
  final String message;
  final int? code;

  ProtocolException(this.message, [this.code]);

  String toString() => "ProtocolException: ($code) $message";
}

class NoInternetException implements Exception {
  NoInternetException();

  @override
  String toString() => "NoInternetException";
}

class FileNotFoundException implements Exception {
  FileNotFoundException();

  @override
  String toString() => "FileNotFoundException";
}

class UploadResumingException implements Exception {
  UploadResumingException();

  @override
  String toString() => "UploadResumingException";
}

class MissingUploadOffsetException implements Exception {
  final String? message;

  MissingUploadOffsetException({
    this.message,
  });

  @override
  String toString() =>
      "MissingUploadOffsetException: ${message ?? 'response for resuming upload is empty'}";
}

class ChunkUploadFailedException implements Exception {
  @override
  String toString() =>
      'ChunkUploadFailedException: response to PATCH request contains no or invalid Upload-Offset header';
}

class MissingUploadUriException implements Exception {
  @override
  String toString() =>
      'MissingUploadUriException: missing upload Uri in response for creating upload';
}
