enum HostMatchType { exact, suffix }

extension HostMatchTypeX on HostMatchType {
  String get label => switch (this) {
    HostMatchType.exact => '精确',
    HostMatchType.suffix => '后缀',
  };
}

class HostRule {
  const HostRule({
    required this.id,
    required this.domain,
    required this.matchType,
    required this.targetIp,
    required this.enabled,
    required this.note,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String domain;
  final HostMatchType matchType;
  final String targetIp;
  final bool enabled;
  final String note;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory HostRule.fromJson(Map<String, dynamic> json) {
    return HostRule(
      id: json['id'] as String,
      domain: json['domain'] as String,
      matchType: HostMatchType.values.byName(json['matchType'] as String),
      targetIp: json['targetIp'] as String,
      enabled: json['enabled'] as bool,
      note: json['note'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  HostRule copyWith({
    String? id,
    String? domain,
    HostMatchType? matchType,
    String? targetIp,
    bool? enabled,
    String? note,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return HostRule(
      id: id ?? this.id,
      domain: domain ?? this.domain,
      matchType: matchType ?? this.matchType,
      targetIp: targetIp ?? this.targetIp,
      enabled: enabled ?? this.enabled,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'domain': domain,
      'matchType': matchType.name,
      'targetIp': targetIp,
      'enabled': enabled,
      'note': note,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }
}
