import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class AppReleaseInfo {
  const AppReleaseInfo({
    required this.version,
    required this.apkUrl,
    required this.fileName,
    required this.expectedSize,
    required this.expectedSha256,
    required this.releasePageUrl,
  });

  final String version;
  final String apkUrl;
  final String fileName;
  final int expectedSize;
  final String expectedSha256;
  final String releasePageUrl;
}

class AppUpdateService {
  AppUpdateService({HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient();

  final HttpClient _httpClient;
  static const String _cacheDirectoryName = 'vhosts_update_cache';
  static const String _apkName = 'app-release.apk';
  static final Uri _latestReleaseUri = Uri.parse(
    'https://api.github.com/repos/xiyang029/vhosts/releases/latest',
  );

  Future<AppReleaseInfo> fetchLatestRelease() async {
    final response = await _get(_latestReleaseUri, followRedirects: true);
    final Map<String, dynamic> data = json.decode(
      await _readResponseBody(response),
    );
    final assets = data['assets'] as List<dynamic>? ?? const [];
    final apkAsset = assets.cast<Map<String, dynamic>>().firstWhere(
      (asset) => asset['name'] == _apkName,
      orElse: () => throw const FormatException(
        'app-release.apk not found in GitHub assets',
      ),
    );
    final version = (data['tag_name'] as String?)?.trim().takeIfNotEmpty();
    final expectedSize = (apkAsset['size'] as num?)?.toInt();

    final digest = (apkAsset['digest'] as String?)?.trim() ?? '';
    final sha256 = _parseSha256Digest(digest);
    return AppReleaseInfo(
      version: version ?? _throwFormat('Release tag_name is missing'),
      apkUrl: apkAsset['browser_download_url'] as String,
      fileName: apkAsset['name'] as String? ?? _apkName,
      expectedSize: expectedSize ?? _throwFormat('APK size is missing'),
      expectedSha256: sha256,
      releasePageUrl:
          (data['html_url'] as String?)?.trim().takeIfNotEmpty() ??
          _latestReleaseUri.toString(),
    );
  }

  Future<File> downloadReleaseApk(
    AppReleaseInfo release, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    final file = await _resolveCachedApkFile(release);
    if (await _isValidCachedApk(file, release)) {
      onProgress?.call(release.expectedSize, release.expectedSize);
      return file;
    }
    await _deleteIfExists(file);

    final downloadUri = Uri.parse(release.apkUrl);
    final response = await _get(downloadUri, followRedirects: true);
    final totalBytes = response.contentLength > 0
        ? response.contentLength
        : null;
    final partialFile = File('${file.path}.part');
    await _deleteIfExists(partialFile);
    final sink = partialFile.openWrite();
    var receivedBytes = 0;
    final digestSink = _DigestSink();
    final byteConversionSink = sha256.startChunkedConversion(digestSink);

    try {
      await for (final chunk in response) {
        sink.add(chunk);
        byteConversionSink.add(chunk);
        receivedBytes += chunk.length;
        onProgress?.call(receivedBytes, totalBytes);
      }
      await sink.flush();
      await sink.close();
      byteConversionSink.close();
      final actualSha256 = digestSink.value;
      await _verifyDownloadedApk(
        file: partialFile,
        release: release,
        receivedBytes: receivedBytes,
        actualSha256: actualSha256,
      );
      await partialFile.rename(file.path);
      return file;
    } catch (_) {
      await sink.close().catchError((_) {});
      byteConversionSink.close();
      await _deleteIfExists(partialFile);
      await _deleteIfExists(file);
      rethrow;
    }
  }

  Future<File?> findCachedReleaseApk(AppReleaseInfo release) async {
    final file = await _resolveCachedApkFile(release);
    if (await _isValidCachedApk(file, release)) {
      return file;
    }
    await _deleteIfExists(file);
    return null;
  }

  Future<File> _resolveCachedApkFile(AppReleaseInfo release) async {
    final cacheDirectory = Directory(
      '${Directory.systemTemp.path}\\$_cacheDirectoryName',
    );
    if (!await cacheDirectory.exists()) {
      await cacheDirectory.create(recursive: true);
    }

    final safeName = release.fileName.endsWith('.apk')
        ? release.fileName
        : '${release.fileName}.apk';
    return File('${cacheDirectory.path}\\$safeName');
  }

  Future<HttpClientResponse> _get(
    Uri uri, {
    required bool followRedirects,
  }) async {
    final request = await _httpClient.getUrl(uri);
    request.followRedirects = followRedirects;
    request.headers.set(HttpHeaders.userAgentHeader, 'vhosts-app-updater');
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    final response = await request.close();
    if (response.statusCode >= 400) {
      throw HttpException(
        'Request failed with status ${response.statusCode}',
        uri: uri,
      );
    }
    return response;
  }

  Future<String> _readResponseBody(HttpClientResponse response) async {
    return utf8.decodeStream(response);
  }

  Future<bool> _isValidCachedApk(File file, AppReleaseInfo release) async {
    if (!await file.exists()) {
      return false;
    }

    final actualSize = await file.length();
    if (actualSize != release.expectedSize) {
      return false;
    }

    final actualSha256 = await _computeFileSha256(file);
    return actualSha256 == release.expectedSha256;
  }

  Future<String> _computeFileSha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<void> _verifyDownloadedApk({
    required File file,
    required AppReleaseInfo release,
    required int receivedBytes,
    required String actualSha256,
  }) async {
    final actualSize = await file.length();
    if (receivedBytes != release.expectedSize ||
        actualSize != release.expectedSize) {
      throw FileSystemException(
        'APK size mismatch: expected ${release.expectedSize}, got $actualSize',
        file.path,
      );
    }

    if (actualSha256 != release.expectedSha256) {
      throw FileSystemException('APK hash mismatch', file.path);
    }
  }

  Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) {
      await file.delete();
    }
  }

  Never _throwFormat(String message) {
    throw FormatException(message);
  }

  String _parseSha256Digest(String digest) {
    final match = RegExp(r'^sha256:([a-fA-F0-9]{64})$').firstMatch(digest);
    if (match == null) {
      throw FormatException('Invalid GitHub asset digest: $digest');
    }
    return match.group(1)!.toLowerCase();
  }
}

extension on String {
  String? takeIfNotEmpty() => isEmpty ? null : this;
}

class _DigestSink implements Sink<Digest> {
  String value = '';

  @override
  void add(Digest data) {
    value = data.toString();
  }

  @override
  void close() {}
}
