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
                ],
              ),
            ),
        ],
      ),
    );
  }
}
