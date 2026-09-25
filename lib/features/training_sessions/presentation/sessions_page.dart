import 'dart:math';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/supabase_configuration.dart';
import '../../clubs/presentation/clubs_page.dart';
import '../data/session_progress_repository.dart';
import '../models/training_session.dart';

class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key});

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  final SessionProgressRepository _progressRepository =
      SessionProgressRepository();
  bool _isLoadingProgress = true;
  bool _failedToLoadProgress = false;

  String get _ownerId => SupabaseConfiguration.isConfigured
      ? Supabase.instance.client.auth.currentUser!.id
      : 'local';

  final List<TrainingSession> _sessionTemplates = [
    TrainingSession(
      id: 'intervals-6x800',
      title: 'Intervalos: 6 × 800 m',
      description: 'Trabajo de velocidad con recuperación entre series',
      distance: '8 km',
      scheduledDate: DateTime.now(),
      steps: const [
        TrainingStep(
          title: 'Calentamiento',
          target: '2 km',
          description: 'Trote suave y movilidad dinámica.',
        ),
        TrainingStep(
          title: 'Series',
          target: '6 × 800 m',
          description: 'Corre cada repetición a ritmo de 5 km.',
        ),
        TrainingStep(
          title: 'Recuperación',
          target: '2 min entre series',
          description: 'Trote suave antes de iniciar la siguiente repetición.',
        ),
        TrainingStep(
          title: 'Enfriamiento',
          target: '1.2 km',
          description: 'Termina con trote fácil.',
        ),
      ],
    ),
    TrainingSession(
      id: 'easy-run-6k',
      title: 'Carrera suave',
      description: 'Ritmo cómodo · Termina con movilidad',
      distance: '6 km',
      scheduledDate: DateTime.now(),
      steps: const [
        TrainingStep(
          title: 'Calentamiento',
          target: '1 km',
          description: 'Empieza con trote muy suave.',
        ),
        TrainingStep(
          title: 'Carrera aeróbica',
          target: '4 km',
          description: 'Mantén un ritmo cómodo y conversacional.',
        ),
        TrainingStep(
          title: 'Enfriamiento',
          target: '1 km',
          description: 'Baja el ritmo y termina con movilidad.',
        ),
      ],
    ),
  ];
  final List<TrainingSession> _sessions = [];

  @override
  void initState() {
    super.initState();
    _loadSavedProgress();
  }

  Future<void> _loadSavedProgress() async {
    try {
      await _progressRepository.claimUnownedData(_ownerId);
      if (!SupabaseConfiguration.isConfigured) {
        await _progressRepository.ensureDefaultSessions(
          _ownerId,
          _sessionTemplates,
        );
      }
      final savedSessions = await _progressRepository.loadTrainingSessions(
        _ownerId,
      );
      final savedProgress = await _progressRepository.loadAll(_ownerId);
      final visibleSessions = SupabaseConfiguration.isConfigured
          ? savedSessions
                .where(
                  (session) => !_sessionTemplates.any(
                    (template) => template.id == session.id,
                  ),
                )
                .toList()
          : savedSessions;
      if (!mounted) return;

      setState(() {
        _sessions
          ..clear()
          ..addAll(visibleSessions);
        for (final session in _sessions) {
          final progress = savedProgress[session.id];
          if (progress == null) continue;

          session.isCompleted = progress.isCompleted;
          session.effortRating = progress.effortRating;
          session.feelingNote = progress.feelingNote;
          session.completedAt = progress.completedAt;
        }
        _isLoadingProgress = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _failedToLoadProgress = true;
        _isLoadingProgress = false;
      });
    }
  }

  Future<void> _addTrainingSession() async {
    final request = await showDialog<_NewSessionRequest>(
      context: context,
      builder: (_) => _AddTrainingSessionDialog(templates: _sessionTemplates),
    );

    if (request == null || !mounted) return;

    final session = TrainingSession(
      id:
          'session-${DateTime.now().microsecondsSinceEpoch}-'
          '${Random.secure().nextInt(1 << 32)}',
      title: request.title,
      description: request.description,
      distance: request.distance,
      steps: request.steps,
      scheduledDate: request.scheduledDate,
    );

    try {
      await _progressRepository.saveTrainingSession(_ownerId, session);
    } catch (_) {
      _showSaveError();
      return;
    }

    if (!mounted) return;
    setState(() {
      _sessions.add(session);
      _sessions.sort(
        (first, second) => first.scheduledDate.compareTo(second.scheduledDate),
      );
    });
  }

  bool _isBuiltInSession(TrainingSession session) {
    return _sessionTemplates.any((template) => template.id == session.id);
  }

  Future<void> _editTrainingSession(TrainingSession session) async {
    final request = await showDialog<_NewSessionRequest>(
      context: context,
      builder: (_) => _AddTrainingSessionDialog(
        templates: _sessionTemplates,
        initialSession: session,
      ),
    );

    if (request == null || !mounted) return;

    final updatedSession = TrainingSession(
      id: session.id,
      title: request.title,
      description: request.description,
      distance: request.distance,
      steps: request.steps,
      scheduledDate: request.scheduledDate,
      isCompleted: session.isCompleted,
      effortRating: session.effortRating,
      feelingNote: session.feelingNote,
      completedAt: session.completedAt,
    );

    try {
      await _progressRepository.saveTrainingSession(_ownerId, updatedSession);
    } catch (_) {
      _showSaveError();
      return;
    }

    if (!mounted) return;
    setState(() {
      final index = _sessions.indexWhere((item) => item.id == session.id);
      if (index == -1) return;
      _sessions[index] = updatedSession;
      _sessions.sort(
        (first, second) => first.scheduledDate.compareTo(second.scheduledDate),
      );
    });
  }

  Future<void> _deleteTrainingSession(TrainingSession session) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar entrenamiento'),
        content: Text(
          'Se eliminará "${session.title}" y su progreso guardado.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (shouldDelete != true || !mounted) return;

    try {
      await _progressRepository.deleteTrainingSession(_ownerId, session.id);
    } catch (_) {
      _showSaveError();
      return;
    }

    if (!mounted) return;
    setState(() {
      _sessions.removeWhere((item) => item.id == session.id);
    });
  }

  Future<void> _toggleSession(int index) async {
    final session = _sessions[index];
    final nextCompletionState = !session.isCompleted;
    final completedAt = nextCompletionState ? DateTime.now() : null;

    try {
      await _progressRepository.save(
        ownerId: _ownerId,
        sessionId: session.id,
        isCompleted: nextCompletionState,
        effortRating: session.effortRating,
        feelingNote: session.feelingNote,
        completedAt: completedAt,
      );
    } catch (_) {
      _showSaveError();
      return;
    }

    if (!mounted) return;
    setState(() {
      session.isCompleted = nextCompletionState;
      session.completedAt = completedAt;
    });
  }

  Future<void> _showFeedbackDialog(TrainingSession session) async {
    final feedback = await showDialog<_SessionFeedback>(
      context: context,
      builder: (_) => _FeedbackDialog(
        initialEffortRating: session.effortRating ?? 5,
        initialNote: session.feelingNote ?? '',
      ),
    );

    if (feedback != null && mounted) {
      final note = feedback.note.isEmpty ? null : feedback.note;

      try {
        await _progressRepository.save(
          ownerId: _ownerId,
          sessionId: session.id,
          isCompleted: session.isCompleted,
          effortRating: feedback.effortRating,
          feelingNote: note,
          completedAt: session.completedAt,
        );
      } catch (_) {
        _showSaveError();
        return;
      }

      if (!mounted) return;
      setState(() {
        session.effortRating = feedback.effortRating;
        session.feelingNote = note;
      });
    }
  }

  void _showSaveError() {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'No se pudieron guardar los cambios. Inténtalo de nuevo.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final completedCount = _sessions
        .where((session) => session.isCompleted)
        .length;
    final sessionsWithEffort = _sessions
        .where((session) => session.isCompleted && session.effortRating != null)
        .toList();
    final averageEffort = sessionsWithEffort.isEmpty
        ? null
        : sessionsWithEffort
                  .map((session) => session.effortRating!)
                  .reduce((total, rating) => total + rating) /
              sessionsWithEffort.length;
    final today = DateTime.now();
    final todayWithoutTime = DateTime(today.year, today.month, today.day);
    final lastSevenDays = List.generate(7, (index) {
      final date = todayWithoutTime.subtract(Duration(days: 6 - index));
      final count = _sessions.where((session) {
        final completedAt = session.completedAt;
        return completedAt != null &&
            completedAt.year == date.year &&
            completedAt.month == date.month &&
            completedAt.day == date.day;
      }).length;

      return _DailyCompletion(date: date, count: count);
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mis entrenamientos'),
        actions: [
          if (SupabaseConfiguration.isConfigured)
            IconButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const ClubsPage()),
              ),
              tooltip: 'Mis clubes',
              icon: const Icon(Icons.groups_outlined),
            ),
          IconButton(
            onPressed: _isLoadingProgress || _failedToLoadProgress
                ? null
                : _addTrainingSession,
            tooltip: 'Añadir entrenamiento',
            icon: const Icon(Icons.add),
          ),
          if (SupabaseConfiguration.isConfigured)
            IconButton(
              onPressed: () => Supabase.instance.client.auth.signOut(),
              tooltip: 'Cerrar sesión',
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: _isLoadingProgress
          ? const Center(child: CircularProgressIndicator())
          : _failedToLoadProgress
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No se pudo cargar el progreso guardado. '
                  'Cierra y vuelve a abrir la app para '
                  'intentarlo de nuevo.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Hola, atleta',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                _ProgressSummary(
                  completedSessions: completedCount,
                  totalSessions: _sessions.length,
                  averageEffort: averageEffort,
                  lastSevenDays: lastSevenDays,
                ),
                const SizedBox(height: 16),
                if (_sessions.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Todavía no tienes entrenamientos personales. '
                        'Usa + para crear uno o abre tu club para ver las '
                        'sesiones que te asignó tu entrenador.',
                      ),
                    ),
                  ),
                for (var index = 0; index < _sessions.length; index++)
                  Card(
                    child: ExpansionTile(
                      leading: Checkbox(
                        value: _sessions[index].isCompleted,
                        onChanged: (_) => _toggleSession(index),
                      ),
                      title: Text(_sessions[index].title),
                      subtitle: Text(
                        '${_sessions[index].description}\n'
                        'Distancia: ${_sessions[index].distance}\n'
                        'Fecha: '
                        '${_formatDate(_sessions[index].scheduledDate)}',
                      ),
                      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      children: [
                        for (final step in _sessions[index].steps)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.directions_run),
                            title: Text(step.title),
                            subtitle: Text(
                              '${step.target}\n${step.description}',
                            ),
                            isThreeLine: true,
                          ),
                        if (_sessions[index].isCompleted) ...[
                          if (_sessions[index].effortRating != null)
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.favorite_outline),
                              title: Text(
                                'Esfuerzo percibido: '
                                '${_sessions[index].effortRating} de 10',
                              ),
                              subtitle: _sessions[index].feelingNote == null
                                  ? null
                                  : Text(_sessions[index].feelingNote!),
                            ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: () =>
                                  _showFeedbackDialog(_sessions[index]),
                              icon: Icon(
                                _sessions[index].effortRating == null
                                    ? Icons.add_comment_outlined
                                    : Icons.edit_outlined,
                              ),
                              label: Text(
                                _sessions[index].effortRating == null
                                    ? 'Registrar sensaciones'
                                    : 'Editar sensaciones',
                              ),
                            ),
                          ),
                        ] else
                          const Padding(
                            padding: EdgeInsets.all(12),
                            child: Text(
                              'Marca la sesión como completada para '
                              'registrar tus sensaciones.',
                            ),
                          ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () =>
                                _editTrainingSession(_sessions[index]),
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('Editar entrenamiento'),
                          ),
                        ),
                        if (!_isBuiltInSession(_sessions[index]))
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: () =>
                                  _deleteTrainingSession(_sessions[index]),
                              icon: const Icon(Icons.delete_outline),
                              label: const Text('Eliminar entrenamiento'),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _ProgressSummary extends StatelessWidget {
  const _ProgressSummary({
    required this.completedSessions,
    required this.totalSessions,
    required double? averageEffort,
    required this.lastSevenDays,
  }) : _averageEffort = averageEffort;

  final int completedSessions;
  final int totalSessions;
  final double? _averageEffort;
  final List<_DailyCompletion> lastSevenDays;

  @override
  Widget build(BuildContext context) {
    final progress = totalSessions == 0
        ? 0.0
        : completedSessions / totalSessions;
    final percentage = (progress * 100).round();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Progreso del plan',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$completedSessions de $totalSessions sesiones '
                    'completadas',
                  ),
                ),
                SizedBox(
                  width: 64,
                  height: 64,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: progress,
                        strokeWidth: 7,
                      ),
                      Text('$percentage%'),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_averageEffort == null)
              const Text('Registra tus sensaciones para ver tu esfuerzo medio.')
            else
              Row(
                children: [
                  const Icon(Icons.favorite_outline, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    'Esfuerzo medio: '
                    '${_averageEffort.toStringAsFixed(1)} de 10',
                  ),
                ],
              ),
            const SizedBox(height: 20),
            Text(
              'Sesiones completadas · últimos 7 días',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            _WeeklyCompletionsChart(days: lastSevenDays),
          ],
        ),
      ),
    );
  }
}

class _DailyCompletion {
  const _DailyCompletion({required this.date, required this.count});

  final DateTime date;
  final int count;
}

class _NewSessionRequest {
  const _NewSessionRequest({
    required this.title,
    required this.description,
    required this.distance,
    required this.steps,
    required this.scheduledDate,
  });

  final String title;
  final String description;
  final String distance;
  final List<TrainingStep> steps;
  final DateTime scheduledDate;
}

class _AddTrainingSessionDialog extends StatefulWidget {
  const _AddTrainingSessionDialog({
    required this.templates,
    this.initialSession,
  });

  final List<TrainingSession> templates;
  final TrainingSession? initialSession;

  @override
  State<_AddTrainingSessionDialog> createState() =>
      _AddTrainingSessionDialogState();
}

class _AddTrainingSessionDialogState extends State<_AddTrainingSessionDialog> {
  static const _customSessionValue = -1;

  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _distanceController = TextEditingController();
  final List<_TrainingStepDraft> _stepDrafts = [];
  int _selectedTemplateIndex = 0;
  DateTime _scheduledDate = DateTime.now();

  bool get _isCustomSession => _selectedTemplateIndex == _customSessionValue;

  @override
  void initState() {
    super.initState();
    final initialSession = widget.initialSession;
    if (initialSession == null) {
      _stepDrafts.add(_TrainingStepDraft());
      return;
    }

    _selectedTemplateIndex = _customSessionValue;
    _scheduledDate = initialSession.scheduledDate;
    _titleController.text = initialSession.title;
    _descriptionController.text = initialSession.description;
    _distanceController.text = initialSession.distance;
    if (initialSession.steps.isEmpty) {
      _stepDrafts.add(_TrainingStepDraft());
      return;
    }
    _stepDrafts.addAll(initialSession.steps.map(_TrainingStepDraft.fromStep));
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

  Future<void> _chooseDate() async {
    final maximumDate = DateTime.now().add(const Duration(days: 365));
    final lastDate = _scheduledDate.isAfter(maximumDate)
        ? _scheduledDate
        : maximumDate;
    final selectedDate = await showDatePicker(
      context: context,
      initialDate: _scheduledDate,
      firstDate: DateTime(2000),
      lastDate: lastDate,
    );

    if (selectedDate == null || !mounted) return;
    setState(() {
      _scheduledDate = selectedDate;
    });
  }

  void _addStep() {
    setState(() {
      _stepDrafts.add(_TrainingStepDraft());
    });
  }

  void _removeStep(int index) {
    setState(() {
      _stepDrafts.removeAt(index).dispose();
    });
  }

  void _submit() {
    if (_isCustomSession && !(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    final template = _isCustomSession
        ? null
        : widget.templates[_selectedTemplateIndex];
    final request = _NewSessionRequest(
      title: template?.title ?? _titleController.text.trim(),
      description: template?.description ?? _descriptionController.text.trim(),
      distance: template?.distance ?? _distanceController.text.trim(),
      steps:
          template?.steps ??
          _stepDrafts
              .map(
                (draft) => TrainingStep(
                  title: draft.titleController.text.trim(),
                  target: draft.targetController.text.trim(),
                  description: draft.descriptionController.text.trim(),
                ),
              )
              .toList(),
      scheduledDate: _scheduledDate,
    );

    Navigator.of(context).pop(request);
  }

  Widget _buildCustomFields() {
    return Form(
      key: _formKey,
      child: Column(
        children: [
          TextFormField(
            controller: _titleController,
            decoration: const InputDecoration(labelText: 'Nombre'),
            validator: _requiredFieldValidator,
          ),
          TextFormField(
            controller: _distanceController,
            decoration: const InputDecoration(
              labelText: 'Distancia',
              hintText: 'Ejemplo: 8 km',
            ),
            validator: _requiredFieldValidator,
          ),
          TextFormField(
            controller: _descriptionController,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Descripción'),
            validator: _requiredFieldValidator,
          ),
          const SizedBox(height: 12),
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
                            onPressed: () => _removeStep(index),
                            tooltip: 'Eliminar paso',
                            icon: const Icon(Icons.delete_outline),
                          ),
                      ],
                    ),
                    TextFormField(
                      controller: _stepDrafts[index].titleController,
                      decoration: const InputDecoration(
                        labelText: 'Nombre del paso',
                      ),
                      validator: _requiredFieldValidator,
                    ),
                    TextFormField(
                      controller: _stepDrafts[index].targetController,
                      decoration: const InputDecoration(
                        labelText: 'Objetivo',
                        hintText: 'Ejemplo: 2 km o 5 × 400 m',
                      ),
                      validator: _requiredFieldValidator,
                    ),
                    TextFormField(
                      controller: _stepDrafts[index].descriptionController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Instrucciones',
                      ),
                      validator: _requiredFieldValidator,
                    ),
                  ],
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _addStep,
              icon: const Icon(Icons.add),
              label: const Text('Agregar paso'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.initialSession == null
            ? 'Añadir entrenamiento'
            : 'Editar entrenamiento',
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<int>(
                initialValue: _selectedTemplateIndex,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Entrenamiento'),
                items: [
                  const DropdownMenuItem(
                    value: _customSessionValue,
                    child: Text('Personalizado'),
                  ),
                  for (var index = 0; index < widget.templates.length; index++)
                    DropdownMenuItem(
                      value: index,
                      child: Text(widget.templates[index].title),
                    ),
                ],
                onChanged: (index) {
                  if (index == null) return;
                  setState(() {
                    _selectedTemplateIndex = index;
                  });
                },
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _chooseDate,
                icon: const Icon(Icons.calendar_month_outlined),
                label: Text('Fecha: ${_formatDate(_scheduledDate)}'),
              ),
              if (_isCustomSession) _buildCustomFields(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.initialSession == null ? 'Añadir' : 'Guardar'),
        ),
      ],
    );
  }
}

class _TrainingStepDraft {
  _TrainingStepDraft()
    : titleController = TextEditingController(),
      targetController = TextEditingController(),
      descriptionController = TextEditingController();

  _TrainingStepDraft.fromStep(TrainingStep step)
    : titleController = TextEditingController(text: step.title),
      targetController = TextEditingController(text: step.target),
      descriptionController = TextEditingController(text: step.description);

  final TextEditingController titleController;
  final TextEditingController targetController;
  final TextEditingController descriptionController;

  void dispose() {
    titleController.dispose();
    targetController.dispose();
    descriptionController.dispose();
  }
}

String? _requiredFieldValidator(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Completa este campo';
  }
  return null;
}

String _formatDate(DateTime date) {
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  return '$day/$month/${date.year}';
}

class _WeeklyCompletionsChart extends StatelessWidget {
  const _WeeklyCompletionsChart({required this.days});

  final List<_DailyCompletion> days;

  @override
  Widget build(BuildContext context) {
    final highestCount = days.fold<int>(
      0,
      (highest, day) => day.count > highest ? day.count : highest,
    );
    const weekdayLabels = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];
    final color = Theme.of(context).colorScheme.primary;

    return SizedBox(
      height: 118,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final day in days)
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SizedBox(
                    height: 20,
                    child: Text(
                      '${day.count}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                  SizedBox(
                    height: 68,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        width: 18,
                        height: highestCount == 0 || day.count == 0
                            ? 4.0
                            : day.count / highestCount * 64,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(weekdayLabels[day.date.weekday - 1]),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SessionFeedback {
  const _SessionFeedback({required this.effortRating, required this.note});

  final int effortRating;
  final String note;
}

class _FeedbackDialog extends StatefulWidget {
  const _FeedbackDialog({
    required this.initialEffortRating,
    required this.initialNote,
  });

  final int initialEffortRating;
  final String initialNote;

  @override
  State<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<_FeedbackDialog> {
  late final TextEditingController _noteController;
  late int _effortRating;

  @override
  void initState() {
    super.initState();
    _noteController = TextEditingController(text: widget.initialNote);
    _effortRating = widget.initialEffortRating;
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('¿Cómo te sentiste?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Esfuerzo percibido: $_effortRating de 10'),
            Slider(
              value: _effortRating.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              label: '$_effortRating',
              onChanged: (value) {
                setState(() {
                  _effortRating = value.round();
                });
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _noteController,
              maxLines: 3,
              maxLength: 300,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Agrega una nota sobre tus sensaciones',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              _SessionFeedback(
                effortRating: _effortRating,
                note: _noteController.text.trim(),
              ),
            );
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
