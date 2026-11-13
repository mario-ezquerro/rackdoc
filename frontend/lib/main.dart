import 'dart:async';
import 'package:flutter/material.dart';
import 'core/widgets/avisos.dart';
import 'core/theme.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'core/api_client.dart';
import 'core/image_file_picker.dart';
import 'features/admin/admin_view.dart';
import 'features/certscope/certscope_view.dart';
import 'features/cmdb/cmdb_view.dart';
import 'features/datacenter/datacenter_floor_view.dart';
import 'features/locations/locations_view.dart';
import 'features/network_hosts/network_hosts_view.dart';
import 'features/rack_editor/rack_editor_view.dart';
import 'features/rack_editor/rack_elevation_overview_view.dart';
import 'models/datacenter_models.dart';
import 'shared/widgets/diagram_exporter.dart';

import 'features/sre_alarms/sre_alarms_view.dart';
part 'features/dashboard/dashboard_overview_section.dart';
part 'features/shell/shell_widgets.dart';

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
        colorSchemeSeed: AppPalette.blue900,
        scaffoldBackgroundColor: AppPalette.slate50,
        fontFamily: 'SF Pro Text',
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          width: 440,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      home: const SelectionArea(
        child: RackDocShell(),
      ),
    );
  }
}

class RackDocShell extends StatefulWidget {
  const RackDocShell({super.key});

  @override
  State<RackDocShell> createState() => _RackDocShellState();
}

class _RackDocShellState extends State<RackDocShell> {
  /// Puente interno para reconstruir el estado desde extensiones `part`.
  void _rebuildState(VoidCallback fn) => setState(fn);

  final RackDocApiClient _api = RackDocApiClient();

  // Flujo jerárquico: 'locations' -> 'datacenter' -> 'rack_editor' -> 'dashboard' -> 'admin'
  String _activeNav = 'locations';
  int _activeLocationId = 1;
  int? _activeFloorId;
  int? _highlightedFloorDeviceId;
  int _activeRackId = 1;
  bool _showRackElevationOverview = true;
  int? _highlightedDeviceId;
  int? _highlightedStackId;
  int? _highlightedStackNodeId;
  int _sreInitialTabIndex = 0;

  void _openSreAlarms({int tabIndex = 0}) {
    setState(() {
      _sreInitialTabIndex = tabIndex;
      _activeNav = 'sre_alarms';
    });
  }

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

  // Estado de '4. Dashboard & Excel': Hierro Línea a Línea vs Patch Panels Boca a Boca vs Heartbeat
  Map<String, dynamic>? _dashboardInventory;
  String _dashMainSection = 'all_sections'; // 'all_sections' | 'hierro_lines' | 'patch_panels' | 'heartbeat'
  int? _dashSelectedRackId; // null = Todos los Racks
  String _dashRackLineKindFilter = 'all'; // 'all' | 'hierro' | 'pasivo'
  String _dashPatchBocaFilter = 'all'; // 'all' | 'occupied' | 'free'
  int? _dashSelectedPatchPanelId; // null = Todos los Patch Panels

  bool _loading = true;
  String? _error;

  // Modo Kiosco para presentar Locations, Datacenter, Rack Editor o Dashboard en monitores / videowalls
  bool _isKioskMode = false;
  bool _kioskExitHovered = false;
  Timer? _kioskRefreshTimer;
  Timer? _backgroundStatusPollTimer;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleGlobalHardwareKey);
    // Sin sesión no se pide nada al backend: toda la API exige un JWT y las
    // llamadas solo devolverían 401. Los datos se cargan tras el login.
    // El frontend consulta periódicamente al backend el estado de Heartbeat
    _backgroundStatusPollTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshDataSilently(),
    );
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalHardwareKey);
    _kioskRefreshTimer?.cancel();
    _backgroundStatusPollTimer?.cancel();
    _gateUserCtrl.dispose();
    _gatePassCtrl.dispose();
    _dashSearchCtrl.dispose();
    super.dispose();
  }

  bool _handleGlobalHardwareKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        _isKioskMode) {
      if (mounted) {
        _setKioskMode(false);
      }
      return true;
    }
    return false;
  }

  void _toggleKioskMode() => _setKioskMode(!_isKioskMode);

  void _setKioskMode(bool enabled) {
    setState(() {
      _isKioskMode = enabled;
      if (!enabled) {
        _kioskExitHovered = false;
      }
    });
    _kioskRefreshTimer?.cancel();
    if (enabled) {
      _kioskRefreshTimer = Timer.periodic(
        const Duration(seconds: 25),
        (_) => _refreshDataSilently(),
      );
    }
  }

  Future<void> _loadInitialData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // getUsers() solo está permitido a 'admin'; para el resto de roles
      // devuelve 403, así que se pide aparte para no tumbar el resto de la carga.
      final results = await Future.wait([
        _api.getLocations(),
        _api.getTemplates(),
        _api.getUsers().catchError((_) => <UserModel>[]),
        _api.fetchDashboardInventory(),
      ]);
      final locs = results[0] as List<LocationNode>;
      final tpls = results[1] as List<DeviceTemplateModel>;
      final usrs = results[2] as List<UserModel>;
      final dashInv = results[3] as Map<String, dynamic>;

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
          _dashboardInventory = dashInv;
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
    if (!_isAuthenticated || !_api.hasSession) return;
    try {
      final results = await Future.wait([
        _api.getLocations(),
        _api.fetchDashboardInventory(),
      ]);
      if (mounted) {
        setState(() {
          _locations = results[0] as List<LocationNode>;
          _dashboardInventory = results[1] as Map<String, dynamic>;
        });
      }
    } on RackDocAuthException catch (e) {
      // Token caducado o revocado: devolvemos al usuario a la pantalla de login.
      if (e.requiresLogin && mounted) {
        setState(() {
          _isAuthenticated = false;
          _gatePassCtrl.clear();
        });
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
      _showRackElevationOverview = false;
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
        await _loadInitialData();
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
              Icon(Icons.lock_person_outlined, color: AppPalette.blue900),
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
                  style: TextStyle(fontSize: 12, color: AppPalette.slate600),
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
                            await _loadInitialData();
                            if (ctx.mounted) Navigator.pop(ctx);
                            messenger.aviso('Sesión iniciada como ${logged.username} (${logged.roleLabel}).');
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
                          await _loadInitialData();
                          if (ctx.mounted) Navigator.pop(ctx);
                          messenger.aviso('Sesión iniciada como ${logged.username} (${logged.roleLabel}).');
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
                      color: AppPalette.red50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppPalette.red200),
                    ),
                    child: Text(
                      authError!,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppPalette.red600,
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
                    color: AppPalette.slate900,
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
                        selectedTileColor: AppPalette.blue50,
                        leading: Icon(
                          u.authSource == 'ad'
                              ? Icons.domain_verification
                              : Icons.person_outline,
                          size: 18,
                          color: AppPalette.blue900,
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
                                color: AppPalette.green600,
                                size: 18,
                              )
                            : const Text(
                                'Seleccionar',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppPalette.blue600,
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
                // Se descarta el JWT y los datos ya cargados para que no quede
                // información de la sesión anterior en pantalla.
                _api.clearSession();
                setState(() {
                  _isAuthenticated = false;
                  _gateUserCtrl.text = _currentUser.username;
                  _gatePassCtrl.clear();
                  _locations = [];
                  _users = [];
                  _dashboardInventory = {};
                });
              },
              icon: const Icon(
                Icons.logout,
                size: 15,
                color: AppPalette.red600,
              ),
              label: const Text(
                'Cerrar Sesión',
                style: TextStyle(color: AppPalette.red600),
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
    int unmonitored = 0,
    required int monitored,
    required int online,
    int warning = 0,
    required int offline,
    String prefix = '',
  }) {
    final parts = <String>[];
    if (prefix.isNotEmpty) parts.add(prefix);
    final statusParts = <String>[
      '⚪$unmonitored',
      '🟢$online',
      if (warning > 0) '🟠$warning',
      '🔴$offline',
    ];
    parts.add(statusParts.join(' '));
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
              Icon(Icons.upload_file_rounded, color: AppPalette.green700),
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
                    color: AppPalette.green50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppPalette.green300),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.description_outlined,
                            size: 18,
                            color: AppPalette.green700,
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
                          foregroundColor: AppPalette.green700,
                          side: const BorderSide(color: AppPalette.green600),
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
                    color: AppPalette.slate50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppPalette.slate300),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.cloud_upload_outlined,
                            size: 18,
                            color: AppPalette.blue900,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'Paso 2: Sube tu archivo Excel (.xlsx) para crear o actualizar',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                              color: AppPalette.slate900,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'RackDoc8 importará automáticamente las Sedes, Plantas, Racks y montará cada Equipo/Host en su unidad U correspondiente.',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: AppPalette.slate600,
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
                                  messenger.avisoExito('Importación de Excel completada correctamente.');
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
                          backgroundColor: AppPalette.blue900,
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
                      color: AppPalette.red50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppPalette.red200),
                    ),
                    child: Text(
                      'Error: $importError',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: AppPalette.red600,
                      ),
                    ),
                  ),
                ],
                if (importResult != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppPalette.blue50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppPalette.blue300),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '✓ Resumen de Importación completada:',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.blue900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '• Sedes nuevas: ${importResult!['locations_created'] ?? 0}  |  Plantas nuevas: ${importResult!['floors_created'] ?? 0}\n'
                          '• Racks creados: ${importResult!['racks_created'] ?? 0}  |  Racks actualizados: ${importResult!['racks_updated'] ?? 0}\n'
                          '• Equipos creados: ${importResult!['devices_created'] ?? 0}  |  Equipos actualizados: ${importResult!['devices_updated'] ?? 0}',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppPalette.slate800,
                          ),
                        ),
                        if ((importResult!['errors'] as List?)?.isNotEmpty ==
                            true) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Avisos (${(importResult!['errors'] as List).length}): ${(importResult!['errors'] as List).take(3).join(' | ')}',
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: AppPalette.amber700,
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
      backgroundColor: AppPalette.slate900,
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
                      color: AppPalette.blue900,
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
                            color: AppPalette.slate900,
                          ),
                        ),
                        Text(
                          'Acceso Seguro — Autenticación Local (.env) / Active Directory',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppPalette.slate500,
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
                    color: AppPalette.red50,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppPalette.red200),
                  ),
                  child: Text(
                    _gateAuthError!,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppPalette.red600,
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
                    backgroundColor: AppPalette.blue900,
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
                  color: AppPalette.slate50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppPalette.slate200),
                ),
                child: const Text(
                  'Credenciales iniciales por defecto (.env): usuario "admin" / contraseña "admin" (o "rackdoc123" para usuarios AD/locales de demostración).',
                  style: TextStyle(fontSize: 11, color: AppPalette.slate600),
                ),
              ),
              const SizedBox(height: 12),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => launchUrl(
                  Uri.parse('https://github.com/mario-ezquerro/rackdoc'),
                  mode: LaunchMode.externalApplication,
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppPalette.slate900,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.code_rounded,
                        size: 16,
                        color: AppPalette.sky400,
                      ),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Repositorio Oficial GitHub: github.com/mario-ezquerro/rackdoc',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      SizedBox(width: 6),
                      Icon(
                        Icons.open_in_new_rounded,
                        size: 13,
                        color: AppPalette.slate400,
                      ),
                    ],
                  ),
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
      body: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // BARRA LATERAL IZQUIERDA CON EL FLUJO JERÁRQUICO + ICONO RUEDA CONFIGURACIÓN (oculta en Modo Kiosco)
              if (!_isKioskMode)
                Container(
                  width: 245,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(right: BorderSide(color: AppPalette.slate200)),
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
                          color: AppPalette.slate900,
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
                                color: AppPalette.slate900,
                              ),
                            ),
                            Text(
                              'PBX Datacenter',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppPalette.slate500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // ICONO REPOSITORIO GITHUB OFICIAL
                      Tooltip(
                        message:
                            'Repositorio GitHub: https://github.com/mario-ezquerro/rackdoc',
                        child: InkWell(
                          onTap: () => launchUrl(
                            Uri.parse(
                              'https://github.com/mario-ezquerro/rackdoc',
                            ),
                            mode: LaunchMode.externalApplication,
                          ),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: AppPalette.slate100,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: AppPalette.slate300,
                              ),
                            ),
                            child: const Icon(
                              Icons.code_rounded,
                              size: 18,
                              color: AppPalette.slate900,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
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
                                  ? AppPalette.blue100
                                  : AppPalette.slate100,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _activeNav == 'admin'
                                    ? AppPalette.blue600
                                    : AppPalette.slate300,
                              ),
                            ),
                            child: Icon(
                              Icons.settings_rounded,
                              size: 18,
                              color: _activeNav == 'admin'
                                  ? AppPalette.blue700
                                  : AppPalette.slate700,
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
                        color: AppPalette.slate50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppPalette.slate300),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.verified_user_outlined,
                            size: 16,
                            color: AppPalette.blue900,
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
                                    color: AppPalette.slate900,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  'Rol: ${_currentUser.roleLabel}',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: AppPalette.blue600,
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
                              color: AppPalette.slate500,
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
                  label: 'Sedes y mapa',
                  active: _activeNav == 'locations',
                  onTap: () => setState(() => _activeNav = 'locations'),
                ),
                _SidebarItem(
                  icon: Icons.apartment_rounded,
                  label: 'Plantas',
                  active: _activeNav == 'datacenter',
                  onTap: () => setState(() => _activeNav = 'datacenter'),
                ),
                _SidebarItem(
                  icon: Icons.developer_board_outlined,
                  label: 'Racks',
                  active: _activeNav == 'rack_editor',
                  onTap: () => setState(() {
                    _activeNav = 'rack_editor';
                    _showRackElevationOverview = true;
                  }),
                ),
                _SidebarItem(
                  icon: Icons.account_tree_rounded,
                  label: 'Red y monitorización',
                  active: _activeNav == 'network_hosts',
                  onTap: () => setState(() => _activeNav = 'network_hosts'),
                ),
                _SidebarItem(
                  icon: Icons.dashboard_outlined,
                  label: 'Informes',
                  active: _activeNav == 'dashboard',
                  onTap: () {
                    setState(() => _activeNav = 'dashboard');
                    _refreshDataSilently();
                  },
                ),
                _SidebarItem(
                  icon: Icons.hub_rounded,
                  label: 'CMDB e IPAM',
                  active: _activeNav == 'cmdb',
                  onTap: () => setState(() => _activeNav = 'cmdb'),
                ),
                _SidebarItem(
                  icon: Icons.verified_user_rounded,
                  label: 'Certificados TLS',
                  active: _activeNav == 'certscope',
                  onTap: () => setState(() => _activeNav = 'certscope'),
                ),
                _SidebarItem(
                  icon: Icons.notifications_active_rounded,
                  label: 'Alarmas',
                  active: _activeNav == 'sre_alarms',
                  onTap: () => _openSreAlarms(tabIndex: 0),
                ),
                _SidebarItem(
                  icon: Icons.settings_rounded,
                  label: 'Administración',
                  active: _activeNav == 'admin',
                  onTap: () => setState(() => _activeNav = 'admin'),
                ),
                if (_activeNav != 'admin')
                  _SidebarItem(
                    icon: Icons.tv_rounded,
                    label: 'Modo Kiosco (Monitor)',
                    active: _isKioskMode,
                    onTap: () => _setKioskMode(true),
                  ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 6),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'INFRAESTRUCTURA',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: AppPalette.slate400,
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
                              color: AppPalette.slate500,
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
                              color: AppPalette.slate500,
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
                                        ? AppPalette.blue50
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
                                                  ? AppPalette.blue700
                                                  : AppPalette.slate600,
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
                                                      ? AppPalette.red600
                                                      : AppPalette.slate900,
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
                                                          unmonitored: loc
                                                              .unmonitoredCount,
                                                          monitored: loc
                                                              .monitoredCount,
                                                          online:
                                                              loc.onlineCount,
                                                          warning:
                                                              loc.warningCount,
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
                                                              AppPalette.slate600,
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
                                                      ? AppPalette.slate100
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
                                                          !_showRackElevationOverview &&
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
                                                                    !_showRackElevationOverview &&
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
                                                                  !_showRackElevationOverview &&
                                                                  _activeRackId ==
                                                                      rk.id)
                                                              ? FontWeight.w700
                                                              : FontWeight.w500,
                                                          color: (_activeNav ==
                                                                      'rack_editor' &&
                                                                  !_showRackElevationOverview &&
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
                                                          unmonitored: rk
                                                              .unmonitoredCount,
                                                          monitored:
                                                              rk.monitoredCount,
                                                          online:
                                                              rk.onlineCount,
                                                          warning:
                                                              rk.warningCount,
                                                          offline:
                                                              rk.offlineCount,
                                                        ),
                                                        style: const TextStyle(
                                                          fontSize: 9,
                                                          color:
                                                              AppPalette.slate500,
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
                      DiagramExportMenuButton(
                        buttonLabel: 'Exportar Todo (.xlsx/.dia/.pdf/.png)',
                        compact: true,
                        onExportExcel: () {
                          final url = Uri.parse(_api.getExcelExportUrl());
                          launchUrl(url, mode: LaunchMode.externalApplication);
                        },
                        documentBuilder: _buildGlobalExportDocument,
                      ),
                      const SizedBox(height: 6),
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => launchUrl(
                          Uri.parse(
                            'https://github.com/mario-ezquerro/rackdoc',
                          ),
                          mode: LaunchMode.externalApplication,
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: AppPalette.slate900,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.code_rounded,
                                size: 14,
                                color: AppPalette.sky400,
                              ),
                              SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  'GitHub: mario-ezquerro/rackdoc',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              SizedBox(width: 4),
                              Icon(
                                Icons.open_in_new_rounded,
                                size: 12,
                                color: AppPalette.slate400,
                              ),
                            ],
                          ),
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
      if (_isKioskMode) _buildDiscreetKioskExitOverlay(),
    ],
  ),
);
  }

  /// Control flotante discreto en la esquina inferior derecha cuando el Modo Kiosco está activo:
  /// Permanece casi transparente (opacidad 0.22) para no distraer en el monitor, y al acercar el ratón
  /// se ilumina permitiendo cambiar de vista (1. Mapa / 2. Planta / 3. Rack / 4. Dashboard) o salir del Modo Kiosco.
  Widget _buildDiscreetKioskExitOverlay() {
    return Positioned(
      right: 14,
      bottom: 14,
      child: MouseRegion(
        onEnter: (_) => setState(() => _kioskExitHovered = true),
        onExit: (_) => setState(() => _kioskExitHovered = false),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: _kioskExitHovered ? 0.96 : 0.22,
          child: Material(
            color: AppPalette.slate900,
            elevation: _kioskExitHovered ? 8 : 1,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: _kioskExitHovered ? 10 : 8,
                vertical: _kioskExitHovered ? 6 : 5,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _kioskExitHovered
                      ? AppPalette.sky400
                      : AppPalette.slate600,
                  width: 1.0,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_kioskExitHovered) ...[
                    _buildKioskQuickNavChip('1. Mapa', 'locations'),
                    const SizedBox(width: 4),
                    _buildKioskQuickNavChip('2. Planta', 'datacenter'),
                    const SizedBox(width: 4),
                    _buildKioskQuickNavChip('3. Rack', 'rack_editor'),
                    const SizedBox(width: 4),
                    _buildKioskQuickNavChip('4. Red & Host', 'network_hosts'),
                    const SizedBox(width: 4),
                    _buildKioskQuickNavChip('5. Dashboard', 'dashboard'),
                    const SizedBox(width: 4),
                    _buildKioskQuickNavChip('6. CMDB', 'cmdb'),
                    const SizedBox(width: 4),
                    _buildKioskQuickNavChip('7. CertScope', 'certscope'),
                    const SizedBox(width: 4),
                    _buildKioskQuickNavChip('8. Alarmas SRE', 'sre_alarms'),
                    Container(
                      width: 1,
                      height: 16,
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      color: AppPalette.slate600,
                    ),
                  ],
                  InkWell(
                    onTap: () => _setKioskMode(false),
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.fullscreen_exit_rounded,
                            size: 16,
                            color: AppPalette.sky400,
                          ),
                          if (_kioskExitHovered) ...[
                            const SizedBox(width: 5),
                            const Text(
                              'Salir Kiosco (Esc)',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKioskQuickNavChip(String label, String navKey) {
    final active = _activeNav == navKey;
    return InkWell(
      onTap: () {
        setState(() {
          _activeNav = navKey;
          if (navKey == 'rack_editor') {
            _showRackElevationOverview = true;
          }
        });
        if (navKey == 'dashboard') {
          _refreshDataSilently();
        }
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: active ? AppPalette.sky600 : AppPalette.slate800,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : AppPalette.slate300,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
          ),
        ),
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
            border: Border.all(color: AppPalette.slate200),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 42, color: AppPalette.red600),
              const SizedBox(height: 12),
              const Text(
                'No se pudo conectar con el Backend de RackDoc',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'Detalle: $_error',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: AppPalette.slate500),
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
        isKioskMode: _isKioskMode,
        onToggleKioskMode: _toggleKioskMode,
      );
    }

    if (_activeNav == 'datacenter') {
      return DatacenterFloorView(
        api: _api,
        locations: _locations,
        activeLocationId: _activeLocationId,
        initialFloorId: _activeFloorId,
        initialFloorDeviceId: _highlightedFloorDeviceId,
        onChangeLocation: (id) => setState(() {
          _activeLocationId = id;
          _activeFloorId = null;
          _highlightedFloorDeviceId = null;
        }),
        onBackToLocations: () => setState(() => _activeNav = 'locations'),
        onOpenRack: _openRack,
        onRefresh: _refreshDataSilently,
        isKioskMode: _isKioskMode,
        onToggleKioskMode: _toggleKioskMode,
      );
    }

    if (_activeNav == 'dashboard') {
      return _buildDashboardOverview();
    }

    if (_activeNav == 'network_hosts') {
      return NetworkHostsView(
        key: const ValueKey('network_hosts_view'),
        api: _api,
        canEdit: _currentUser.canEdit,
        initialStackId: _highlightedStackId,
        initialStackNodeId: _highlightedStackNodeId,
        onOpenSreDocs: () => _openSreAlarms(tabIndex: 3),
        onNavigateToLocation: (locationId) {
          setState(() {
            if (locationId != null) {
              _activeLocationId = locationId;
              _expandedLocationIds.add(locationId);
            }
            _activeNav = 'locations';
          });
        },
        onNavigateToFloorDevice: (locationId, floorId, floorDeviceId) async {
          await _refreshDataSilently();
          if (!mounted) return;
          setState(() {
            if (locationId != null) {
              _activeLocationId = locationId;
              _expandedLocationIds.add(locationId);
            } else if (floorId != null) {
              for (final loc in _locations) {
                if (loc.floors.any((fl) => fl.id == floorId)) {
                  _activeLocationId = loc.id;
                  _expandedLocationIds.add(loc.id);
                  break;
                }
              }
            }
            if (floorId != null) {
              _activeFloorId = floorId;
              _expandedFloorIds.add(floorId);
            }
            _highlightedFloorDeviceId = floorDeviceId;
            _activeNav = 'datacenter';
          });
        },
        onNavigateToRackDevice: (rackId, deviceId) {
          _openRack(rackId, highlightDeviceId: deviceId);
        },
        onNavigateToNetworkHost: (assetId, stackId, stackNodeId) {
          setState(() {
            if (stackId != null) _highlightedStackId = stackId;
            if (stackNodeId != null) _highlightedStackNodeId = stackNodeId;
            _activeNav = 'network_hosts';
          });
        },
        onNavigateToDashboard: (rackId) {
          setState(() {
            if (rackId != null) _dashSelectedRackId = rackId;
            _activeNav = 'dashboard';
          });
          _refreshDataSilently();
        },
        onNavigateToCmdb: (_) {
          setState(() => _activeNav = 'cmdb');
        },
        onNavigateToCertScope: (_) {
          setState(() => _activeNav = 'certscope');
        },
      );
    }

    if (_activeNav == 'sre_alarms') {
      return SreAlarmsView(
        key: const ValueKey('sre_alarms_view'),
        api: _api,
        canEdit: _currentUser.canEdit,
        initialTabIndex: _sreInitialTabIndex,
        onNavigateToLocation: (locationId) {
          setState(() {
            if (locationId != null) {
              _activeLocationId = locationId;
              _expandedLocationIds.add(locationId);
            }
            _activeNav = 'locations';
          });
        },
        onNavigateToFloorDevice: (locationId, floorId, floorDeviceId) async {
          await _refreshDataSilently();
          if (!mounted) return;
          setState(() {
            if (locationId != null) {
              _activeLocationId = locationId;
              _expandedLocationIds.add(locationId);
            } else if (floorId != null) {
              for (final loc in _locations) {
                if (loc.floors.any((fl) => fl.id == floorId)) {
                  _activeLocationId = loc.id;
                  _expandedLocationIds.add(loc.id);
                  break;
                }
              }
            }
            if (floorId != null) {
              _activeFloorId = floorId;
              _expandedFloorIds.add(floorId);
            }
            _highlightedFloorDeviceId = floorDeviceId;
            _activeNav = 'datacenter';
          });
        },
        onNavigateToRackDevice: (rackId, deviceId) {
          _openRack(rackId, highlightDeviceId: deviceId);
        },
        onNavigateToNetworkHost: (assetId, stackId, stackNodeId) {
          setState(() {
            if (stackId != null) _highlightedStackId = stackId;
            if (stackNodeId != null) _highlightedStackNodeId = stackNodeId;
            _activeNav = 'network_hosts';
          });
        },
        onNavigateToDashboard: (rackId) {
          setState(() {
            if (rackId != null) _dashSelectedRackId = rackId;
            _activeNav = 'dashboard';
          });
          _refreshDataSilently();
        },
        onNavigateToCmdb: (_) {
          setState(() => _activeNav = 'cmdb');
        },
        onNavigateToCertScope: (_) {
          setState(() => _activeNav = 'certscope');
        },
      );
    }

    if (_activeNav == 'cmdb') {
      return CmdbView(
        api: _api,
        canEdit: _currentUser.canEdit,
        onNavigateToSreDocs: () => _openSreAlarms(tabIndex: 3),
        onNavigateToRackDevice: (rackId, deviceId) {
          _openRack(rackId, highlightDeviceId: deviceId);
        },
        onNavigateToFloorDevice: (locationId, floorId, floorDeviceId) async {
          await _refreshDataSilently();
          if (!mounted) return;
          setState(() {
            if (locationId != null) {
              _activeLocationId = locationId;
              _expandedLocationIds.add(locationId);
            } else {
              for (final loc in _locations) {
                if (loc.floors.any((fl) => fl.id == floorId)) {
                  _activeLocationId = loc.id;
                  _expandedLocationIds.add(loc.id);
                  break;
                }
              }
            }
            _activeFloorId = floorId;
            _expandedFloorIds.add(floorId);
            _highlightedFloorDeviceId = floorDeviceId;
            _activeNav = 'datacenter';
          });
        },
        onNavigateToStackNode: (stackId, nodeId) {
          setState(() {
            _highlightedStackId = stackId;
            _highlightedStackNodeId = nodeId;
            _activeNav = 'network_hosts';
          });
        },
        onExportExcel: () async {
          final url = _api.getExcelExportUrl();
          await launchUrl(Uri.parse(url));
        },
      );
    }

    if (_activeNav == 'certscope') {
      return CertScopeView(
        api: _api,
        canEdit: _currentUser.canEdit,
        canOperate: _currentUser.canEdit,
        onNavigateToSreDocs: () => _openSreAlarms(tabIndex: 3),
        onNavigateToRack: (rackId, deviceId) {
          _openRack(rackId, highlightDeviceId: deviceId);
        },
        onNavigateToFloor: (floorId, floorDeviceId) async {
          await _refreshDataSilently();
          if (!mounted) return;
          setState(() {
            for (final loc in _locations) {
              if (loc.floors.any((fl) => fl.id == floorId)) {
                _activeLocationId = loc.id;
                _expandedLocationIds.add(loc.id);
                break;
              }
            }
            _activeFloorId = floorId;
            _expandedFloorIds.add(floorId);
            _highlightedFloorDeviceId = floorDeviceId;
            _activeNav = 'datacenter';
          });
        },
        onNavigateToStack: (stackId, nodeId) {
          setState(() {
            _highlightedStackId = stackId;
            _highlightedStackNodeId = nodeId;
            _activeNav = 'network_hosts';
          });
        },
        onNavigateToCmdb: () {
          setState(() => _activeNav = 'cmdb');
        },
      );
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

    if (_showRackElevationOverview) {
      return RackElevationOverviewView(
        api: _api,
        activeLocationId: _activeLocationId,
        onOpenRack: _openRack,
        isKioskMode: _isKioskMode,
        onToggleKioskMode: _toggleKioskMode,
      );
    }

    return RackEditorView(
      key: ValueKey(
        'rack_editor_${_activeRackId}_${_highlightedDeviceId ?? 0}',
      ),
      api: _api,
      rackId: _activeRackId,
      initialHighlightDeviceId: _highlightedDeviceId,
      templates: _templates,
      onBackToLocations: () {
        _refreshDataSilently();
        setState(() => _activeNav = 'datacenter');
      },
      onOpenElevationOverview: () {
        _refreshDataSilently();
        setState(() {
          _highlightedDeviceId = null;
          _showRackElevationOverview = true;
        });
      },
      onSwitchRack: (rId) => _openRack(rId),
      onJumpToRackAndDevice: (rId, devId) =>
          _openRack(rId, highlightDeviceId: devId),
      onTemplatesChanged: _refreshTemplates,
      currentUser: _currentUser,
      isKioskMode: _isKioskMode,
      onToggleKioskMode: _toggleKioskMode,
    );
  }
}
