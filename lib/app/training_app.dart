import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_configuration.dart';
import '../features/auth/presentation/auth_page.dart';
import '../features/training_sessions/presentation/sessions_page.dart';

class TrainingApp extends StatefulWidget {
  const TrainingApp({super.key});

  @override
  State<TrainingApp> createState() => _TrainingAppState();
}

class _TrainingAppState extends State<TrainingApp> {
  bool _isInitializing = true;
  String? _initializationError;

  @override
  void initState() {
    super.initState();
    _initializeBackend();
  }

  Future<void> _initializeBackend() async {
    setState(() {
      _isInitializing = true;
      _initializationError = null;
    });
    try {
      await SupabaseConfiguration.initialize();
      if (!mounted) return;
      setState(() => _isInitializing = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _initializationError = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Training App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: _isInitializing
          ? const _StartupPage()
          : _initializationError != null
              ? _InitializationErrorPage(
                  message: _initializationError!,
                  onRetry: _initializeBackend,
                )
              : SupabaseConfiguration.isConfigured
                  ? const _SupabaseAuthGate()
                  : const SessionsPage(),
    );
  }
}

class _StartupPage extends StatelessWidget {
  const _StartupPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Iniciando Training App…'),
          ],
        ),
      ),
    );
  }
}

class _InitializationErrorPage extends StatelessWidget {
  const _InitializationErrorPage({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('No se pudo iniciar la app')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 48),
              const SizedBox(height: 16),
              const Text(
                'No se pudo conectar con el servicio. Revisa la conexión e '
                'inténtalo de nuevo.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              SelectableText(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SupabaseAuthGate extends StatelessWidget {
  const _SupabaseAuthGate();

  @override
  Widget build(BuildContext context) {
    final auth = Supabase.instance.client.auth;
    return StreamBuilder<AuthState>(
      stream: auth.onAuthStateChange,
      builder: (context, snapshot) {
        if (auth.currentSession != null) return const SessionsPage();
        return const AuthPage();
      },
    );
  }
}
