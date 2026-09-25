import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/manual_activity_importer.dart';

class WearableActivitiesPage extends StatefulWidget {
  const WearableActivitiesPage({
    required this.clubId,
    required this.clubName,
    super.key,
  });

  final String clubId;
  final String clubName;

  @override
  State<WearableActivitiesPage> createState() => _WearableActivitiesPageState();
}

class _WearableActivitiesPageState extends State<WearableActivitiesPage> {
  final _client = Supabase.instance.client;
  final _appLinks = AppLinks();
  final _activityImporter = const ManualActivityImporter();
  StreamSubscription<Uri>? _linkSubscription;
  List<_WearableActivity> _activities = [];
  List<_AssignedTraining> _sessions = [];
  bool _isLoading = true;
  bool _isBusy = false;
  bool _isConnected = false;
  String? _error;
  String? _message;
  String? _lastHandledLink;

  @override
  void initState() {
    super.initState();
    _linkSubscription = _appLinks.uriLinkStream.listen(_handleLink);
    unawaited(_readInitialLink());
    unawaited(_loadData());
  }

  @override
  void dispose() {
    unawaited(_linkSubscription?.cancel());
    super.dispose();
  }

  Future<void> _readInitialLink() async {
    try {
      final uri = await _appLinks.getInitialLink();
      if (uri != null) _handleLink(uri);
    } catch (_) {
      // The normal page load still works if the platform has no initial link.
    }
  }

  void _handleLink(Uri uri) {
    if (uri.scheme != 'trainingapp' ||
        uri.host != 'polar-connected' ||
        uri.toString() == _lastHandledLink) {
      return;
    }
    _lastHandledLink = uri.toString();
    final connected = uri.queryParameters['status'] == 'connected';
    if (!mounted) return;
    setState(() {
      _message = connected
          ? 'Cuenta Polar conectada.'
          : 'Polar no pudo completar la conexión. Inténtalo otra vez.';
    });
    unawaited(_loadData());
  }

  Future<void> _loadData() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }
    try {
      final userId = _client.auth.currentUser!.id;
      var connected = false;
      try {
        final status = await _client.functions.invoke(
          'polar-connect',
          method: HttpMethod.get,
        );
        final statusData = status.data as Map<String, dynamic>;
        connected = statusData['connected'] == true;
      } catch (_) {
        // Manual imports and saved activities remain available without Polar.
      }
      final activityRows = await _client
          .from('wearable_activities')
          .select(
            'id, provider_activity_id, linked_training_session_id, title, '
            'sport, started_at, duration_seconds, distance_meters, '
            'average_heart_rate, maximum_heart_rate, calories',
          )
          .eq('athlete_id', userId)
          .order('started_at', ascending: false)
          .limit(40);
      final sessionRows = await _client
          .from('training_sessions')
          .select('id, title, scheduled_at')
          .eq('club_id', widget.clubId)
          .eq('athlete_id', userId)
          .order('scheduled_at', ascending: false);

      if (!mounted) return;
      setState(() {
        _isConnected = connected;
        _activities = activityRows
            .map((row) => _WearableActivity.fromMap(row))
            .toList();
        _sessions = sessionRows
            .map((row) => _AssignedTraining.fromMap(row))
            .toList();
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudieron cargar las actividades del reloj: $error';
        _isLoading = false;
      });
    }
  }

  Future<void> _connect() async {
    setState(() {
      _isBusy = true;
      _error = null;
      _message = null;
    });
    try {
      final response = await _client.functions.invoke('polar-connect');
      final data = response.data as Map<String, dynamic>;
      final authorizationUrl = data['authorizationUrl'] as String?;
      if (authorizationUrl == null ||
          !await launchUrl(
            Uri.parse(authorizationUrl),
            mode: LaunchMode.externalApplication,
          )) {
        throw StateError('No se pudo abrir la autorización de Polar.');
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'No se pudo conectar Polar: $error');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _sync() async {
    setState(() {
      _isBusy = true;
      _error = null;
      _message = null;
    });
    try {
      final response = await _client.functions.invoke('polar-sync');
      final result = response.data as Map<String, dynamic>;
      final count = result['imported'] as int? ?? 0;
      await _loadData();
      if (mounted) {
        setState(
          () => _message = count == 0
              ? 'No hay actividades nuevas para importar.'
              : 'Se importaron $count actividades de Polar.',
        );
      }
    } on FunctionException catch (error) {
      if (mounted) setState(() => _error = _functionMessage(error));
    } catch (error) {
      if (mounted)
        setState(() => _error = 'No se pudieron importar actividades: $error');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Desconectar Polar'),
        content: const Text(
          'Se revocará el acceso a Polar y se quitará de forma segura la '
          'credencial guardada. Las actividades ya importadas se conservarán.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Desconectar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _isBusy = true;
      _error = null;
      _message = null;
    });
    try {
      await _client.functions.invoke('polar-disconnect');
      await _loadData();
      if (mounted) setState(() => _message = 'Cuenta Polar desconectada.');
    } on FunctionException catch (error) {
      if (mounted) setState(() => _error = _functionMessage(error));
    } catch (error) {
      if (mounted)
        setState(() => _error = 'No se pudo desconectar Polar: $error');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _importGarminFile() async {
    setState(() {
      _isBusy = true;
      _error = null;
      _message = null;
    });
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['tcx', 'gpx'],
      );
      if (file == null) return;
      final fileLength = file.lengthSync() ?? await file.length();
      if (fileLength == null || fileLength == 0) {
        throw const FormatException('El archivo está vacío o no se pudo leer.');
      }
      if (fileLength > 25 * 1024 * 1024) {
        throw const FormatException(
          'El archivo supera el límite de 25 MB para una actividad.',
        );
      }
      final imported = _activityImporter.parse(
        fileName: file.name,
        bytes: await file.readAsBytes(),
      );
      final athleteId = _client.auth.currentUser!.id;
      final ids = imported
          .map((activity) => activity.providerActivityId)
          .toList();
      final existingRows = await _client
          .from('wearable_activities')
          .select('provider_activity_id')
          .eq('athlete_id', athleteId)
          .eq('provider', 'garmin')
          .inFilter('provider_activity_id', ids);
      final existingIds = existingRows
          .map((row) => row['provider_activity_id'] as String)
          .toSet();
      final newActivities = imported
          .where(
            (activity) => !existingIds.contains(activity.providerActivityId),
          )
          .toList();
      if (newActivities.isNotEmpty) {
        await _client
            .from('wearable_activities')
            .insert(
              newActivities
                  .map((activity) => activity.toDatabaseRow(athleteId))
                  .toList(),
            );
      }
      await _loadData();
      if (mounted) {
        setState(() {
          _message = newActivities.isEmpty
              ? 'Ese archivo ya se había importado.'
              : 'Se importaron ${newActivities.length} actividades de Garmin.';
        });
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'No se pudo importar el archivo: $error');
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _linkActivity(_WearableActivity activity) async {
    if (_sessions.isEmpty) {
      setState(
        () => _error = 'Todavía no tienes sesiones asignadas en este club.',
      );
      return;
    }
    final selectedId = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Vincular con una sesión'),
        children: [
          for (final session in _sessions)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, session.id),
              child: Text(
                '${session.title} · ${_formatDate(session.scheduledAt.toLocal())}',
              ),
            ),
        ],
      ),
    );
    if (selectedId == null || !mounted) return;
    setState(() {
      _isBusy = true;
      _error = null;
    });
    try {
      await _client
          .from('wearable_activities')
          .update({'linked_training_session_id': selectedId})
          .eq('id', activity.id)
          .eq('athlete_id', _client.auth.currentUser!.id);
      await _loadData();
      if (mounted)
        setState(() => _message = 'Actividad vinculada a la sesión.');
    } catch (error) {
      if (mounted) setState(() => _error = 'No se pudo vincular: $error');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  String _functionMessage(FunctionException error) {
    final details = error.details;
    if (details is Map && details['error'] is String) {
      return details['error'] as String;
    }
    return 'La solicitud a Supabase falló (${error.status}).';
  }

  String _formatDate(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/${date.year}';

  String _linkedSessionTitle(_WearableActivity activity) {
    for (final session in _sessions) {
      if (session.id == activity.linkedSessionId) return session.title;
    }
    return 'Vinculada a sesión';
  }

  String _formatDuration(int? seconds) {
    if (seconds == null) return 'Duración no disponible';
    final duration = Duration(seconds: seconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final remainingSeconds = duration.inSeconds.remainder(60);
    return hours > 0
        ? '${hours}h ${minutes}m'
        : '${minutes}m ${remainingSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reloj y actividades')),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Polar Flow · ${widget.clubName}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _isConnected ? 'Cuenta Polar conectada.' : 'Conecta Polar Flow para importar tus entrenamientos.',
                    ),
                    const SizedBox(height: 12),
                    if (_isConnected) ...[
                      FilledButton.icon(
                        onPressed: _isBusy ? null : _sync,
                        icon: const Icon(Icons.sync),
                        label: const Text('Sincronizar actividades'),
                      ),
                      TextButton.icon(
                        onPressed: _isBusy ? null : _disconnect,
                        icon: const Icon(Icons.link_off),
                        label: const Text('Desconectar Polar'),
                      ),
                    ] else
                      FilledButton.icon(
                        onPressed: _isBusy ? null : _connect,
                        icon: const Icon(Icons.watch_outlined),
                        label: const Text('Conectar Polar'),
                      ),
                  ],
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Garmin Connect',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'La conexión estará disponible cuando Garmin apruebe el '
                      'acceso a su Activity API. Por ahora puedes consultar '
                      'los requisitos del programa para desarrolladores.',
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () => launchUrl(
                        Uri.parse(
                          'https://developer.garmin.com/gc-developer-program/activity-api/',
                        ),
                        mode: LaunchMode.externalApplication,
                      ),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Ver requisitos de Garmin'),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Importación manual desde Garmin Connect',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Exporta una actividad como TCX o GPX desde Garmin Connect '
                      'y selecciónala aquí. La app procesa el archivo en el '
                      'teléfono y guarda solo el resumen de la actividad.',
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _isBusy ? null : _importGarminFile,
                      icon: const Icon(Icons.upload_file_outlined),
                      label: const Text('Elegir archivo TCX o GPX'),
                    ),
                  ],
                ),
              ),
            ),
            if (_isBusy) const LinearProgressIndicator(),
            if (_error != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!),
                ),
              ),
            if (_message != null)
              Card(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_message!),
                ),
              ),
            const SizedBox(height: 16),
            Text(
              'Actividades importadas',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_activities.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('Aquí aparecerán las actividades que importes.'),
              )
            else
              for (final activity in _activities)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.directions_run),
                          title: Text(activity.title),
                          subtitle: Text(
                            [
                              _formatDate(activity.startedAt.toLocal()),
                              _formatDuration(activity.durationSeconds),
                              if (activity.distanceMeters != null)
                                '${(activity.distanceMeters! / 1000).toStringAsFixed(2)} km',
                              if (activity.averageHeartRate != null)
                                'FC media ${activity.averageHeartRate} bpm',
                              if (activity.maximumHeartRate != null)
                                'FC máx. ${activity.maximumHeartRate} bpm',
                            ].join(' · '),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: _isBusy
                                ? null
                                : () => _linkActivity(activity),
                            icon: Icon(
                              activity.linkedSessionId == null
                                  ? Icons.link
                                  : Icons.link_off,
                            ),
                            label: Text(
                              activity.linkedSessionId == null
                                  ? 'Vincular a una sesión'
                                  : _linkedSessionTitle(activity),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _WearableActivity {
  const _WearableActivity({
    required this.id,
    required this.title,
    required this.startedAt,
    required this.linkedSessionId,
    this.sport,
    this.durationSeconds,
    this.distanceMeters,
    this.averageHeartRate,
    this.maximumHeartRate,
  });

  factory _WearableActivity.fromMap(Map<String, dynamic> row) =>
      _WearableActivity(
        id: row['id'] as String,
        title: row['title'] as String,
        startedAt: DateTime.parse(row['started_at'] as String),
        linkedSessionId: row['linked_training_session_id'] as String?,
        sport: row['sport'] as String?,
        durationSeconds: row['duration_seconds'] as int?,
        distanceMeters: (row['distance_meters'] as num?)?.toDouble(),
        averageHeartRate: row['average_heart_rate'] as int?,
        maximumHeartRate: row['maximum_heart_rate'] as int?,
      );

  final String id;
  final String title;
  final String? sport;
  final DateTime startedAt;
  final int? durationSeconds;
  final double? distanceMeters;
  final int? averageHeartRate;
  final int? maximumHeartRate;
  final String? linkedSessionId;
}

class _AssignedTraining {
  const _AssignedTraining({
    required this.id,
    required this.title,
    required this.scheduledAt,
  });

  factory _AssignedTraining.fromMap(Map<String, dynamic> row) =>
      _AssignedTraining(
        id: row['id'] as String,
        title: row['title'] as String,
        scheduledAt: DateTime.parse(row['scheduled_at'] as String),
      );

  final String id;
  final String title;
  final DateTime scheduledAt;
}
