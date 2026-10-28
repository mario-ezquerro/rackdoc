import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'core/api_client.dart';
import 'features/admin/admin_view.dart';
import 'features/datacenter/datacenter_floor_view.dart';
import 'features/locations/locations_view.dart';
import 'features/rack_editor/rack_editor_view.dart';
import 'models/datacenter_models.dart';

void main() {
  runApp(const RackDocApp());
}

class RackDocApp extends StatelessWidget {
  const RackDocApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RackDoc — DCIM & Visual Rack Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF1E3A8A),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        fontFamily: 'SF Pro Text',
      ),
      home: const RackDocShell(),
    );
  }
}

class RackDocShell extends StatefulWidget {
  const RackDocShell({super.key});

  @override
  State<RackDocShell> createState() => _RackDocShellState();
}

class _RackDocShellState extends State<RackDocShell> {
  final RackDocApiClient _api = RackDocApiClient();

  // Flujo jerárquico: 'locations' -> 'datacenter' -> 'rack_editor' -> 'dashboard' -> 'admin'
  String _activeNav = 'locations';
  int _activeLocationId = 1;
  int _activeRackId = 1;

  List<LocationNode> _locations = [];
  List<DeviceTemplateModel> _templates = [];
  List<UserModel> _users = [];
  UserModel _currentUser = UserModel(
    id: 1,
    username: 'admin',
    email: 'admin@rackdoc.local',
    fullName: 'Administrador General (.env)',
    role: 'admin',
    authSource: 'local',
    adDn: '',
    isActive: true,
  );

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _api.getLocations(),
        _api.getTemplates(),
        _api.getUsers(),
      ]);
      final locs = results[0] as List<LocationNode>;
      final tpls = results[1] as List<DeviceTemplateModel>;
      final usrs = results[2] as List<UserModel>;

      int defaultLocId = _activeLocationId;
      int defaultRackId = _activeRackId;
      if (locs.isNotEmpty) {
        if (!locs.any((l) => l.id == defaultLocId)) {
          defaultLocId = locs.first.id;
        }
        for (final l in locs) {
          for (final f in l.floors) {
            for (final r in f.rooms) {
              if (r.racks.isNotEmpty && defaultRackId == 1) {
                defaultRackId = r.racks.first.id;
                break;
              }
            }
          }
        }
      }

      UserModel activeUsr = _currentUser;
      if (usrs.isNotEmpty) {
        activeUsr = usrs.firstWhere(
          (u) => u.username == _currentUser.username,
          orElse: () => usrs.first,
        );
      }

      if (mounted) {
        setState(() {
          _locations = locs;
          _templates = tpls;
          _users = usrs;
          _currentUser = activeUsr;
          _activeLocationId = defaultLocId;
          _activeRackId = defaultRackId;
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

  Future<void> _refreshDataSilently() async {
    try {
      final locs = await _api.getLocations();
      if (mounted) {
        setState(() => _locations = locs);
      }
    } catch (_) {}
  }

  Future<void> _refreshTemplates() async {
    final tpls = await _api.getTemplates();
    if (mounted) {
      setState(() => _templates = tpls);
    }
  }

  void _openDatacenter(int locationId) {
    setState(() {
      _activeLocationId = locationId;
      _activeNav = 'datacenter';
    });
  }

  void _openRack(int rackId) {
    for (final l in _locations) {
      for (final f in l.floors) {
        for (final r in f.rooms) {
          if (r.racks.any((rk) => rk.id == rackId)) {
            _activeLocationId = l.id;
          }
        }
      }
    }
    setState(() {
      _activeRackId = rackId;
      _activeNav = 'rack_editor';
    });
  }

  Future<void> _showLoginOrSwitchUserModal() async {
    final messenger = ScaffoldMessenger.of(context);
    final userCtrl = TextEditingController(text: 'admin');
    final passCtrl = TextEditingController(text: 'admin');
    String? authError;

    try {
      _users = await _api.getUsers();
    } catch (_) {}

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.shield_outlined, color: Color(0xFF1E3A8A)),
              SizedBox(width: 8),
              Text('Iniciar Sesión / Cambiar Rol de Usuario'),
            ],
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Autenticación Local (.env admin/admin) o Active Directory (LDAP):',
                  style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: userCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Usuario (ej. admin)',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: passCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Contraseña (ej. admin)',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () async {
                        try {
                          final logged = await _api.login(
                            userCtrl.text.trim(),
                            passCtrl.text,
                          );
                          setState(() => _currentUser = logged);
                          if (ctx.mounted) Navigator.pop(ctx);
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                'Sesión iniciada como ${logged.username} (${logged.roleLabel}).',
                              ),
                            ),
                          );
                        } catch (e) {
                          setModal(() => authError = e.toString());
                        }
                      },
                      child: const Text('Entrar'),
                    ),
                  ],
                ),
                if (authError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    authError!,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFDC2626),
                    ),
                  ),
                ],
                const Divider(height: 24),
                const Text(
                  'Cambio Rápido de Sesión (Probar los 4 Roles RBAC):',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 8),
                ..._users.map((u) {
                  final isSel = u.id == _currentUser.id;
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    selected: isSel,
                    selectedTileColor: const Color(0xFFEFF6FF),
                    leading: Icon(
                      u.authSource == 'ad'
                          ? Icons.domain_verification
                          : Icons.person_outline,
                      size: 18,
                      color: const Color(0xFF1E3A8A),
                    ),
                    title: Text(
                      '${u.username} — ${u.fullName}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: Text(
                      'Rol: ${u.roleLabel} (${u.role}) • Origen: ${u.authSource.toUpperCase()}',
                      style: const TextStyle(fontSize: 10.5),
                    ),
                    trailing: isSel
                        ? const Icon(
                            Icons.check_circle,
                            color: Color(0xFF16A34A),
                            size: 18,
                          )
                        : const Text(
                            'Usar',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFF2563EB),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                    onTap: () {
                      setState(() => _currentUser = u);
                      Navigator.pop(ctx);
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            'Sesión activa: ${u.username} — Rol: ${u.roleLabel}',
                          ),
                        ),
                      );
                    },
                  );
                }),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // BARRA LATERAL IZQUIERDA CON EL FLUJO JERÁRQUICO + ADMINISTRACIÓN RBAC/AD
          Container(
            width: 235,
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(right: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(
                          Icons.dns_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'RackDoc DCIM',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                            Text(
                              'PBX Datacenter',
                              style: TextStyle(
                                fontSize: 11,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Tarjeta de Sesión Activa y Rol RBAC
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: InkWell(
                    onTap: _showLoginOrSwitchUserModal,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.verified_user_outlined,
                            size: 16,
                            color: Color(0xFF1E3A8A),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${_currentUser.username} (${_currentUser.authSource.toUpperCase()})',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF0F172A),
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  'Rol: ${_currentUser.roleLabel}',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF2563EB),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.swap_horiz_rounded,
                            size: 16,
                            color: Color(0xFF64748B),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                const Divider(height: 1),
                const SizedBox(height: 6),

                _SidebarItem(
                  icon: Icons.location_on_outlined,
                  label: '1. Locations (Mapa)',
                  active: _activeNav == 'locations',
                  onTap: () => setState(() => _activeNav = 'locations'),
                ),
                _SidebarItem(
                  icon: Icons.apartment_rounded,
                  label: '2. Datacenter (Plantas)',
                  active: _activeNav == 'datacenter',
                  onTap: () => setState(() => _activeNav = 'datacenter'),
                ),
                _SidebarItem(
                  icon: Icons.developer_board_outlined,
                  label: '3. Rack Editor (42U)',
                  active: _activeNav == 'rack_editor',
                  onTap: () => setState(() => _activeNav = 'rack_editor'),
                ),
                _SidebarItem(
                  icon: Icons.dashboard_outlined,
                  label: '4. Dashboard & Excel',
                  active: _activeNav == 'dashboard',
                  onTap: () => setState(() => _activeNav = 'dashboard'),
                ),
                _SidebarItem(
                  icon: Icons.admin_panel_settings_outlined,
                  label: '5. Administración & AD',
                  active: _activeNav == 'admin',
                  onTap: () => setState(() => _activeNav = 'admin'),
                ),

                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Text(
                    'DATACENTERS & RACKS',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF94A3B8),
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      for (final loc in _locations) ...[
                        ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          leading: const Icon(
                            Icons.business_rounded,
                            size: 16,
                            color: Color(0xFF0F172A),
                          ),
                          title: Text(
                            '${loc.code} — ${loc.name}',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          onTap: () => _openDatacenter(loc.id),
                        ),
                        for (final fl in loc.floors)
                          for (final rm in fl.rooms)
                            for (final rk in rm.racks)
                              Padding(
                                padding: const EdgeInsets.only(left: 10),
                                child: ListTile(
                                  dense: true,
                                  visualDensity: VisualDensity.compact,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  selected: _activeNav == 'rack_editor' &&
                                      _activeRackId == rk.id,
                                  selectedTileColor: const Color(0xFFEFF6FF),
                                  leading: Icon(
                                    Icons.dns_outlined,
                                    size: 15,
                                    color: (_activeNav == 'rack_editor' &&
                                            _activeRackId == rk.id)
                                        ? const Color(0xFF2563EB)
                                        : const Color(0xFF64748B),
                                  ),
                                  title: Text(
                                    '${rk.code} (${rk.name})',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight:
                                          (_activeNav == 'rack_editor' &&
                                                  _activeRackId == rk.id)
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                      color: (_activeNav == 'rack_editor' &&
                                              _activeRackId == rk.id)
                                          ? const Color(0xFF1D4ED8)
                                          : const Color(0xFF334155),
                                    ),
                                  ),
                                  subtitle: Text(
                                    'P${fl.levelNumber} • ${rk.aisleName}',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: Color(0xFF94A3B8),
                                    ),
                                  ),
                                  onTap: () => _openRack(rk.id),
                                ),
                              ),
                      ],
                    ],
                  ),
                ),

                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: OutlinedButton.icon(
                    onPressed: () {
                      final url = Uri.parse(_api.getExcelExportUrl());
                      launchUrl(url, mode: LaunchMode.externalApplication);
                    },
                    icon: const Icon(Icons.table_view_outlined, size: 16),
                    label: const Text(
                      'Exportar Todo a Excel',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // CONTENIDO PRINCIPAL
          Expanded(
            child: _buildMainContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Container(
          padding: const EdgeInsets.all(24),
          constraints: const BoxConstraints(maxWidth: 480),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 42, color: Color(0xFFDC2626)),
              const SizedBox(height: 12),
              const Text(
                'No se pudo conectar con el Backend de RackDoc',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'Detalle: $_error',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadInitialData,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar conexión'),
              ),
            ],
          ),
        ),
      );
    }

    if (_activeNav == 'locations') {
      return LocationsView(
        api: _api,
        locations: _locations,
        onRefresh: _refreshDataSilently,
        onOpenDatacenter: _openDatacenter,
        onOpenRack: _openRack,
      );
    }

    if (_activeNav == 'datacenter') {
      return DatacenterFloorView(
        api: _api,
        locations: _locations,
        activeLocationId: _activeLocationId,
        onChangeLocation: (id) => setState(() => _activeLocationId = id),
        onBackToLocations: () => setState(() => _activeNav = 'locations'),
        onOpenRack: _openRack,
        onRefresh: _refreshDataSilently,
      );
    }

    if (_activeNav == 'dashboard') {
      return _buildDashboardOverview();
    }

    if (_activeNav == 'admin') {
      return AdminView(
        api: _api,
        currentUser: _currentUser,
        onSwitchActiveUser: (usr) async {
          final usrs = await _api.getUsers();
          if (mounted) {
            setState(() {
              _users = usrs;
              _currentUser = usr;
            });
          }
        },
      );
    }

    return RackEditorView(
      api: _api,
      rackId: _activeRackId,
      templates: _templates,
      onBackToLocations: () {
        _refreshDataSilently();
        setState(() => _activeNav = 'datacenter');
      },
      onSwitchRack: _openRack,
      onTemplatesChanged: _refreshTemplates,
      currentUser: _currentUser,
    );
  }

  Widget _buildDashboardOverview() {
    int totalFloors = 0;
    int totalRooms = 0;
    int totalRacks = 0;
    int totalDevices = 0;

    for (final l in _locations) {
      totalFloors += l.floorsCount;
      totalRooms += l.roomsCount;
      totalRacks += l.racksCount;
      for (final f in l.floors) {
        for (final r in f.rooms) {
          for (final rk in r.racks) {
            totalDevices += rk.deviceCount;
          }
        }
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Dashboard & Exportación de Informes',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Resumen global de sedes, plantas del edificio, racks (Front & Back), red y exportación Excel.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: () {
                  final url = Uri.parse(_api.getExcelExportUrl());
                  launchUrl(url, mode: LaunchMode.externalApplication);
                },
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Descargar Inventario Completo (.xlsx)'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF15803D),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              _DashboardCard(
                title: 'Datacenters (Locations)',
                value: '${_locations.length}',
                icon: Icons.public,
                color: const Color(0xFF2563EB),
              ),
              _DashboardCard(
                title: 'Plantas y Salas',
                value: '$totalFloors Plantas / $totalRooms Salas',
                icon: Icons.layers_outlined,
                color: const Color(0xFF0284C7),
              ),
              _DashboardCard(
                title: 'Racks Operativos',
                value: '$totalRacks Racks',
                icon: Icons.dns_outlined,
                color: const Color(0xFF7C3AED),
              ),
              _DashboardCard(
                title: 'Equipos Montados',
                value: '$totalDevices Dispositivos',
                icon: Icons.settings_ethernet,
                color: const Color(0xFF16A34A),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: active ? const Color(0xFFEFF6FF) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: active
                    ? const Color(0xFF2563EB)
                    : const Color(0xFF475569),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active
                        ? const Color(0xFF1D4ED8)
                        : const Color(0xFF334155),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashboardCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _DashboardCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
            ),
          ),
        ],
      ),
    );
  }
}
