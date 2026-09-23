class TrainingSession {
  TrainingSession({
    required this.title,
    required this.description,
    required this.distance,
    required this.steps,
    this.isCompleted = false,
  });

  final String title;
  final String description;
  final String distance;
  final List<TrainingStep> steps;
  bool isCompleted;
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
