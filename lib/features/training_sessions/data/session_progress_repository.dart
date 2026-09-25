import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../models/training_session.dart';

class SessionProgress {
  const SessionProgress({
    required this.isCompleted,
    required this.effortRating,
    required this.feelingNote,
    required this.completedAt,
  });

  final bool isCompleted;
  final int? effortRating;
  final String? feelingNote;
  final DateTime? completedAt;
}

class SessionProgressRepository {
  Future<Database>? _databaseFuture;

  Future<Database> get _database {
    _databaseFuture ??= _openDatabase();
    return _databaseFuture!;
  }

  Future<Database> _openDatabase() async {
    final databasesPath = await getDatabasesPath();

    return openDatabase(
      path.join(databasesPath, 'training_app.db'),
      version: 4,
      onCreate: (database, version) async {
        await database.execute('''
          CREATE TABLE session_progress (
            owner_id TEXT NOT NULL,
            session_id TEXT PRIMARY KEY,
            is_completed INTEGER NOT NULL,
            effort_rating INTEGER,
            feeling_note TEXT,
            completed_at TEXT
          )
        ''');
        await database.execute('''
          CREATE TABLE training_sessions (
            owner_id TEXT NOT NULL,
            session_id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            description TEXT NOT NULL,
            distance TEXT NOT NULL,
            steps_json TEXT NOT NULL,
            scheduled_date TEXT NOT NULL
          )
        ''');
      },
      onUpgrade: (database, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await database.execute(
            'ALTER TABLE session_progress ADD COLUMN completed_at TEXT',
          );
        }
        if (oldVersion < 3) {
          await database.execute('''
            CREATE TABLE training_sessions (
              session_id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              description TEXT NOT NULL,
              distance TEXT NOT NULL,
              steps_json TEXT NOT NULL,
              scheduled_date TEXT NOT NULL
            )
          ''');
        }
        if (oldVersion < 4) {
          await database.execute(
            'ALTER TABLE training_sessions ADD COLUMN owner_id TEXT',
          );
          await database.execute(
            'ALTER TABLE session_progress ADD COLUMN owner_id TEXT',
          );
        }
      },
    );
  }

  Future<void> claimUnownedData(String ownerId) async {
    final database = await _database;
    await database.transaction((transaction) async {
      await transaction.update('training_sessions', {
        'owner_id': ownerId,
      }, where: 'owner_id IS NULL');
      await transaction.update('session_progress', {
        'owner_id': ownerId,
      }, where: 'owner_id IS NULL');
    });
  }

  Future<Map<String, SessionProgress>> loadAll(String ownerId) async {
    final database = await _database;
    final rows = await database.query(
      'session_progress',
      where: 'owner_id = ?',
      whereArgs: [ownerId],
    );

    return {
      for (final row in rows)
        row['session_id'] as String: SessionProgress(
          isCompleted: row['is_completed'] == 1,
          effortRating: row['effort_rating'] as int?,
          feelingNote: row['feeling_note'] as String?,
          completedAt: row['completed_at'] == null
              ? null
              : DateTime.tryParse(row['completed_at'] as String),
        ),
    };
  }

  Future<void> ensureDefaultSessions(
    String ownerId,
    List<TrainingSession> defaults,
  ) async {
    final database = await _database;
    final batch = database.batch();

    for (final session in defaults) {
      batch.insert(
        'training_sessions',
        _sessionToRow(ownerId, session),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }

    await batch.commit(noResult: true);
  }

  Future<List<TrainingSession>> loadTrainingSessions(String ownerId) async {
    final database = await _database;
    final rows = await database.query(
      'training_sessions',
      where: 'owner_id = ?',
      whereArgs: [ownerId],
      orderBy: 'scheduled_date ASC, title ASC',
    );

    return rows.map((row) {
      final steps = (jsonDecode(row['steps_json'] as String) as List<dynamic>)
          .map(
            (step) => TrainingStep(
              title: step['title'] as String,
              target: step['target'] as String,
              description: step['description'] as String,
            ),
          )
          .toList();

      return TrainingSession(
        id: row['session_id'] as String,
        title: row['title'] as String,
        description: row['description'] as String,
        distance: row['distance'] as String,
        steps: steps,
        scheduledDate: DateTime.parse(row['scheduled_date'] as String),
      );
    }).toList();
  }

  Future<void> saveTrainingSession(
    String ownerId,
    TrainingSession session,
  ) async {
    final database = await _database;
    await database.insert(
      'training_sessions',
      _sessionToRow(ownerId, session),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteTrainingSession(String ownerId, String sessionId) async {
    final database = await _database;

    await database.transaction((transaction) async {
      await transaction.delete(
        'session_progress',
        where: 'owner_id = ? AND session_id = ?',
        whereArgs: [ownerId, sessionId],
      );
      await transaction.delete(
        'training_sessions',
        where: 'owner_id = ? AND session_id = ?',
        whereArgs: [ownerId, sessionId],
      );
    });
  }

  Map<String, Object?> _sessionToRow(String ownerId, TrainingSession session) {
    return {
      'owner_id': ownerId,
      'session_id': session.id,
      'title': session.title,
      'description': session.description,
      'distance': session.distance,
      'steps_json': jsonEncode(
        session.steps
            .map(
              (step) => {
                'title': step.title,
                'target': step.target,
                'description': step.description,
              },
            )
            .toList(),
      ),
      'scheduled_date': session.scheduledDate.toIso8601String(),
    };
  }

  Future<void> save({
    required String ownerId,
    required String sessionId,
    required bool isCompleted,
    required int? effortRating,
    required String? feelingNote,
    required DateTime? completedAt,
  }) async {
    final database = await _database;

    await database.insert('session_progress', {
      'owner_id': ownerId,
      'session_id': sessionId,
      'is_completed': isCompleted ? 1 : 0,
      'effort_rating': effortRating,
      'feeling_note': feelingNote,
      'completed_at': completedAt?.toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
