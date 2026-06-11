T enumByName<T extends Enum>(Iterable<T> values, String value, T fallback) {
  return values.firstWhere(
    (item) => item.name == value,
    orElse: () => fallback,
  );
}

String stringValue(dynamic value, [String fallback = '']) {
  if (value == null) {
    return fallback;
  }
  return value.toString();
}

bool boolValue(dynamic value, [bool fallback = false]) {
  return value is bool ? value : fallback;
}

int intValue(dynamic value, [int fallback = 0]) {
  return value is num ? value.toInt() : fallback;
}

int? nullableIntValue(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value.toString());
}

DateTime dateTimeValue(dynamic value, [DateTime? fallback]) {
  if (value is DateTime) {
    return value;
  }
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) {
      return parsed;
    }
  }
  return fallback ?? DateTime.fromMillisecondsSinceEpoch(0);
}

bool hasUriHost(String value, {required String scheme}) {
  final input = value.trim();
  if (input.isEmpty) {
    return false;
  }
  final uri = Uri.tryParse('$scheme://$input');
  return uri != null && uri.host.isNotEmpty;
}
