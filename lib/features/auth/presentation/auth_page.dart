import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isCreatingAccount = false;
  bool _isLoading = false;
  String? _message;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _message = null;
    });

    try {
      final auth = Supabase.instance.client.auth;
      if (_isCreatingAccount) {
        final response = await auth.signUp(
          email: _emailController.text.trim(),
          password: _passwordController.text,
          data: {'display_name': _nameController.text.trim()},
        );
        if (!mounted) return;
        if (response.session == null) {
          setState(() {
            _message = 'Cuenta creada. Revisa tu correo para confirmarla y '
                'después inicia sesión.';
            _isCreatingAccount = false;
          });
        }
      } else {
        await auth.signInWithPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
      }
    } on AuthException catch (error) {
      if (!mounted) return;
      setState(() => _message = _friendlyAuthError(error));
    } catch (_) {
      if (!mounted) return;
      setState(() => _message = 'No se pudo conectar. Revisa tu conexión e '
          'inténtalo de nuevo.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _friendlyAuthError(AuthException error) {
    final text = error.message.toLowerCase();
    if (text.contains('invalid login credentials')) {
      return 'Correo o contraseña incorrectos.';
    }
    if (text.contains('already registered') || text.contains('already been registered')) {
      return 'Ya existe una cuenta con ese correo. Inicia sesión.';
    }
    if (text.contains('password')) return 'La contraseña debe tener al menos '
        '6 caracteres.';
    return error.message;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Training App')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _isCreatingAccount ? 'Crea tu cuenta' : 'Bienvenido',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(_isCreatingAccount
                      ? 'Regístrate para empezar a organizar tus entrenamientos.'
                      : 'Inicia sesión para continuar.'),
                  const SizedBox(height: 24),
                  if (_isCreatingAccount) ...[
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Nombre',
                        border: OutlineInputBorder(),
                      ),
                      textCapitalization: TextCapitalization.words,
                      validator: (value) => value == null || value.trim().isEmpty
                          ? 'Escribe tu nombre.'
                          : null,
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextFormField(
                    controller: _emailController,
                    decoration: const InputDecoration(
                      labelText: 'Correo electrónico',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    validator: (value) => value == null ||
                            !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                                .hasMatch(value.trim())
                        ? 'Escribe un correo válido.'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    decoration: const InputDecoration(
                      labelText: 'Contraseña',
                      border: OutlineInputBorder(),
                    ),
                    obscureText: true,
                    validator: (value) => value == null || value.length < 6
                        ? 'Usa al menos 6 caracteres.'
                        : null,
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _message!,
                      style: TextStyle(color: Theme.of(context).colorScheme.primary),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _isLoading ? null : _submit,
                    child: _isLoading
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_isCreatingAccount ? 'Crear cuenta' : 'Iniciar sesión'),
                  ),
                  TextButton(
                    onPressed: _isLoading
                        ? null
                        : () => setState(() {
                              _isCreatingAccount = !_isCreatingAccount;
                              _message = null;
                            }),
                    child: Text(_isCreatingAccount
                        ? 'Ya tengo una cuenta'
                        : 'Crear una cuenta nueva'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
