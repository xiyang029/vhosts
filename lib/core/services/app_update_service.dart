import 'dart:async';
import 'dart:convert';
import 'dart:io';

class AppReleaseInfo {
  const AppReleaseInfo({
    required this.version,
    required this.releasePageUrl,
    required this.apkUrl,
    required this.fileName,
  });

  final String version;
  final String releasePageUrl;
  final String apkUrl;
  final String fileName;
}

class AppUpdateService {
  AppUpdateService({HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient();

  final HttpClient _httpClient;
  static const String _cacheDirectoryName = 'vhosts_update_cache';
  static final Uri _latestReleaseUri = Uri.parse(
    'https://gitee.com/xiaoxi233xyz/vhosts/releases/latest',
  );

  Future<AppReleaseInfo> fetchLatestRelease() async {
    final latestResponse = await _get(
      _latestReleaseUri,
      followRedirects: false,
    );
    try {
      final location = latestResponse.headers.value(HttpHeaders.locationHeader);
      final releaseUri = location == null || location.isEmpty
          ? _latestReleaseUri
          : _latestReleaseUri.resolve(location);
      final version = _extractVersionFromReleaseUri(releaseUri);
      final html = await _readResponseBody(
        await _get(releaseUri, followRedirects: true),
      );
      final apkUri = _extractApkUri(html, releaseUri);
      return AppReleaseInfo(
        version: version,
        releasePageUrl: releaseUri.toString(),
        apkUrl: apkUri.toString(),
        fileName: apkUri.pathSegments.isNotEmpty
            ? apkUri.pathSegments.last
            : 'vhosts-$version.apk',
      );
    } finally {
      latestResponse.detachSocket().then((socket) => socket.destroy());
    }
  }

  Future<File> downloadReleaseApk(
    AppReleaseInfo release, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    final file = await _resolveCachedApkFile(release);
    if (await file.exists()) {
      onProgress?.call(await file.length(), await file.length());
      return file;
    }

    final downloadUri = Uri.parse(release.apkUrl);
    final response = await _get(downloadUri, followRedirects: true);
    final totalBytes = response.contentLength > 0
        ? response.contentLength
        : null;
    if (await file.exists()) {
      await file.delete();
    }
    final sink = file.openWrite();
    var receivedBytes = 0;

    try {
      await for (final chunk in response) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        onProgress?.call(receivedBytes, totalBytes);
      }
      await sink.flush();
      return file;
    } finally {
      await sink.close();
    }
  }

  Future<File?> findCachedReleaseApk(AppReleaseInfo release) async {
    final file = await _resolveCachedApkFile(release);
    if (await file.exists()) {
      return file;
    }
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

  String _extractVersionFromReleaseUri(Uri uri) {
    final segments = uri.pathSegments;
    final tagIndex = segments.indexOf('tag');
    if (tagIndex >= 0 && tagIndex + 1 < segments.length) {
      return segments[tagIndex + 1];
    }
    throw const FormatException('Unable to resolve latest release version');
  }

  Uri _extractApkUri(String html, Uri releaseUri) {
    final match = RegExp(
      r'''href=["']([^"']*?/releases/download/[^"']+?\.apk)["']''',
      caseSensitive: false,
    ).firstMatch(html);
    if (match == null) {
      throw const FormatException('APK download link not found');
    }
    return releaseUri.resolve(match.group(1)!);
  }
}
