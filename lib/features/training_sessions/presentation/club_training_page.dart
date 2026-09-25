import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'wearable_activities_page.dart';

class ClubTrainingPage extends StatefulWidget {
  const ClubTrainingPage({
    required this.clubId,
    required this.clubName,
    required this.role,
    super.key,
  });

  final String clubId;
  final String clubName;
  final String role;

  @override
  State<ClubTrainingPage> createState() => _ClubTrainingPageState();
}

class _ClubTrainingPageState extends State<ClubTrainingPage> {
  final _client = Supabase.instance.client;
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _distanceController = TextEditingController();
  final List<_ClubStepDraft> _stepDrafts = [_ClubStepDraft()];
  List<_ClubAthlete> _athletes = [];
  List<_CloudTrainingSession> _sessions = [];
  String? _selectedAthleteId;
  String? _progressAthleteId;
  DateTime _scheduledDate = DateTime.now();
  bool _isLoading = true;
  bool _isSaving = false;
  bool _showAssignmentForm = false;
  String? _error;
  String? _message;

  bool get _isCoach => widget.role == 'coach';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _distanceController.dispose();
    for (final draft in _stepDrafts) {
      draft.dispose();
    }
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      List<_ClubAthlete> athletes = [];
      if (_isCoach) {
        final athleteRows = await _client
            .from('club_memberships')
            .select('user_id, profiles(display_name)')
            .eq('club_id', widget.clubId)
            .eq('role', 'athlete')
            .order('joined_at');
        athletes = athleteRows.map((row) {
          final profile = row['profiles'] as Map<String, dynamic>;
          return _ClubAthlete(
            id: row['user_id'] as String,
            name: profile['display_name'] as String,
          );
        }).toList();
      }

      final sessionRows = await _client
          .from('training_sessions')
          .select(
            'id, athlete_id, title, description, distance_meters, scheduled_at',
          )
          .eq('club_id', widget.clubId)
          .order('scheduled_at');
      final sessionIds = sessionRows.map((row) => row['id'] as String).toList();
      final stepRows = sessionIds.isEmpty
          ? <dynamic>[]
          : await _client
                .from('training_steps')
                .select(
                  'training_session_id, position, title, target, description',
                )
                .inFilter('training_session_id', sessionIds)
                .order('position');
      final feedbackRows = sessionIds.isEmpty
          ? <dynamic>[]
          : await _client
                .from('session_feedback')
                .select(
                  'training_session_id, effort_rating, feeling_note, '
                  'voice_note_path, completed_at',
                )
                .inFilter('training_session_id', sessionIds);
      final wearableActivityRows = sessionIds.isEmpty
          ? <dynamic>[]
          : await _client
                .from('wearable_activities')
                .select(
                  'id, linked_training_session_id, provider, title, sport, '
                  'started_at, duration_seconds, distance_meters, '
                  'average_heart_rate, maximum_heart_rate',
                )
                .inFilter('linked_training_session_id', sessionIds)
                .order('started_at', ascending: false);

      final stepsBySession = <String, List<_CloudTrainingStep>>{};
      for (final row in stepRows) {
        final sessionId = row['training_session_id'] as String;
        stepsBySession
            .putIfAbsent(sessionId, () => [])
            .add(
              _CloudTrainingStep(
                title: row['title'] as String,
                target: row['target'] as String,
                description: row['description'] as String,
              ),
            );
      }
      final feedbackBySession = <String, _CloudFeedback>{
        for (final row in feedbackRows)
          row['training_session_id'] as String: _CloudFeedback.fromMap(row),
      };
      final activitiesBySession = <String, List<_WearableActivitySummary>>{};
      for (final row in wearableActivityRows) {
        final sessionId = row['linked_training_session_id'] as String;
        activitiesBySession
            .putIfAbsent(sessionId, () => [])
            .add(_WearableActivitySummary.fromMap(row));
      }
      final athleteNames = {
        for (final athlete in athletes) athlete.id: athlete.name,
      };
      final sessions = sessionRows
          .map(
            (row) => _CloudTrainingSession.fromMap(
              row,
              stepsBySession[row['id'] as String] ?? const [],
              athleteNames[row['athlete_id'] as String],
              feedbackBySession[row['id'] as String],
              activitiesBySession[row['id'] as String] ?? const [],
            ),
          )
          .toList();

      if (!mounted) return;
      setState(() {
        _athletes = athletes;
        _sessions = sessions;
        _selectedAthleteId ??= athletes.isEmpty ? null : athletes.first.id;
        if (_selectedAthleteId != null &&
            !athletes.any((athlete) => athlete.id == _selectedAthleteId)) {
          _selectedAthleteId = athletes.isEmpty ? null : athletes.first.id;
        }
        if (_progressAthleteId != null &&
            !athletes.any((athlete) => athlete.id == _progressAthleteId)) {
          _progressAthleteId = null;
        }
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudieron cargar los entrenamientos: $error';
        _isLoading = false;
      });
    }
  }

  Future<void> _chooseDate() async {
    final chosen = await showDatePicker(
      context: context,
      initialDate: _scheduledDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      helpText: 'Elige el día de entrenamiento',
    );
    if (chosen != null && mounted) {
      setState(() => _scheduledDate = chosen);
    }
  }

  Future<void> _assignTraining() async {
    final title = _titleController.text.trim();
    if (_selectedAthleteId == null) {
      setState(
        () => _error = 'Primero debe unirse al club al menos un atleta.',
      );
      return;
    }
    if (title.isEmpty) {
      setState(() => _error = 'Escribe el nombre de la sesión.');
      return;
    }

    final distanceText = _distanceController.text.trim().replaceAll(',', '.');
    final distanceKm = distanceText.isEmpty
        ? null
        : double.tryParse(distanceText);
    if (distanceText.isNotEmpty && (distanceKm == null || distanceKm <= 0)) {
      setState(
        () => _error = 'La distancia debe ser un número mayor que cero.',
      );
      return;
    }

    final steps = <Map<String, String>>[];
    for (final draft in _stepDrafts) {
      final stepTitle = draft.titleController.text.trim();
      final target = draft.targetController.text.trim();
      final detail = draft.descriptionController.text.trim();
      if (stepTitle.isEmpty && target.isEmpty && detail.isEmpty) continue;
      if (stepTitle.isEmpty || target.isEmpty) {
        setState(
          () => _error = 'Completa el nombre y el objetivo de cada paso.',
        );
        return;
      }
      steps.add({'title': stepTitle, 'target': target, 'description': detail});
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isSaving = true;
      _error = null;
      _message = null;
    });
    try {
      await _client.rpc(
        'assign_training_session',
        params: {
          'target_club_id': widget.clubId,
          'target_athlete_id': _selectedAthleteId,
          'session_title': title,
          'session_description': _descriptionController.text.trim(),
          'session_distance_meters': distanceKm == null
              ? null
              : (distanceKm * 1000).round(),
          'session_scheduled_at': DateTime(
            _scheduledDate.year,
            _scheduledDate.month,
            _scheduledDate.day,
            12,
          ).toUtc().toIso8601String(),
          'session_steps': steps,
        },
      );
      _titleController.clear();
      _descriptionController.clear();
      _distanceController.clear();
      for (final draft in _stepDrafts) {
        draft.dispose();
      }
      _stepDrafts
        ..clear()
        ..add(_ClubStepDraft());
      setState(() => _showAssignmentForm = false);
      await _loadData();
      if (mounted) setState(() => _message = 'Sesión asignada correctamente.');
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted)
        setState(() => _error = 'No se pudo guardar la sesión: $error');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _recordFeedback(_CloudTrainingSession session) async {
    final draft = await showDialog<_ClubFeedbackDraft>(
      context: context,
      builder: (_) => _ClubFeedbackDialog(feedback: session.feedback),
    );
    if (draft == null || !mounted) return;

    final athleteId = _client.auth.currentUser?.id;
    if (athleteId == null) {
      setState(() => _error = 'Inicia sesión para registrar el entrenamiento.');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
      _message = null;
    });
    final completedAt = draft.isCompleted ? DateTime.now().toUtc() : null;
    final previousVoiceNotePath = session.feedback?.voiceNotePath;
    var voiceNotePath = draft.removeVoiceNote ? null : previousVoiceNotePath;
    String? uploadedVoiceNotePath;
    try {
      if (draft.recordedVoicePath != null) {
        voiceNotePath =
            '${session.id}/$athleteId-'
            '${DateTime.now().microsecondsSinceEpoch}.m4a';
        await _client.storage
            .from('training-voice-notes')
            .upload(
              voiceNotePath,
              File(draft.recordedVoicePath!),
              fileOptions: const FileOptions(contentType: 'audio/mp4'),
            );
        uploadedVoiceNotePath = voiceNotePath;
      }
      await _client.from('session_feedback').upsert({
        'training_session_id': session.id,
        'athlete_id': athleteId,
        'effort_rating': draft.effortRating,
        'feeling_note': draft.note.isEmpty ? null : draft.note,
        'voice_note_path': voiceNotePath,
        'completed_at': completedAt?.toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'training_session_id');
      if (previousVoiceNotePath != null &&
          previousVoiceNotePath != voiceNotePath) {
        try {
          await _client.storage.from('training-voice-notes').remove([
            previousVoiceNotePath,
          ]);
        } catch (_) {
          // A stale file can be cleaned up later; the saved feedback is valid.
        }
      }
      if (!mounted) return;
      setState(() {
        session.feedback = _CloudFeedback(
          effortRating: draft.effortRating,
          feelingNote: draft.note.isEmpty ? null : draft.note,
          voiceNotePath: voiceNotePath,
          completedAt: completedAt,
        );
        _message = 'Entrenamiento y sensaciones guardados.';
      });
    } on PostgrestException catch (error) {
      await _removeUploadedVoiceNote(uploadedVoiceNotePath);
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      await _removeUploadedVoiceNote(uploadedVoiceNotePath);
      if (mounted) setState(() => _error = 'No se pudo guardar: $error');
    } finally {
      if (draft.recordedVoicePath != null) {
        try {
          await File(draft.recordedVoicePath!).delete();
        } catch (_) {
          // Temporary files are also removed by the operating system.
        }
      }
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _removeUploadedVoiceNote(String? path) async {
    if (path == null) return;
    try {
      await _client.storage.from('training-voice-notes').remove([path]);
    } catch (_) {
      // Do not hide the original feedback save error.
    }
  }

  String _formatDate(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/${date.year}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.clubName)),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              if (_error != null)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!),
                  ),
                ),
              if (_message != null)
                Card(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_message!),
                  ),
                ),
              if (!_isCoach)
                OutlinedButton.icon(
                  onPressed: _isSaving
                      ? null
                      : () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => WearableActivitiesPage(
                                clubId: widget.clubId,
                                clubName: widget.clubName,
                              ),
                            ),
                          );
                          if (mounted) await _loadData();
                        },
                  icon: const Icon(Icons.watch_outlined),
                  label: const Text('Reloj y actividades'),
                ),
              if (_isCoach) ...[
                OutlinedButton.icon(
                  onPressed: _isSaving
                      ? null
                      : () => setState(() {
                          _showAssignmentForm = !_showAssignmentForm;
                          _error = null;
                          _message = null;
                        }),
                  icon: const Icon(Icons.add),
                  label: Text(
                    _showAssignmentForm
                        ? 'Ocultar formulario'
                        : 'Asignar entrenamiento',
                  ),
                ),
                if (_showAssignmentForm) ...[
                  const SizedBox(height: 12),
                  if (_athletes.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'Aún no hay atletas aprobados en este club. '
                          'Cuando se una uno, podrás asignarle sesiones.',
                        ),
                      ),
                    )
                  else ...[
                    DropdownButtonFormField<String>(
                      initialValue: _selectedAthleteId,
                      decoration: const InputDecoration(
                        labelText: 'Atleta',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final athlete in _athletes)
                          DropdownMenuItem(
                            value: athlete.id,
                            child: Text(athlete.name),
                          ),
                      ],
                      onChanged: _isSaving
                          ? null
                          : (id) {
                              if (id != null) {
                                setState(() => _selectedAthleteId = id);
                              }
                            },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _titleController,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Nombre del entrenamiento',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _descriptionController,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Descripción o instrucciones',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _distanceController,
                      decoration: const InputDecoration(
                        labelText: 'Distancia total en km (opcional)',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _isSaving ? null : _chooseDate,
                        icon: const Icon(Icons.calendar_today_outlined),
                        label: Text('Fecha: ${_formatDate(_scheduledDate)}'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Pasos del entrenamiento (opcional)',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    for (var index = 0; index < _stepDrafts.length; index++)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(child: Text('Paso ${index + 1}')),
                                  if (_stepDrafts.length > 1)
                                    IconButton(
                                      onPressed: _isSaving
                                          ? null
                                          : () => setState(() {
                                              _stepDrafts
                                                  .removeAt(index)
                                                  .dispose();
                                            }),
                                      tooltip: 'Eliminar paso',
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                                ],
                              ),
                              TextField(
                                controller: _stepDrafts[index].titleController,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                decoration: const InputDecoration(
                                  labelText: 'Nombre del paso',
                                ),
                              ),
                              TextField(
                                controller: _stepDrafts[index].targetController,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                decoration: const InputDecoration(
                                  labelText: 'Objetivo',
                                  hintText: 'Ejemplo: 2 km o 5 × 400 m',
                                ),
                              ),
                              TextField(
                                controller:
                                    _stepDrafts[index].descriptionController,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                maxLines: 2,
                                decoration: const InputDecoration(
                                  labelText: 'Instrucciones',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _isSaving
                            ? null
                            : () => setState(
                                () => _stepDrafts.add(_ClubStepDraft()),
                              ),
                        icon: const Icon(Icons.add),
                        label: const Text('Agregar paso'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _isSaving ? null : _assignTraining,
                      child: const Text('Guardar y asignar'),
                    ),
                  ],
                ],
              ],
              const SizedBox(height: 20),
              Text(
                'Entrenamientos',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (_isCoach && _athletes.isNotEmpty) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _progressAthleteId ?? 'all',
                  decoration: const InputDecoration(
                    labelText: 'Progreso del atleta',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: 'all',
                      child: Text('Todo el club'),
                    ),
                    for (final athlete in _athletes)
                      DropdownMenuItem(
                        value: athlete.id,
                        child: Text(athlete.name),
                      ),
                  ],
                  onChanged: (value) => setState(
                    () => _progressAthleteId = value == 'all' ? null : value,
                  ),
                ),
              ],
              if (_isCoach)
                _ClubProgressSummary(
                  sessions: _sessions.where(
                    (session) =>
                        _progressAthleteId == null ||
                        session.athleteId == _progressAthleteId,
                  ),
                ),
              if (_visibleSessions.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('Todavía no hay entrenamientos asignados.'),
                ),
              for (final session in _visibleSessions)
                Card(
                  child: ExpansionTile(
                    leading: const Icon(Icons.directions_run),
                    title: Text(session.title),
                    subtitle: Text(
                      [
                        _formatDate(session.scheduledDate.toLocal()),
                        if (_isCoach && session.athleteName != null)
                          session.athleteName!,
                        if (session.distanceMeters != null)
                          '${(session.distanceMeters! / 1000).toStringAsFixed(1)} km',
                      ].join(' · '),
                    ),
                    children: [
                      if (session.description.isNotEmpty)
                        ListTile(
                          title: const Text('Instrucciones'),
                          subtitle: Text(session.description),
                        ),
                      for (var index = 0; index < session.steps.length; index++)
                        ListTile(
                          leading: CircleAvatar(child: Text('${index + 1}')),
                          title: Text(session.steps[index].title),
                          subtitle: Text(
                            [
                              session.steps[index].target,
                              if (session.steps[index].description.isNotEmpty)
                                session.steps[index].description,
                            ].join(' · '),
                          ),
                        ),
                      for (final activity in session.wearableActivities)
                        _CoachWearableActivitySummary(activity: activity),
                      if (_isCoach)
                        _CoachFeedbackSummary(
                          feedback: session.feedback,
                          formatDate: _formatDate,
                        )
                      else
                        Column(
                          children: [
                            _AthleteFeedbackSummary(
                              feedback: session.feedback,
                              formatDate: _formatDate,
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                              child: SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: _isSaving
                                      ? null
                                      : () => _recordFeedback(session),
                                  icon: const Icon(Icons.check_circle_outline),
                                  label: Text(
                                    session.feedback == null
                                        ? 'Registrar entrenamiento y sensaciones'
                                        : 'Actualizar entrenamiento y sensaciones',
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  List<_CloudTrainingSession> get _visibleSessions {
    if (_progressAthleteId == null) return _sessions;
    return _sessions
        .where((session) => session.athleteId == _progressAthleteId)
        .toList();
  }
}

class _ClubAthlete {
  const _ClubAthlete({required this.id, required this.name});

  final String id;
  final String name;
}

class _CloudTrainingStep {
  const _CloudTrainingStep({
    required this.title,
    required this.target,
    required this.description,
  });

  final String title;
  final String target;
  final String description;
}

class _CloudTrainingSession {
  _CloudTrainingSession({
    required this.id,
    required this.athleteId,
    required this.title,
    required this.description,
    required this.distanceMeters,
    required this.scheduledDate,
    required this.steps,
    required this.athleteName,
    required this.feedback,
    required this.wearableActivities,
  });

  factory _CloudTrainingSession.fromMap(
    Map<String, dynamic> row,
    List<_CloudTrainingStep> steps,
    String? athleteName,
    _CloudFeedback? feedback,
    List<_WearableActivitySummary> wearableActivities,
  ) {
    return _CloudTrainingSession(
      id: row['id'] as String,
      athleteId: row['athlete_id'] as String,
      title: row['title'] as String,
      description: row['description'] as String,
      distanceMeters: row['distance_meters'] as int?,
      scheduledDate: DateTime.parse(row['scheduled_at'] as String),
      steps: steps,
      athleteName: athleteName,
      feedback: feedback,
      wearableActivities: wearableActivities,
    );
  }

  final String id;
  final String athleteId;
  final String title;
  final String description;
  final int? distanceMeters;
  final DateTime scheduledDate;
  final List<_CloudTrainingStep> steps;
  final String? athleteName;
  _CloudFeedback? feedback;
  final List<_WearableActivitySummary> wearableActivities;
}

class _WearableActivitySummary {
  const _WearableActivitySummary({
    required this.provider,
    required this.title,
    required this.startedAt,
    this.sport,
    this.durationSeconds,
    this.distanceMeters,
    this.averageHeartRate,
    this.maximumHeartRate,
  });

  factory _WearableActivitySummary.fromMap(Map<String, dynamic> row) =>
      _WearableActivitySummary(
        provider: row['provider'] as String,
        title: row['title'] as String,
        startedAt: DateTime.parse(row['started_at'] as String),
        sport: row['sport'] as String?,
        durationSeconds: row['duration_seconds'] as int?,
        distanceMeters: (row['distance_meters'] as num?)?.toDouble(),
        averageHeartRate: row['average_heart_rate'] as int?,
        maximumHeartRate: row['maximum_heart_rate'] as int?,
      );

  final String provider;
  final String title;
  final String? sport;
  final DateTime startedAt;
  final int? durationSeconds;
  final double? distanceMeters;
  final int? averageHeartRate;
  final int? maximumHeartRate;
}

class _CoachWearableActivitySummary extends StatelessWidget {
  const _CoachWearableActivitySummary({required this.activity});

  final _WearableActivitySummary activity;

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      activity.provider.toUpperCase(),
      if (activity.sport != null) activity.sport!,
      if (activity.distanceMeters != null)
        '${(activity.distanceMeters! / 1000).toStringAsFixed(2)} km',
      if (activity.durationSeconds != null)
        '${activity.durationSeconds! ~/ 60} min',
      if (activity.averageHeartRate != null)
        'FC media ${activity.averageHeartRate} bpm',
      if (activity.maximumHeartRate != null)
        'FC máx. ${activity.maximumHeartRate} bpm',
    ];
    final startedAt = activity.startedAt.toLocal();
    return ListTile(
      leading: const Icon(Icons.watch_outlined),
      title: Text('Actividad importada · ${activity.title}'),
      subtitle: Text(
        '${startedAt.day.toString().padLeft(2, '0')}/'
        '${startedAt.month.toString().padLeft(2, '0')}/${startedAt.year}'
        ' · ${details.join(' · ')}',
      ),
    );
  }
}

class _CloudFeedback {
  const _CloudFeedback({
    required this.effortRating,
    required this.feelingNote,
    required this.voiceNotePath,
    required this.completedAt,
  });

  factory _CloudFeedback.fromMap(Map<String, dynamic> row) {
    final completedAt = row['completed_at'] as String?;
    return _CloudFeedback(
      effortRating: row['effort_rating'] as int?,
      feelingNote: row['feeling_note'] as String?,
      voiceNotePath: row['voice_note_path'] as String?,
      completedAt: completedAt == null ? null : DateTime.parse(completedAt),
    );
  }

  final int? effortRating;
  final String? feelingNote;
  final String? voiceNotePath;
  final DateTime? completedAt;
}

class _CoachFeedbackSummary extends StatelessWidget {
  const _CoachFeedbackSummary({
    required this.feedback,
    required this.formatDate,
  });

  final _CloudFeedback? feedback;
  final String Function(DateTime) formatDate;

  @override
  Widget build(BuildContext context) {
    final completedAt = feedback?.completedAt;
    return Column(
      children: [
        ListTile(
          leading: Icon(
            completedAt == null ? Icons.radio_button_unchecked : Icons.task_alt,
            color: completedAt == null
                ? Theme.of(context).colorScheme.outline
                : Theme.of(context).colorScheme.primary,
          ),
          title: Text(
            completedAt == null
                ? 'Pendiente'
                : 'Completado · ${formatDate(completedAt.toLocal())}',
          ),
          subtitle: feedback == null
              ? const Text('El atleta aún no registra sus sensaciones.')
              : Text(
                  [
                    if (feedback!.effortRating != null)
                      'Esfuerzo: ${feedback!.effortRating} de 10',
                    if (feedback!.feelingNote?.isNotEmpty == true)
                      feedback!.feelingNote!,
                    if (feedback!.effortRating == null &&
                        feedback!.feelingNote?.isNotEmpty != true &&
                        feedback!.voiceNotePath == null)
                      'Sin comentario.',
                  ].join('\n'),
                ),
        ),
        if (feedback?.voiceNotePath != null)
          _VoiceNotePlayer(path: feedback!.voiceNotePath!),
      ],
    );
  }
}

class _AthleteFeedbackSummary extends StatelessWidget {
  const _AthleteFeedbackSummary({
    required this.feedback,
    required this.formatDate,
  });

  final _CloudFeedback? feedback;
  final String Function(DateTime) formatDate;

  @override
  Widget build(BuildContext context) {
    final completedAt = feedback?.completedAt;
    return Column(
      children: [
        ListTile(
          leading: Icon(
            completedAt == null ? Icons.radio_button_unchecked : Icons.task_alt,
            color: completedAt == null
                ? Theme.of(context).colorScheme.outline
                : Theme.of(context).colorScheme.primary,
          ),
          title: Text(
            completedAt == null
                ? 'Pendiente de completar'
                : 'Completado · ${formatDate(completedAt.toLocal())}',
          ),
          subtitle: feedback == null
              ? const Text(
                  'Al terminar, registra tu esfuerzo y tus sensaciones.',
                )
              : Text(
                  [
                    if (feedback!.effortRating != null)
                      'Esfuerzo: ${feedback!.effortRating} de 10',
                    if (feedback!.feelingNote?.isNotEmpty == true)
                      feedback!.feelingNote!,
                  ].join('\n'),
                ),
        ),
        if (feedback?.voiceNotePath != null)
          _VoiceNotePlayer(path: feedback!.voiceNotePath!),
      ],
    );
  }
}

class _VoiceNotePlayer extends StatefulWidget {
  const _VoiceNotePlayer({required this.path});

  final String path;

  @override
  State<_VoiceNotePlayer> createState() => _VoiceNotePlayerState();
}

class _VoiceNotePlayerState extends State<_VoiceNotePlayer> {
  final _player = AudioPlayer();
  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<void>? _completeSubscription;
  bool _isLoading = false;
  bool _isPlaying = false;
  bool _isPaused = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _playerStateSubscription = _player.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() {
        _isPlaying = state == PlayerState.playing;
        _isPaused = state == PlayerState.paused;
      });
    });
    _completeSubscription = _player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _isPlaying = false;
        _isPaused = false;
      });
    });
  }

  @override
  void didUpdateWidget(covariant _VoiceNotePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _player.stop();
  }

  @override
  void dispose() {
    _playerStateSubscription?.cancel();
    _completeSubscription?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      if (_isPlaying) {
        await _player.pause();
      } else if (_isPaused) {
        await _player.resume();
      } else {
        final url = await Supabase.instance.client.storage
            .from('training-voice-notes')
            .createSignedUrl(widget.path, 300);
        await _player.play(UrlSource(url));
      }
    } catch (error) {
      if (mounted)
        setState(() => _error = 'No se pudo reproducir el audio: $error');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: _togglePlayback,
                icon: _isLoading
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                tooltip: _isPlaying
                    ? 'Pausar nota de voz'
                    : 'Reproducir nota de voz',
              ),
              const Text('Nota de voz del atleta'),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

class _ClubProgressSummary extends StatelessWidget {
  const _ClubProgressSummary({required this.sessions});

  final Iterable<_CloudTrainingSession> sessions;

  @override
  Widget build(BuildContext context) {
    final sessionList = sessions.toList();
    final completed = sessionList
        .where((session) => session.feedback?.completedAt != null)
        .toList();
    final completionRate = sessionList.isEmpty
        ? 0.0
        : completed.length / sessionList.length;
    final effortRatings = completed
        .map((session) => session.feedback?.effortRating)
        .whereType<int>()
        .toList();
    final averageEffort = effortRatings.isEmpty
        ? null
        : effortRatings.reduce((first, second) => first + second) /
              effortRatings.length;
    final today = DateTime.now();
    final days = List.generate(
      7,
      (index) => DateTime(today.year, today.month, today.day - 6 + index),
    );
    const weekdays = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
    final dailyCounts = [
      for (final day in days)
        completed.where((session) {
          final date = session.feedback!.completedAt!.toLocal();
          return date.year == day.year &&
              date.month == day.month &&
              date.day == day.day;
        }).length,
    ];
    final maxCount = dailyCounts.fold<int>(
      0,
      (max, count) => count > max ? count : max,
    );

    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Resumen de progreso',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 20,
              runSpacing: 8,
              children: [
                Text('${completed.length} / ${sessionList.length} completados'),
                Text('${(completionRate * 100).round()}% de cumplimiento'),
                if (averageEffort != null)
                  Text(
                    'Esfuerzo medio: ${averageEffort.toStringAsFixed(1)}/10',
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Sesiones completadas · últimos 7 días',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            for (var index = 0; index < days.length; index++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 36,
                      child: Text(weekdays[days[index].weekday - 1]),
                    ),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: maxCount == 0
                            ? 0
                            : dailyCounts[index] / maxCount,
                      ),
                    ),
                    SizedBox(
                      width: 28,
                      child: Text(
                        '${dailyCounts[index]}',
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ClubStepDraft {
  final titleController = TextEditingController();
  final targetController = TextEditingController();
  final descriptionController = TextEditingController();

  void dispose() {
    titleController.dispose();
    targetController.dispose();
    descriptionController.dispose();
  }
}

class _ClubFeedbackDraft {
  const _ClubFeedbackDraft({
    required this.isCompleted,
    required this.effortRating,
    required this.note,
    required this.recordedVoicePath,
    required this.removeVoiceNote,
  });

  final bool isCompleted;
  final int effortRating;
  final String note;
  final String? recordedVoicePath;
  final bool removeVoiceNote;
}

class _ClubFeedbackDialog extends StatefulWidget {
  const _ClubFeedbackDialog({required this.feedback});

  final _CloudFeedback? feedback;

  @override
  State<_ClubFeedbackDialog> createState() => _ClubFeedbackDialogState();
}

class _ClubFeedbackDialogState extends State<_ClubFeedbackDialog> {
  static const _maxRecordingDuration = Duration(seconds: 90);

  final _recorder = AudioRecorder();
  late final TextEditingController _noteController;
  late int _effortRating;
  late bool _isCompleted;
  Timer? _recordingTimer;
  Duration _recordingDuration = Duration.zero;
  bool _isRecording = false;
  bool _removeVoiceNote = false;
  String? _recordingPath;
  String? _recordedVoicePath;
  String? _recordingError;

  @override
  void initState() {
    super.initState();
    _noteController = TextEditingController(
      text: widget.feedback?.feelingNote ?? '',
    );
    _effortRating = widget.feedback?.effortRating ?? 5;
    _isCompleted = widget.feedback?.completedAt != null;
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    unawaited(_recorder.dispose());
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    try {
      if (!await _recorder.hasPermission()) {
        setState(
          () => _recordingError = 'Se necesita permiso para usar el micrófono.',
        );
        return;
      }
      final directory = await getTemporaryDirectory();
      final path = p.join(
        directory.path,
        'training-${DateTime.now().microsecondsSinceEpoch}.m4a',
      );
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000),
        path: path,
      );
      if (!mounted) return;
      setState(() {
        _isRecording = true;
        _recordingPath = path;
        _recordedVoicePath = null;
        _removeVoiceNote = false;
        _recordingDuration = Duration.zero;
        _recordingError = null;
      });
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        final nextDuration = _recordingDuration + const Duration(seconds: 1);
        setState(() => _recordingDuration = nextDuration);
        if (nextDuration >= _maxRecordingDuration) _stopRecording();
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _recordingError = 'No se pudo iniciar la grabación: $error',
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    try {
      final path = await _recorder.stop();
      if (!mounted) return;
      setState(() {
        _isRecording = false;
        _recordedVoicePath = path ?? _recordingPath;
        _recordingError = path == null ? 'No se guardó el audio.' : null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _isRecording = false;
          _recordingError = 'No se pudo detener la grabación: $error';
        });
      }
    }
  }

  Future<void> _cancel() async {
    _recordingTimer?.cancel();
    if (_isRecording) await _recorder.cancel();
    final path = _recordedVoicePath ?? _recordingPath;
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {
        // The temporary directory will be cleaned by the operating system.
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  String get _formattedDuration {
    final minutes = _recordingDuration.inMinutes.toString().padLeft(1, '0');
    final seconds = (_recordingDuration.inSeconds % 60).toString().padLeft(
      2,
      '0',
    );
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Registrar entrenamiento'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _isCompleted,
              title: const Text('Marcar como completado'),
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (value) =>
                  setState(() => _isCompleted = value ?? false),
            ),
            Row(
              children: [
                IconButton.filledTonal(
                  onPressed: _isRecording ? _stopRecording : _startRecording,
                  icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                  tooltip: _isRecording
                      ? 'Detener grabación'
                      : 'Grabar nota de voz',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _isRecording
                        ? 'Grabando $_formattedDuration / 1:30'
                        : _recordedVoicePath != null
                        ? 'Nota de voz lista para guardar'
                        : widget.feedback?.voiceNotePath != null &&
                              !_removeVoiceNote
                        ? 'Ya hay una nota de voz guardada'
                        : 'Graba hasta 90 segundos',
                  ),
                ),
              ],
            ),
            if (!_isRecording &&
                _recordedVoicePath == null &&
                widget.feedback?.voiceNotePath != null &&
                !_removeVoiceNote)
              TextButton.icon(
                onPressed: () => setState(() => _removeVoiceNote = true),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Quitar nota de voz'),
              ),
            if (_removeVoiceNote && _recordedVoicePath == null)
              TextButton.icon(
                onPressed: () => setState(() => _removeVoiceNote = false),
                icon: const Icon(Icons.undo),
                label: const Text('Conservar nota guardada'),
              ),
            if (_recordingError != null)
              Text(
                _recordingError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Text('Esfuerzo percibido: $_effortRating de 10'),
            Slider(
              value: _effortRating.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              label: '$_effortRating',
              onChanged: (value) =>
                  setState(() => _effortRating = value.round()),
            ),
            TextField(
              controller: _noteController,
              maxLines: 3,
              maxLength: 300,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '¿Cómo te sentiste durante la sesión?',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text('Cancelar')),
        FilledButton(
          onPressed:
              _isRecording ||
                  (_recordedVoicePath != null &&
                      !File(_recordedVoicePath!).existsSync())
              ? null
              : () => Navigator.of(context).pop(
                  _ClubFeedbackDraft(
                    isCompleted: _isCompleted,
                    effortRating: _effortRating,
                    note: _noteController.text.trim(),
                    recordedVoicePath: _recordedVoicePath,
                    removeVoiceNote: _removeVoiceNote,
                  ),
                ),
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
