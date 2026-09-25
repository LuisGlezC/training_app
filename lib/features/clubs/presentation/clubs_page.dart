import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../training_sessions/presentation/club_training_page.dart';

class ClubsPage extends StatefulWidget {
  const ClubsPage({super.key});

  @override
  State<ClubsPage> createState() => _ClubsPageState();
}

class _ClubsPageState extends State<ClubsPage> {
  final _client = Supabase.instance.client;
  final _clubNameController = TextEditingController();
  final _joinCodeController = TextEditingController();
  List<_ClubMembership> _memberships = [];
  List<_ClubJoinRequest> _myRequests = [];
  List<_ClubJoinRequest> _pendingRequests = [];
  bool _isLoading = true;
  bool _isSaving = false;
  String? _activeAction;
  String _requestedRole = 'athlete';
  String? _error;
  String? _successMessage;

  @override
  void initState() {
    super.initState();
    _loadClubs();
  }

  @override
  void dispose() {
    _clubNameController.dispose();
    _joinCodeController.dispose();
    super.dispose();
  }

  Future<void> _loadClubs() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final userId = _client.auth.currentUser!.id;
      final rows = await _client
          .from('club_memberships')
          .select('role, clubs(id, name, join_code)')
          .eq('user_id', userId);
      final memberships = rows.map((row) {
        final club = row['clubs'] as Map<String, dynamic>;
        return _ClubMembership(
          id: club['id'] as String,
          name: club['name'] as String,
          joinCode: club['join_code'] as String,
          role: row['role'] as String,
        );
      }).toList();
      final myRequestRows = await _client
          .from('club_join_requests')
          .select(
            'id, requester_name, club_name, requested_role, status, created_at',
          )
          .eq('user_id', userId)
          .order('created_at', ascending: false);
      final coachClubIds = memberships
          .where((membership) => membership.role == 'coach')
          .map((membership) => membership.id)
          .toList();
      final pendingRequestRows = coachClubIds.isEmpty
          ? <dynamic>[]
          : await _client
              .from('club_join_requests')
              .select(
                'id, requester_name, club_name, requested_role, status, '
                'created_at',
              )
              .eq('status', 'pending')
              .inFilter('club_id', coachClubIds)
              .order('created_at');
      final myRequests = myRequestRows
          .map((row) => _ClubJoinRequest.fromMap(row))
          .where((request) => request.status != 'approved')
          .toList();
      final pendingRequests = pendingRequestRows
          .map((row) => _ClubJoinRequest.fromMap(row))
          .toList();
      if (!mounted) return;
      setState(() {
        _memberships = memberships;
        _myRequests = myRequests;
        _pendingRequests = pendingRequests;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'No se pudieron cargar clubes o solicitudes. Comprueba que '
            'ejecutaste todas las migraciones de Supabase.';
        _isLoading = false;
      });
    }
  }

  Future<void> _createClub() async {
    final name = _clubNameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Escribe el nombre del club.');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _isSaving = true);
    try {
      await _client.from('clubs').insert({
        'name': name,
        'coach_id': _client.auth.currentUser!.id,
      });
      _clubNameController.clear();
      _activeAction = null;
      await _loadClubs();
      if (mounted) {
        setState(() => _successMessage =
            'Club creado. Comparte su código con tus atletas.');
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'No se pudo crear el club: $error');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _joinClub() async {
    final code = _joinCodeController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Escribe el código de invitación.');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _isSaving = true);
    try {
      await _client.rpc(
        'request_club_membership',
        params: {
          'invitation_code': code.trim().toUpperCase(),
          'requested_role': _requestedRole,
        },
      );
      _joinCodeController.clear();
      _activeAction = null;
      await _loadClubs();
      if (mounted) {
        setState(() => _successMessage =
            'Solicitud enviada. Un entrenador del club debe aprobarla.');
      }
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error =
          'No se pudo usar ese código. Compruébalo e inténtalo de nuevo. $error');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _reviewRequest(
    _ClubJoinRequest request, {
    required bool approve,
  }) async {
    FocusScope.of(context).unfocus();
    setState(() => _isSaving = true);
    try {
      await _client.rpc(
        'review_club_join_request',
        params: {
          'target_request_id': request.id,
          'accept_request': approve,
        },
      );
      await _loadClubs();
      if (mounted) {
        setState(() => _successMessage = approve
            ? 'Solicitud aceptada. El usuario ya forma parte del club.'
            : 'Solicitud rechazada.');
      }
    } on PostgrestException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = 'No se pudo revisar la solicitud: $error');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mis clubes')),
      body: RefreshIndicator(
        onRefresh: _loadClubs,
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
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(_error!),
                      ),
                    ),
                  if (_successMessage != null)
                    Card(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(_successMessage!),
                      ),
                    ),
                  if (_memberships.isEmpty && _error == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'Aún no perteneces a un club. Si eres entrenador, '
                        'crea uno. Si eres atleta, únete con un código.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  for (final membership in _memberships)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.groups_outlined),
                        title: Text(membership.name),
                        subtitle: Text(membership.role == 'coach'
                            ? 'Entrenador · Código: ${membership.joinCode}'
                            : 'Atleta'),
                        trailing: membership.role == 'coach'
                            ? IconButton(
                                tooltip: 'Compartir código',
                                icon: const Icon(Icons.share_outlined),
                                onPressed: () async {
                                  await Clipboard.setData(
                                    ClipboardData(text: membership.joinCode),
                                  );
                                  if (mounted) {
                                    setState(() => _successMessage =
                                        'Código copiado: ${membership.joinCode}');
                                  }
                                },
                              )
                            : null,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ClubTrainingPage(
                              clubId: membership.id,
                              clubName: membership.name,
                              role: membership.role,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_myRequests.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text('Tus solicitudes',
                        style: Theme.of(context).textTheme.titleLarge),
                    for (final request in _myRequests)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.hourglass_top),
                          title: Text(request.clubName),
                          subtitle: Text(
                            'Solicitud como ${_roleName(request.requestedRole)} · '
                            '${_statusName(request.status)}',
                          ),
                        ),
                      ),
                  ],
                  if (_pendingRequests.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text('Solicitudes por revisar',
                        style: Theme.of(context).textTheme.titleLarge),
                    for (final request in _pendingRequests)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.person_add_alt_1),
                                title: Text(request.requesterName),
                                subtitle: Text(
                                  '${request.clubName} · Solicita entrar como '
                                  '${_roleName(request.requestedRole)}',
                                ),
                              ),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: _isSaving
                                          ? null
                                          : () => _reviewRequest(
                                                request,
                                                approve: false,
                                              ),
                                      child: const Text('Rechazar'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: FilledButton(
                                      onPressed: _isSaving
                                          ? null
                                          : () => _reviewRequest(
                                                request,
                                                approve: true,
                                              ),
                                      child: const Text('Aceptar'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _isSaving
                        ? null
                        : () => setState(() {
                              _activeAction =
                                  _activeAction == 'create' ? null : 'create';
                              _error = null;
                              _successMessage = null;
                            }),
                    icon: const Icon(Icons.add),
                    label: const Text('Crear club (entrenador)'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _isSaving
                        ? null
                        : () => setState(() {
                              _activeAction =
                                  _activeAction == 'join' ? null : 'join';
                              _error = null;
                              _successMessage = null;
                            }),
                    icon: const Icon(Icons.vpn_key_outlined),
                    label: const Text('Unirme con un código (atleta)'),
                  ),
                  if (_activeAction == 'create') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _clubNameController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Nombre del club',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: _isSaving ? null : _createClub,
                      child: const Text('Guardar club'),
                    ),
                  ],
                  if (_activeAction == 'join') ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _requestedRole,
                      decoration: const InputDecoration(
                        labelText: 'Solicitar ingresar como',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'athlete',
                          child: Text('Atleta'),
                        ),
                        DropdownMenuItem(
                          value: 'coach',
                          child: Text('Entrenador'),
                        ),
                      ],
                      onChanged: _isSaving
                          ? null
                          : (role) {
                              if (role != null) {
                                setState(() => _requestedRole = role);
                              }
                            },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _joinCodeController,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Código de invitación',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: _isSaving ? null : _joinClub,
                      child: const Text('Unirme al club'),
                    ),
                  ],
                  if (_isSaving) ...[
                    const SizedBox(height: 16),
                    const Center(child: CircularProgressIndicator()),
                  ],
                ],
          ],
        ),
      ),
    );
  }
}

class _ClubMembership {
  const _ClubMembership({
    required this.id,
    required this.name,
    required this.joinCode,
    required this.role,
  });

  final String id;
  final String name;
  final String joinCode;
  final String role;
}

class _ClubJoinRequest {
  const _ClubJoinRequest({
    required this.id,
    required this.requesterName,
    required this.clubName,
    required this.requestedRole,
    required this.status,
  });

  factory _ClubJoinRequest.fromMap(Map<String, dynamic> row) {
    return _ClubJoinRequest(
      id: row['id'] as String,
      requesterName: row['requester_name'] as String,
      clubName: row['club_name'] as String,
      requestedRole: row['requested_role'] as String,
      status: row['status'] as String,
    );
  }

  final String id;
  final String requesterName;
  final String clubName;
  final String requestedRole;
  final String status;
}

String _roleName(String role) => role == 'coach' ? 'entrenador' : 'atleta';

String _statusName(String status) => switch (status) {
      'pending' => 'pendiente',
      'rejected' => 'rechazada',
      'approved' => 'aceptada',
      _ => status,
    };
