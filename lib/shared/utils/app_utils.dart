bool hasUriHost(String value, {required String scheme}) {
  final input = value.trim();
  if (input.isEmpty) {
    return false;
  }
  final uri = Uri.tryParse('$scheme://$input');
  return uri != null && uri.host.isNotEmpty;
}
