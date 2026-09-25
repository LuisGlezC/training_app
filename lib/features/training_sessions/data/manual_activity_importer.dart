import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:convert';

import 'package:xml/xml.dart';

class ImportedActivity {
  const ImportedActivity({
    required this.providerActivityId,
    required this.title,
    required this.sport,
    required this.startedAt,
    this.durationSeconds,
    this.distanceMeters,
    this.averageHeartRate,
    this.maximumHeartRate,
    this.calories,
  });

  final String providerActivityId;
  final String title;
  final String? sport;
  final DateTime startedAt;
  final int? durationSeconds;
  final double? distanceMeters;
  final int? averageHeartRate;
  final int? maximumHeartRate;
  final int? calories;

  Map<String, dynamic> toDatabaseRow(String athleteId) => {
    'athlete_id': athleteId,
    'provider': 'garmin',
    'provider_activity_id': providerActivityId,
    'title': title,
    'sport': sport,
    'started_at': startedAt.toUtc().toIso8601String(),
    'duration_seconds': durationSeconds,
    'distance_meters': distanceMeters,
    'average_heart_rate': averageHeartRate,
    'maximum_heart_rate': maximumHeartRate,
    'calories': calories,
  };
}

class ManualActivityImporter {
  const ManualActivityImporter();

  List<ImportedActivity> parse({
    required String fileName,
    required Uint8List bytes,
  }) {
    final extension = fileName.split('.').last.toLowerCase();
    if (extension != 'tcx' && extension != 'gpx') {
      throw const FormatException('Elige un archivo .tcx o .gpx.');
    }
    if (bytes.isEmpty) {
      throw const FormatException('El archivo está vacío.');
    }

    final document = XmlDocument.parse(
      utf8.decode(bytes, allowMalformed: true),
    );
    final activities = extension == 'tcx'
        ? _parseTcx(document)
        : _parseGpx(document);
    if (activities.isEmpty) {
      throw const FormatException(
        'No encontré una actividad con fecha en ese archivo.',
      );
    }
    return {
      for (final activity in activities) activity.providerActivityId: activity,
    }.values.toList();
  }

  List<ImportedActivity> _parseTcx(XmlDocument document) {
    final activityNodes = document.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'Activity',
    );
    return [
      for (final activity in activityNodes)
        if (_parseTcxActivity(activity) case final parsed?) parsed,
    ];
  }

  ImportedActivity? _parseTcxActivity(XmlElement activity) {
    final startText = _childText(activity, 'Id');
    final startedAt = startText == null ? null : DateTime.tryParse(startText);
    if (startedAt == null) return null;

    final laps = activity.children
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'Lap')
        .toList();
    final durationValues = laps
        .map((lap) => _childDouble(lap, 'TotalTimeSeconds'))
        .whereType<double>()
        .toList();
    final distanceValues = laps
        .map((lap) => _childDouble(lap, 'DistanceMeters'))
        .whereType<double>()
        .toList();
    final calorieValues = laps
        .map((lap) => _childInt(lap, 'Calories'))
        .whereType<int>()
        .toList();
    final averageValues = laps
        .map((lap) => _childInt(lap, 'AverageHeartRateBpm', nested: 'Value'))
        .whereType<int>()
        .toList();
    final maximumValues = laps
        .map((lap) => _childInt(lap, 'MaximumHeartRateBpm', nested: 'Value'))
        .whereType<int>()
        .toList();
    final sport = activity.getAttribute('Sport');
    final formattedDate = startedAt
        .toLocal()
        .toIso8601String()
        .split('T')
        .first;
    final sportTitle = _sportTitle(sport);

    return ImportedActivity(
      providerActivityId: _activityId(
        startedAt,
        durationValues,
        distanceValues,
      ),
      title: '$sportTitle · $formattedDate',
      sport: sport,
      startedAt: startedAt,
      durationSeconds: durationValues.isEmpty
          ? null
          : durationValues.fold<double>(0, (sum, value) => sum + value).round(),
      distanceMeters: distanceValues.isEmpty
          ? null
          : distanceValues.fold<double>(0, (sum, value) => sum + value),
      averageHeartRate: averageValues.isEmpty
          ? null
          : (averageValues.reduce((a, b) => a + b) / averageValues.length)
                .round(),
      maximumHeartRate: maximumValues.isEmpty
          ? null
          : maximumValues.fold<int>(
              0,
              (maximum, value) => value > maximum ? value : maximum,
            ),
      calories: calorieValues.isEmpty
          ? null
          : calorieValues.fold<int>(0, (sum, value) => sum + value),
    );
  }

  List<ImportedActivity> _parseGpx(XmlDocument document) {
    final tracks = document.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'trk',
    );
    final results = <ImportedActivity>[];
    for (final track in tracks) {
      final points = track.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'trkpt')
          .toList();
      final timestamps = points
          .map((point) => _childText(point, 'time'))
          .whereType<String>()
          .map(DateTime.tryParse)
          .whereType<DateTime>()
          .toList();
      if (timestamps.isEmpty) continue;
      timestamps.sort();
      final distance = _trackDistance(points);
      final heartRates = points
          .map((point) => _descendantText(point, 'hr'))
          .whereType<String>()
          .map(int.tryParse)
          .whereType<int>()
          .toList();
      final title = _childText(track, 'name') ?? 'Actividad Garmin';
      final sport = _childText(track, 'type');
      final duration = timestamps.last.difference(timestamps.first).inSeconds;

      results.add(
        ImportedActivity(
          providerActivityId: _activityId(
            timestamps.first,
            [duration.toDouble()],
            [distance],
          ),
          title: title,
          sport: sport,
          startedAt: timestamps.first,
          durationSeconds: duration < 0 ? null : duration,
          distanceMeters: distance > 0 ? distance : null,
          averageHeartRate: heartRates.isEmpty
              ? null
              : (heartRates.reduce((a, b) => a + b) / heartRates.length)
                    .round(),
          maximumHeartRate: heartRates.isEmpty
              ? null
              : heartRates.fold<int>(
                  0,
                  (maximum, value) => value > maximum ? value : maximum,
                ),
        ),
      );
    }
    return results;
  }

  String? _childText(XmlElement parent, String name, {String? nested}) {
    for (final child in parent.children.whereType<XmlElement>()) {
      if (child.name.local != name) continue;
      if (nested == null) return child.innerText.trim();
      for (final nestedChild in child.children.whereType<XmlElement>()) {
        if (nestedChild.name.local == nested)
          return nestedChild.innerText.trim();
      }
    }
    return null;
  }

  String? _descendantText(XmlElement parent, String name) {
    for (final child in parent.descendants.whereType<XmlElement>()) {
      if (child.name.local == name) return child.innerText.trim();
    }
    return null;
  }

  double? _childDouble(XmlElement parent, String name) {
    final value = _childText(parent, name);
    return value == null ? null : double.tryParse(value);
  }

  int? _childInt(XmlElement parent, String name, {String? nested}) {
    final value = _childText(parent, name, nested: nested);
    return value == null ? null : int.tryParse(value);
  }

  double _trackDistance(List<XmlElement> points) {
    var meters = 0.0;
    (double, double)? previous;
    for (final point in points) {
      final latitude = double.tryParse(point.getAttribute('lat') ?? '');
      final longitude = double.tryParse(point.getAttribute('lon') ?? '');
      if (latitude == null || longitude == null) continue;
      final current = (latitude, longitude);
      final last = previous;
      if (last != null) meters += _distanceBetween(last, current);
      previous = current;
    }
    return meters;
  }

  double _distanceBetween((double, double) first, (double, double) second) {
    const earthRadiusMeters = 6371000.0;
    final latitudeDelta = _toRadians(second.$1 - first.$1);
    final longitudeDelta = _toRadians(second.$2 - first.$2);
    final a =
        (math.pow(math.sin(latitudeDelta / 2), 2) +
                math.cos(_toRadians(first.$1)) *
                    math.cos(_toRadians(second.$1)) *
                    math.pow(math.sin(longitudeDelta / 2), 2))
            .clamp(0.0, 1.0)
            .toDouble();
    return earthRadiusMeters * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  double _toRadians(double degrees) => degrees * math.pi / 180;

  String _sportTitle(String? sport) {
    switch (sport?.toLowerCase()) {
      case 'running':
        return 'Carrera';
      case 'biking':
      case 'cycling':
        return 'Ciclismo';
      case 'swimming':
        return 'Natación';
      case null:
      case '':
        return 'Actividad Garmin';
      default:
        return sport!;
    }
  }

  String _activityId(
    DateTime startedAt,
    List<double> durations,
    List<double> distances,
  ) {
    final duration = durations
        .fold<double>(0, (sum, value) => sum + value)
        .round();
    final distance = distances
        .fold<double>(0, (sum, value) => sum + value)
        .round();
    return 'manual-${startedAt.toUtc().millisecondsSinceEpoch}-$duration-$distance';
  }
}
