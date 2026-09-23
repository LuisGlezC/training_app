import 'package:flutter/material.dart';

import '../models/training_session.dart';

class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key});

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  final List<TrainingSession> _sessions = [
    TrainingSession(
      title: 'Intervalos: 6 × 800 m',
      description: 'Trabajo de velocidad con recuperación entre series',
      distance: '8 km',
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
      title: 'Carrera suave',
      description: 'Ritmo cómodo · Termina con movilidad',
      distance: '6 km',
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

  void _toggleSession(int index) {
    setState(() {
      _sessions[index].isCompleted = !_sessions[index].isCompleted;
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
      setState(() {
        session.effortRating = feedback.effortRating;
        session.feelingNote = feedback.note.isEmpty ? null : feedback.note;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final completedCount =
        _sessions.where((session) => session.isCompleted).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mis entrenamientos'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Hola, atleta',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text('$completedCount de ${_sessions.length} sesiones completadas'),
          const SizedBox(height: 16),
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
                  'Distancia: ${_sessions[index].distance}',
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                children: [
                  for (final step in _sessions[index].steps)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.directions_run),
                      title: Text(step.title),
                      subtitle: Text('${step.target}\n${step.description}'),
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
                        'Marca la sesión como completada para registrar '
                        'tus sensaciones.',
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

class _SessionFeedback {
  const _SessionFeedback({
    required this.effortRating,
    required this.note,
  });

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
