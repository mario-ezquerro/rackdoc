import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'core/api_client.dart';
import 'core/image_file_picker.dart';
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
      title: 'RackDoc8 — DCIM & Visual Rack Manager',
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
  int? _activeFloorId;
  int _activeRackId = 1;
  int? _highlightedDeviceId;

  // Estado de expansión del árbol jerárquico en la columna izquierda ("DATACENTERS & RACKS"):
  // Cada Datacenter tiene su triángulo (gira 90°) para mostrar sus Pisos, y cada Piso tiene su triángulo (gira 90°) para mostrar sus Racks.
  final Set<int> _expandedLocationIds = {};
  final Set<int> _expandedFloorIds = {};

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

  bool _isAuthenticated = false;
  final TextEditingController _gateUserCtrl = TextEditingController(text: 'admin');
  final TextEditingController _gatePassCtrl = TextEditingController();
  String? _gateAuthError;
  bool _gateAuthenticating = false;

  // Estado del buscador y organizador de Sistemas Monitorizados en el Dashboard
  final TextEditingController _dashSearchCtrl = TextEditingController();
  String _dashStatusFilter = 'all'; // 'all' | 'online' | 'offline' | 'warning'
  String _dashMethodFilter = 'all'; // 'all' | 'icmp' | 'ssh' | 'https' | 'http' | 'tcp' | 'snmp'
  String _dashSortBy = 'status'; // 'status' | 'code' | 'ip' | 'rack' | 'latency' | 'method'
  bool _dashSortAsc = true;

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
          if (_expandedLocationIds.isEmpty && locs.isNotEmpty) {
            _expandedLocationIds.add(defaultLocId);
            final defLoc = locs.firstWhere(
              (l) => l.id == defaultLocId,
              orElse: () => locs.first,
            );
            if (defLoc.floors.isNotEmpty) {
              _expandedFloorIds.add(defLoc.floors.first.id);
              _activeFloorId ??= defLoc.floors.first.id;
            }
          }
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

  void _openDatacenter(int locationId, {int? floorId}) {
    setState(() {
      _activeLocationId = locationId;
      _expandedLocationIds.add(locationId);
      if (floorId != null) {
        _activeFloorId = floorId;
        _expandedFloorIds.add(floorId);
      }
      _activeNav = 'datacenter';
    });
  }

  void _openRack(int rackId, {int? highlightDeviceId}) {
    for (final l in _locations) {
      for (final f in l.floors) {
        for (final r in f.rooms) {
          if (r.racks.any((rk) => rk.id == rackId)) {
            _activeLocationId = l.id;
            _activeFloorId = f.id;
            _expandedLocationIds.add(l.id);
            _expandedFloorIds.add(f.id);
          }
        }
      }
    }
    setState(() {
      _activeRackId = rackId;
      _highlightedDeviceId = highlightDeviceId;
      _activeNav = 'rack_editor';
    });
  }

  Future<void> _performGateLogin() async {
    setState(() {
      _gateAuthenticating = true;
      _gateAuthError = null;
    });
    try {
      final logged = await _api.login(
        _gateUserCtrl.text.trim(),
        _gatePassCtrl.text,
      );
      if (mounted) {
        setState(() {
          _currentUser = logged;
          _isAuthenticated = true;
          _gateAuthenticating = false;
          _gatePassCtrl.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _gateAuthError = e.toString().replaceFirst('Exception: ', '');
          _gateAuthenticating = false;
        });
      }
    }
  }

  Future<void> _showLoginOrSwitchUserModal({String? prefillUsername}) async {
    final messenger = ScaffoldMessenger.of(context);
    final userCtrl = TextEditingController(
      text: prefillUsername ?? _currentUser.username,
    );
    final passCtrl = TextEditingController();
    final passFocus = FocusNode();
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
              Icon(Icons.lock_person_outlined, color: Color(0xFF1E3A8A)),
              SizedBox(width: 8),
              Text('Cambiar de Usuario (Requiere Contraseña)'),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Introduce el usuario y la contraseña para cambiar de sesión (Local .env o Active Directory):',
                  style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: userCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Usuario *',
                          prefixIcon: Icon(Icons.person_outline, size: 17),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: passCtrl,
                        focusNode: passFocus,
                        autofocus: true,
                        obscureText: true,
                        onSubmitted: (_) async {
                          try {
                            final logged = await _api.login(
                              userCtrl.text.trim(),
                              passCtrl.text,
                            );
                            setState(() {
                              _currentUser = logged;
                              _isAuthenticated = true;
                            });
                            if (ctx.mounted) Navigator.pop(ctx);
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Sesión iniciada como ${logged.username} (${logged.roleLabel}).',
                                ),
                              ),
                            );
                          } catch (e) {
                            setModal(
                              () => authError = e.toString().replaceFirst(
                                    'Exception: ',
                                    '',
                                  ),
                            );
                          }
                        },
                        decoration: const InputDecoration(
                          labelText: 'Contraseña *',
                          prefixIcon: Icon(Icons.key_outlined, size: 17),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () async {
                        try {
                          final logged = await _api.login(
                            userCtrl.text.trim(),
                            passCtrl.text,
                          );
                          setState(() {
                            _currentUser = logged;
                            _isAuthenticated = true;
                          });
                          if (ctx.mounted) Navigator.pop(ctx);
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                'Sesión iniciada como ${logged.username} (${logged.roleLabel}).',
                              ),
                            ),
                          );
                        } catch (e) {
                          setModal(
                            () => authError = e.toString().replaceFirst(
                                  'Exception: ',
                                  '',
                                ),
                          );
                        }
                      },
                      icon: const Icon(Icons.login, size: 15),
                      label: const Text('Autenticar'),
                    ),
                  ],
                ),
                if (authError != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFFECACA)),
                    ),
                    child: Text(
                      authError!,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFDC2626),
                      ),
                    ),
                  ),
                ],
                const Divider(height: 24),
                const Text(
                  'Usuarios registrados (pulsa uno para rellenar su nombre y escribe su contraseña):',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView(
                    shrinkWrap: true,
                    children: _users.map((u) {
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
                                'Seleccionar',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF2563EB),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                        onTap: () {
                          setModal(() {
                            userCtrl.text = u.username;
                            passCtrl.clear();
                            authError =
                                'Introduce la contraseña de "${u.username}" y pulsa Autenticar.';
                          });
                          passFocus.requestFocus();
                        },
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                setState(() {
                  _isAuthenticated = false;
                  _gateUserCtrl.text = _currentUser.username;
                  _gatePassCtrl.clear();
                });
              },
              icon: const Icon(
                Icons.logout,
                size: 15,
                color: Color(0xFFDC2626),
              ),
              label: const Text(
                'Cerrar Sesión',
                style: TextStyle(color: Color(0xFFDC2626)),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatMonitoredInline({
    required int monitored,
    required int online,
    required int offline,
    String prefix = '',
  }) {
    final parts = <String>[];
    if (prefix.isNotEmpty) parts.add(prefix);
    parts.add('Monit: $monitored');
    final statusParts = <String>[];
    if (online > 0) statusParts.add('🟢$online');
    if (offline > 0) statusParts.add('🔴$offline');
    if (statusParts.isNotEmpty) {
      parts.add(statusParts.join(' '));
    }
    return parts.join(' • ');
  }

  Future<void> _showImportExcelDialog() async {
    final messenger = ScaffoldMessenger.of(context);
    bool importing = false;
    Map<String, dynamic>? importResult;
    String? importError;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.upload_file_rounded, color: Color(0xFF15803D)),
              SizedBox(width: 8),
              Text('Importar Datos desde Excel (.xlsx)'),
            ],
          ),
          content: SizedBox(
            width: 540,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0FDF4),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF86EFAC)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.description_outlined,
                            size: 18,
                            color: Color(0xFF15803D),
                          ),
                          SizedBox(width: 6),
                          Text(
                            'Paso 1 (Recomendado): Descarga la Plantilla Excel de Ejemplo',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF14532D),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Incluye las pestañas "1_Racks_y_Sedes", "2_Equipos_y_Hosts" y "3_Instrucciones_y_Librerias" con ejemplos pre-rellenados (HP ProLiant, Dell PowerEdge, Supermicro, Cisco, Fortinet) listos para editar.',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFF166534),
                        ),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: () {
                          final url = Uri.parse(_api.getExcelTemplateUrl());
                          launchUrl(url, mode: LaunchMode.externalApplication);
                        },
                        style: OutlinedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF15803D),
                          side: const BorderSide(color: Color(0xFF16A34A)),
                        ),
                        icon: const Icon(Icons.download_rounded, size: 16),
                        label: const Text(
                          'Descargar Plantilla Ejemplo (.xlsx)',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFCBD5E1)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.cloud_upload_outlined,
                            size: 18,
                            color: Color(0xFF1E3A8A),
                          ),
                          SizedBox(width: 6),
                          Text(
                            'Paso 2: Sube tu archivo Excel (.xlsx) para crear o actualizar',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'RackDoc8 importará automáticamente las Sedes, Plantas, Racks y montará cada Equipo/Host en su unidad U correspondiente.',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFF475569),
                        ),
                      ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: importing
                            ? null
                            : () async {
                                final picked = await pickExcelFile();
                                if (picked == null) return;
                                setModal(() {
                                  importing = true;
                                  importError = null;
                                  importResult = null;
                                });
                                try {
                                  final res = await _api.importExcelFile(
                                    filename: picked.name,
                                    fileBytes: picked.bytes,
                                  );
                                  await _loadInitialData();
                                  setModal(() {
                                    importing = false;
                                    importResult = res;
                                  });
                                  messenger.showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Importación de Excel completada correctamente.',
                                      ),
                                      backgroundColor: Color(0xFF15803D),
                                    ),
                                  );
                                } catch (e) {
                                  setModal(() {
                                    importing = false;
                                    importError = e
                                        .toString()
                                        .replaceFirst('Exception: ', '');
                                  });
                                }
                              },
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1E3A8A),
                        ),
                        icon: Icon(
                          importing
                              ? Icons.hourglass_top_rounded
                              : Icons.folder_open_rounded,
                          size: 16,
                        ),
                        label: Text(
                          importing
                              ? 'Importando datos del Excel...'
                              : 'Seleccionar y Cargar Excel (.xlsx)',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (importError != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFECACA)),
                    ),
                    child: Text(
                      'Error: $importError',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFDC2626),
                      ),
                    ),
                  ),
                ],
                if (importResult != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF93C5FD)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '✓ Resumen de Importación completada:',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF1E3A8A),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '• Sedes nuevas: ${importResult!['locations_created'] ?? 0}  |  Plantas nuevas: ${importResult!['floors_created'] ?? 0}\n'
                          '• Racks creados: ${importResult!['racks_created'] ?? 0}  |  Racks actualizados: ${importResult!['racks_updated'] ?? 0}\n'
                          '• Equipos creados: ${importResult!['devices_created'] ?? 0}  |  Equipos actualizados: ${importResult!['devices_updated'] ?? 0}',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                        if ((importResult!['errors'] as List?)?.isNotEmpty ==
                            true) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Avisos (${(importResult!['errors'] as List).length}): ${(importResult!['errors'] as List).take(3).join(' | ')}',
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: Color(0xFFB45309),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
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

  Widget _buildLoginGateScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Center(
        child: Container(
          width: 440,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 24,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E3A8A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.dns_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'RackDoc8 DCIM',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        Text(
                          'Acceso Seguro — Autenticación Local (.env) / Active Directory',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _gateUserCtrl,
                decoration: const InputDecoration(
                  labelText: 'Usuario (Username)',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _performGateLogin(),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _gatePassCtrl,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Contraseña (Password)',
                  prefixIcon: Icon(Icons.lock_outline),
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _performGateLogin(),
              ),
              if (_gateAuthError != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFFECACA)),
                  ),
                  child: Text(
                    _gateAuthError!,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFDC2626),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              SizedBox(
                height: 44,
                child: FilledButton.icon(
                  onPressed: _gateAuthenticating ? null : _performGateLogin,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1E3A8A),
                  ),
                  icon: const Icon(Icons.login, size: 18),
                  label: Text(
                    _gateAuthenticating
                        ? 'Verificando credenciales...'
                        : 'Iniciar Sesión en RackDoc',
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: const Text(
                  'Credenciales iniciales por defecto (.env): usuario "admin" / contraseña "admin" (o "rackdoc123" para usuarios AD/locales de demostración).',
                  style: TextStyle(fontSize: 11, color: Color(0xFF475569)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAuthenticated) {
      return _buildLoginGateScreen();
    }

    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // BARRA LATERAL IZQUIERDA CON EL FLUJO JERÁRQUICO + ICONO RUEDA CONFIGURACIÓN (USUARIOS/ROLES/AD)
          Container(
            width: 245,
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(right: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
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
                              'RackDoc8 DCIM',
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
                      // ICONO RUEDA DE CONFIGURACIÓN (Usuarios, Contraseñas, Roles RBAC y Servidores AD)
                      Tooltip(
                        message:
                            'Configuración: Usuarios, Contraseñas, Roles RBAC y Active Directory',
                        child: InkWell(
                          onTap: () => setState(() => _activeNav = 'admin'),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: _activeNav == 'admin'
                                  ? const Color(0xFFDBEAFE)
                                  : const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _activeNav == 'admin'
                                    ? const Color(0xFF2563EB)
                                    : const Color(0xFFCBD5E1),
                              ),
                            ),
                            child: Icon(
                              Icons.settings_rounded,
                              size: 18,
                              color: _activeNav == 'admin'
                                  ? const Color(0xFF1D4ED8)
                                  : const Color(0xFF334155),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Tarjeta de Sesión Activa y Rol RBAC + Botón Rueda Configuración
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                  child: InkWell(
                    onTap: () => _showLoginOrSwitchUserModal(),
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
                          const Tooltip(
                            message: 'Cambiar usuario (pide usuario y contraseña)',
                            child: Icon(
                              Icons.swap_horiz_rounded,
                              size: 16,
                              color: Color(0xFF64748B),
                            ),
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
                  icon: Icons.settings_rounded,
                  label: '5. Configuración (Usuarios/AD)',
                  active: _activeNav == 'admin',
                  onTap: () => setState(() => _activeNav = 'admin'),
                ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 6),
                  child: Row(
                    children: [
                      const Expanded(
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
                      Tooltip(
                        message: 'Desplegar todo el árbol (Datacenters, Pisos y Racks)',
                        child: InkWell(
                          onTap: () {
                            setState(() {
                              for (final l in _locations) {
                                _expandedLocationIds.add(l.id);
                                for (final f in l.floors) {
                                  _expandedFloorIds.add(f.id);
                                }
                              }
                            });
                          },
                          borderRadius: BorderRadius.circular(4),
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(
                              Icons.unfold_more_rounded,
                              size: 14,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      Tooltip(
                        message: 'Plegar todo el árbol',
                        child: InkWell(
                          onTap: () {
                            setState(() {
                              _expandedLocationIds.clear();
                              _expandedFloorIds.clear();
                            });
                          },
                          borderRadius: BorderRadius.circular(4),
                          child: const Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(
                              Icons.unfold_less_rounded,
                              size: 14,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    children: [
                      for (final loc in _locations)
                        Builder(
                          builder: (_) {
                            final isLocExpanded =
                                _expandedLocationIds.contains(loc.id);
                            final isLocActive = _activeNav == 'datacenter' &&
                                _activeLocationId == loc.id;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // NIVEL 1: DATACENTER (con Triángulo ▶ que gira 90° a ▼ para desplegar Pisos)
                                Container(
                                  margin: const EdgeInsets.only(bottom: 2),
                                  decoration: BoxDecoration(
                                    color: isLocActive
                                        ? const Color(0xFFEFF6FF)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    children: [
                                      InkWell(
                                        borderRadius: BorderRadius.circular(6),
                                        onTap: () {
                                          setState(() {
                                            if (isLocExpanded) {
                                              _expandedLocationIds
                                                  .remove(loc.id);
                                            } else {
                                              _expandedLocationIds.add(loc.id);
                                            }
                                          });
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                            6,
                                            8,
                                            4,
                                            8,
                                          ),
                                          child: AnimatedRotation(
                                            turns: isLocExpanded ? 0.25 : 0.0,
                                            duration: const Duration(
                                              milliseconds: 180,
                                            ),
                                            child: Icon(
                                              Icons.play_arrow_rounded,
                                              size: 17,
                                              color: isLocExpanded
                                                  ? const Color(0xFF1D4ED8)
                                                  : const Color(0xFF475569),
                                            ),
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: InkWell(
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          onTap: () {
                                            setState(() {
                                              if (!isLocExpanded) {
                                                _expandedLocationIds
                                                    .add(loc.id);
                                              }
                                            });
                                            _openDatacenter(loc.id);
                                          },
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 6,
                                              horizontal: 4,
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  Icons.business_rounded,
                                                  size: 15,
                                                  color: loc.offlineCount > 0
                                                      ? const Color(0xFFDC2626)
                                                      : const Color(0xFF0F172A),
                                                ),
                                                const SizedBox(width: 6),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        '${loc.code} — ${loc.name}',
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          fontSize: 11.5,
                                                          fontWeight:
                                                              FontWeight.w800,
                                                          color: isLocActive
                                                              ? const Color(
                                                                  0xFF1D4ED8,
                                                                )
                                                              : const Color(
                                                                  0xFF0F172A,
                                                                ),
                                                        ),
                                                      ),
                                                      Text(
                                                        _formatMonitoredInline(
                                                          monitored: loc
                                                              .monitoredCount,
                                                          online:
                                                              loc.onlineCount,
                                                          offline:
                                                              loc.offlineCount,
                                                          prefix:
                                                              '${loc.floors.length} pisos',
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: const TextStyle(
                                                          fontSize: 9.5,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color:
                                                              Color(0xFF475569),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                // NIVEL 2: PISOS / PLANTAS DEL DATACENTER (cuando el triángulo del Datacenter está girado 90°)
                                if (isLocExpanded)
                                  for (final fl in loc.floors)
                                    Builder(
                                      builder: (_) {
                                        final isFloorExpanded =
                                            _expandedFloorIds.contains(fl.id);
                                        final floorRacks = <RackSummary>[
                                          for (final rm in fl.rooms)
                                            ...rm.racks,
                                        ];
                                        final isFloorActive =
                                            _activeNav == 'datacenter' &&
                                                _activeLocationId == loc.id &&
                                                _activeFloorId == fl.id;
                                        return Padding(
                                          padding:
                                              const EdgeInsets.only(left: 14),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              Container(
                                                margin: const EdgeInsets.only(
                                                  bottom: 1,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: isFloorActive
                                                      ? const Color(0xFFF1F5F9)
                                                      : Colors.transparent,
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                ),
                                                child: Row(
                                                  children: [
                                                    InkWell(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                        6,
                                                      ),
                                                      onTap: () {
                                                        setState(() {
                                                          if (isFloorExpanded) {
                                                            _expandedFloorIds
                                                                .remove(fl.id);
                                                          } else {
                                                            _expandedFloorIds
                                                                .add(fl.id);
                                                          }
                                                        });
                                                      },
                                                      child: Padding(
                                                        padding:
                                                            const EdgeInsets
                                                                .fromLTRB(
                                                          4,
                                                          6,
                                                          4,
                                                          6,
                                                        ),
                                                        child: AnimatedRotation(
                                                          turns: isFloorExpanded
                                                              ? 0.25
                                                              : 0.0,
                                                          duration:
                                                              const Duration(
                                                            milliseconds: 180,
                                                          ),
                                                          child: Icon(
                                                            Icons
                                                                .play_arrow_rounded,
                                                            size: 15,
                                                            color: isFloorExpanded
                                                                ? const Color(
                                                                    0xFF2563EB,
                                                                  )
                                                                : const Color(
                                                                    0xFF64748B,
                                                                  ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                    Expanded(
                                                      child: InkWell(
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(6),
                                                        onTap: () {
                                                          setState(() {
                                                            if (!isFloorExpanded) {
                                                              _expandedFloorIds
                                                                  .add(fl.id);
                                                            }
                                                          });
                                                          _openDatacenter(
                                                            loc.id,
                                                            floorId: fl.id,
                                                          );
                                                        },
                                                        child: Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .symmetric(
                                                            vertical: 5,
                                                            horizontal: 4,
                                                          ),
                                                          child: Row(
                                                            children: [
                                                              const Icon(
                                                                Icons
                                                                    .layers_outlined,
                                                                size: 14,
                                                                color: Color(
                                                                  0xFF1E3A8A,
                                                                ),
                                                              ),
                                                              const SizedBox(
                                                                width: 5,
                                                              ),
                                                              Expanded(
                                                                child: Text(
                                                                  'P${fl.levelNumber} — ${fl.name} (${floorRacks.length})',
                                                                  maxLines: 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                  style:
                                                                      TextStyle(
                                                                    fontSize:
                                                                        11,
                                                                    fontWeight: isFloorExpanded
                                                                        ? FontWeight
                                                                            .w700
                                                                        : FontWeight
                                                                            .w600,
                                                                    color: const Color(
                                                                      0xFF1E293B,
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),

                                              // NIVEL 3: RACKS DEL PISO (cuando el triángulo del Piso está girado 90°)
                                              if (isFloorExpanded)
                                                for (final rk in floorRacks)
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                      left: 16,
                                                      bottom: 1,
                                                    ),
                                                    child: ListTile(
                                                      dense: true,
                                                      visualDensity:
                                                          VisualDensity.compact,
                                                      contentPadding:
                                                          const EdgeInsets
                                                              .symmetric(
                                                        horizontal: 8,
                                                        vertical: 0,
                                                      ),
                                                      shape:
                                                          RoundedRectangleBorder(
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(6),
                                                      ),
                                                      selected: _activeNav ==
                                                              'rack_editor' &&
                                                          _activeRackId ==
                                                              rk.id,
                                                      selectedTileColor:
                                                          const Color(
                                                        0xFFEFF6FF,
                                                      ),
                                                      leading: Icon(
                                                        Icons.dns_outlined,
                                                        size: 14,
                                                        color: rk.offlineCount >
                                                                0
                                                            ? const Color(
                                                                0xFFDC2626,
                                                              )
                                                            : ((_activeNav ==
                                                                        'rack_editor' &&
                                                                    _activeRackId ==
                                                                        rk.id)
                                                                ? const Color(
                                                                    0xFF2563EB,
                                                                  )
                                                                : const Color(
                                                                    0xFF64748B,
                                                                  )),
                                                      ),
                                                      title: Text(
                                                        '${rk.code} (${rk.name})',
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight: (_activeNav ==
                                                                      'rack_editor' &&
                                                                  _activeRackId ==
                                                                      rk.id)
                                                              ? FontWeight.w700
                                                              : FontWeight.w500,
                                                          color: (_activeNav ==
                                                                      'rack_editor' &&
                                                                  _activeRackId ==
                                                                      rk.id)
                                                              ? const Color(
                                                                  0xFF1D4ED8,
                                                                )
                                                              : const Color(
                                                                  0xFF334155,
                                                                ),
                                                        ),
                                                      ),
                                                      subtitle: Text(
                                                        _formatMonitoredInline(
                                                          monitored:
                                                              rk.monitoredCount,
                                                          online:
                                                              rk.onlineCount,
                                                          offline:
                                                              rk.offlineCount,
                                                        ),
                                                        style: const TextStyle(
                                                          fontSize: 9,
                                                          color:
                                                              Color(0xFF64748B),
                                                        ),
                                                      ),
                                                      onTap: () =>
                                                          _openRack(rk.id),
                                                    ),
                                                  ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                              ],
                            );
                          },
                        ),
                    ],
                  ),
                ),

                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _showImportExcelDialog,
                        icon: const Icon(Icons.upload_file_rounded, size: 16),
                        label: const Text(
                          'Importar Excel / Ejemplo',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
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
                    ],
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
        initialFloorId: _activeFloorId,
        onChangeLocation: (id) => setState(() {
          _activeLocationId = id;
          _activeFloorId = null;
        }),
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
            setState(() => _users = usrs);
          }
          if (usr.id == _currentUser.id) {
            if (mounted) {
              setState(() => _currentUser = usr);
            }
          } else {
            await _showLoginOrSwitchUserModal(prefillUsername: usr.username);
          }
        },
      );
    }

    return RackEditorView(
      api: _api,
      rackId: _activeRackId,
      initialHighlightDeviceId: _highlightedDeviceId,
      templates: _templates,
      onBackToLocations: () {
        _refreshDataSilently();
        setState(() => _activeNav = 'datacenter');
      },
      onSwitchRack: (rId) => _openRack(rId),
      onTemplatesChanged: _refreshTemplates,
      currentUser: _currentUser,
    );
  }

  Widget _buildDashboardOverview() {
    int totalFloors = 0;
    int totalRooms = 0;
    int totalRacks = 0;
    int totalDevices = 0;
    int totalMonitored = 0;
    int totalOnline = 0;
    int totalOffline = 0;
    int totalWarning = 0;

    final allMonitoredSystems = <Map<String, dynamic>>[];

    for (final l in _locations) {
      totalFloors += l.floorsCount;
      totalRooms += l.roomsCount;
      totalRacks += l.racksCount;
      totalMonitored += l.monitoredCount;
      totalOnline += l.onlineCount;
      totalOffline += l.offlineCount;
      totalWarning += l.warningCount;
      for (final f in l.floors) {
        for (final r in f.rooms) {
          for (final rk in r.racks) {
            totalDevices += rk.deviceCount;
            for (final md in rk.monitoredDevices) {
              allMonitoredSystems.add({
                ...md,
                'location_id': l.id,
                'location_code': l.code,
                'location_name': l.name,
                'floor_name': f.name,
                'room_name': r.name,
                'rack_id': rk.id,
                'rack_code': rk.code,
                'rack_name': rk.name,
              });
            }
          }
        }
      }
    }

    // Filtrado por texto, estado y método Heartbeat
    final q = _dashSearchCtrl.text.trim().toLowerCase();
    final filtered = allMonitoredSystems.where((sys) {
      final st = (sys['status'] ?? 'unknown').toString().toLowerCase();
      final method = (sys['monitor_method'] ?? 'icmp').toString().toLowerCase();
      if (_dashStatusFilter != 'all' && st != _dashStatusFilter) {
        return false;
      }
      if (_dashMethodFilter != 'all' && method != _dashMethodFilter) {
        return false;
      }
      if (q.isNotEmpty) {
        final hay = [
          sys['code'],
          sys['name'],
          sys['hostname'],
          sys['ip_address'],
          sys['model_name'],
          sys['rack_code'],
          sys['location_code'],
          sys['monitor_method'],
        ].map((e) => (e ?? '').toString().toLowerCase()).join(' ');
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();

    // Ordenación interactiva
    int statusPriority(String st) {
      if (st == 'offline') return 0; // Rojo primero
      if (st == 'warning') return 1;
      if (st == 'online') return 2; // Verde
      return 3;
    }

    filtered.sort((a, b) {
      int cmp = 0;
      switch (_dashSortBy) {
        case 'status':
          cmp = statusPriority((a['status'] ?? '').toString()).compareTo(
            statusPriority((b['status'] ?? '').toString()),
          );
          if (cmp == 0) {
            cmp = (a['code'] ?? '').toString().compareTo(
                  (b['code'] ?? '').toString(),
                );
          }
          break;
        case 'code':
          cmp = (a['code'] ?? '').toString().compareTo(
                (b['code'] ?? '').toString(),
              );
          break;
        case 'ip':
          cmp = (a['ip_address'] ?? '').toString().compareTo(
                (b['ip_address'] ?? '').toString(),
              );
          break;
        case 'rack':
          cmp = (a['rack_code'] ?? '').toString().compareTo(
                (b['rack_code'] ?? '').toString(),
              );
          break;
        case 'method':
          cmp = (a['monitor_method'] ?? '').toString().compareTo(
                (b['monitor_method'] ?? '').toString(),
              );
          break;
        case 'latency':
          final la = (a['last_ping_ms'] as num?)?.toDouble() ?? 999999.0;
          final lb = (b['last_ping_ms'] as num?)?.toDouble() ?? 999999.0;
          cmp = la.compareTo(lb);
          break;
      }
      return _dashSortAsc ? cmp : -cmp;
    });

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
                      'Dashboard, Monitorización Heartbeat & Exportación Excel',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Estado en tiempo real de todos los sistemas monitorizados (Verde/Rojo), métricas por Datacenter/Rack y exportación Excel.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: _refreshDataSilently,
                icon: const Icon(Icons.refresh, size: 17),
                label: const Text('Actualizar Estado'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () {
                  final url = Uri.parse(_api.getExcelTemplateUrl());
                  launchUrl(url, mode: LaunchMode.externalApplication);
                },
                icon: const Icon(Icons.description_outlined, size: 17),
                label: const Text('Plantilla Ejemplo (.xlsx)'),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: _showImportExcelDialog,
                icon: const Icon(Icons.upload_file_rounded, size: 18),
                label: const Text('Importar Excel (.xlsx)'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1E3A8A),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: () {
                  final url = Uri.parse(_api.getExcelExportUrl());
                  launchUrl(url, mode: LaunchMode.externalApplication);
                },
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Exportar Inventario (.xlsx)'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF15803D),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              _DashboardCard(
                title: 'Datacenters / Plantas',
                value: '${_locations.length} Sedes / $totalFloors Plantas ($totalRooms Salas)',
                icon: Icons.public,
                color: const Color(0xFF2563EB),
              ),
              _DashboardCard(
                title: 'Racks & Equipos',
                value: '$totalRacks Racks / $totalDevices Eq.',
                icon: Icons.dns_outlined,
                color: const Color(0xFF7C3AED),
              ),
              _DashboardCard(
                title: 'Sistemas Monitorizados',
                value: '$totalMonitored Activos',
                icon: Icons.monitor_heart_outlined,
                color: const Color(0xFF0284C7),
              ),
              _DashboardCard(
                title: 'Estado Online (Verde)',
                value: totalOnline > 0 ? '🟢 $totalOnline Online' : 'Sin equipos online',
                icon: Icons.check_circle_outline,
                color: const Color(0xFF16A34A),
              ),
              _DashboardCard(
                title: 'Alertas Offline (Rojo)',
                value: totalOffline > 0
                    ? '🔴 $totalOffline Offline${totalWarning > 0 ? ' • 🟠 $totalWarning' : ''}'
                    : 'Sin alertas caídas',
                icon: Icons.error_outline,
                color: const Color(0xFFDC2626),
              ),
            ],
          ),

          const SizedBox(height: 26),

          // LISTADO ORGANIZABLE Y BUSCABLE DE SISTEMAS MONITORIZADOS
          Container(
            padding: const EdgeInsets.all(20),
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
                      Icons.monitor_heart_rounded,
                      color: Color(0xFF1E3A8A),
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Listado de Sistemas Monitorizados (${filtered.length} de $totalMonitored)',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const Spacer(),
                    // Filtro rápido por estado
                    SegmentedButton<String>(
                      segments: [
                        ButtonSegment(
                          value: 'all',
                          label: Text(
                            'Todos ($totalMonitored)',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                        ButtonSegment(
                          value: 'online',
                          label: Text(
                            '${totalOnline > 0 ? '🟢 ' : ''}Verde ($totalOnline)',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                        ButtonSegment(
                          value: 'offline',
                          label: Text(
                            '${totalOffline > 0 ? '🔴 ' : ''}Rojo ($totalOffline)',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                      selected: {_dashStatusFilter},
                      onSelectionChanged: (s) {
                        setState(() => _dashStatusFilter = s.first);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                // Barra de búsqueda, filtro por método y selector de ordenación
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _dashSearchCtrl,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText:
                              'Buscar por hostname, código, IP, modelo, rack o datacenter...',
                          prefixIcon: const Icon(Icons.search, size: 18),
                          suffixIcon: _dashSearchCtrl.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 16),
                                  onPressed: () {
                                    _dashSearchCtrl.clear();
                                    setState(() {});
                                  },
                                )
                              : null,
                          isDense: true,
                          filled: true,
                          fillColor: const Color(0xFFF8FAFC),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                              color: Color(0xFFCBD5E1),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<String>(
                        initialValue: _dashMethodFilter,
                        isDense: true,
                        decoration: InputDecoration(
                          labelText: 'Filtrar Método Heartbeat',
                          isDense: true,
                          filled: true,
                          fillColor: const Color(0xFFF8FAFC),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text('Todos los métodos', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'icmp',
                            child: Text('ICMP Ping', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'ssh',
                            child: Text('SSH (22)', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'https',
                            child: Text('HTTPS / SSL', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'http',
                            child: Text('HTTP URL', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'tcp',
                            child: Text('TCP Port', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'snmp',
                            child: Text('SNMP', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                        onChanged: (v) =>
                            setState(() => _dashMethodFilter = v ?? 'all'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<String>(
                        initialValue: _dashSortBy,
                        isDense: true,
                        decoration: InputDecoration(
                          labelText: 'Organizar / Ordenar por',
                          isDense: true,
                          filled: true,
                          fillColor: const Color(0xFFF8FAFC),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'status',
                            child: Text('Estado (Rojo / Alertas primero)', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'code',
                            child: Text('Código / Hostname', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'ip',
                            child: Text('Dirección IP', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'rack',
                            child: Text('Datacenter / Rack', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'method',
                            child: Text('Método Heartbeat', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'latency',
                            child: Text('Latencia (ms)', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                        onChanged: (v) =>
                            setState(() => _dashSortBy = v ?? 'status'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      tooltip: _dashSortAsc
                          ? 'Orden Ascendente (pulsa para invertir)'
                          : 'Orden Descendente (pulsa para invertir)',
                      onPressed: () =>
                          setState(() => _dashSortAsc = !_dashSortAsc),
                      icon: Icon(
                        _dashSortAsc
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        size: 18,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Divider(height: 1),
                if (filtered.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text(
                        'No se encontraron sistemas monitorizados con los filtros actuales.',
                        style: TextStyle(color: Color(0xFF64748B)),
                      ),
                    ),
                  )
                else
                  ...filtered.map((sys) {
                    final st = (sys['status'] ?? 'unknown').toString();
                    final isOnline = st == 'online';
                    final isOffline = st == 'offline';
                    final stCol = isOnline
                        ? const Color(0xFF16A34A)
                        : (isOffline
                            ? const Color(0xFFDC2626)
                            : const Color(0xFFD97706));
                    final method = (sys['monitor_method'] ?? 'icmp')
                        .toString()
                        .toUpperCase();
                    final port = sys['monitor_port'] ?? 22;
                    final pingMs = sys['last_ping_ms'];
                    final rackId = sys['rack_id'] as int;

                    final devId = sys['id'] as int?;

                    return InkWell(
                      onTap: () => _openRack(
                        rackId,
                        highlightDeviceId: devId,
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: isOffline
                              ? const Color(0xFFFEF2F2)
                              : Colors.transparent,
                          border: const Border(
                            bottom: BorderSide(color: Color(0xFFF1F5F9)),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: stCol.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: stCol.withValues(alpha: 0.45),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: stCol,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    isOnline
                                        ? 'VERDE (ONLINE)'
                                        : (isOffline
                                            ? 'ROJO (OFFLINE)'
                                            : st.toUpperCase()),
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                      color: stCol,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              flex: 3,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${sys['code']} — ${sys['name']}',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF0F172A),
                                    ),
                                  ),
                                  Text(
                                    '${sys['model_name']} • Hostname: ${sys['hostname']?.toString().isNotEmpty == true ? sys['hostname'] : '-'}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF64748B),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'IP: ${sys['ip_address']?.toString().isNotEmpty == true ? sys['ip_address'] : 'Sin IP'}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF1E293B),
                                    ),
                                  ),
                                  Text(
                                    'Heartbeat: $method (Puerto $port)${pingMs != null ? ' • $pingMs ms' : ''}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF475569),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${sys['location_code']} > ${sys['rack_code']} (U${sys['start_u']})',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF1E3A8A),
                                    ),
                                  ),
                                  Text(
                                    '${sys['floor_name']} • ${sys['rack_name']}',
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      color: Color(0xFF64748B),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: () => _openRack(
                                rackId,
                                highlightDeviceId: devId,
                              ),
                              icon: const Icon(
                                Icons.my_location_rounded,
                                size: 15,
                              ),
                              label: const Text(
                                'Localizar en Rack',
                                style: TextStyle(fontSize: 11.5),
                              ),
                            ),
                          ],
                        ),
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
