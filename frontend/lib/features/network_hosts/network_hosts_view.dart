import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/theme.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api_client.dart';
import '../../models/datacenter_models.dart';
import '../../shared/widgets/cmdb_asset_explorer_dialog.dart';
import '../../shared/widgets/diagram_exporter.dart';

part 'sre_alarms/sre_alarms_live_tab.dart';
part 'sre_alarms/sre_alerts_routing_and_slo_tabs.dart';
part 'sre_alarms/sre_ansible_and_ai_docs_tab.dart';
part 'tabs/tech_stack_2d_tab.dart';
part 'tabs/logical_topology_tab.dart';
part 'tabs/nagios_snmp_prometheus_tabs.dart';
part 'dialogs/network_hosts_crud_dialogs.dart';
part 'widgets/datacenter_style_host_config_panel.dart';
part 'widgets/network_hosts_painters.dart';

/// Vista coordinadora de **`4. Red & Host`** y motor compartido de **`8. Alarmas SRE`**.
///
/// La implementación se divide en submódulos cohesivos mediante `part`:
/// - `tabs/`: Stack Tecnológico 2D, Topología Lógica, Nagios, SNMP y Prometheus.
/// - `sre_alarms/`: Estado en vivo de alarmas, navegador de 5 columnas, SLOs y Ansible.
/// - `dialogs/` y `widgets/`: diálogos CRUD, panel lateral de configuración y `CustomPainter`s.
class NetworkHostsView extends StatefulWidget {
  final RackDocApiClient api;
  final bool canEdit;
  final bool isSreAlarmsMode;
  final int initialSreTabIndex;
  final int? initialStackId;
  final int? initialStackNodeId;
  final void Function(int? locationId)? onNavigateToLocation;
  final void Function(int? locationId, int? floorId, int? floorDeviceId)?
      onNavigateToFloorDevice;
  final void Function(int rackId, int? deviceId)? onNavigateToRackDevice;
  final void Function(int? assetId, int? stackId, int? stackNodeId)?
      onNavigateToNetworkHost;
  final void Function(int? rackId)? onNavigateToDashboard;
  final void Function(String? assetCode)? onNavigateToCmdb;
  final void Function(String? hostCodeOrIp)? onNavigateToCertScope;
  final VoidCallback? onOpenSreDocs;

  const NetworkHostsView({
    super.key,
    required this.api,
    this.canEdit = true,
    this.isSreAlarmsMode = false,
    this.initialSreTabIndex = 0,
    this.initialStackId,
    this.initialStackNodeId,
    this.onNavigateToLocation,
    this.onNavigateToFloorDevice,
    this.onNavigateToRackDevice,
    this.onNavigateToNetworkHost,
    this.onNavigateToDashboard,
    this.onNavigateToCmdb,
    this.onNavigateToCertScope,
    this.onOpenSreDocs,
  });

  @override
  State<NetworkHostsView> createState() => _NetworkHostsViewState();
}

class _NetworkHostsViewState extends State<NetworkHostsView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  /// Puente interno para reconstruir el estado desde extensiones `part` sin infringir `@protected`.
  void _rebuildState(VoidCallback fn) => setState(fn);

  String _promHostSearch = '';
  String _promCategoryFilter = 'all';

  /// Traduce el `delivery_status` del registro de avisos. Importa distinguir
  /// «no se intentó enviar» de «se intentó y falló»: antes los dos llegaban como
  /// `simulated_ready`, que se leía como un casi-éxito.
  static String _rotuloEntrega(Object? estado) {
    switch ('${estado ?? ''}'.toLowerCase()) {
      case 'sent':
      case 'sent_smtp':
        return 'enviado por correo';
      case 'sent_webhook':
        return 'enviado por webhook';
      case 'not_configured':
        return 'registrado, NO enviado (sin SMTP configurado)';
      case 'error':
        return 'FALLO DE ENVÍO';
      case 'suppressed_maintenance':
        return 'silenciado (ventana de mantenimiento)';
      case 'suppressed_unreachable':
        return 'silenciado (equipo padre caído)';
      default:
        return '${estado ?? 'desconocido'}';
    }
  }

  bool _loading = true;
  bool _runningAction = false;
  String? _error;

  Map<String, dynamic> _overview = {};
  int? _selectedStackId;
  int? _selectedHostId;
  int? _selectedSwitchAssetId;
  int _telemetryRangeHours = 6;
  Map<String, dynamic>? _telemetryData;
  bool _loadingTelemetry = false;

  // Estado del Dashboard de Stacks Tecnológicos estilo Datacenter Floor 2D
  final GlobalKey _stackCanvasKey = GlobalKey();
  final Map<int, Offset> _stackNodePositions = {};
  final Map<int, Size> _stackNodeSizes = {};
  List<Map<String, dynamic>> _stackBoxes = [];
  int? _selectedStackNodeId;
  String? _selectedBoxId;

  // Seguimiento 1:1 exacto con el ratón (coordenadas globales) para Nodos, Cajas y Ventana Flotante
  Offset? _nodeDragStartGlobal;
  Offset? _nodeDragStartPx;
  Offset? _nodeResizeStartGlobal;
  Size? _nodeResizeStartSize;

  Offset? _boxDragStartGlobal;
  Offset? _boxDragStartPx;
  Offset? _boxResizeStartGlobal;
  Rect? _boxResizeStartRect;

  Offset? _floatWinDragStartGlobal;
  Offset? _floatWinDragStartPos;

  bool _showStackLeftLibrary = true;
  bool _showStackRightSettings = true;
  bool _showStackEdges = true;
  double _stackCanvasScale = 1.0;
  bool _isStackHandMode = false;

  // Modo interactivo para enlazar elementos desde los pequeños cuadrados en el medio de los 4 lados
  bool _isLinkModeActive = false;
  int? _linkSourceNodeId;
  String? _linkSourceSide; // 'top' | 'bottom' | 'left' | 'right'
  Offset? _linkLiveMousePos;
  int? _hoveredSideNodeId;
  String? _hoveredSideName;

  // Ventana Flotante Arrastrable con Datos Técnicos y Gráficas Prometheus Afinadas
  bool _showFloatingTechWindow = false;
  bool _floatingWinMinimized = false;
  Offset _floatingWinPos = const Offset(28, 22);
  String _floatingWinTab = 'charts'; // 'charts' | 'tech'

  String _searchQuery = '';
  String _layerFilter = 'all';
  String _stateFilter = 'all';

  // Filtros y búsqueda de la 1ª Pestaña de 8. Alarmas SRE (Estado de Dispositivos & Alarmas en Vivo)
  String _sreDeviceSearchQuery = '';
  String _sreDeviceStateFilter = 'all'; // 'all' | 'in_alarm' | 'CRITICAL' | 'WARNING' | 'UNREACHABLE' | 'MAINTENANCE' | 'OK'
  String _sreDeviceGroupFilter = 'all';
  String _sreDeviceLayerFilter = 'all';
  String _sreDeviceLocationFilter = 'all'; // 'all' | 'in_rack' | 'in_floor' | 'in_stack' | 'virtual'
  String _sreDeviceSortMode = 'alarm_priority'; // 'alarm_priority' | 'longest_alarm' | 'recent_change' | 'name_asc' | 'latency_desc'

  Map<String, dynamic>? _aiContextManifest;
  Map<String, dynamic>? _apiOnboardingGuide;
  Map<String, dynamic>? _certScopeOverview;

  @override
  void initState() {
    super.initState();
    _selectedStackId = widget.initialStackId;
    _selectedStackNodeId = widget.initialStackNodeId;
    final tabLen = widget.isSreAlarmsMode ? 4 : 5;
    final initIdx = widget.isSreAlarmsMode
        ? widget.initialSreTabIndex.clamp(0, 3)
        : 0;
    _tabController = TabController(
      length: tabLen,
      initialIndex: initIdx,
      vsync: this,
    );
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging && mounted) {
        if (!widget.isSreAlarmsMode &&
            _tabController.index == 4 &&
            _selectedHostId != null) {
          _loadHostTelemetry(_selectedHostId!);
        } else if (widget.isSreAlarmsMode && _tabController.index == 3) {
          if (_aiContextManifest == null) _loadAiContextManifest();
          if (_apiOnboardingGuide == null) _loadApiOnboardingGuide();
        }
        setState(() {});
      }
    });
    _loadOverview();
    if (widget.isSreAlarmsMode) {
      _loadSreAuxiliaryData();
    }
  }

  @override
  void didUpdateWidget(covariant NetworkHostsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSreAlarmsMode &&
        widget.initialSreTabIndex != oldWidget.initialSreTabIndex) {
      final target = widget.initialSreTabIndex.clamp(0, 3);
      if (_tabController.index != target) {
        _tabController.animateTo(target);
      }
    }
    if (!widget.isSreAlarmsMode &&
        ((widget.initialStackId != null &&
                widget.initialStackId != oldWidget.initialStackId) ||
            (widget.initialStackNodeId != null &&
                widget.initialStackNodeId != oldWidget.initialStackNodeId))) {
      setState(() {
        if (widget.initialStackId != null) {
          _selectedStackId = widget.initialStackId;
        }
        if (widget.initialStackNodeId != null) {
          _selectedStackNodeId = widget.initialStackNodeId;
          _selectedBoxId = null;
        }
        _syncStackCanvasState();
      });
      if (_tabController.index != 0) {
        _tabController.animateTo(0);
      }
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _techStacks =>
      ((_overview['tech_stacks'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  List<Map<String, dynamic>> get _hosts =>
      ((_overview['hosts'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  List<Map<String, dynamic>> get _logicalLinks =>
      ((_overview['logical_links'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  List<Map<String, dynamic>> get _connectors =>
      ((_overview['connectors'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  List<Map<String, dynamic>> get _hostGroups =>
      ((_overview['host_groups'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  List<Map<String, dynamic>> get _alertContacts =>
      ((_overview['alert_contacts'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  List<Map<String, dynamic>> get _alertContactGroups =>
      ((_overview['alert_contact_groups'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  List<Map<String, dynamic>> get _notificationRules =>
      ((_overview['notification_rules'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  List<Map<String, dynamic>> get _maintenanceWindows =>
      ((_overview['maintenance_windows'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  List<Map<String, dynamic>> get _alertLogs =>
      ((_overview['alert_logs'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  Map<String, dynamic> get _summary =>
      Map<String, dynamic>.from((_overview['summary'] as Map?) ?? {});

  Map<String, dynamic> get _smtpConfig =>
      Map<String, dynamic>.from((_overview['smtp_config'] as Map?) ?? {});

  /// Usuarios dados de alta en RackDoc (Administración > Usuarios, locales y de
  /// dominio). Se usan para no tener que teclear a mano en las alarmas a gente
  /// que ya existe en el sistema. El endpoint /users es solo de 'admin', así que
  /// para el resto de roles esta lista queda vacía y se explica en la interfaz.
  List<UserModel> _directoryUsers = [];
  bool _directoryUsersDenegado = false;

  // Estado de la Matriz 5 Columnas (Estilo Active Directory + Drag & Drop) en '1. Avisos de Alarmas'
  int? _selectedAlertHostGroupId;
  int? _selectedAlertUserGroupId;
  int? _selectedAlertContactId;
  String _alertGroupSourceFilter = 'all'; // 'all' | 'ad' | 'local' | 'custom'
  String _knownUsersSourceFilter = 'all'; // 'all' | 'ad' | 'local' | 'custom'
  String _knownUsersSearchQuery = '';
  bool _showAllUsersInCol4 = false;
  bool _showAlertBottomLogs = true;

  void _syncStackCanvasState([Map<String, dynamic>? nextOverview]) {
    if (nextOverview != null) {
      _overview = nextOverview;
    }
    final stacks = _techStacks;
    if (stacks.isEmpty) return;
    if (_selectedStackId == null ||
        !stacks.any((st) => st['id'] == _selectedStackId)) {
      _selectedStackId = stacks.first['id'] as int;
    }
    final activeStack = stacks.firstWhere(
      (s) => s['id'] == _selectedStackId,
      orElse: () => stacks.first,
    );
    _stackCanvasScale =
        ((activeStack['map_scale'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 2.0);
    _stackBoxes = ((activeStack['canvas_boxes'] as List?) ?? []).map((raw) {
      final b = Map<String, dynamic>.from(raw as Map);
      final px = (b['pos_x'] as num?)?.toDouble() ??
          (((b['x_px'] as num?)?.toDouble() ?? 40.0) / 1350.0);
      final py = (b['pos_y'] as num?)?.toDouble() ??
          (((b['y_px'] as num?)?.toDouble() ?? 40.0) / 680.0);
      final wRel = (b['width_rel'] as num?)?.toDouble() ??
          (((b['width_px'] as num?)?.toDouble() ?? 520.0) / 1350.0);
      final hRel = (b['height_rel'] as num?)?.toDouble() ??
          (((b['height_px'] as num?)?.toDouble() ?? 430.0) / 680.0);
      b['id'] = '${b['id'] ?? 'box-${DateTime.now().microsecondsSinceEpoch}'}';
      b['title'] = (b['title'] as String?) ?? 'ZONA / AGRUPACIÓN';
      b['corner_data'] =
          (b['corner_data'] as String?) ?? (b['subtitle'] as String?) ?? '';
      b['pos_x'] = px.clamp(0.01, 0.90).toDouble();
      b['pos_y'] = py.clamp(0.01, 0.88).toDouble();
      b['width_rel'] = wRel.clamp(0.12, 0.95).toDouble();
      b['height_rel'] = hRel.clamp(0.14, 0.95).toDouble();
      b['color_hex'] = (b['color_hex'] as String?) ?? '#2563EB';
      return b;
    }).toList();

    final nodes = ((activeStack['nodes'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    int idx = 0;
    for (final sn in nodes) {
      final nid = sn['id'] as int;
      final px = ((sn['pos_x'] as num?)?.toDouble() ??
              (0.10 + (idx % 4) * 0.22))
          .clamp(0.01, 0.92);
      final py = ((sn['pos_y'] as num?)?.toDouble() ??
              (0.18 + (idx ~/ 4) * 0.26))
          .clamp(0.02, 0.90);
      _stackNodePositions[nid] = Offset(px, py);
      final w =
          ((sn['width_px'] as num?)?.toDouble() ?? 220.0).clamp(160.0, 500.0);
      final h =
          ((sn['height_px'] as num?)?.toDouble() ?? 124.0).clamp(96.0, 340.0);
      _stackNodeSizes[nid] = Size(w, h);
      idx++;
    }
    if (_selectedStackNodeId != null &&
        !nodes.any((n) => n['id'] == _selectedStackNodeId)) {
      _selectedStackNodeId =
          nodes.isNotEmpty ? (nodes.first['id'] as int) : null;
    } else if (_selectedStackNodeId == null &&
        _selectedBoxId == null &&
        nodes.isNotEmpty) {
      _selectedStackNodeId = nodes.first['id'] as int;
    }
  }

  Future<void> _loadOverview({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await widget.api.getNetworkHostsOverview();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _syncStackCanvasState(data);
        final hosts = _hosts;
        if (hosts.isNotEmpty) {
          if (_selectedHostId == null ||
              !hosts.any((h) => h['id'] == _selectedHostId)) {
            _selectedHostId = hosts.first['id'] as int;
          }
          final swHosts = hosts
              .where((h) => ((h['snmp_ports_count'] as num?) ?? 0) > 0)
              .toList();
          if (swHosts.isNotEmpty &&
              (_selectedSwitchAssetId == null ||
                  !swHosts.any((h) => h['id'] == _selectedSwitchAssetId))) {
            _selectedSwitchAssetId = swHosts.first['id'] as int;
          }
        }
      });
      if (_selectedHostId != null && _telemetryData == null) {
        _loadHostTelemetry(_selectedHostId!);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadHostTelemetry(int assetId) async {
    setState(() => _loadingTelemetry = true);
    try {
      final res = await widget.api.getNetworkHostTelemetry(
        assetId,
        rangeHours: _telemetryRangeHours,
      );
      if (!mounted) return;
      setState(() {
        _telemetryData = res;
        _loadingTelemetry = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingTelemetry = false);
    }
  }

  Future<void> _loadAiContextManifest() async {
    try {
      final res = await widget.api.getAiAgentContextManifest();
      if (!mounted) return;
      setState(() => _aiContextManifest = res);
    } catch (_) {}
  }

  Future<void> _loadApiOnboardingGuide() async {
    try {
      final res = await widget.api.getApiOnboardingGuide();
      if (!mounted) return;
      setState(() => _apiOnboardingGuide = res);
    } catch (_) {}
  }

  Future<void> _loadDirectoryUsers() async {
    try {
      final usuarios = await widget.api.getUsers();
      if (!mounted) return;
      setState(() {
        _directoryUsers = usuarios;
        _directoryUsersDenegado = false;
      });
    } on RackDocAuthException catch (e) {
      // 403: el rol no llega a 'admin'. No es un fallo, es la política de RBAC;
      // se marca para poder decirlo en el selector en vez de callar.
      if (!mounted) return;
      setState(() => _directoryUsersDenegado = e.isForbidden);
    } catch (_) {}
  }

  Future<void> _loadSreAuxiliaryData() async {
    _loadAiContextManifest();
    _loadApiOnboardingGuide();
    _loadDirectoryUsers();
    try {
      final certData = await widget.api.getCertScopeOverview();
      if (!mounted) return;
      setState(() => _certScopeOverview = certData);
    } catch (_) {}
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? AppTheme.error : AppTheme.accentBlue,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _runAllChecksNow() async {
    setState(() => _runningAction = true);
    try {
      final res = await widget.api.runAllNetworkServiceChecks();
      final batch = Map<String, dynamic>.from((res['batch'] as Map?) ?? {});
      if (res['overview'] is Map) {
        setState(() {
          _overview = Map<String, dynamic>.from(res['overview'] as Map);
        });
      }
      _showSnack(
        'Chequeo masivo completado: ${batch['checked_count'] ?? 0} servicios evaluados '
        '(OK: ${batch['ok_count'] ?? 0}, WARN: ${batch['warning_count'] ?? 0}, CRIT: ${batch['critical_count'] ?? 0}). '
        'Prometheus SD actualizado.',
      );
    } catch (e) {
      _showSnack('Error al evaluar servicios: $e', isError: true);
    } finally {
      if (mounted) setState(() => _runningAction = false);
    }
  }

  Color _nagiosStateColor(String state) {
    switch (state.toUpperCase()) {
      case 'UP':
      case 'OK':
        return AppTheme.success;
      case 'WARNING':
      case 'DEGRADED':
        return AppTheme.warning;
      case 'DOWN':
      case 'CRITICAL':
        return AppTheme.error;
      case 'UNREACHABLE':
        return AppTheme.accentPurple;
      case 'MAINTENANCE':
        return AppTheme.accentCyan;
      default:
        return AppTheme.textMuted;
    }
  }

  IconData _layerIcon(String layer) {
    switch (layer) {
      case 'edge_security':
        return Icons.security_rounded;
      case 'network_switching':
        return Icons.router_rounded;
      case 'hypervisors_phys':
        return Icons.dns_rounded;
      case 'vms_containers':
        return Icons.cloud_queue_rounded;
      case 'services_apps':
        return Icons.hub_rounded;
      default:
        return Icons.devices_other_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppTheme.error, size: 48),
            const SizedBox(height: 12),
            Text(
              'Error cargando Red & Host: $_error',
              style: const TextStyle(color: AppTheme.textPrimary),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _loadOverview,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        _buildTopTacticalHeader(),
        _buildSubNavigationTabBar(),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: widget.isSreAlarmsMode
                ? [
                    _buildSreDevicesAlarmStatusTab(),
                    _buildAlertsContactsAndMaintenanceTab(),
                    _buildSloSreObjectivesTab(),
                    _buildAnsibleWebhooksAndAiDocsTab(),
                  ]
                : [
                    _buildTechStacksCanvasTab(),
                    _buildLogicalTopologyTab(),
                    _buildNagiosServiceMonitorTab(),
                    _buildSnmpSwitchesAndConnectorsTab(),
                    _buildPrometheusChartsAndAgentsTab(),
                  ],
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // CABECERA PRINCIPAL ADAPTATIVA DE LADO A LADO (SIN FILA RECARGADA DE CONTADORES)
  // ===========================================================================

  Widget _buildTopTacticalHeader() {
    final s = _summary;
    final promUrl =
        (s['prometheus_url'] as String?) ?? 'http://localhost:9090';

    if (widget.isSreAlarmsMode) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: const BoxDecoration(
          color: AppTheme.bgSecondary,
          border: Border(bottom: BorderSide(color: AppTheme.border)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxW = constraints.maxWidth;
            final isWide = maxW >= 980;

            final titleBlock = Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        AppTheme.accentPurple.withValues(alpha: 0.28),
                        AppTheme.accentCyan.withValues(alpha: 0.25),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(
                      color: AppTheme.accentCyan.withValues(alpha: 0.45),
                    ),
                  ),
                  child: const Icon(
                    Icons.notifications_active_rounded,
                    color: AppTheme.accentCyan,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '8. ALARMAS SRE — ESTADO EN VIVO, AVISOS, OBJETIVOS SLO/SLI & DOCUMENTACIÓN',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                          color: AppTheme.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Monitorización de Dispositivos en Alarma y Tiempo en Incidencia • Enrutamiento a Grupos AD/Usuarios y SMTP • SLO/Error Budgets • Automatización Ansible & API',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            );

            final actionsBlock = Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: isWide ? WrapAlignment.end : WrapAlignment.start,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _runningAction ? null : _runAllChecksNow,
                  icon: _runningAction
                      ? const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bolt_rounded, size: 15),
                  label: const Text(
                    'Evaluar Heartbeats Ahora',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _tabController.animateTo(1),
                  icon: const Icon(
                    Icons.manage_accounts_rounded,
                    size: 15,
                    color: AppTheme.accentCyan,
                  ),
                  label: const Text(
                    'Configurar Avisos / Grupos AD',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
                DiagramExportMenuButton(
                  buttonLabel: 'Exportar (.dia / .png / .pdf / .csv / .json)',
                  documentBuilder: _buildCurrentStackExportDocument,
                  darkStyle: true,
                ),
                ElevatedButton.icon(
                  onPressed: () => _tabController.animateTo(3),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accentBlue,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.menu_book_rounded, size: 15),
                  label: const Text(
                    'Documentación, Ansible & API',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            );

            if (isWide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(child: titleBlock),
                  const SizedBox(width: 16),
                  actionsBlock,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                titleBlock,
                const SizedBox(height: 8),
                actionsBlock,
              ],
            );
          },
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: const BoxDecoration(
        color: AppTheme.bgSecondary,
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth;
          final isWide = maxW >= 1040;

          final titleBlock = Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppTheme.accentCyan.withValues(alpha: 0.25),
                      AppTheme.accentBlue.withValues(alpha: 0.25),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: AppTheme.accentCyan.withValues(alpha: 0.45),
                  ),
                ),
                child: const Icon(
                  Icons.account_tree_rounded,
                  color: AppTheme.accentCyan,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '4. RED & HOST — TOPOLOGÍA LÓGICA, MONITORIZACIÓN & PROMETHEUS',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                        color: AppTheme.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Coordinado en vivo con 3. Rack Editor, 6. CMDB y 8. Alarmas SRE • Comprobación SNMP de switches • Estados Nagios • Series Temporales Prometheus',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          );

          final actionsBlock = Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: isWide ? WrapAlignment.end : WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _runningAction ? null : _runAllChecksNow,
                icon: _runningAction
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bolt_rounded, size: 15),
                label: const Text(
                  'Evaluar Heartbeats',
                  style: TextStyle(fontSize: 11.5),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _showSnmpDiscoveryDialog,
                icon: const Icon(Icons.radar_rounded, size: 15),
                label: const Text(
                  'Comprobar Switch (SNMP)',
                  style: TextStyle(fontSize: 11.5),
                ),
              ),
              DiagramExportMenuButton(
                documentBuilder: _buildCurrentStackExportDocument,
                darkStyle: true,
              ),
              if (widget.onOpenSreDocs != null)
                OutlinedButton.icon(
                  onPressed: widget.onOpenSreDocs,
                  icon: const Icon(
                    Icons.menu_book_rounded,
                    size: 15,
                    color: AppTheme.accentCyan,
                  ),
                  label: const Text(
                    'Alarmas SRE (8)',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              if (widget.canEdit)
                ElevatedButton.icon(
                  onPressed: () =>
                      _showCreateVirtualMachineWithServicesDialog(
                        attachToCurrentStack: _tabController.index == 0,
                      ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accentBlue,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.add_location_alt_outlined, size: 16),
                  label: const Text(
                    '+ Añadir Elemento / Host',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              OutlinedButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(promUrl),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(
                  Icons.local_fire_department_rounded,
                  size: 15,
                  color: AppTheme.warning,
                ),
                label: const Text(
                  'Prometheus (:9090)',
                  style: TextStyle(fontSize: 11.5),
                ),
              ),
            ],
          );

          if (isWide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(child: titleBlock),
                const SizedBox(width: 16),
                actionsBlock,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              titleBlock,
              const SizedBox(height: 8),
              actionsBlock,
            ],
          );
        },
      ),
    );
  }

  Widget _buildSubNavigationTabBar() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: AppTheme.bgSecondary,
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fillTabs = widget.isSreAlarmsMode
              ? constraints.maxWidth >= 920
              : constraints.maxWidth >= 1100;
          return TabBar(
            controller: _tabController,
            isScrollable: !fillTabs,
            tabAlignment: fillTabs ? TabAlignment.fill : TabAlignment.start,
            indicatorSize: TabBarIndicatorSize.tab,
            indicatorColor: AppTheme.accentCyan,
            labelColor: AppTheme.accentCyan,
            unselectedLabelColor: AppTheme.textSecondary,
            labelStyle: const TextStyle(
              fontSize: 11.8,
              fontWeight: FontWeight.w700,
            ),
            tabs: widget.isSreAlarmsMode
                ? const [
                    Tab(
                      icon: Icon(Icons.crisis_alert_rounded, size: 16),
                      text:
                          '1. Estado de Dispositivos & Alarmas en Vivo (Tiempo y Enlaces)',
                    ),
                    Tab(
                      icon: Icon(Icons.notifications_active_rounded, size: 16),
                      text:
                          '2. Configuración de Avisos (Grupos AD / Usuarios / SMTP) & Mantenimiento',
                    ),
                    Tab(
                      icon: Icon(Icons.speed_rounded, size: 16),
                      text:
                          '3. Objetivos SLO / SLI, Error Budgets & Indicadores SRE',
                    ),
                    Tab(
                      icon: Icon(Icons.menu_book_rounded, size: 16),
                      text:
                          '4. Documentación, Automatización Ansible, API (cURL/Puppet) & Agentes',
                    ),
                  ]
                : const [
                    Tab(
                      icon: Icon(Icons.layers_rounded, size: 16),
                      text:
                          '1. Stacks Tecnológicos & Lógica de Negocio (Lienzo 2D + SSH)',
                    ),
                    Tab(
                      icon: Icon(Icons.schema_rounded, size: 16),
                      text: '2. Topología de Capas (Red / Rack / VMs)',
                    ),
                    Tab(
                      icon: Icon(Icons.monitor_heart_rounded, size: 16),
                      text: '3. Estados Nagios & Heartbeats (HTTP/HTTPS/SSL/TCP)',
                    ),
                    Tab(
                      icon: Icon(Icons.settings_ethernet_rounded, size: 16),
                      text:
                          '4. Switches SNMP & Conectores (Proxmox/VMware/Docker/Web)',
                    ),
                    Tab(
                      icon: Icon(Icons.multiline_chart_rounded, size: 16),
                      text:
                          '5. Gráficas Prometheus TSDB & Telemetría en Tiempo Real',
                    ),
                  ],
          );
        },
      ),
    );
  }
}
