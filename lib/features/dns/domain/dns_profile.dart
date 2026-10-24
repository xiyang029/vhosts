class DnsProfile {
  const DnsProfile({
    required this.id,
    required this.name,
    required this.server,
    required this.secondaryServer,
    required this.timeoutMs,
    required this.retryCount,
    required this.enabled,
  });

  final String id;
  final String name;
  final String server;
  final String secondaryServer;
  final int timeoutMs;
  final int retryCount;
  final bool enabled;

  factory DnsProfile.fromJson(Map<dynamic, dynamic> json) {
    return DnsProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      server: json['server'] as String,
      secondaryServer: json['secondaryServer'] as String,
      timeoutMs: (json['timeoutMs'] as num).toInt(),
      retryCount: (json['retryCount'] as num).toInt(),
      enabled: json['enabled'] as bool,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'server': server,
      'secondaryServer': secondaryServer,
      'timeoutMs': timeoutMs,
      'retryCount': retryCount,
      'enabled': enabled,
    };
  }
}
