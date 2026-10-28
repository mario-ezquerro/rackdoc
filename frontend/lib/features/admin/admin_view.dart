import 'package:flutter/material.dart';
import '../../core/api_client.dart';
import '../../models/datacenter_models.dart';

class AdminView extends StatefulWidget {
  final RackDocApiClient api;
  final UserModel currentUser;
  final ValueChanged<UserModel> onSwitchActiveUser;

  const AdminView({
    super.key,
    required this.api,
    required this.currentUser,
    required this.onSwitchActiveUser,
  });

  @override
  State<AdminView> createState() => _AdminViewState();
}

class _AdminViewState extends State<AdminView> {
  List<UserModel> _users = [];
  List<ADServerModel> _adServers = [];
  bool _loading = true;
  String? _error;

  // Controladores del formulario rápido de Alta de Usuario Local (sin AD)
  final TextEditingController _quickUsernameCtrl = TextEditingController();
  final TextEditingController _quickFullNameCtrl = TextEditingController();
  final TextEditingController _quickEmailCtrl = TextEditingController();
  final TextEditingController _quickPasswordCtrl = TextEditingController();
  String _quickRole = 'editor';
  bool _creatingLocalUser = false;

  @override
  void initState() {
    super.initState();
    _loadAdminData();
  }

  @override
  void dispose() {
    _quickUsernameCtrl.dispose();
    _quickFullNameCtrl.dispose();
    _quickEmailCtrl.dispose();
    _quickPasswordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitQuickLocalUser() async {
    final messenger = ScaffoldMessenger.of(context);
    final uname = _quickUsernameCtrl.text.trim();
    final pass = _quickPasswordCtrl.text.trim();
    if (uname.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Escribe un nombre de usuario (username) para dar de alta.'),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }
    setState(() => _creatingLocalUser = true);
    try {
      await widget.api.createUser({
        'username': uname,
        'full_name': _quickFullNameCtrl.text.trim().isEmpty
            ? uname
            : _quickFullNameCtrl.text.trim(),
        'email': _quickEmailCtrl.text.trim().isEmpty
            ? '$uname@rackdoc.local'
            : _quickEmailCtrl.text.trim(),
        'password': pass.isEmpty ? 'rackdoc123' : pass,
        'role': _quickRole,
        'auth_source': 'local',
      });
      _quickUsernameCtrl.clear();
      _quickFullNameCtrl.clear();
      _quickEmailCtrl.clear();
      _quickPasswordCtrl.clear();
      await _loadAdminData();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Usuario local "$uname" dado de alta correctamente con rol $_quickRole.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
      );
    } finally {
      if (mounted) {
        setState(() => _creatingLocalUser = false);
      }
    }
  }

  Future<void> _loadAdminData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Future.wait([
        widget.api.getUsers(),
        widget.api.getAdServers(),
      ]);
      if (mounted) {
        setState(() {
          _users = res[0] as List<UserModel>;
          _adServers = res[1] as List<ADServerModel>;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  static Color _roleColor(String role) {
    switch (role) {
      case 'admin':
        return const Color(0xFFDC2626);
      case 'editor':
        return const Color(0xFF2563EB);
      case 'operator':
        return const Color(0xFF0D9488);
      case 'viewer':
      default:
        return const Color(0xFF64748B);
    }
  }

  Future<void> _showCreateOrEditUserDialog({UserModel? existing}) async {
    final messenger = ScaffoldMessenger.of(context);
    final usernameCtrl = TextEditingController(text: existing?.username ?? '');
    final fullNameCtrl = TextEditingController(text: existing?.fullName ?? '');
    final emailCtrl = TextEditingController(text: existing?.email ?? '');
    final passwordCtrl = TextEditingController();
    String selectedRole = existing?.role ?? 'operator';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: Text(
            existing == null
                ? 'Crear Nuevo Usuario'
                : 'Editar Usuario (${existing.username})',
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: usernameCtrl,
                        enabled: existing == null,
                        decoration: const InputDecoration(
                          labelText: 'Usuario (Username) *',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: fullNameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Nombre Completo',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: emailCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Correo Electrónico',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: passwordCtrl,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: existing == null
                        ? 'Contraseña *'
                        : 'Nueva Contraseña (dejar vacío para mantener)',
                  ),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: selectedRole,
                  decoration: const InputDecoration(
                    labelText: 'Rol de Acceso (RBAC)',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'admin',
                      child: Text(
                        'admin — Administrador Total (Usuarios, AD, Edición, SSH/Web)',
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'editor',
                      child: Text(
                        'editor — Editor (Editar Racks/Mapas/Cables + SSH/Web)',
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'operator',
                      child: Text(
                        'operator — Solo Ver & Interactuar (SSH / Telnet / Web / Ping)',
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'viewer',
                      child: Text(
                        'viewer — Solo Ver (Lectura estricta sin conexión a hosts)',
                      ),
                    ),
                  ],
                  onChanged: (v) =>
                      setModal(() => selectedRole = v ?? 'viewer'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.save_outlined, size: 16),
              label: Text(existing == null ? 'Crear Usuario' : 'Guardar'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      try {
        if (existing == null) {
          await widget.api.createUser({
            'username': usernameCtrl.text.trim(),
            'full_name': fullNameCtrl.text.trim(),
            'email': emailCtrl.text.trim(),
            'password': passwordCtrl.text.isEmpty
                ? 'rackdoc123'
                : passwordCtrl.text,
            'role': selectedRole,
            'auth_source': 'local',
          });
        } else {
          final payload = <String, dynamic>{
            'full_name': fullNameCtrl.text.trim(),
            'email': emailCtrl.text.trim(),
            'role': selectedRole,
          };
          if (passwordCtrl.text.trim().isNotEmpty) {
            payload['password'] = passwordCtrl.text.trim();
          }
          final updated = await widget.api.updateUser(existing.id, payload);
          if (updated.id == widget.currentUser.id) {
            widget.onSwitchActiveUser(updated);
          }
        }
        await _loadAdminData();
        messenger.showSnackBar(
          const SnackBar(content: Text('Usuario guardado correctamente.')),
        );
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
        );
      }
    }
  }

  Future<void> _showCreateOrEditAdServerDialog({
    ADServerModel? existing,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final nameCtrl = TextEditingController(
      text: existing?.name ?? 'AD Sucursal Europea',
    );
    final hostCtrl = TextEditingController(
      text: existing?.host ?? 'ldap://ad-eu.corp.rackdoc.local',
    );
    final portCtrl = TextEditingController(text: '${existing?.port ?? 389}');
    final domainCtrl = TextEditingController(
      text: existing?.domain ?? 'EU.CORP.RACKDOC.LOCAL',
    );
    final baseDnCtrl = TextEditingController(
      text: existing?.baseDn ?? 'DC=eu,DC=corp,DC=rackdoc,DC=local',
    );
    final bindDnCtrl = TextEditingController(
      text:
          existing?.bindDn ??
          'CN=svc_rackdoc,OU=ServiceAccounts,DC=eu,DC=corp,DC=rackdoc,DC=local',
    );
    final bindPassCtrl = TextEditingController();
    final filterCtrl = TextEditingController(
      text:
          existing?.userFilter ?? '(&(objectClass=user)(sAMAccountName={username}))',
    );
    String defaultRole = existing?.defaultRole ?? 'operator';
    bool useSsl = existing?.useSsl ?? false;
    final List<Map<String, dynamic>> groupRules = existing != null &&
            existing.groupRoleMapping.isNotEmpty
        ? existing.groupRoleMapping
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : [
            {'group': 'CN=Domain Admins,OU=Groups', 'role': 'admin'},
            {'group': 'CN=NetOps_Infrastructure,OU=Groups', 'role': 'editor'},
            {'group': 'CN=NOC_Operators,OU=Groups', 'role': 'operator'},
            {'group': 'CN=SecAudit_ReadOnly,OU=Groups', 'role': 'viewer'},
          ];
    final newGroupCtrl = TextEditingController();
    String newGroupRole = 'operator';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: Text(
            existing == null
                ? 'Conectar Nuevo Servidor Active Directory (LDAP / LDAPS)'
                : 'Editar Servidor Active Directory (${existing.name})',
          ),
          content: SizedBox(
            width: 580,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: nameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Nombre Descriptivo del AD *',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: domainCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Dominio Kerberos/AD',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: hostCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Host / URI (ej. ldap://dc01.corp.local)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: portCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Puerto (389/636)',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: baseDnCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Base DN (ej. DC=corp,DC=rackdoc,DC=local)',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: bindDnCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Bind DN (Cuenta de Servicio)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: bindPassCtrl,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Bind Password',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: filterCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Filtro LDAP de Búsqueda de Usuarios',
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: defaultRole,
                    decoration: const InputDecoration(
                      labelText: 'Rol por Defecto al Importar Usuarios de este AD',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'admin',
                        child: Text('admin — Administrador'),
                      ),
                      DropdownMenuItem(
                        value: 'editor',
                        child: Text('editor — Editor'),
                      ),
                      DropdownMenuItem(
                        value: 'operator',
                        child: Text('operator — Ver y Conectarse (SSH/Web)'),
                      ),
                      DropdownMenuItem(
                        value: 'viewer',
                        child: Text('viewer — Solo Ver'),
                      ),
                    ],
                    onChanged: (v) =>
                        setModal(() => defaultRole = v ?? 'viewer'),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Usar LDAPS / SSL (Puerto 636)',
                      style: TextStyle(fontSize: 13),
                    ),
                    value: useSsl,
                    onChanged: (v) => setModal(() {
                      useSsl = v;
                      portCtrl.text = v ? '636' : '389';
                    }),
                  ),
                  const Divider(height: 20),
                  const Text(
                    'Mapeo de Roles por Grupos de Active Directory (Group -> Role RBAC):',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 6),
                  ...groupRules.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final rule = entry.value;
                    final grp = (rule['group'] ?? '').toString();
                    final rRole = (rule['role'] ?? 'viewer').toString();
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.groups_2_outlined,
                            size: 16,
                            color: Color(0xFF1E3A8A),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              grp,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          DropdownButton<String>(
                            value: rRole,
                            isDense: true,
                            items: const [
                              DropdownMenuItem(
                                value: 'admin',
                                child: Text('Rol: ADMIN', style: TextStyle(fontSize: 11)),
                              ),
                              DropdownMenuItem(
                                value: 'editor',
                                child: Text('Rol: EDITOR', style: TextStyle(fontSize: 11)),
                              ),
                              DropdownMenuItem(
                                value: 'operator',
                                child: Text('Rol: OPERATOR', style: TextStyle(fontSize: 11)),
                              ),
                              DropdownMenuItem(
                                value: 'viewer',
                                child: Text('Rol: VIEWER', style: TextStyle(fontSize: 11)),
                              ),
                            ],
                            onChanged: (v) {
                              if (v != null) {
                                setModal(() => groupRules[idx]['role'] = v);
                              }
                            },
                          ),
                          IconButton(
                            onPressed: () =>
                                setModal(() => groupRules.removeAt(idx)),
                            icon: const Icon(
                              Icons.delete_outline,
                              size: 15,
                              color: Color(0xFFDC2626),
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: newGroupCtrl,
                          style: const TextStyle(fontSize: 12),
                          decoration: const InputDecoration(
                            labelText:
                                'Nuevo Grupo AD (ej. CN=NetOps,OU=Groups)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: DropdownButtonFormField<String>(
                          initialValue: newGroupRole,
                          isDense: true,
                          decoration: const InputDecoration(
                            labelText: 'Rol RBAC',
                            isDense: true,
                          ),
                          items: const [
                            DropdownMenuItem(value: 'admin', child: Text('admin')),
                            DropdownMenuItem(value: 'editor', child: Text('editor')),
                            DropdownMenuItem(value: 'operator', child: Text('operator')),
                            DropdownMenuItem(value: 'viewer', child: Text('viewer')),
                          ],
                          onChanged: (v) =>
                              setModal(() => newGroupRole = v ?? 'viewer'),
                        ),
                      ),
                      const SizedBox(width: 6),
                      FilledButton.tonal(
                        onPressed: () {
                          if (newGroupCtrl.text.trim().isNotEmpty) {
                            setModal(() {
                              groupRules.add({
                                'group': newGroupCtrl.text.trim(),
                                'role': newGroupRole,
                              });
                              newGroupCtrl.clear();
                            });
                          }
                        },
                        child: const Text('+ Grupo'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.dns_outlined, size: 16),
              label: Text(
                existing == null ? 'Conectar AD' : 'Guardar Cambios',
              ),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      try {
        final rawHost = hostCtrl.text.trim();
        final portNum = int.tryParse(portCtrl.text.trim()) ?? (useSsl ? 636 : 389);
        final scheme = useSsl ? 'ldaps://' : 'ldap://';
        final cleanHost = rawHost
            .replaceFirst(RegExp(r'^ldaps?://'), '')
            .split(':')
            .first;
        final ldapUrl = '$scheme$cleanHost:$portNum';
        final payload = {
          'name': nameCtrl.text.trim(),
          'ldap_url': ldapUrl,
          'domain': domainCtrl.text.trim(),
          'base_dn': baseDnCtrl.text.trim(),
          'bind_dn': bindDnCtrl.text.trim(),
          'bind_password': bindPassCtrl.text,
          'user_filter': filterCtrl.text.trim(),
          'default_role': defaultRole,
          'group_role_mapping': groupRules,
          'enabled': true,
        };
        if (existing == null) {
          await widget.api.createAdServer(payload);
        } else {
          await widget.api.updateAdServer(existing.id, payload);
        }
        await _loadAdminData();
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Servidor Active Directory guardado correctamente.'),
          ),
        );
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
        );
      }
    }
  }

  Future<void> _showSearchAndImportAdUsersDialog(ADServerModel ad) async {
    final messenger = ScaffoldMessenger.of(context);
    final queryCtrl = TextEditingController();
    List<Map<String, dynamic>> results = [];
    final selectedUsers = <String, String>{}; // username -> role
    bool searching = true;

    Future<void> runSearch(StateSetter setModal) async {
      setModal(() => searching = true);
      try {
        final res = await widget.api.searchAdUsers(
          ad.id,
          queryCtrl.text.trim(),
        );
        final list = ((res['results'] ?? []) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        setModal(() {
          results = list;
          for (final u in list) {
            final uname = (u['username'] ?? '').toString();
            final suggested =
                (u['suggested_role'] ?? ad.defaultRole).toString();
            selectedUsers.putIfAbsent(uname, () => suggested);
          }
          searching = false;
        });
      } catch (_) {
        setModal(() => searching = false);
      }
    }

    final checkedUsernames = <String>{};

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        bool initialized = false;
        return StatefulBuilder(
          builder: (ctx, setModal) {
            if (!initialized) {
              initialized = true;
              Future.microtask(() => runSearch(setModal));
            }
            return AlertDialog(
              title: Text(
                'Dar de Alta Usuarios desde "${ad.name}" (${ad.domain})',
              ),
              content: SizedBox(
                width: 640,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: queryCtrl,
                            onSubmitted: (_) => runSearch(setModal),
                            decoration: const InputDecoration(
                              hintText:
                                  'Buscar en Active Directory por sAMAccountName, nombre, departamento...',
                              prefixIcon: Icon(Icons.search, size: 18),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonalIcon(
                          onPressed: () => runSearch(setModal),
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('Consultar AD'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (ad.groupRoleMapping.isNotEmpty) ...[
                      const Text(
                        'Aplicar Rol a todo un Grupo de AD en 1 clic:',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1E3A8A),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: ad.groupRoleMapping.map((rule) {
                          final grp = (rule['group'] ?? '').toString();
                          final rRole = (rule['role'] ?? 'viewer').toString();
                          final shortGrp = grp
                              .replaceFirst('CN=', '')
                              .split(',')
                              .first;
                          return ActionChip(
                            avatar: const Icon(
                              Icons.groups_2_outlined,
                              size: 14,
                              color: Color(0xFF1E3A8A),
                            ),
                            label: Text(
                              '$shortGrp → ${rRole.toUpperCase()}',
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            onPressed: () {
                              setModal(() {
                                for (final u in results) {
                                  final uGrp =
                                      (u['ad_group'] ?? u['ad_dn'] ?? '')
                                          .toString();
                                  final uname = (u['username'] ?? '').toString();
                                  if (uGrp
                                          .toLowerCase()
                                          .contains(shortGrp.toLowerCase()) ||
                                      grp
                                          .toLowerCase()
                                          .contains(uGrp.toLowerCase())) {
                                    checkedUsernames.add(uname);
                                    selectedUsers[uname] = rRole;
                                  }
                                }
                              });
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 8),
                    ],
                    const Text(
                      'Selecciona los usuarios o grupos del Directorio Activo y asígnales uno de los 4 roles de RackDoc:',
                      style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
                    ),
                    const SizedBox(height: 8),
                    if (searching)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else
                      Container(
                        height: 300,
                        decoration: BoxDecoration(
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ListView.separated(
                          itemCount: results.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (ctx, idx) {
                            final item = results[idx];
                            final uname = (item['username'] ?? '').toString();
                            final fname = (item['full_name'] ?? '').toString();
                            final email = (item['email'] ?? '').toString();
                            final dept = (item['department'] ?? '').toString();
                            final adGroup = (item['ad_group'] ?? '').toString();
                            final already =
                                item['already_registered'] == true ||
                                item['already_imported'] == true;
                            final isChecked = checkedUsernames.contains(uname);
                            final assignedRole =
                                selectedUsers[uname] ?? ad.defaultRole;

                            return CheckboxListTile(
                              value: isChecked,
                              onChanged: (v) {
                                setModal(() {
                                  if (v == true) {
                                    checkedUsernames.add(uname);
                                  } else {
                                    checkedUsernames.remove(uname);
                                  }
                                });
                              },
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Text(
                                              '$fname ($uname)',
                                              style: const TextStyle(
                                                fontSize: 12.5,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            if (adGroup.isNotEmpty) ...[
                                              const SizedBox(width: 6),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 5,
                                                      vertical: 1.5,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFFE0E7FF),
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  'Grupo AD: ${adGroup.replaceFirst('CN=', '').split(',').first}',
                                                  style: const TextStyle(
                                                    fontSize: 9.5,
                                                    fontWeight: FontWeight.w700,
                                                    color: Color(0xFF3730A3),
                                                  ),
                                                ),
                                              ),
                                            ],
                                            if (already) ...[
                                              const SizedBox(width: 6),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: const Color(
                                                    0xFFDCFCE7,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: const Text(
                                                  'Ya en RackDoc (Actualizar Rol)',
                                                  style: TextStyle(
                                                    fontSize: 9.5,
                                                    fontWeight: FontWeight.bold,
                                                    color: Color(0xFF15803D),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                        Text(
                                          '$email • $dept',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Color(0xFF64748B),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  DropdownButton<String>(
                                    value: assignedRole,
                                    isDense: true,
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF0F172A),
                                    ),
                                    items: const [
                                      DropdownMenuItem(
                                        value: 'admin',
                                        child: Text('Rol: Administrador'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'editor',
                                        child: Text('Rol: Editor'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'operator',
                                        child: Text('Rol: Ver y Conectarse'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'viewer',
                                        child: Text('Rol: Solo Ver'),
                                      ),
                                    ],
                                    onChanged: (val) {
                                      if (val != null) {
                                        setModal(() {
                                          selectedUsers[uname] = val;
                                          checkedUsernames.add(uname);
                                        });
                                      }
                                    },
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancelar'),
                ),
                FilledButton.icon(
                  onPressed: checkedUsernames.isEmpty
                      ? null
                      : () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.person_add_alt_1, size: 16),
                  label: Text(
                    'Dar de Alta / Aplicar Rol (${checkedUsernames.length})',
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed == true && checkedUsernames.isNotEmpty) {
      try {
        final toImport = results
            .where((r) => checkedUsernames.contains(r['username']))
            .map(
              (r) => {
                'username': r['username'],
                'full_name': r['full_name'],
                'email': r['email'],
                'ad_dn': r['ad_dn'],
                'role': selectedUsers[r['username']] ?? ad.defaultRole,
              },
            )
            .toList();
        final res = await widget.api.importAdUsers(ad.id, toImport);
        await _loadAdminData();
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Usuarios AD procesados desde "${ad.name}": ${res['imported_count'] ?? toImport.length} dados de alta / actualizados.',
            ),
          ),
        );
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text('Error cargando administración: $_error'));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // CABECERA PRINCIPAL
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Administración de Usuarios, 4 Roles RBAC y Multi-Active Directory',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Credenciales admin por defecto configurables en .env / Docker (ADMIN_USERNAME=admin, ADMIN_PASSWORD=admin) + Conexión a uno o varios servidores AD.',
                      style: TextStyle(fontSize: 12.5, color: Color(0xFF64748B)),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: () => _showCreateOrEditUserDialog(),
                icon: const Icon(Icons.person_add_alt_1, size: 16),
                label: const Text('+ Nuevo Usuario Local'),
              ),
              const SizedBox(width: 10),
              FilledButton.tonalIcon(
                onPressed: () => _showCreateOrEditAdServerDialog(),
                icon: const Icon(Icons.domain_add, size: 16),
                label: const Text('+ Conectar Servidor AD'),
              ),
            ],
          ),

          const SizedBox(height: 18),

          // TARJETAS EXPLICATIVAS DE LOS 4 ROLES (RBAC)
          const Row(
            children: [
              Expanded(
                child: _RoleInfoCard(
                  roleCode: 'admin',
                  title: '1. Administrador (admin)',
                  color: Color(0xFFDC2626),
                  description:
                      'Control total: gestión de Usuarios, servidores Active Directory, edición de Sedes/Plantas/Racks/Librerías y conexión SSH/Telnet/Web.',
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: _RoleInfoCard(
                  roleCode: 'editor',
                  title: '2. Editor (editor)',
                  color: Color(0xFF2563EB),
                  description:
                      'Permite crear, mover, editar y borrar Locations, Plantas, Racks, Equipos, Tomas Schuko y Cables + conectar por SSH/Telnet/Web.',
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: _RoleInfoCard(
                  roleCode: 'operator',
                  title: '3. Ver y Conectarse (operator)',
                  color: Color(0xFF0D9488),
                  description:
                      'Modo lectura sobre el diseño físico del rack, PERO permite interactuar con cada host mediante SSH, Telnet, Web UI (iLO/iDRAC) y Ping.',
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: _RoleInfoCard(
                  roleCode: 'viewer',
                  title: '4. Solo Ver (viewer)',
                  color: Color(0xFF64748B),
                  description:
                      'Auditoría y visualización estricta de mapas, plantas y racks. No puede modificar nada ni lanzar sesiones SSH/Telnet/Web.',
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // SECCIÓN 0: ALTA DIRECTA DE USUARIOS NUEVOS LOCALES (NO SOLO DE AD)
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF93C5FD), width: 1.4),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x08000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFDBEAFE),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(
                        Icons.person_add_alt_1_rounded,
                        size: 18,
                        color: Color(0xFF1D4ED8),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Dar de Alta Nuevo Usuario Local (Base de Datos RackDoc — Sin Active Directory)',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          Text(
                            'Crea cuentas de usuario locales con contraseña propia y asígnales directamente cualquiera de los 4 roles RBAC.',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFF475569),
                            ),
                          ),
                        ],
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _showCreateOrEditUserDialog(),
                      icon: const Icon(Icons.open_in_new, size: 15),
                      label: const Text('Formulario Completo'),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _quickUsernameCtrl,
                        decoration: InputDecoration(
                          labelText: 'Usuario (Username) *',
                          hintText: 'ej. jgarcia, operador1',
                          prefixIcon: const Icon(Icons.person_outline, size: 17),
                          isDense: true,
                          filled: true,
                          fillColor: const Color(0xFFF8FAFC),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _quickFullNameCtrl,
                        decoration: InputDecoration(
                          labelText: 'Nombre y Apellidos',
                          hintText: 'ej. Javier García',
                          prefixIcon: const Icon(Icons.badge_outlined, size: 17),
                          isDense: true,
                          filled: true,
                          fillColor: const Color(0xFFF8FAFC),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _quickEmailCtrl,
                        decoration: InputDecoration(
                          labelText: 'Correo Electrónico',
                          hintText: 'ej. jgarcia@empresa.es',
                          prefixIcon: const Icon(Icons.email_outlined, size: 17),
                          isDense: true,
                          filled: true,
                          fillColor: const Color(0xFFF8FAFC),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _quickPasswordCtrl,
                        obscureText: true,
                        onSubmitted: (_) => _submitQuickLocalUser(),
                        decoration: InputDecoration(
                          labelText: 'Contraseña *',
                          hintText: 'Por defecto: rackdoc123',
                          prefixIcon: const Icon(Icons.key_outlined, size: 17),
                          isDense: true,
                          filled: true,
                          fillColor: const Color(0xFFF8FAFC),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<String>(
                        initialValue: _quickRole,
                        isDense: true,
                        decoration: InputDecoration(
                          labelText: 'Rol RBAC',
                          isDense: true,
                          filled: true,
                          fillColor: const Color(0xFFF8FAFC),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'admin',
                            child: Text('admin (Total)', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'editor',
                            child: Text('editor (Editar)', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'operator',
                            child: Text('operator (SSH/Web)', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'viewer',
                            child: Text('viewer (Solo Ver)', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                        onChanged: (v) =>
                            setState(() => _quickRole = v ?? 'editor'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed:
                          _creatingLocalUser ? null : _submitQuickLocalUser,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF1E3A8A),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 14,
                        ),
                      ),
                      icon: const Icon(Icons.person_add_alt_1, size: 16),
                      label: Text(
                        _creatingLocalUser ? 'Creando...' : 'Dar de Alta',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // SECCIÓN 1: SERVIDORES ACTIVE DIRECTORY CONECTADOS (MULTI-AD)
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.account_tree_outlined,
                      size: 20,
                      color: Color(0xFF1E3A8A),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Servidores Active Directory / LDAP Conectados (${_adServers.length})',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const Spacer(),
                    OutlinedButton.icon(
                      onPressed: () => _showCreateOrEditAdServerDialog(),
                      icon: const Icon(Icons.add, size: 15),
                      label: const Text('Añadir otro AD'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: _adServers.map((ad) {
                    return Container(
                      width: 460,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFDBEAFE),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  ad.useSsl ? 'LDAPS:${ad.port}' : 'LDAP:${ad.port}',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF1D4ED8),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  ad.name,
                                  style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                              ),
                              IconButton(
                                onPressed: () =>
                                    _showCreateOrEditAdServerDialog(
                                      existing: ad,
                                    ),
                                icon: const Icon(Icons.edit_outlined, size: 16),
                                tooltip: 'Editar configuración AD',
                                visualDensity: VisualDensity.compact,
                              ),
                              IconButton(
                                onPressed: () async {
                                  await widget.api.deleteAdServer(ad.id);
                                  await _loadAdminData();
                                },
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 16,
                                  color: Color(0xFFDC2626),
                                ),
                                tooltip: 'Eliminar servidor AD',
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Host: ${ad.host} • Dominio: ${ad.domain}',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFF334155),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'Base DN: ${ad.baseDn}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF64748B),
                            ),
                          ),
                          if (ad.groupRoleMapping.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              children: ad.groupRoleMapping.map((rule) {
                                final grp = (rule['group'] ?? '')
                                    .toString()
                                    .replaceFirst('CN=', '')
                                    .split(',')
                                    .first;
                                final rl = (rule['role'] ?? 'viewer').toString();
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _roleColor(rl).withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: _roleColor(rl).withValues(alpha: 0.35),
                                    ),
                                  ),
                                  child: Text(
                                    'Grupo $grp → ${rl.toUpperCase()}',
                                    style: TextStyle(
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w700,
                                      color: _roleColor(rl),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: _roleColor(
                                    ad.defaultRole,
                                  ).withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  'Rol por defecto: ${ad.defaultRole.toUpperCase()}',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.bold,
                                    color: _roleColor(ad.defaultRole),
                                  ),
                                ),
                              ),
                              const Spacer(),
                              FilledButton.tonalIcon(
                                onPressed: () =>
                                    _showSearchAndImportAdUsersDialog(ad),
                                icon: const Icon(
                                  Icons.person_search_outlined,
                                  size: 16,
                                ),
                                label: const Text(
                                  'Dar de Alta Usuarios de este AD',
                                  style: TextStyle(fontSize: 11.5),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // SECCIÓN 2: TABLA DE USUARIOS REGISTRADOS Y ASIGNACIÓN DE ROL EN 1 CLIC
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.people_alt_outlined,
                      size: 20,
                      color: Color(0xFF0F172A),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Usuarios Registrados y Permisos RBAC (${_users.length})',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const Spacer(),
                    const Text(
                      'Cambia el rol en el desplegable o pulsa "Probar Sesión" para verificar permisos en vivo',
                      style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                ..._users.map((u) {
                  final isCurrent = u.id == widget.currentUser.id;
                  final roleCol = _roleColor(u.role);
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: isCurrent
                          ? const Color(0xFFEFF6FF)
                          : Colors.transparent,
                      border: const Border(
                        bottom: BorderSide(color: Color(0xFFF1F5F9)),
                      ),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: roleCol.withValues(alpha: 0.15),
                          child: Text(
                            u.username.substring(0, 1).toUpperCase(),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: roleCol,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    u.fullName.isNotEmpty
                                        ? '${u.fullName} (${u.username})'
                                        : u.username,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF0F172A),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: u.authSource == 'ad'
                                          ? const Color(0xFFFEF3C7)
                                          : const Color(0xFFE2E8F0),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      u.authSource == 'ad'
                                          ? 'AD: ${u.adServerName ?? 'Active Directory'}'
                                          : 'LOCAL (.env / DB)',
                                      style: TextStyle(
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w800,
                                        color: u.authSource == 'ad'
                                            ? const Color(0xFFB45309)
                                            : const Color(0xFF334155),
                                      ),
                                    ),
                                  ),
                                  if (isCurrent) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFDCFCE7),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Text(
                                        'SESIÓN ACTIVA',
                                        style: TextStyle(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF15803D),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              Text(
                                u.email.isNotEmpty
                                    ? '${u.email}${u.adDn.isNotEmpty ? ' • ${u.adDn}' : ''}'
                                    : 'Sin email',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF64748B),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Selector rápido de Rol (los 4 roles solicitados)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: roleCol.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: roleCol.withValues(alpha: 0.35),
                            ),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: u.role,
                              isDense: true,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: roleCol,
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'admin',
                                  child: Text('admin (Administrador)'),
                                ),
                                DropdownMenuItem(
                                  value: 'editor',
                                  child: Text('editor (Editor)'),
                                ),
                                DropdownMenuItem(
                                  value: 'operator',
                                  child: Text('operator (Ver & Conectarse)'),
                                ),
                                DropdownMenuItem(
                                  value: 'viewer',
                                  child: Text('viewer (Solo Ver)'),
                                ),
                              ],
                              onChanged: (newRole) async {
                                if (newRole == null || newRole == u.role) {
                                  return;
                                }
                                final updated = await widget.api.updateUser(
                                  u.id,
                                  {'role': newRole},
                                );
                                if (u.id == widget.currentUser.id) {
                                  widget.onSwitchActiveUser(updated);
                                }
                                await _loadAdminData();
                              },
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        if (!isCurrent)
                          OutlinedButton.icon(
                            onPressed: () => widget.onSwitchActiveUser(u),
                            icon: const Icon(Icons.login, size: 14),
                            label: const Text(
                              'Probar Sesión',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                        const SizedBox(width: 6),
                        IconButton(
                          onPressed: () =>
                              _showCreateOrEditUserDialog(existing: u),
                          icon: const Icon(Icons.edit_outlined, size: 17),
                          tooltip: 'Editar usuario / contraseña',
                        ),
                        if (u.username != 'admin')
                          IconButton(
                            onPressed: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              try {
                                await widget.api.deleteUser(u.id);
                                await _loadAdminData();
                              } catch (e) {
                                messenger.showSnackBar(
                                  SnackBar(content: Text('$e')),
                                );
                              }
                            },
                            icon: const Icon(
                              Icons.delete_outline,
                              size: 17,
                              color: Color(0xFFDC2626),
                            ),
                            tooltip: 'Eliminar usuario',
                          ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RoleInfoCard extends StatelessWidget {
  final String roleCode;
  final String title;
  final Color color;
  final String description;

  const _RoleInfoCard({
    required this.roleCode,
    required this.title,
    required this.color,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border(
          top: BorderSide(color: color, width: 3.5),
          left: const BorderSide(color: Color(0xFFE2E8F0)),
          right: const BorderSide(color: Color(0xFFE2E8F0)),
          bottom: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: const TextStyle(fontSize: 11, color: Color(0xFF475569)),
          ),
        ],
      ),
    );
  }
}
