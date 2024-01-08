import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data' show Uint8List, BytesBuilder;

import 'package:http/http.dart' as http;
import 'package:speed_test_dart/speed_test_dart.dart';
import 'package:tus_client_dart/src/retry_scale.dart';
import 'package:tus_client_dart/src/vimeo_tus_client_base.dart';

import 'exceptions.dart';

/// This class is used for creating or resuming uploads.
class VimeoTusClient extends VimeoTusClientBase {
  VimeoTusClient(
    super.file,
    super.url, {
    super.maxChunkSize = 512 * 1024,
    super.retries = 0,
    super.retryScale = RetryScale.constant,
    super.retryInterval = 0,
  });

  /// Override this method to use a custom Client
  http.Client getHttpClient() => http.Client();

  int _actualRetry = 0;

  Future<bool> isResumable() async {
    try {
      _fileSize = await file.length();
      _pauseUpload = false;
      return true;
    } catch (e) {
      throw FileNotFoundException();
    }
  }

  Future<void> setUploadTestServers() async {
    final tester = SpeedTestDart();

    try {
      final settings = await tester.getSettings();
      final servers = settings.servers;

      bestServers = await tester.getBestServers(
        servers: servers,
      );
    } catch (_) {
      bestServers = null;
    }
  }

  Future<void> uploadSpeedTest() async {
    final tester = SpeedTestDart();

    // If bestServers are null or they are empty, we will not measure upload speed
    // as it wouldn't be accurate at all
    if (bestServers == null || (bestServers?.isEmpty ?? true)) {
      uploadSpeed = null;
      return;
    }

    try {
      uploadSpeed = await tester.testUploadSpeed(servers: bestServers ?? []);
    } catch (_) {
      uploadSpeed = null;
    }
  }

  /// Start or resume an upload in chunks of [maxChunkSize] throwing
  /// [ProtocolException] on server error
  Future<void> upload({
    Function(double, int, Duration)? onProgress,
    Function(VimeoTusClient, Duration?)? onStart,
    Function()? onComplete,
    Function(Exception)? onError,
    Map<String, String>? metadata = const {},
    Map<String, String>? headers = const {},
    bool measureUploadSpeed = false,
  }) async {
    setUploadData(headers, metadata);
    try {
      await isResumable();

      if (measureUploadSpeed) {
        await setUploadTestServers();
        await uploadSpeedTest();
      }

      // get offset from server
      _offset = await _getOffset();

      // Save the file size as an int in a variable to avoid having to call
      int totalBytes = _fileSize as int;

      if (_offset == totalBytes && !_pauseUpload) {
        if (onComplete != null) {
          onComplete();
          return;
        }
      }

      // We start a stopwatch to calculate the upload speed
      final uploadStopwatch = Stopwatch()..start();

      // start upload
      final client = getHttpClient();

      if (onStart != null) {
        Duration? estimate;
        if (uploadSpeed != null) {
          final _workedUploadSpeed = uploadSpeed! * 1000000;

          estimate = Duration(
            seconds: (totalBytes / _workedUploadSpeed).round(),
          );
        }
        // The time remaining to finish the upload
        onStart(this, estimate);
      }

      while (!_pauseUpload && _offset < totalBytes) {
        if (!File(file.path).existsSync()) {
          throw FileNotFoundException();
        }
        final uploadHeaders = Map<String, String>.from(headers ?? {})
          ..addAll({
            "Tus-Resumable": tusVersion,
            "Upload-Offset": "$_offset",
            "Content-Type": "application/offset+octet-stream"
          });

        await _performUpload(
          onComplete: onComplete,
          onProgress: onProgress,
          onError: onError,
          uploadHeaders: uploadHeaders,
          client: client,
          uploadStopwatch: uploadStopwatch,
          totalBytes: totalBytes,
        );
      }
    } on http.ClientException catch (_) {
      if (onError != null) {
        onError(NoInternetException());
      }
      return;
    } on SocketException catch (e) {
      if (onError != null) {
        onError(NoInternetException());
      }
      return;
    } on FileNotFoundException {
      if (onError != null) {
        onError(FileNotFoundException());
      }
    } on UploadResumingException {
      if (onError != null) {
        onError(UploadResumingException());
      }
    } catch (e, str) {
      if (onError != null) {
        onError(ProtocolException(e.toString()));
      }
    } finally {
      return;
    }
  }

  Future<void> _performUpload({
    Function(double, int, Duration)? onProgress,
    Function()? onComplete,
    Function(Exception)? onError,
    required Map<String, String> uploadHeaders,
    required http.Client client,
    required Stopwatch uploadStopwatch,
    required int totalBytes,
  }) async {
    try {
      final request = http.Request("PATCH", url)
        ..headers.addAll(uploadHeaders)
        ..bodyBytes = await _getData();
      _response = await client.send(request);

      if (_response != null) {
        await _response?.stream.listen(
          (newBytes) {
            if (_actualRetry != 0) _actualRetry = 0;
          },
          onDone: () {
            if (onProgress != null && !_pauseUpload) {
              // Total byte sent
              final totalSent = _offset + maxChunkSize;
              double _workedUploadSpeed = 1.0;

              // If upload speed != null, it means it has been measured
              if (uploadSpeed != null) {
                // Multiplied by 10^6 to convert from Mb/s to b/s
                _workedUploadSpeed = uploadSpeed! * 1000000;
              } else {
                _workedUploadSpeed =
                    totalSent / uploadStopwatch.elapsedMilliseconds;
              }

              // The data that hasn't been sent yet
              final remainData = totalBytes - totalSent;

              // The time remaining to finish the upload
              final estimate = Duration(
                seconds: (remainData / _workedUploadSpeed).round(),
              );

              final progress = totalSent / totalBytes * 100;
              onProgress((progress).clamp(0, 100), totalSent, estimate);
              _actualRetry = 0;
            }
          },
        );

        // check if correctly uploaded
        if (!(_response!.statusCode >= 200 && _response!.statusCode < 300)) {
          throw UploadResumingException();
        }

        int? serverOffset = _parseOffset(_response!.headers["upload-offset"]);
        if (serverOffset == null) {
          throw UploadResumingException();
        }
        if (_offset != serverOffset) {
          throw UploadResumingException();
        }

        if (_offset == totalBytes && !_pauseUpload) {
          if (onComplete != null) {
            onComplete();
          }
        }
      } else {
        throw ProtocolException("Error getting Response from server");
      }
    } catch (e) {
      if (_actualRetry >= retries) {
        // if (onError != null) {
        //   onError();
        // }
        rethrow;
      }
      final waitInterval = retryScale.getInterval(
        _actualRetry,
        retryInterval,
      );
      _actualRetry += 1;
      log('Failed to upload,try: $_actualRetry, interval: $waitInterval');
      await Future.delayed(waitInterval);
      return await _performUpload(
        onComplete: onComplete,
        onProgress: onProgress,
        uploadHeaders: uploadHeaders,
        client: client,
        uploadStopwatch: uploadStopwatch,
        totalBytes: totalBytes,
      );
    }
  }

  /// Pause the current upload
  Future<bool> pauseUpload() async {
    try {
      _pauseUpload = true;
      await _response?.stream.timeout(Duration.zero);
      return true;
    } catch (e) {
      throw Exception("Error pausing upload");
    }
  }

  Future<bool> cancelUpload() async {
    try {
      await pauseUpload();
      return true;
    } catch (_) {
      throw Exception("Error cancelling upload");
    }
  }

  void setUploadData(
    Map<String, String>? headers,
    Map<String, String>? metadata,
  ) {
    this.headers = headers;
    this.metadata = metadata;
    _uploadMetadata = generateMetadata();
  }

  /// Get offset from server throwing [ProtocolException] on error
  Future<int> _getOffset() async {
    final client = getHttpClient();

    final offsetHeaders = Map<String, String>.from(headers ?? {})
      ..addAll({
        "Tus-Resumable": tusVersion,
      });
    final response = await client.head(url, headers: offsetHeaders);

    if (!(response.statusCode >= 200 && response.statusCode < 300)) {
      throw UploadResumingException();
    }

    int? serverOffset = _parseOffset(response.headers["upload-offset"]);
    if (serverOffset == null) {
      throw UploadResumingException();
    }
    return serverOffset;
  }

  /// Get data from file to upload

  Future<Uint8List> _getData() async {
    int start = _offset;
    int end = _offset + maxChunkSize;
    end = end > (_fileSize ?? 0) ? _fileSize ?? 0 : end;

    final result = BytesBuilder();
    await for (final chunk in file.openRead(start, end)) {
      result.add(chunk);
    }

    final bytesRead = min(maxChunkSize, result.length);
    _offset = _offset + bytesRead;

    return result.takeBytes();
  }

  int? _parseOffset(String? offset) {
    if (offset == null || offset.isEmpty) {
      return null;
    }
    if (offset.contains(",")) {
      offset = offset.substring(0, offset.indexOf(","));
    }
    return int.tryParse(offset);
  }

  http.StreamedResponse? _response;

  int? _fileSize;

  String? _uploadMetadata;

  int _offset = 0;

  bool _pauseUpload = false;

  /// The fingerprint of the file being uploaded

  /// The 'Upload-Metadata' header sent to server
  String get uploadMetadata => _uploadMetadata ?? "";
}
