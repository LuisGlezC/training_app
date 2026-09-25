class TrainingSession {
  TrainingSession({
    required this.id,
    required this.title,
    required this.description,
    required this.distance,
    required this.steps,
    required this.scheduledDate,
    this.isCompleted = false,
    this.effortRating,
    this.feelingNote,
    this.completedAt,
  });

  final String id;
  final String title;
  final String description;
  final String distance;
  final List<TrainingStep> steps;
  final DateTime scheduledDate;
  bool isCompleted;
  int? effortRating;
  String? feelingNote;
  DateTime? completedAt;
}

class TrainingStep {
  const TrainingStep({
    required this.title,
    required this.target,
    required this.description,
  });

  final String title;
  final String target;
  final String description;
}
