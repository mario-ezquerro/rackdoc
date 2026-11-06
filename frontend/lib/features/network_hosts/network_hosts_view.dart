import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api_client.dart';

class AppTheme {
  static const Color bgPrimary = Color(0xFFF8FAFC);
  static const Color bgSecondary = Color(0xFFFFFFFF);
  static const Color bgCard = Color(0xFFF1F5F9);
  static const Color bgElevated = Color(0xFFE2E8F0);
  static const Color border = Color(0xFFCBD5E1);
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF334155);
  static const Color textMuted = Color(0xFF64748B);
  static const Color accentCyan = Color(0xFF0284C7);
  static const Color accentBlue = Color(0xFF2563EB);
  static const Color accentPurple = Color(0xFF7C3AED);
  static const Color accentTeal = Color(0xFF0D9488);
  static const Color success = Color(0xFF16A34A);
  static const Color warning = Color(0xFFD97706);
  static const Color error = Color(0xFFDC2626);
}

class NetworkHostsView extends StatefulWidget {
  final RackDocApiClient api;
  final bool canEdit;
  final void Function(int rackId, int? deviceId)? onNavigateToRackDevice;
  final void Function(String? assetCode)? onNavigateToCmdb;

  const NetworkHostsView({
    super.key,
    required this.api,
    this.canEdit = true,
    this.onNavigateToRackDevice,
    this.onNavigateToCmdb,
  });

  @override
  State<NetworkHostsView> createState() => _NetworkHostsViewState();
}

class _NetworkHostsViewState extends State<NetworkHostsView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

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

  Map<String, dynamic>? _aiContextManifest;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging && mounted) {
        if (_tabController.index == 4 && _selectedHostId != null) {
          _loadHostTelemetry(_selectedHostId!);
        } else if (_tabController.index == 6 && _aiContextManifest == null) {
          _loadAiContextManifest();
        }
        setState(() {});
      }
    });
    _loadOverview();
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

  // Estado de la Matriz 4 Columnas (Estilo Active Directory + Drag & Drop) en '6. Avisos & Alarmas'
  int? _selectedAlertHostGroupId;
  int? _selectedAlertUserGroupId;
  int? _selectedAlertContactId;
  String _alertGroupSourceFilter = 'all'; // 'all' | 'ad' | 'local' | 'custom'
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
            children: [
              _buildTechStacksCanvasTab(),
              _buildLogicalTopologyTab(),
              _buildNagiosServiceMonitorTab(),
              _buildSnmpSwitchesAndConnectorsTab(),
              _buildPrometheusChartsAndAgentsTab(),
              _buildAlertsContactsAndMaintenanceTab(),
              _buildAnsibleWebhooksAndAiDocsTab(),
            ],
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // CABECERA TÁCTICA (ESTILO NAGIOS CORE + OBSERVIUM + PROMETHEUS TSDB)
  // ===========================================================================

  Widget _buildTopTacticalHeader() {
    final s = _summary;
    final promUrl =
        (s['prometheus_url'] as String?) ?? 'http://localhost:9090';

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
      decoration: const BoxDecoration(
        color: AppTheme.bgSecondary,
        border: Border(bottom: BorderSide(color: AppTheme.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 10,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          AppTheme.accentCyan.withValues(alpha: 0.25),
                          AppTheme.accentBlue.withValues(alpha: 0.25),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppTheme.accentCyan.withValues(alpha: 0.45),
                      ),
                    ),
                    child: const Icon(
                      Icons.account_tree_rounded,
                      color: AppTheme.accentCyan,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '4. RED & HOST — TOPOLOGÍA LÓGICA, MONITORIZACIÓN & PROMETHEUS',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.4,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Coordinado en vivo con 3. Rack Editor y 6. CMDB • Autodescubrimiento SNMP + LLDP • Estados Nagios (SOFT/HARD + UNREACHABLE) • Series Temporales Prometheus • Webhooks Ansible',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
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
                      'Evaluar Todos los Heartbeats',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _showSnmpDiscoveryDialog,
                    icon: const Icon(Icons.radar_rounded, size: 15),
                    label: const Text(
                      'Autodescubrir Switch (SNMP)',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                  if (widget.canEdit) ...[
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
                  ],
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
              ),
            ],
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildTacCounterChip(
                  label: 'HOSTS UP',
                  count: '${s['hosts_up'] ?? 0}',
                  color: AppTheme.success,
                  icon: Icons.check_circle_rounded,
                ),
                const SizedBox(width: 8),
                _buildTacCounterChip(
                  label: 'HOSTS DOWN',
                  count: '${s['hosts_down'] ?? 0}',
                  color: AppTheme.error,
                  icon: Icons.cancel_rounded,
                ),
                const SizedBox(width: 8),
                _buildTacCounterChip(
                  label: 'UNREACHABLE (PADRE CAÍDO)',
                  count: '${s['hosts_unreachable'] ?? 0}',
                  color: AppTheme.accentPurple,
                  icon: Icons.account_tree_outlined,
                ),
                const SizedBox(width: 8),
                _buildTacCounterChip(
                  label: 'EN MANTENIMIENTO (ANSIBLE)',
                  count: '${s['hosts_maintenance'] ?? 0}',
                  color: AppTheme.accentCyan,
                  icon: Icons.build_circle_rounded,
                ),
                const SizedBox(width: 14),
                Container(width: 1, height: 26, color: AppTheme.border),
                const SizedBox(width: 14),
                _buildTacCounterChip(
                  label: 'SERVICIOS OK',
                  count: '${s['services_ok'] ?? 0}',
                  color: AppTheme.success,
                  icon: Icons.verified_rounded,
                ),
                const SizedBox(width: 8),
                _buildTacCounterChip(
                  label: 'SERVICIOS WARNING',
                  count: '${s['services_warning'] ?? 0}',
                  color: AppTheme.warning,
                  icon: Icons.warning_amber_rounded,
                ),
                const SizedBox(width: 8),
                _buildTacCounterChip(
                  label: 'SERVICIOS CRITICAL',
                  count: '${s['services_critical'] ?? 0}',
                  color: AppTheme.error,
                  icon: Icons.gpp_bad_rounded,
                ),
                const SizedBox(width: 14),
                Container(width: 1, height: 26, color: AppTheme.border),
                const SizedBox(width: 14),
                _buildTacCounterChip(
                  label: 'BOCAS SWITCH SNMP',
                  count: '${s['total_snmp_ports'] ?? 0}',
                  color: AppTheme.accentBlue,
                  icon: Icons.settings_ethernet_rounded,
                ),
                const SizedBox(width: 8),
                _buildTacCounterChip(
                  label: 'CONECTORES ACTIVOS',
                  count: '${s['total_connectors'] ?? 0}',
                  color: AppTheme.accentTeal,
                  icon: Icons.power_rounded,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTacCounterChip({
    required String label,
    required String count,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            count,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubNavigationTabBar() {
    return Container(
      color: AppTheme.bgSecondary,
      alignment: Alignment.centerLeft,
      child: TabBar(
        controller: _tabController,
        isScrollable: true,
        indicatorColor: AppTheme.accentCyan,
        labelColor: AppTheme.accentCyan,
        unselectedLabelColor: AppTheme.textSecondary,
        labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        tabs: const [
          Tab(
            icon: Icon(Icons.layers_rounded, size: 16),
            text: '1. Stacks Tecnológicos & Lógica de Negocio (Lienzo 2D + SSH)',
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
            text: '4. Switches SNMP (LLDP) & Conectores (Proxmox/VMware/Docker/Web)',
          ),
          Tab(
            icon: Icon(Icons.multiline_chart_rounded, size: 16),
            text: '5. Gráficas Prometheus TSDB & Agentes a Instalar',
          ),
          Tab(
            icon: Icon(Icons.notifications_active_rounded, size: 16),
            text: '6. Avisos de Alarmas (Personas/Grupos/HostGroups) & Mantenimiento',
          ),
          Tab(
            icon: Icon(Icons.smart_toy_rounded, size: 16),
            text: '7. Automatización Ansible, Webhooks & Guía Agentes IA',
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 1: STACKS TECNOLÓGICOS & LÓGICA DE NEGOCIO (ESTILO DATACENTER FLOOR:
  // LIENZO 2D LIBRE + CAJAS CON TEXTO EN ESQUINA + ENLACES LIBRES + VENTANA FLOTANTE MOVIBLE + PANEL SETTINGS)
  // ===========================================================================

  Map<String, dynamic> get _activeStack {
    final stacks = _techStacks;
    return stacks.firstWhere(
      (s) => s['id'] == _selectedStackId,
      orElse: () => stacks.isNotEmpty ? stacks.first : <String, dynamic>{},
    );
  }

  Future<void> _persistStackBoxesAndScale({
    List<Map<String, dynamic>>? boxes,
    double? mapScale,
  }) async {
    final st = _activeStack;
    final stId = st['id'] as int?;
    if (stId == null) return;
    try {
      final res = await widget.api.updateTechStackDiagram(stId, {
        'canvas_boxes': ?boxes,
        'map_scale': ?mapScale,
      });
      if (mounted) {
        setState(() {
          _overview = res;
          _syncStackCanvasState();
        });
      }
    } catch (e) {
      _showSnack('Error al guardar lienzo del Stack: $e', isError: true);
    }
  }

  Widget _buildTechStacksCanvasTab() {
    final stacks = _techStacks;
    final activeStack = _activeStack;
    final nodes = ((activeStack['nodes'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final edges = ((activeStack['edges'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final selectedNode = nodes.firstWhere(
      (n) => n['id'] == _selectedStackNodeId,
      orElse: () => nodes.isNotEmpty ? nodes.first : <String, dynamic>{},
    );

    return Column(
      children: [
        // Barra superior estilo Datacenter Dashboard
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: const BoxDecoration(
            color: AppTheme.bgCard,
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => setState(
                      () => _showStackLeftLibrary = !_showStackLeftLibrary,
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      backgroundColor: _showStackLeftLibrary
                          ? AppTheme.accentBlue.withValues(alpha: 0.14)
                          : null,
                    ),
                    icon: const Icon(Icons.widgets_outlined, size: 14),
                    label: Text(
                      _showStackLeftLibrary ? 'Library: ON' : 'Library: OFF',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.layers_rounded,
                    size: 17,
                    color: AppTheme.accentCyan,
                  ),
                  const SizedBox(width: 6),
                  if (stacks.isNotEmpty)
                    DropdownButton<int>(
                      value: activeStack['id'] as int?,
                      dropdownColor: AppTheme.bgElevated,
                      underline: const SizedBox.shrink(),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.accentBlue,
                      ),
                      items: stacks
                          .map(
                            (st) => DropdownMenuItem<int>(
                              value: st['id'] as int,
                              child: Text(
                                '${st['name']} (${st['nodes_count']} elem.)',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() {
                        _selectedStackId = v;
                        _selectedStackNodeId = null;
                        _selectedBoxId = null;
                        _isLinkModeActive = false;
                        _linkSourceNodeId = null;
                        _syncStackCanvasState();
                      }),
                    ),
                  if (widget.canEdit) ...[
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: 'Crear nuevo Stack Tecnológico',
                      icon: const Icon(
                        Icons.create_new_folder_rounded,
                        size: 16,
                        color: AppTheme.accentCyan,
                      ),
                      onPressed: _showCreateTechStackDialog,
                    ),
                  ],
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // Toggle Ver Conexiones
                  OutlinedButton.icon(
                    onPressed: () =>
                        setState(() => _showStackEdges = !_showStackEdges),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 6,
                      ),
                      backgroundColor: _showStackEdges
                          ? AppTheme.accentCyan.withValues(alpha: 0.14)
                          : null,
                    ),
                    icon: const Icon(Icons.hub_rounded, size: 14),
                    label: Text(
                      _showStackEdges
                          ? 'Enlaces (${edges.length}): ON'
                          : 'Enlaces: OFF',
                      style: const TextStyle(
                        fontSize: 10.8,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (widget.canEdit && activeStack.isNotEmpty) ...[
                    // Modo Enlazar interactivo (clic origen -> clic destino en cualquier dirección)
                    ElevatedButton.icon(
                      onPressed: () {
                        setState(() {
                          _isLinkModeActive = !_isLinkModeActive;
                          _linkSourceNodeId = _isLinkModeActive
                              ? _selectedStackNodeId
                              : null;
                        });
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isLinkModeActive
                            ? AppTheme.warning
                            : AppTheme.bgElevated,
                        foregroundColor: _isLinkModeActive
                            ? Colors.black
                            : AppTheme.textPrimary,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                      ),
                      icon: const Icon(Icons.add_link_rounded, size: 15),
                      label: Text(
                        _isLinkModeActive
                            ? (_linkSourceNodeId == null
                                  ? '🔗 1º Clic en Origen...'
                                  : '🔗 2º Clic en Destino...')
                            : '🔗 Enlazar Elementos',
                        style: const TextStyle(
                          fontSize: 10.8,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    // Añadir Caja / Zona dibujable con texto en esquina superior
                    OutlinedButton.icon(
                      onPressed: () => _showAddOrEditStackZoneBoxDialog(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                      ),
                      icon: const Icon(
                        Icons.select_all_rounded,
                        size: 14,
                        color: AppTheme.accentPurple,
                      ),
                      label: const Text(
                        '+ Caja / Zona con Datos',
                        style: TextStyle(
                          fontSize: 10.8,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    // Añadir Elemento / Host estilo Datacenter
                    ElevatedButton.icon(
                      onPressed: () =>
                          _showCreateVirtualMachineWithServicesDialog(
                            attachToCurrentStack: true,
                          ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accentBlue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                      ),
                      icon: const Icon(Icons.add_circle_outline, size: 14),
                      label: const Text(
                        '+ Añadir Elemento / Host',
                        style: TextStyle(
                          fontSize: 10.8,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                  // Modo Mano (Pan) y Escala estilo Datacenter
                  OutlinedButton.icon(
                    onPressed: () => setState(
                      () => _isStackHandMode = !_isStackHandMode,
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 6,
                      ),
                      backgroundColor: _isStackHandMode
                          ? AppTheme.accentTeal.withValues(alpha: 0.16)
                          : null,
                    ),
                    icon: const Icon(Icons.pan_tool_alt_rounded, size: 14),
                    label: Text(
                      _isStackHandMode ? 'Mano: ON' : 'Mano',
                      style: const TextStyle(
                        fontSize: 10.8,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  // Botón para mostrar/ocultar la Ventana Flotante Movible de Datos Técnicos y Gráficas
                  OutlinedButton.icon(
                    onPressed: () => setState(() {
                      _showFloatingTechWindow = !_showFloatingTechWindow;
                      if (_showFloatingTechWindow &&
                          _selectedStackNodeId == null &&
                          nodes.isNotEmpty) {
                        _selectedStackNodeId = nodes.first['id'] as int;
                        final h = Map<String, dynamic>.from(
                          (nodes.first['host'] as Map?) ?? {},
                        );
                        if (h['id'] != null) {
                          _selectedHostId = h['id'] as int;
                          _loadHostTelemetry(_selectedHostId!);
                        }
                      }
                    }),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 6,
                      ),
                      backgroundColor: _showFloatingTechWindow
                          ? AppTheme.accentTeal.withValues(alpha: 0.15)
                          : null,
                    ),
                    icon: const Icon(
                      Icons.analytics_outlined,
                      size: 14,
                      color: AppTheme.accentTeal,
                    ),
                    label: Text(
                      _showFloatingTechWindow
                          ? '📊 Ventana Flotante: ON'
                          : '📊 Ventana Flotante',
                      style: const TextStyle(
                        fontSize: 10.8,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  // Toggle Panel Derecho Settings (igual que en Datacenter)
                  OutlinedButton.icon(
                    onPressed: () => setState(
                      () => _showStackRightSettings = !_showStackRightSettings,
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 6,
                      ),
                      backgroundColor: _showStackRightSettings
                          ? AppTheme.accentBlue.withValues(alpha: 0.14)
                          : null,
                    ),
                    icon: const Icon(Icons.tune_rounded, size: 14),
                    label: Text(
                      _showStackRightSettings ? 'Settings: ON' : 'Settings',
                      style: const TextStyle(
                        fontSize: 10.8,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        // Cuerpo en 3 columnas idéntico al Dashboard de Datacenter:
        // [Left Elements Library] + [Central 2D Architectural Grid Canvas + Floating Window] + [Right Settings Panel]
        Expanded(
          child: activeStack.isEmpty
              ? const Center(
                  child: Text('Crea un Stack Tecnológico para empezar'),
                )
              : Row(
                  children: [
                    if (_showStackLeftLibrary)
                      _buildStackLeftLibraryPanel(activeStack, nodes),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return DragTarget<String>(
                            onWillAcceptWithDetails: (_) => widget.canEdit,
                            onAcceptWithDetails: (details) async {
                              final box =
                                  _stackCanvasKey.currentContext
                                          ?.findRenderObject()
                                      as RenderBox?;
                              Offset rel = const Offset(0.35, 0.35);
                              if (box != null) {
                                final local = box.globalToLocal(details.offset);
                                rel = Offset(
                                  (local.dx / box.size.width).clamp(0.02, 0.86),
                                  (local.dy / box.size.height).clamp(
                                    0.03,
                                    0.84,
                                  ),
                                );
                              }
                              await _handleStackCanvasDrop(
                                details.data,
                                rel,
                                activeStack['id'] as int,
                              );
                            },
                            builder: (context, candidateData, rejectedData) {
                              return MouseRegion(
                                onHover: (event) {
                                  if (_isLinkModeActive &&
                                      _linkSourceNodeId != null) {
                                    setState(() {
                                      _linkLiveMousePos = event.localPosition;
                                    });
                                  }
                                },
                                child: GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onTap: () {
                                    setState(() {
                                      if (_isLinkModeActive) {
                                        _isLinkModeActive = false;
                                        _linkSourceNodeId = null;
                                        _linkSourceSide = null;
                                        _linkLiveMousePos = null;
                                      } else {
                                        _selectedBoxId = null;
                                      }
                                    });
                                  },
                                  child: Container(
                                    key: _stackCanvasKey,
                                    width: constraints.maxWidth,
                                    height: constraints.maxHeight,
                                    color: AppTheme.bgPrimary,
                                    child: Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        // 0. Cuadrícula arquitectónica libre estilo Datacenter (IgnorePointer para no bloquear eventos)
                                        Positioned.fill(
                                          child: IgnorePointer(
                                            child: CustomPaint(
                                              painter:
                                                  _StackArchitecturalGridPainter(
                                                    scale: _stackCanvasScale,
                                                  ),
                                            ),
                                          ),
                                        ),
                                        // 1. Cajas / Zonas seleccionables, redimensionables y arrastrables con el ratón + borrar en "X" superior izquierda
                                        for (final zBox in _stackBoxes)
                                          _buildStackCanvasZoneBox(
                                            zBox: zBox,
                                            canvasWidth: constraints.maxWidth,
                                            canvasHeight: constraints.maxHeight,
                                          ),
                                        // 2. Flechas de unión multi-dirección + Flecha en vivo desde los cuadrados laterales (IgnorePointer para no tapar cajas)
                                        if (_showStackEdges || _isLinkModeActive)
                                          Positioned.fill(
                                            child: IgnorePointer(
                                              child: CustomPaint(
                                                painter: _TechStackEdgesPainter(
                                                  nodes: nodes,
                                                  edges: _showStackEdges
                                                      ? edges
                                                      : const [],
                                                  nodePositions:
                                                      _stackNodePositions,
                                                  nodeSizes: _stackNodeSizes,
                                                  canvasSize: Size(
                                                    constraints.maxWidth,
                                                    constraints.maxHeight,
                                                  ),
                                                  liveSourceNodeId:
                                                      _isLinkModeActive
                                                      ? _linkSourceNodeId
                                                      : null,
                                                  liveSourceSide:
                                                      _linkSourceSide,
                                                  liveMousePos:
                                                      _linkLiveMousePos,
                                                ),
                                              ),
                                            ),
                                          ),
                                        if (_showStackEdges)
                                          ..._buildEdgeInteractivePills(
                                            nodes: nodes,
                                            edges: edges,
                                            canvasWidth: constraints.maxWidth,
                                            canvasHeight: constraints.maxHeight,
                                          ),
                                        // 3. Elementos / Nodos libremente arrastrables (1:1 con ratón), redimensionables y con 4 cuadrados laterales de enlace
                                        for (final sn in nodes)
                                          _buildDraggableStackNodeCard(
                                            sn: sn,
                                            allNodes: nodes,
                                            canvasWidth: constraints.maxWidth,
                                            canvasHeight: constraints.maxHeight,
                                          ),
                                        // 4. Banner de ayuda cuando el Modo Enlazar o un cuadrado lateral está activo
                                        if (_isLinkModeActive)
                                          Positioned(
                                            top: 10,
                                            left: 16,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                    vertical: 7,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: AppTheme.warning,
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                boxShadow: const [
                                                  BoxShadow(
                                                    color: Colors.black26,
                                                    blurRadius: 8,
                                                  ),
                                                ],
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const Icon(
                                                    Icons.link_rounded,
                                                    size: 16,
                                                    color: Colors.black,
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    _linkSourceNodeId == null
                                                        ? 'MODO ENLAZAR: Haz clic en un cuadrado lateral (o elemento) ORIGEN'
                                                        : 'FLECHA DE UNIÓN ACTIVA (${_linkSourceSide?.toUpperCase() ?? "AUTO"}): Haz clic o suelta en cualquier cuadrado lateral o elemento DESTINO',
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      color: Colors.black,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  InkWell(
                                                    onTap: () => setState(() {
                                                      _isLinkModeActive = false;
                                                      _linkSourceNodeId = null;
                                                      _linkSourceSide = null;
                                                      _linkLiveMousePos = null;
                                                    }),
                                                    child: const Icon(
                                                      Icons.close,
                                                      size: 15,
                                                      color: Colors.black87,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                      // 5. Ventana Flotante Movible con Datos Técnicos, SSH y Gráficas Prometheus Afinadas
                                      if (_showFloatingTechWindow &&
                                          selectedNode.isNotEmpty)
                                        _buildFloatingTechnicalAndChartsWindow(
                                          sn: selectedNode,
                                          canvasWidth: constraints.maxWidth,
                                          canvasHeight: constraints.maxHeight,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                        },
                      ),
                    ),
                    if (_showStackRightSettings)
                      _buildStackRightSettingsPanel(
                        activeStack: activeStack,
                        nodes: nodes,
                        edges: edges,
                        selectedNode: selectedNode,
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  // ===========================================================================
  // PANEL IZQUIERDO ESTILO DATACENTER: ELEMENTS & HOSTS LIBRARY (DRAG & DROP)
  // ===========================================================================

  Widget _buildStackLeftLibraryPanel(
    Map<String, dynamic> activeStack,
    List<Map<String, dynamic>> currentNodes,
  ) {
    final stackId = activeStack['id'] as int;
    final inStackAssetIds = currentNodes
        .map((n) => (n['host'] as Map?)?['id'] as int?)
        .whereType<int>()
        .toSet();

    final zoneTemplates = [
      (
        'box:dmz',
        'Caja Zona DMZ / Perímetro',
        'VLAN 10 • 10.10.0.0/24 • WAF/LB',
        '#0EA5E9',
        Icons.shield_outlined,
      ),
      (
        'box:app',
        'Caja Clúster Frontales & Apps',
        'VLAN 20 • VMware/Proxmox HA • K8s',
        '#6366F1',
        Icons.dns_rounded,
      ),
      (
        'box:db',
        'Caja Zona Datos & Storage',
        'VLAN 30 • PostgreSQL / Redis HA',
        '#14B8A6',
        Icons.storage_rounded,
      ),
    ];

    final elementTemplates = [
      (
        'tpl:virtual_machine',
        'Máquina Virtual (VM)',
        'VMware / Proxmox / Hyper-V',
        Icons.computer_rounded,
        AppTheme.accentBlue,
      ),
      (
        'tpl:container',
        'Contenedor / Pod / Servicio Web',
        'Docker / Kubernetes / LXC',
        Icons.view_in_ar_rounded,
        AppTheme.accentPurple,
      ),
      (
        'tpl:vip_cluster',
        'Balanceador / VIP / API Gateway',
        'HAProxy / Nginx / Keepalived',
        Icons.alt_route_rounded,
        AppTheme.accentCyan,
      ),
      (
        'tpl:database',
        'Motor Base de Datos / Caché',
        'PostgreSQL / MySQL / Redis',
        Icons.table_chart_rounded,
        AppTheme.accentTeal,
      ),
      (
        'tpl:physical_server',
        'Servidor Físico / Barebone',
        'Host Físico o Servidor Dedicado',
        Icons.dns_outlined,
        AppTheme.success,
      ),
    ];

    return Container(
      width: 255,
      decoration: const BoxDecoration(
        color: AppTheme.bgCard,
        border: Border(right: BorderSide(color: AppTheme.border)),
      ),
      child: ListView(
        padding: const EdgeInsets.all(10),
        children: [
          const Text(
            'ELEMENTS & ZONES LIBRARY',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w900,
              color: AppTheme.textPrimary,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 3),
          const Text(
            'Arrastra al lienzo o pulsa + para añadir cajas con texto o elementos libres.',
            style: TextStyle(fontSize: 10, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 10),
          // 1. Cajas / Zonas agrupadoras con datos en esquina superior
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'CAJAS / ZONAS CON TEXTO',
                style: TextStyle(
                  fontSize: 9.8,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.accentPurple,
                ),
              ),
              InkWell(
                onTap: () => _showAddOrEditStackZoneBoxDialog(),
                child: const Text(
                  '+ Personalizada',
                  style: TextStyle(
                    fontSize: 9.8,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.accentBlue,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final z in zoneTemplates)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Draggable<String>(
                data: z.$1,
                feedback: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.accentPurple),
                    ),
                    child: Text(
                      z.$2,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                child: InkWell(
                  onTap: () => _handleStackCanvasDrop(
                    z.$1,
                    const Offset(0.08, 0.12),
                    stackId,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: Row(
                      children: [
                        Icon(z.$5, size: 15, color: AppTheme.accentPurple),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                z.$2,
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                z.$3,
                                style: const TextStyle(
                                  fontSize: 9,
                                  color: AppTheme.textMuted,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.add_circle_outline,
                          size: 14,
                          color: AppTheme.accentPurple,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const Divider(height: 18),
          // 2. Nuevos Elementos / Sistemas
          const Text(
            'NUEVOS ELEMENTOS / HOSTS',
            style: TextStyle(
              fontSize: 9.8,
              fontWeight: FontWeight.w800,
              color: AppTheme.accentCyan,
            ),
          ),
          const SizedBox(height: 6),
          for (final tpl in elementTemplates)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Draggable<String>(
                data: tpl.$1,
                feedback: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: tpl.$5),
                    ),
                    child: Text(
                      tpl.$2,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                child: InkWell(
                  onTap: () => _showCreateVirtualMachineWithServicesDialog(
                    attachToCurrentStack: true,
                    initialAssetClass: tpl.$1.replaceFirst('tpl:', ''),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: Row(
                      children: [
                        Icon(tpl.$4, size: 15, color: tpl.$5),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                tpl.$2,
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                tpl.$3,
                                style: const TextStyle(
                                  fontSize: 9,
                                  color: AppTheme.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.add_circle_outline,
                          size: 14,
                          color: tpl.$5,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const Divider(height: 18),
          // 3. Hosts ya registrados en CMDB / Red & Host para arrastrar al Stack
          Text(
            'HOSTS EN CMDB (${_hosts.length})',
            style: const TextStyle(
              fontSize: 9.8,
              fontWeight: FontWeight.w800,
              color: AppTheme.accentTeal,
            ),
          ),
          const SizedBox(height: 6),
          for (final h in _hosts)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Draggable<String>(
                data: 'host:${h['id']}',
                feedback: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.accentTeal),
                    ),
                    child: Text(
                      '${h['code']} (${h['heartbeat_ip']})',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: inStackAssetIds.contains(h['id'])
                        ? AppTheme.accentTeal.withValues(alpha: 0.08)
                        : AppTheme.bgSecondary,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: inStackAssetIds.contains(h['id'])
                          ? AppTheme.accentTeal.withValues(alpha: 0.4)
                          : AppTheme.border,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 7,
                        color: _nagiosStateColor(
                          (h['nagios_host_state'] as String?) ?? 'UP',
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${h['code']}',
                              style: const TextStyle(
                                fontSize: 10.2,
                                fontWeight: FontWeight.w800,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${h['heartbeat_ip']} • ${h['name']}',
                              style: const TextStyle(
                                fontSize: 8.8,
                                color: AppTheme.textMuted,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (widget.canEdit)
                        InkWell(
                          onTap: () => _handleStackCanvasDrop(
                            'host:${h['id']}',
                            const Offset(0.32, 0.32),
                            stackId,
                          ),
                          child: const Icon(
                            Icons.add_box_outlined,
                            size: 14,
                            color: AppTheme.accentTeal,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _handleStackCanvasDrop(
    String data,
    Offset relPos,
    int stackId,
  ) async {
    if (data.startsWith('box:')) {
      final kind = data.substring(4);
      final Map<String, (String, String, String)> presets = {
        'dmz': (
          'ZONA PERÍMETRO / DMZ / BALANCEO',
          'VLAN 10 • 10.10.0.0/24 • HAProxy / WAF',
          '#0EA5E9',
        ),
        'app': (
          'CLÚSTER APLICACIONES & FRONTALES WEB',
          'VLAN 20 • VMware vSphere / Proxmox HA • 10.20.20.0/24',
          '#6366F1',
        ),
        'db': (
          'ZONA BASES DE DATOS & CACHÉ',
          'VLAN 30 • PostgreSQL 16 + Redis Cluster • Backup Diario',
          '#14B8A6',
        ),
      };
      final p = presets[kind] ?? ('NUEVA ZONA / CAJA', 'Datos técnicos', '#0EA5E9');
      final newBox = <String, dynamic>{
        'id': 'box-${DateTime.now().millisecondsSinceEpoch}',
        'title': p.$1,
        'corner_data': p.$2,
        'pos_x': relPos.dx.clamp(0.02, 0.72),
        'pos_y': relPos.dy.clamp(0.03, 0.70),
        'width_rel': 0.36,
        'height_rel': 0.42,
        'color_hex': p.$3,
      };
      final updated = [..._stackBoxes, newBox];
      setState(() {
        _stackBoxes = updated;
        _selectedBoxId = newBox['id'] as String;
      });
      await _persistStackBoxesAndScale(boxes: updated);
      return;
    }

    if (data.startsWith('host:')) {
      final hostId = int.tryParse(data.substring(5));
      if (hostId == null) return;
      final hostObj = _hosts.firstWhere(
        (h) => h['id'] == hostId,
        orElse: () => <String, dynamic>{},
      );
      if (hostObj.isEmpty) return;
      final res = await widget.api.createTechStackNode({
        'stack_id': stackId,
        'asset_id': hostId,
        'role_layer': 'app_middleware',
        'custom_label': '${hostObj['name']}',
        'pos_x': relPos.dx.clamp(0.02, 0.86),
        'pos_y': relPos.dy.clamp(0.03, 0.84),
        'width_px': 236.0,
        'height_px': 134.0,
        'ssh_enabled': hostObj['ssh_enabled'] != false,
        'ssh_user': hostObj['ssh_user'] ?? 'root',
        'ssh_port': hostObj['ssh_port'] ?? 22,
      });
      if (mounted) {
        setState(() {
          _overview = res;
          _syncStackCanvasState();
        });
      }
      return;
    }

    if (data.startsWith('tpl:')) {
      final cls = data.substring(4);
      await _showCreateVirtualMachineWithServicesDialog(
        attachToCurrentStack: true,
        initialAssetClass: cls == 'database' ? 'virtual_machine' : cls,
        initialDropPosition: relPos,
      );
    }
  }

  // ===========================================================================
  // CAJAS / ZONAS CON TEXTO EN ESQUINA SUPERIOR (ARRASTRABLES Y REDIMENSIONABLES)
  // ===========================================================================

  Color _parseBoxHexColor(String? hex) {
    final clean = (hex ?? '#0EA5E9').replaceAll('#', '').trim();
    if (clean.length == 6) {
      final v = int.tryParse('FF$clean', radix: 16);
      if (v != null) return Color(v);
    }
    return AppTheme.accentCyan;
  }

  Widget _buildStackCanvasZoneBox({
    required Map<String, dynamic> zBox,
    required double canvasWidth,
    required double canvasHeight,
  }) {
    final boxId = '${zBox['id']}';
    final px = ((zBox['pos_x'] as num?)?.toDouble() ??
            (((zBox['x_px'] as num?)?.toDouble() ?? 40.0) / canvasWidth))
        .clamp(0.01, 0.92)
        .toDouble();
    final py = ((zBox['pos_y'] as num?)?.toDouble() ??
            (((zBox['y_px'] as num?)?.toDouble() ?? 40.0) / canvasHeight))
        .clamp(0.01, 0.90)
        .toDouble();
    final wRel = ((zBox['width_rel'] as num?)?.toDouble() ??
            (((zBox['width_px'] as num?)?.toDouble() ?? 520.0) / canvasWidth))
        .clamp(0.12, 0.95)
        .toDouble();
    final hRel = ((zBox['height_rel'] as num?)?.toDouble() ??
            (((zBox['height_px'] as num?)?.toDouble() ?? 430.0) / canvasHeight))
        .clamp(0.14, 0.95)
        .toDouble();

    final left = px * canvasWidth;
    final top = py * canvasHeight;
    final width = wRel * canvasWidth;
    final height = hRel * canvasHeight;
    final col = _parseBoxHexColor(zBox['color_hex'] as String?);
    final isSelected = _selectedBoxId == boxId;
    final cornerText = ((zBox['corner_data'] as String?) ??
            (zBox['subtitle'] as String?) ??
            '')
        .trim();

    Future<void> deleteThisBox() async {
      final updated = _stackBoxes.where((b) => '${b['id']}' != boxId).toList();
      setState(() {
        _stackBoxes = updated;
        if (_selectedBoxId == boxId) {
          _selectedBoxId = null;
        }
      });
      await _persistStackBoxesAndScale(boxes: updated);
    }

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() {
            _selectedBoxId = boxId;
            _selectedStackNodeId = null;
          });
        },
        onDoubleTap: widget.canEdit
            ? () {
                setState(() {
                  _selectedBoxId = boxId;
                  _selectedStackNodeId = null;
                });
                _showAddOrEditStackZoneBoxDialog(existingBox: zBox);
              }
            : null,
        onPanStart: widget.canEdit
            ? (details) {
                setState(() {
                  _selectedBoxId = boxId;
                  _selectedStackNodeId = null;
                  _boxDragStartGlobal = details.globalPosition;
                  _boxDragStartPx = Offset(left, top);
                });
              }
            : null,
        onPanUpdate: widget.canEdit
            ? (details) {
                if (_boxDragStartGlobal == null || _boxDragStartPx == null) {
                  return;
                }
                final globalDelta =
                    details.globalPosition - _boxDragStartGlobal!;
                final newLeft = (_boxDragStartPx!.dx + globalDelta.dx).clamp(
                  4.0,
                  math.max(8.0, canvasWidth - width - 4.0),
                );
                final newTop = (_boxDragStartPx!.dy + globalDelta.dy).clamp(
                  4.0,
                  math.max(8.0, canvasHeight - height - 4.0),
                );
                setState(() {
                  zBox['pos_x'] = (newLeft / canvasWidth)
                      .clamp(0.005, 0.96)
                      .toDouble();
                  zBox['pos_y'] = (newTop / canvasHeight)
                      .clamp(0.005, 0.95)
                      .toDouble();
                });
              }
            : null,
        onPanEnd: widget.canEdit
            ? (_) {
                _boxDragStartGlobal = null;
                _boxDragStartPx = null;
                _persistStackBoxesAndScale(boxes: _stackBoxes);
              }
            : null,
        child: MouseRegion(
          cursor: widget.canEdit
              ? SystemMouseCursors.move
              : SystemMouseCursors.basic,
          child: Container(
            decoration: BoxDecoration(
              color: col.withValues(alpha: isSelected ? 0.08 : 0.045),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? col : col.withValues(alpha: 0.45),
                width: isSelected ? 2.4 : 1.4,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: col.withValues(alpha: 0.16),
                        blurRadius: 10,
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Cabecera en la ESQUINA SUPERIOR IZQUIERDA:
                // [ Botón "X" Borrar ] + [ Título editable + Datos Técnicos + Botón Editar Nombre ]
                Positioned(
                  left: 8,
                  top: 8,
                  right: 24,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // Botón "X" en la esquina superior izquierda para borrar la caja
                      if (widget.canEdit)
                        Tooltip(
                          message: 'Borrar esta caja / zona',
                          child: InkWell(
                            onTap: deleteThisBox,
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: AppTheme.error.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: AppTheme.error.withValues(alpha: 0.75),
                                ),
                              ),
                              child: const Icon(
                                Icons.close_rounded,
                                size: 14,
                                color: AppTheme.error,
                              ),
                            ),
                          ),
                        ),
                      // Etiqueta clicable para seleccionar o cambiar nombre/datos de la caja
                      InkWell(
                        onTap: () {
                          setState(() {
                            _selectedBoxId = boxId;
                            _selectedStackNodeId = null;
                          });
                          if (widget.canEdit) {
                            _showAddOrEditStackZoneBoxDialog(existingBox: zBox);
                          }
                        },
                        borderRadius: BorderRadius.circular(7),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.bgSecondary.withValues(alpha: 0.96),
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(
                              color: col.withValues(alpha: 0.8),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.crop_free_rounded,
                                size: 12,
                                color: col,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  '${zBox['title'] ?? 'ZONA'}',
                                  style: TextStyle(
                                    fontSize: 10.8,
                                    fontWeight: FontWeight.w900,
                                    color: col,
                                    letterSpacing: 0.3,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (cornerText.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: col.withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: Text(
                                    cornerText,
                                    style: const TextStyle(
                                      fontSize: 9.5,
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.textPrimary,
                                    ),
                                  ),
                                ),
                              ],
                              if (widget.canEdit) ...[
                                const SizedBox(width: 6),
                                const Icon(
                                  Icons.edit_outlined,
                                  size: 13,
                                  color: AppTheme.textSecondary,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Tirador de redimensionado DERECHO (ancho) 1:1 con el ratón
                if (widget.canEdit)
                  Positioned(
                    right: -4,
                    top: height * 0.25,
                    bottom: height * 0.25,
                    width: 12,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (details) {
                        setState(() {
                          _selectedBoxId = boxId;
                          _boxResizeStartGlobal = details.globalPosition;
                          _boxResizeStartRect = Rect.fromLTWH(
                            left,
                            top,
                            width,
                            height,
                          );
                        });
                      },
                      onPanUpdate: (details) {
                        if (_boxResizeStartGlobal == null ||
                            _boxResizeStartRect == null) {
                          return;
                        }
                        final dx =
                            details.globalPosition.dx -
                            _boxResizeStartGlobal!.dx;
                        final nw =
                            ((_boxResizeStartRect!.width + dx) / canvasWidth)
                                .clamp(0.10, 0.98 - px)
                                .toDouble();
                        setState(() => zBox['width_rel'] = nw);
                      },
                      onPanEnd: (_) {
                        _boxResizeStartGlobal = null;
                        _boxResizeStartRect = null;
                        _persistStackBoxesAndScale(boxes: _stackBoxes);
                      },
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeLeftRight,
                        child: Center(
                          child: Container(
                            width: 5,
                            height: 28,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? col
                                  : col.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                // Tirador de redimensionado INFERIOR (alto) 1:1 con el ratón
                if (widget.canEdit)
                  Positioned(
                    bottom: -4,
                    left: width * 0.25,
                    right: width * 0.25,
                    height: 12,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (details) {
                        setState(() {
                          _selectedBoxId = boxId;
                          _boxResizeStartGlobal = details.globalPosition;
                          _boxResizeStartRect = Rect.fromLTWH(
                            left,
                            top,
                            width,
                            height,
                          );
                        });
                      },
                      onPanUpdate: (details) {
                        if (_boxResizeStartGlobal == null ||
                            _boxResizeStartRect == null) {
                          return;
                        }
                        final dy =
                            details.globalPosition.dy -
                            _boxResizeStartGlobal!.dy;
                        final nh =
                            ((_boxResizeStartRect!.height + dy) / canvasHeight)
                                .clamp(0.12, 0.98 - py)
                                .toDouble();
                        setState(() => zBox['height_rel'] = nh);
                      },
                      onPanEnd: (_) {
                        _boxResizeStartGlobal = null;
                        _boxResizeStartRect = null;
                        _persistStackBoxesAndScale(boxes: _stackBoxes);
                      },
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeUpDown,
                        child: Center(
                          child: Container(
                            width: 28,
                            height: 5,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? col
                                  : col.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                // Tirador de redimensionado ESQUINA INFERIOR DERECHA (ancho + alto 1:1 con ratón)
                if (widget.canEdit)
                  Positioned(
                    right: -4,
                    bottom: -4,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (details) {
                        setState(() {
                          _selectedBoxId = boxId;
                          _boxResizeStartGlobal = details.globalPosition;
                          _boxResizeStartRect = Rect.fromLTWH(
                            left,
                            top,
                            width,
                            height,
                          );
                        });
                      },
                      onPanUpdate: (details) {
                        if (_boxResizeStartGlobal == null ||
                            _boxResizeStartRect == null) {
                          return;
                        }
                        final delta =
                            details.globalPosition - _boxResizeStartGlobal!;
                        final nw =
                            ((_boxResizeStartRect!.width + delta.dx) /
                                    canvasWidth)
                                .clamp(0.10, 0.98 - px)
                                .toDouble();
                        final nh =
                            ((_boxResizeStartRect!.height + delta.dy) /
                                    canvasHeight)
                                .clamp(0.12, 0.98 - py)
                                .toDouble();
                        setState(() {
                          zBox['width_rel'] = nw;
                          zBox['height_rel'] = nh;
                        });
                      },
                      onPanEnd: (_) {
                        _boxResizeStartGlobal = null;
                        _boxResizeStartRect = null;
                        _persistStackBoxesAndScale(boxes: _stackBoxes);
                      },
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeDownRight,
                        child: Container(
                          width: 22,
                          height: 22,
                          alignment: Alignment.bottomRight,
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: AppTheme.bgSecondary.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: col),
                          ),
                          child: Icon(
                            Icons.south_east_rounded,
                            size: 13,
                            color: col,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showAddOrEditStackZoneBoxDialog({
    Map<String, dynamic>? existingBox,
  }) async {
    final isEdit = existingBox != null;
    final titleCtrl = TextEditingController(
      text:
          (existingBox?['title'] as String?) ??
          'ZONA LÓGICA / AGRUPACIÓN DE SISTEMAS',
    );
    final cornerDataCtrl = TextEditingController(
      text:
          (existingBox?['corner_data'] as String?) ??
          'VLAN 20 • 10.20.20.0/24 • Clúster HA',
    );
    String colorHex = (existingBox?['color_hex'] as String?) ?? '#0EA5E9';
    final colorChoices = [
      ('#0EA5E9', 'Cyan Red'),
      ('#6366F1', 'Índigo / App'),
      ('#14B8A6', 'Teal / BBDD'),
      ('#F59E0B', 'Ámbar / DMZ'),
      ('#EC4899', 'Rosa / Core'),
      ('#10B981', 'Verde / Producción'),
    ];

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          backgroundColor: AppTheme.bgCard,
          title: Text(
            isEdit
                ? 'Editar Caja / Zona con Datos en Esquina Superior'
                : 'Añadir Caja / Zona al Lienzo',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Título de la Caja (Esquina Superior Izquierda)',
                    hintText: 'Ej: FRONTALES WEB / CLÚSTER KUBERNETES',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: cornerDataCtrl,
                  decoration: const InputDecoration(
                    labelText:
                        'Datos Técnicos en la Esquina Superior (VLAN, Subred, Notas)',
                    hintText: 'Ej: VLAN 20 • 10.20.20.0/24 • VIP 10.20.20.10',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Color del Borde y Etiqueta:',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in colorChoices)
                      ChoiceChip(
                        label: Text(
                          c.$2,
                          style: const TextStyle(fontSize: 10.5),
                        ),
                        selected: colorHex == c.$1,
                        selectedColor: _parseBoxHexColor(
                          c.$1,
                        ).withValues(alpha: 0.25),
                        onSelected: (_) =>
                            setModalState(() => colorHex = c.$1),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                if (isEdit) {
                  existingBox['title'] = titleCtrl.text.trim();
                  existingBox['corner_data'] = cornerDataCtrl.text.trim();
                  existingBox['color_hex'] = colorHex;
                  setState(() {});
                  await _persistStackBoxesAndScale(boxes: _stackBoxes);
                } else {
                  final newBox = <String, dynamic>{
                    'id': 'box-${DateTime.now().millisecondsSinceEpoch}',
                    'title': titleCtrl.text.trim(),
                    'corner_data': cornerDataCtrl.text.trim(),
                    'pos_x': 0.08,
                    'pos_y': 0.10,
                    'width_rel': 0.38,
                    'height_rel': 0.46,
                    'color_hex': colorHex,
                  };
                  final updated = [..._stackBoxes, newBox];
                  setState(() {
                    _stackBoxes = updated;
                    _selectedBoxId = newBox['id'] as String;
                  });
                  await _persistStackBoxesAndScale(boxes: updated);
                }
              },
              child: Text(isEdit ? 'Guardar Cambios' : 'Añadir Caja al Lienzo'),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // PÍLDORAS INTERACTIVAS DE ENLACES (CLIC PARA EDITAR PROTOCOLO O ELIMINAR)
  // ===========================================================================

  List<Widget> _buildEdgeInteractivePills({
    required List<Map<String, dynamic>> nodes,
    required List<Map<String, dynamic>> edges,
    required double canvasWidth,
    required double canvasHeight,
  }) {
    final nodesById = <int, Map<String, dynamic>>{};
    for (final n in nodes) {
      nodesById[n['id'] as int] = n;
    }

    final pills = <Widget>[];
    for (final e in edges) {
      final src = nodesById[e['source_node_id'] as int];
      final dst = nodesById[e['target_node_id'] as int];
      if (src == null || dst == null) continue;

      final anchors = _computeSmartEdgeAnchors(
        src: src,
        dst: dst,
        canvasSize: Size(canvasWidth, canvasHeight),
        edgeNotes: (e['notes'] as String?) ?? '',
      );
      final midX = (anchors.$1.dx + anchors.$2.dx) / 2;
      final midY = (anchors.$1.dy + anchors.$2.dy) / 2;
      final isDown = (e['status'] as String?) == 'DOWN';
      final color = isDown ? AppTheme.error : AppTheme.accentCyan;

      pills.add(
        Positioned(
          left: (midX - 54).clamp(4.0, math.max(8.0, canvasWidth - 115)),
          top: (midY - 12).clamp(4.0, math.max(8.0, canvasHeight - 28)),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: widget.canEdit
                ? () => _showEditOrDeleteEdgeDialog(e, nodesById)
                : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
              decoration: BoxDecoration(
                color: AppTheme.bgSecondary.withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: color.withValues(alpha: 0.75)),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 4),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${e['protocol_label']}',
                    style: TextStyle(
                      fontSize: 9.2,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                  if (widget.canEdit) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.edit_outlined,
                      size: 10,
                      color: color.withValues(alpha: 0.8),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }
    return pills;
  }

  Offset _sideAnchorPoint(Rect r, String? side) {
    switch (side) {
      case 'top':
        return r.topCenter;
      case 'bottom':
        return r.bottomCenter;
      case 'left':
        return r.centerLeft;
      case 'right':
        return r.centerRight;
      default:
        return r.centerRight;
    }
  }

  (Offset, Offset) _computeSmartEdgeAnchors({
    required Map<String, dynamic> src,
    required Map<String, dynamic> dst,
    required Size canvasSize,
    String edgeNotes = '',
  }) {
    final srcId = src['id'] as int;
    final dstId = dst['id'] as int;
    final sPos =
        _stackNodePositions[srcId] ??
        Offset(
          ((src['pos_x'] as num?)?.toDouble() ?? 0.2),
          ((src['pos_y'] as num?)?.toDouble() ?? 0.3),
        );
    final dPos =
        _stackNodePositions[dstId] ??
        Offset(
          ((dst['pos_x'] as num?)?.toDouble() ?? 0.5),
          ((dst['pos_y'] as num?)?.toDouble() ?? 0.3),
        );
    final sSize =
        _stackNodeSizes[srcId] ??
        Size(
          (src['width_px'] as num?)?.toDouble() ?? 220.0,
          (src['height_px'] as num?)?.toDouble() ?? 124.0,
        );
    final dSize =
        _stackNodeSizes[dstId] ??
        Size(
          (dst['width_px'] as num?)?.toDouble() ?? 220.0,
          (dst['height_px'] as num?)?.toDouble() ?? 124.0,
        );

    final sRect = Rect.fromLTWH(
      sPos.dx * canvasSize.width,
      sPos.dy * canvasSize.height,
      sSize.width,
      sSize.height,
    );
    final dRect = Rect.fromLTWH(
      dPos.dx * canvasSize.width,
      dPos.dy * canvasSize.height,
      dSize.width,
      dSize.height,
    );

    if (edgeNotes.startsWith('side:') && edgeNotes.contains('->')) {
      final parts = edgeNotes.substring(5).split('->');
      if (parts.length == 2) {
        return (
          _sideAnchorPoint(sRect, parts[0].trim()),
          _sideAnchorPoint(dRect, parts[1].trim()),
        );
      }
    }

    final sCenters = [
      sRect.centerRight,
      sRect.centerLeft,
      sRect.bottomCenter,
      sRect.topCenter,
    ];
    final dCenters = [
      dRect.centerLeft,
      dRect.centerRight,
      dRect.topCenter,
      dRect.bottomCenter,
    ];

    Offset bestS = sRect.centerRight;
    Offset bestD = dRect.centerLeft;
    double bestDist = double.infinity;
    for (final sc in sCenters) {
      for (final dc in dCenters) {
        final dist = (sc - dc).distanceSquared;
        if (dist < bestDist) {
          bestDist = dist;
          bestS = sc;
          bestD = dc;
        }
      }
    }
    return (bestS, bestD);
  }

  Future<void> _showEditOrDeleteEdgeDialog(
    Map<String, dynamic> edge,
    Map<int, Map<String, dynamic>> nodesById,
  ) async {
    final srcNode = nodesById[edge['source_node_id'] as int];
    final dstNode = nodesById[edge['target_node_id'] as int];
    final protoCtrl = TextEditingController(
      text: (edge['protocol_label'] as String?) ?? 'HTTPS :443',
    );
    final portCtrl = TextEditingController(
      text: '${edge['target_port'] ?? 443}',
    );

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        title: const Text(
          'Editar o Eliminar Enlace entre Elementos',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Origen: ${(srcNode?['host'] as Map?)?['code'] ?? srcNode?['custom_label']}  ➔  Destino: ${(dstNode?['host'] as Map?)?['code'] ?? dstNode?['custom_label']}',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.accentCyan,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: protoCtrl,
                decoration: const InputDecoration(
                  labelText: 'Etiqueta de Protocolo / Servicio',
                  hintText: 'Ej: HTTPS :443 / PostgreSQL :5432 / gRPC :9000',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: portCtrl,
                decoration: const InputDecoration(
                  labelText: 'Puerto Destino',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              final res = await widget.api.deleteTechStackEdge(
                edge['id'] as int,
              );
              if (mounted) {
                setState(() {
                  _overview = res;
                  _syncStackCanvasState();
                });
              }
            },
            icon: const Icon(
              Icons.delete_outline,
              size: 15,
              color: AppTheme.error,
            ),
            label: const Text(
              'Eliminar Enlace',
              style: TextStyle(color: AppTheme.error),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final res = await widget.api.updateTechStackEdge(
                edge['id'] as int,
                {
                  'protocol_label': protoCtrl.text.trim(),
                  'target_port': int.tryParse(portCtrl.text.trim()) ?? 443,
                },
              );
              if (mounted) {
                setState(() {
                  _overview = res;
                  _syncStackCanvasState();
                });
              }
            },
            child: const Text('Guardar Enlace'),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // TARJETA DE NODO ARRASTRABLE (1:1 CON RATÓN), REDIMENSIONABLE Y CON
  // 4 PEQUEÑOS CUADRADOS EN EL MEDIO DE LOS LADOS PARA LAS FLECHAS DE UNIÓN
  // ===========================================================================

  Widget _buildDraggableStackNodeCard({
    required Map<String, dynamic> sn,
    required List<Map<String, dynamic>> allNodes,
    required double canvasWidth,
    required double canvasHeight,
  }) {
    final nodeId = sn['id'] as int;
    final host = Map<String, dynamic>.from((sn['host'] as Map?) ?? {});
    final pos =
        _stackNodePositions[nodeId] ??
        Offset(
          ((sn['pos_x'] as num?)?.toDouble() ?? 0.2).clamp(0.01, 0.90),
          ((sn['pos_y'] as num?)?.toDouble() ?? 0.3).clamp(0.01, 0.88),
        );
    final nodeSize =
        _stackNodeSizes[nodeId] ??
        Size(
          ((sn['width_px'] as num?)?.toDouble() ?? 220.0).clamp(160.0, 500.0),
          ((sn['height_px'] as num?)?.toDouble() ?? 124.0).clamp(96.0, 340.0),
        );

    final left = (pos.dx * canvasWidth)
        .clamp(4.0, math.max(8.0, canvasWidth - nodeSize.width - 4))
        .toDouble();
    final top = (pos.dy * canvasHeight)
        .clamp(4.0, math.max(8.0, canvasHeight - nodeSize.height - 4))
        .toDouble();

    final state = (host['nagios_host_state'] as String?) ?? 'UP';
    final stateCol = _nagiosStateColor(state);
    final mini = Map<String, dynamic>.from((host['mini_series'] as Map?) ?? {});
    final cpuSeries = ((mini['cpu'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList();
    final checks = ((host['service_checks'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final isSelected = _selectedStackNodeId == nodeId;
    final isLinkSource = _isLinkModeActive && _linkSourceNodeId == nodeId;
    final rackId = host['rack_id'] as int?;
    final targetRackDevId = host['target_rack_device_id'] as int?;

    return Positioned(
      left: left,
      top: top,
      width: nodeSize.width,
      height: nodeSize.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          if (_isLinkModeActive) {
            if (_linkSourceNodeId == null) {
              setState(() {
                _linkSourceNodeId = nodeId;
                _linkSourceSide = 'right';
                _selectedStackNodeId = nodeId;
              });
            } else if (_linkSourceNodeId != nodeId) {
              final srcId = _linkSourceNodeId!;
              final srcSide = _linkSourceSide;
              setState(() {
                _isLinkModeActive = false;
                _linkSourceNodeId = null;
                _linkSourceSide = null;
                _linkLiveMousePos = null;
                _selectedStackNodeId = nodeId;
              });
              await _instantConnectNodes(
                srcId,
                nodeId,
                allNodes,
                sourceSide: srcSide,
                targetSide: null,
              );
            }
            return;
          }
          setState(() {
            _selectedStackNodeId = nodeId;
            _selectedBoxId = null;
            _selectedHostId = host['id'] as int?;
          });
          if (host['id'] != null) {
            _loadHostTelemetry(host['id'] as int);
          }
        },
        onDoubleTap: () {
          setState(() {
            _selectedStackNodeId = nodeId;
            _selectedHostId = host['id'] as int?;
            _showFloatingTechWindow = true;
            _floatingWinMinimized = false;
          });
          if (host['id'] != null) {
            _loadHostTelemetry(host['id'] as int);
          }
        },
        onPanStart: widget.canEdit
            ? (details) {
                setState(() {
                  _selectedStackNodeId = nodeId;
                  _selectedBoxId = null;
                  _nodeDragStartGlobal = details.globalPosition;
                  _nodeDragStartPx = Offset(left, top);
                });
              }
            : null,
        onPanUpdate: widget.canEdit
            ? (details) {
                if (_nodeDragStartGlobal == null || _nodeDragStartPx == null) {
                  return;
                }
                final globalDelta =
                    details.globalPosition - _nodeDragStartGlobal!;
                final newLeft = (_nodeDragStartPx!.dx + globalDelta.dx).clamp(
                  4.0,
                  math.max(8.0, canvasWidth - nodeSize.width - 4.0),
                );
                final newTop = (_nodeDragStartPx!.dy + globalDelta.dy).clamp(
                  4.0,
                  math.max(8.0, canvasHeight - nodeSize.height - 4.0),
                );
                final newPx = (newLeft / canvasWidth)
                    .clamp(0.005, 0.96)
                    .toDouble();
                final newPy = (newTop / canvasHeight)
                    .clamp(0.005, 0.95)
                    .toDouble();
                setState(() {
                  _stackNodePositions[nodeId] = Offset(newPx, newPy);
                  sn['pos_x'] = newPx;
                  sn['pos_y'] = newPy;
                });
              }
            : null,
        onPanEnd: widget.canEdit
            ? (_) async {
                _nodeDragStartGlobal = null;
                _nodeDragStartPx = null;
                final finalPos = _stackNodePositions[nodeId];
                final finalSize = _stackNodeSizes[nodeId] ?? nodeSize;
                if (finalPos == null) return;
                final res = await widget.api.moveTechStackNode(nodeId, {
                  'pos_x': finalPos.dx,
                  'pos_y': finalPos.dy,
                  'width_px': finalSize.width,
                  'height_px': finalSize.height,
                });
                if (mounted) {
                  setState(() {
                    _overview = res;
                    _syncStackCanvasState();
                  });
                }
              }
            : null,
        child: Container(
          padding: const EdgeInsets.fromLTRB(9, 7, 9, 6),
          decoration: BoxDecoration(
            color: AppTheme.bgSecondary,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isLinkSource
                  ? AppTheme.warning
                  : (isSelected ? AppTheme.accentBlue : stateCol),
              width: (isSelected || isLinkSource) ? 2.2 : 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: (isSelected ? AppTheme.accentBlue : stateCol).withValues(
                  alpha: 0.18,
                ),
                blurRadius: isSelected ? 12 : 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Cabecera del nodo: Estado + Código + Latencia + Acciones rápidas
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4.5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: stateCol.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: stateCol),
                        ),
                        child: Text(
                          state,
                          style: TextStyle(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w900,
                            color: stateCol,
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          '${host['code']}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (host['last_ping_ms'] != null)
                        Text(
                          '${host['last_ping_ms']}ms',
                          style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.accentTeal,
                          ),
                        ),
                      const SizedBox(width: 4),
                      // Botón para abrir la Ventana Flotante Movible de Datos Técnicos y Gráficas
                      InkWell(
                        onTap: () {
                          setState(() {
                            _selectedStackNodeId = nodeId;
                            _selectedHostId = host['id'] as int?;
                            _showFloatingTechWindow = true;
                            _floatingWinMinimized = false;
                          });
                          if (host['id'] != null) {
                            _loadHostTelemetry(host['id'] as int);
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.all(2.5),
                          decoration: BoxDecoration(
                            color: AppTheme.accentBlue.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Icon(
                            Icons.analytics_outlined,
                            size: 12,
                            color: AppTheme.accentBlue,
                          ),
                        ),
                      ),
                      if (widget.canEdit) ...[
                        const SizedBox(width: 3),
                        InkWell(
                          onTap: () async {
                            final res = await widget.api.deleteTechStackNode(
                              nodeId,
                            );
                            if (mounted) {
                              setState(() {
                                _overview = res;
                                if (_selectedStackNodeId == nodeId) {
                                  _selectedStackNodeId = null;
                                }
                                _syncStackCanvasState();
                              });
                            }
                          },
                          child: const Icon(
                            Icons.close,
                            size: 12.5,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                  // Nombre/Rol y dirección IP + Alojamiento
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${sn['custom_label'] ?? host['name']}',
                        style: const TextStyle(
                          fontSize: 10.2,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.accentBlue,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${host['heartbeat_ip']} • ${host['rack_location_badge']}',
                        style: const TextStyle(
                          fontSize: 8.8,
                          fontFamily: 'monospace',
                          color: AppTheme.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                  // Sparkline Prometheus refinado con valores en vivo
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'CPU ${host['cpu_pct']}% • RAM ${host['ram_pct']}%',
                            style: const TextStyle(
                              fontSize: 8.8,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                          Text(
                            host['monitoring_enabled'] == false
                                ? 'HB Off'
                                : '${checks.length} chk',
                            style: const TextStyle(
                              fontSize: 8.5,
                              color: AppTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      SizedBox(
                        height: 18,
                        width: double.infinity,
                        child: CustomPaint(
                          painter: _MiniSparklinePainter(
                            values: cpuSeries,
                            color: AppTheme.accentBlue,
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Barra inferior de acciones rápidas (SSH, Gráficas Flotantes, Rack)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (sn['ssh_enabled'] != false &&
                          host['ssh_enabled'] != false &&
                          host['connect_enabled'] != false)
                        InkWell(
                          onTap: () => _showSshWebConsoleDialog(sn, host),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0F172A),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.terminal_rounded,
                                  size: 10,
                                  color: Color(0xFF38BDF8),
                                ),
                                SizedBox(width: 3),
                                Text(
                                  'SSH',
                                  style: TextStyle(
                                    fontSize: 8.8,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      else
                        const Text(
                          'SSH Off',
                          style: TextStyle(
                            fontSize: 8.5,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      InkWell(
                        onTap: () {
                          setState(() {
                            _selectedStackNodeId = nodeId;
                            _selectedHostId = host['id'] as int?;
                            _showFloatingTechWindow = true;
                            _floatingWinMinimized = false;
                          });
                          if (host['id'] != null) {
                            _loadHostTelemetry(host['id'] as int);
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.accentTeal.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            '📊 Datos & Gráficas',
                            style: TextStyle(
                              fontSize: 8.8,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.accentTeal,
                            ),
                          ),
                        ),
                      ),
                      if (rackId != null &&
                          widget.onNavigateToRackDevice != null)
                        InkWell(
                          onTap: () => widget.onNavigateToRackDevice!(
                            rackId,
                            targetRackDevId,
                          ),
                          child: const Text(
                            'Rack ↗',
                            style: TextStyle(
                              fontSize: 8.8,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.accentBlue,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),

              // ===============================================================
              // 4 PEQUEÑOS CUADRADOS EN EL MEDIO DE LOS LADOS (TOP, BOTTOM, LEFT, RIGHT)
              // Al seleccionarlos o arrastrarlos aparecen las flechas de unión
              // ===============================================================
              if (widget.canEdit) ...[
                // Lado SUPERIOR (medio)
                Positioned(
                  left: (nodeSize.width / 2) - 15,
                  top: -14,
                  child: _buildNodeSideConnectorSquare(
                    nodeId: nodeId,
                    side: 'top',
                    allNodes: allNodes,
                    nodeRectInCanvas: Rect.fromLTWH(
                      left,
                      top,
                      nodeSize.width,
                      nodeSize.height,
                    ),
                    canvasWidth: canvasWidth,
                    canvasHeight: canvasHeight,
                  ),
                ),
                // Lado INFERIOR (medio)
                Positioned(
                  left: (nodeSize.width / 2) - 15,
                  bottom: -14,
                  child: _buildNodeSideConnectorSquare(
                    nodeId: nodeId,
                    side: 'bottom',
                    allNodes: allNodes,
                    nodeRectInCanvas: Rect.fromLTWH(
                      left,
                      top,
                      nodeSize.width,
                      nodeSize.height,
                    ),
                    canvasWidth: canvasWidth,
                    canvasHeight: canvasHeight,
                  ),
                ),
                // Lado IZQUIERDO (medio)
                Positioned(
                  left: -14,
                  top: (nodeSize.height / 2) - 15,
                  child: _buildNodeSideConnectorSquare(
                    nodeId: nodeId,
                    side: 'left',
                    allNodes: allNodes,
                    nodeRectInCanvas: Rect.fromLTWH(
                      left,
                      top,
                      nodeSize.width,
                      nodeSize.height,
                    ),
                    canvasWidth: canvasWidth,
                    canvasHeight: canvasHeight,
                  ),
                ),
                // Lado DERECHO (medio)
                Positioned(
                  right: -14,
                  top: (nodeSize.height / 2) - 15,
                  child: _buildNodeSideConnectorSquare(
                    nodeId: nodeId,
                    side: 'right',
                    allNodes: allNodes,
                    nodeRectInCanvas: Rect.fromLTWH(
                      left,
                      top,
                      nodeSize.width,
                      nodeSize.height,
                    ),
                    canvasWidth: canvasWidth,
                    canvasHeight: canvasHeight,
                  ),
                ),
              ],

              // Tirador de redimensionado en la esquina inferior derecha del nodo (1:1 con ratón)
              if (widget.canEdit)
                Positioned(
                  right: -4,
                  bottom: -4,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (details) {
                      setState(() {
                        _selectedStackNodeId = nodeId;
                        _nodeResizeStartGlobal = details.globalPosition;
                        _nodeResizeStartSize = nodeSize;
                      });
                    },
                    onPanUpdate: (details) {
                      if (_nodeResizeStartGlobal == null ||
                          _nodeResizeStartSize == null) {
                        return;
                      }
                      final delta =
                          details.globalPosition - _nodeResizeStartGlobal!;
                      final nw = (_nodeResizeStartSize!.width + delta.dx)
                          .clamp(160.0, 500.0)
                          .toDouble();
                      final nh = (_nodeResizeStartSize!.height + delta.dy)
                          .clamp(96.0, 340.0)
                          .toDouble();
                      setState(() {
                        _stackNodeSizes[nodeId] = Size(nw, nh);
                        sn['width_px'] = nw;
                        sn['height_px'] = nh;
                      });
                    },
                    onPanEnd: (_) async {
                      _nodeResizeStartGlobal = null;
                      _nodeResizeStartSize = null;
                      final finalPos = _stackNodePositions[nodeId] ?? pos;
                      final finalSize = _stackNodeSizes[nodeId] ?? nodeSize;
                      final res = await widget.api.moveTechStackNode(nodeId, {
                        'pos_x': finalPos.dx,
                        'pos_y': finalPos.dy,
                        'width_px': finalSize.width,
                        'height_px': finalSize.height,
                      });
                      if (mounted) {
                        setState(() {
                          _overview = res;
                          _syncStackCanvasState();
                        });
                      }
                    },
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeDownRight,
                      child: Container(
                        width: 16,
                        height: 16,
                        alignment: Alignment.bottomRight,
                        child: const Icon(
                          Icons.south_east_rounded,
                          size: 10,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNodeSideConnectorSquare({
    required int nodeId,
    required String side,
    required List<Map<String, dynamic>> allNodes,
    required Rect nodeRectInCanvas,
    required double canvasWidth,
    required double canvasHeight,
  }) {
    final isOriginPort =
        _isLinkModeActive &&
        _linkSourceNodeId == nodeId &&
        _linkSourceSide == side;
    final isHovered =
        _hoveredSideNodeId == nodeId && _hoveredSideName == side;

    final anchorInCanvas = _sideAnchorPoint(nodeRectInCanvas, side);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        // Si aún no hay origen o se pulsa el mismo cuadrado: activar flecha en vivo desde este cuadrado lateral
        if (!_isLinkModeActive || _linkSourceNodeId == null) {
          setState(() {
            _isLinkModeActive = true;
            _linkSourceNodeId = nodeId;
            _linkSourceSide = side;
            _linkLiveMousePos = anchorInCanvas;
            _selectedStackNodeId = nodeId;
          });
          return;
        }
        // Si se vuelve a pulsar el mismo nodo origen, cambia el lado de salida
        if (_linkSourceNodeId == nodeId) {
          if (_linkSourceSide == side) {
            setState(() {
              _isLinkModeActive = false;
              _linkSourceNodeId = null;
              _linkSourceSide = null;
              _linkLiveMousePos = null;
            });
          } else {
            setState(() {
              _linkSourceSide = side;
              _linkLiveMousePos = anchorInCanvas;
            });
          }
          return;
        }
        // Si ya había un cuadrado lateral origen en otro nodo -> Conectar inmediatamente con flecha de unión
        final srcId = _linkSourceNodeId!;
        final srcSide = _linkSourceSide;
        setState(() {
          _isLinkModeActive = false;
          _linkSourceNodeId = null;
          _linkSourceSide = null;
          _linkLiveMousePos = null;
          _selectedStackNodeId = nodeId;
        });
        await _instantConnectNodes(
          srcId,
          nodeId,
          allNodes,
          sourceSide: srcSide,
          targetSide: side,
        );
      },
      onPanStart: (details) {
        final box =
            _stackCanvasKey.currentContext?.findRenderObject() as RenderBox?;
        final local = box != null
            ? box.globalToLocal(details.globalPosition)
            : anchorInCanvas;
        setState(() {
          _isLinkModeActive = true;
          _linkSourceNodeId = nodeId;
          _linkSourceSide = side;
          _linkLiveMousePos = local;
          _selectedStackNodeId = nodeId;
        });
      },
      onPanUpdate: (details) {
        final box =
            _stackCanvasKey.currentContext?.findRenderObject() as RenderBox?;
        if (box != null) {
          setState(() {
            _linkLiveMousePos = box.globalToLocal(details.globalPosition);
          });
        }
      },
      onPanEnd: (_) async {
        final dropPt = _linkLiveMousePos;
        if (dropPt == null || _linkSourceNodeId == null) return;
        // Buscar si hemos soltado la flecha sobre otro elemento o cerca de alguno de sus 4 cuadrados laterales
        int? targetNodeId;
        String? targetSide;
        double bestDist = double.infinity;

        for (final other in allNodes) {
          final oid = other['id'] as int;
          if (oid == nodeId) continue;
          final oPos =
              _stackNodePositions[oid] ??
              Offset(
                ((other['pos_x'] as num?)?.toDouble() ?? 0.2),
                ((other['pos_y'] as num?)?.toDouble() ?? 0.3),
              );
          final oSize =
              _stackNodeSizes[oid] ??
              Size(
                ((other['width_px'] as num?)?.toDouble() ?? 220.0),
                ((other['height_px'] as num?)?.toDouble() ?? 124.0),
              );
          final oRect = Rect.fromLTWH(
            oPos.dx * canvasWidth,
            oPos.dy * canvasHeight,
            oSize.width,
            oSize.height,
          );
          if (oRect.inflate(18).contains(dropPt)) {
            targetNodeId = oid;
            for (final sName in ['left', 'right', 'top', 'bottom']) {
              final sp = _sideAnchorPoint(oRect, sName);
              final d = (sp - dropPt).distance;
              if (d < bestDist) {
                bestDist = d;
                targetSide = sName;
              }
            }
            break;
          }
        }

        if (targetNodeId != null) {
          final srcId = _linkSourceNodeId!;
          final srcSide = _linkSourceSide;
          setState(() {
            _isLinkModeActive = false;
            _linkSourceNodeId = null;
            _linkSourceSide = null;
            _linkLiveMousePos = null;
            _selectedStackNodeId = targetNodeId;
          });
          await _instantConnectNodes(
            srcId,
            targetNodeId,
            allNodes,
            sourceSide: srcSide,
            targetSide: targetSide,
          );
        }
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.precise,
        onEnter: (_) => setState(() {
          _hoveredSideNodeId = nodeId;
          _hoveredSideName = side;
        }),
        onExit: (_) => setState(() {
          if (_hoveredSideNodeId == nodeId && _hoveredSideName == side) {
            _hoveredSideNodeId = null;
            _hoveredSideName = null;
          }
        }),
        child: Tooltip(
          message:
              'Cuadrado de unión ($side): Clic o arrastra a otro elemento para lanzar flecha de unión',
          child: Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            color: Colors.transparent,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 110),
              width: (isOriginPort || isHovered) ? 12 : 9,
              height: (isOriginPort || isHovered) ? 12 : 9,
              decoration: BoxDecoration(
                color: isOriginPort
                    ? AppTheme.warning
                    : (isHovered ? AppTheme.accentCyan : AppTheme.bgSecondary),
                borderRadius: BorderRadius.circular(2.5),
                border: Border.all(
                  color: isOriginPort
                      ? Colors.black
                      : (isHovered
                            ? AppTheme.accentBlue
                            : AppTheme.accentCyan),
                  width: (isOriginPort || isHovered) ? 2.0 : 1.5,
                ),
                boxShadow: (isOriginPort || isHovered)
                    ? [
                        BoxShadow(
                          color:
                              (isOriginPort
                                      ? AppTheme.warning
                                      : AppTheme.accentCyan)
                                  .withValues(alpha: 0.45),
                          blurRadius: 6,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _instantConnectNodes(
    int sourceNodeId,
    int targetNodeId,
    List<Map<String, dynamic>> nodes, {
    String? sourceSide,
    String? targetSide,
  }) async {
    final activeStack = _activeStack;
    final stackId = activeStack['id'] as int?;
    if (stackId == null || sourceNodeId == targetNodeId) return;
    final dstNode = nodes.firstWhere(
      (n) => n['id'] == targetNodeId,
      orElse: () => <String, dynamic>{},
    );
    final dstHost = Map<String, dynamic>.from((dstNode['host'] as Map?) ?? {});
    final dstCode = ('${dstHost['code'] ?? ''} ${dstHost['name'] ?? ''}')
        .toUpperCase();

    String proto = 'HTTPS / TCP :443';
    int port = 443;
    if (dstCode.contains('PGSQL') || dstCode.contains('POSTGRES')) {
      proto = 'PostgreSQL :5432';
      port = 5432;
    } else if (dstCode.contains('REDIS')) {
      proto = 'Redis :6379';
      port = 6379;
    } else if (dstCode.contains('MYSQL') || dstCode.contains('MARIADB')) {
      proto = 'MySQL :3306';
      port = 3306;
    } else if (dstCode.contains('API') || dstCode.contains('BACKEND')) {
      proto = 'HTTP/gRPC :8080';
      port = 8080;
    }

    final sideNotes = (sourceSide != null || targetSide != null)
        ? 'side:${sourceSide ?? "right"}->${targetSide ?? "left"}'
        : '';

    final res = await widget.api.createTechStackEdge({
      'stack_id': stackId,
      'source_node_id': sourceNodeId,
      'target_node_id': targetNodeId,
      'protocol_label': proto,
      'port': port,
      'target_port': port,
      'notes': sideNotes,
    });
    if (mounted) {
      setState(() {
        _overview = res;
        _syncStackCanvasState();
      });
      _showSnack(
        'Flecha de unión creada ($proto). Haz clic en su etiqueta si quieres cambiar el puerto/protocolo.',
      );
    }
  }

  Future<void> _quickCreateEdgeBetweenNodes(
    int sourceNodeId,
    int targetNodeId,
    List<Map<String, dynamic>> nodes,
  ) async {
    await _instantConnectNodes(sourceNodeId, targetNodeId, nodes);
  }

  // ===========================================================================
  // VENTANA FLOTANTE MOVIBLE (1:1 CON RATÓN) CON DATOS TÉCNICOS Y PROMETHEUS
  // ===========================================================================

  Widget _buildFloatingTechnicalAndChartsWindow({
    required Map<String, dynamic> sn,
    required double canvasWidth,
    required double canvasHeight,
  }) {
    final host = Map<String, dynamic>.from((sn['host'] as Map?) ?? {});
    final checks = ((host['service_checks'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final state = (host['nagios_host_state'] as String?) ?? 'UP';
    final stateCol = _nagiosStateColor(state);

    final telemetryPoints =
        (_telemetryData != null &&
            (_telemetryData!['host'] as Map?)?['id'] == host['id'])
        ? (((_telemetryData!['points'] as List?) ??
                  (_telemetryData!['series'] as List?) ??
                  [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList())
        : _buildFallbackSeriesFromMini(host);

    final winWidth = _floatingWinMinimized ? 320.0 : 520.0;
    final left = _floatingWinPos.dx
        .clamp(8.0, math.max(12.0, canvasWidth - winWidth - 8))
        .toDouble();
    final top = _floatingWinPos.dy
        .clamp(8.0, math.max(12.0, canvasHeight - 80))
        .toDouble();

    return Positioned(
      left: left,
      top: top,
      child: Material(
        elevation: 16,
        borderRadius: BorderRadius.circular(12),
        color: Colors.transparent,
        child: Container(
          width: winWidth,
          decoration: BoxDecoration(
            color: AppTheme.bgSecondary.withValues(alpha: 0.98),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.accentBlue, width: 1.8),
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 20,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Barra de título ARRASTRABLE 1:1 con el ratón para mover la ventana flotante
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (details) {
                  _floatWinDragStartGlobal = details.globalPosition;
                  _floatWinDragStartPos = Offset(left, top);
                },
                onPanUpdate: (details) {
                  if (_floatWinDragStartGlobal == null ||
                      _floatWinDragStartPos == null) {
                    return;
                  }
                  final delta =
                      details.globalPosition - _floatWinDragStartGlobal!;
                  setState(() {
                    _floatingWinPos = Offset(
                      (_floatWinDragStartPos!.dx + delta.dx).clamp(
                        6.0,
                        math.max(12.0, canvasWidth - winWidth - 6),
                      ),
                      (_floatWinDragStartPos!.dy + delta.dy).clamp(
                        6.0,
                        math.max(12.0, canvasHeight - 60),
                      ),
                    );
                  });
                },
                onPanEnd: (_) {
                  _floatWinDragStartGlobal = null;
                  _floatWinDragStartPos = null;
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.bgCard,
                    borderRadius: BorderRadius.vertical(
                      top: const Radius.circular(11),
                      bottom: _floatingWinMinimized
                          ? const Radius.circular(11)
                          : Radius.zero,
                    ),
                    border: const Border(
                      bottom: BorderSide(color: AppTheme.border),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.drag_indicator_rounded,
                        size: 16,
                        color: AppTheme.accentCyan,
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: stateCol.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: stateCol),
                        ),
                        child: Text(
                          state,
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            color: stateCol,
                          ),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          '${host['code']} • ${sn['custom_label'] ?? host['name']}',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: _floatingWinMinimized
                            ? 'Expandir ventana flotante'
                            : 'Minimizar ventana flotante',
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        icon: Icon(
                          _floatingWinMinimized
                              ? Icons.open_in_full_rounded
                              : Icons.minimize_rounded,
                          size: 14,
                          color: AppTheme.textSecondary,
                        ),
                        onPressed: () => setState(
                          () => _floatingWinMinimized = !_floatingWinMinimized,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Cerrar ventana flotante',
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.only(left: 4),
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 15,
                          color: AppTheme.textSecondary,
                        ),
                        onPressed: () =>
                            setState(() => _showFloatingTechWindow = false),
                      ),
                    ],
                  ),
                ),
              ),
              if (!_floatingWinMinimized)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Selector de pestaña interna + rango horario de Prometheus
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Wrap(
                            spacing: 6,
                            children: [
                              ChoiceChip(
                                label: const Text(
                                  '📊 Gráficas Prometheus',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                selected: _floatingWinTab == 'charts',
                                onSelected: (_) =>
                                    setState(() => _floatingWinTab = 'charts'),
                              ),
                              ChoiceChip(
                                label: Text(
                                  '🖧 Datos Técnicos & Checks (${checks.length})',
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                selected: _floatingWinTab == 'tech',
                                onSelected: (_) =>
                                    setState(() => _floatingWinTab = 'tech'),
                              ),
                            ],
                          ),
                          if (_floatingWinTab == 'charts')
                            Wrap(
                              spacing: 4,
                              children: [
                                for (final r in [
                                  (1, '1h'),
                                  (6, '6h'),
                                  (24, '24h'),
                                  (168, '7d'),
                                ])
                                  InkWell(
                                    onTap: () {
                                      setState(
                                        () => _telemetryRangeHours = r.$1,
                                      );
                                      if (host['id'] != null) {
                                        _loadHostTelemetry(host['id'] as int);
                                      }
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _telemetryRangeHours == r.$1
                                            ? AppTheme.accentBlue
                                            : AppTheme.bgCard,
                                        borderRadius: BorderRadius.circular(5),
                                        border: Border.all(
                                          color: AppTheme.border,
                                        ),
                                      ),
                                      child: Text(
                                        r.$2,
                                        style: TextStyle(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w800,
                                          color: _telemetryRangeHours == r.$1
                                              ? Colors.white
                                              : AppTheme.textSecondary,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (_floatingWinTab == 'charts') ...[
                        _buildRefinedCompactChartBox(
                          title: 'CPU & Memoria RAM (%)',
                          points: telemetryPoints,
                          keyA: 'cpu_pct',
                          labelA: 'CPU',
                          colorA: AppTheme.accentBlue,
                          keyB: 'ram_pct',
                          labelB: 'RAM',
                          colorB: AppTheme.accentPurple,
                          unit: '%',
                          warnThreshold: 75,
                          critThreshold: 90,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: _buildRefinedCompactChartBox(
                                title: 'Latencia ICMP / HTTP (ms)',
                                points: telemetryPoints,
                                keyA: 'latency_ms',
                                labelA: 'RTT',
                                colorA: AppTheme.accentTeal,
                                unit: 'ms',
                                height: 82,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _buildRefinedCompactChartBox(
                                title: 'Tráfico Red RX/TX (Mbps)',
                                points: telemetryPoints,
                                keyA: 'rx_mbps',
                                labelA: 'RX',
                                colorA: AppTheme.accentCyan,
                                keyB: 'tx_mbps',
                                labelB: 'TX',
                                colorB: AppTheme.warning,
                                unit: 'Mbps',
                                height: 82,
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppTheme.bgCard,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.border),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'IP Principal: ${host['heartbeat_ip']} • FQDN: ${host['fqdn'] ?? host['hostname']}',
                                style: const TextStyle(
                                  fontSize: 10.2,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'SO / Plataforma: ${host['os_or_firmware']} • ${host['rack_location_badge']}',
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Recursos: ${host['cpu_cores'] ?? 4} vCPU • ${host['ram_gb'] ?? 16} GB RAM • Disco ${host['disk_pct']}% ocupado',
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 120,
                          child: ListView(
                            children: [
                              for (final c in checks)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.circle,
                                        size: 8,
                                        color: _nagiosStateColor(
                                          (c['nagios_state'] as String?) ??
                                              'OK',
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          '${c['service_name']} (${c['check_type']} :${c['port'] ?? '-'}): ${c['status_output']}',
                                          style: const TextStyle(
                                            fontSize: 10,
                                            color: AppTheme.textSecondary,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      // Pie de la ventana flotante con acceso SSH y salto a Tab 5
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (sn['ssh_enabled'] != false &&
                              host['ssh_enabled'] != false)
                            ElevatedButton.icon(
                              onPressed: () =>
                                  _showSshWebConsoleDialog(sn, host),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF0F172A),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                              ),
                              icon: const Icon(
                                Icons.terminal_rounded,
                                size: 13,
                                color: Color(0xFF38BDF8),
                              ),
                              label: Text(
                                'SSH ${sn['ssh_user'] ?? 'root'}@${host['ssh_host'] ?? host['heartbeat_ip']}',
                                style: const TextStyle(fontSize: 10),
                              ),
                            ),
                          OutlinedButton.icon(
                            onPressed: () {
                              setState(
                                () => _selectedHostId = host['id'] as int,
                              );
                              _tabController.animateTo(4);
                              _loadHostTelemetry(host['id'] as int);
                            },
                            icon: const Icon(
                              Icons.open_in_new_rounded,
                              size: 13,
                            ),
                            label: const Text(
                              'Ver Pantalla Completa Prometheus',
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _buildFallbackSeriesFromMini(
    Map<String, dynamic> host,
  ) {
    final mini = Map<String, dynamic>.from((host['mini_series'] as Map?) ?? {});
    final cpu = ((mini['cpu'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList();
    final ram = ((mini['ram'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList();
    final lat = ((mini['latency'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList();
    final traf = ((mini['traffic'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList();
    final len = [
      cpu.length,
      ram.length,
      lat.length,
      traf.length,
    ].fold<int>(0, math.max);
    if (len == 0) return [];
    return List.generate(len, (i) {
      return {
        'label': '${i * 5}m',
        'cpu_pct': i < cpu.length ? cpu[i] : 20.0,
        'ram_pct': i < ram.length ? ram[i] : 45.0,
        'latency_ms': i < lat.length ? lat[i] : 1.2,
        'rx_mbps': i < traf.length ? traf[i] : 30.0,
        'tx_mbps': i < traf.length ? (traf[i] * 0.62) : 18.0,
      };
    });
  }

  Widget _buildRefinedCompactChartBox({
    required String title,
    required List<Map<String, dynamic>> points,
    required String keyA,
    required String labelA,
    required Color colorA,
    String? keyB,
    String? labelB,
    Color? colorB,
    required String unit,
    double height = 98,
    double? warnThreshold,
    double? critThreshold,
  }) {
    final valsA = points
        .map((p) => (p[keyA] as num?)?.toDouble() ?? 0.0)
        .toList();
    final curA = valsA.isNotEmpty ? valsA.last : 0.0;
    final maxA = valsA.isNotEmpty ? valsA.reduce(math.max) : 0.0;
    final avgA = valsA.isNotEmpty
        ? valsA.reduce((a, b) => a + b) / valsA.length
        : 0.0;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '$labelA: ${curA.toStringAsFixed(1)}$unit (Máx ${maxA.toStringAsFixed(1)} • Med ${avgA.toStringAsFixed(1)})',
                style: TextStyle(
                  fontSize: 9.2,
                  fontWeight: FontWeight.w800,
                  color: colorA,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          SizedBox(
            height: height,
            width: double.infinity,
            child: CustomPaint(
              painter: _PrometheusSeriesChartPainter(
                points: points,
                keyA: keyA,
                colorA: colorA,
                keyB: keyB,
                colorB: colorB,
                unit: unit,
                warnThreshold: warnThreshold,
                critThreshold: critThreshold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // PANEL DERECHO DE CONFIGURACIÓN DEL ELEMENTO (ESTILO DATACENTER FLOOR)
  // ===========================================================================

  Widget _buildStackRightSettingsPanel({
    required Map<String, dynamic> activeStack,
    required List<Map<String, dynamic>> nodes,
    required List<Map<String, dynamic>> edges,
    required Map<String, dynamic> selectedNode,
  }) {
    // Si hay una Caja/Zona seleccionada, mostramos sus ajustes editables en directo
    if (_selectedBoxId != null) {
      final box = _stackBoxes.firstWhere(
        (b) => '${b['id']}' == _selectedBoxId,
        orElse: () => <String, dynamic>{},
      );
      if (box.isNotEmpty) {
        final boxId = '${box['id']}';
        final wRel = ((box['width_rel'] as num?)?.toDouble() ?? 0.38).clamp(
          0.10,
          0.96,
        );
        final hRel = ((box['height_rel'] as num?)?.toDouble() ?? 0.45).clamp(
          0.12,
          0.96,
        );
        final colorHex = (box['color_hex'] as String?) ?? '#0EA5E9';
        final colorChoices = [
          ('#0EA5E9', 'Cyan'),
          ('#2563EB', 'Azul'),
          ('#7C3AED', 'Violeta'),
          ('#0D9488', 'Teal'),
          ('#F59E0B', 'Ámbar'),
          ('#EC4899', 'Rosa'),
        ];

        return Container(
          width: 340,
          decoration: const BoxDecoration(
            color: AppTheme.bgCard,
            border: Border(left: BorderSide(color: AppTheme.border)),
          ),
          padding: const EdgeInsets.all(12),
          child: ListView(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'CONFIGURACIÓN DE CAJA / ZONA',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.accentPurple,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 15),
                    onPressed: () => setState(() => _selectedBoxId = null),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: ValueKey('box-title-$boxId'),
                initialValue: '${box['title'] ?? ''}',
                enabled: widget.canEdit,
                decoration: const InputDecoration(
                  labelText: 'Nombre / Título de la Caja',
                  isDense: true,
                ),
                onChanged: (v) {
                  setState(() => box['title'] = v);
                },
                onFieldSubmitted: (_) =>
                    _persistStackBoxesAndScale(boxes: _stackBoxes),
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: ValueKey('box-corner-$boxId'),
                initialValue:
                    '${box['corner_data'] ?? box['subtitle'] ?? ''}',
                enabled: widget.canEdit,
                decoration: const InputDecoration(
                  labelText: 'Datos Técnicos (Esquina Superior)',
                  isDense: true,
                ),
                onChanged: (v) {
                  setState(() {
                    box['corner_data'] = v;
                    box['subtitle'] = v;
                  });
                },
                onFieldSubmitted: (_) =>
                    _persistStackBoxesAndScale(boxes: _stackBoxes),
              ),
              const SizedBox(height: 12),
              Text(
                'Ancho de la Caja: ${(wRel * 100).round()}% del lienzo',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Slider(
                value: wRel.toDouble(),
                min: 0.10,
                max: 0.96,
                onChanged: widget.canEdit
                    ? (v) => setState(() => box['width_rel'] = v)
                    : null,
                onChangeEnd: widget.canEdit
                    ? (_) => _persistStackBoxesAndScale(boxes: _stackBoxes)
                    : null,
              ),
              Text(
                'Alto de la Caja: ${(hRel * 100).round()}% del lienzo',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Slider(
                value: hRel.toDouble(),
                min: 0.12,
                max: 0.96,
                onChanged: widget.canEdit
                    ? (v) => setState(() => box['height_rel'] = v)
                    : null,
                onChangeEnd: widget.canEdit
                    ? (_) => _persistStackBoxesAndScale(boxes: _stackBoxes)
                    : null,
              ),
              const SizedBox(height: 6),
              const Text(
                'Color de la Caja:',
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in colorChoices)
                    ChoiceChip(
                      label: Text(
                        c.$2,
                        style: const TextStyle(fontSize: 10),
                      ),
                      selected: colorHex.toUpperCase() == c.$1.toUpperCase(),
                      onSelected: widget.canEdit
                          ? (_) {
                              setState(() => box['color_hex'] = c.$1);
                              _persistStackBoxesAndScale(boxes: _stackBoxes);
                            }
                          : null,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              if (widget.canEdit) ...[
                ElevatedButton.icon(
                  onPressed: () =>
                      _persistStackBoxesAndScale(boxes: _stackBoxes),
                  icon: const Icon(Icons.save_outlined, size: 15),
                  label: const Text('Guardar Cambios de la Caja'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final updated = _stackBoxes
                        .where((b) => '${b['id']}' != boxId)
                        .toList();
                    setState(() {
                      _stackBoxes = updated;
                      _selectedBoxId = null;
                    });
                    await _persistStackBoxesAndScale(boxes: updated);
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.error,
                  ),
                  icon: const Icon(Icons.close_rounded, size: 15),
                  label: const Text('Borrar Caja / Zona'),
                ),
              ],
            ],
          ),
        );
      }
    }

    if (selectedNode.isEmpty) {
      return Container(
        width: 320,
        decoration: const BoxDecoration(
          color: AppTheme.bgCard,
          border: Border(left: BorderSide(color: AppTheme.border)),
        ),
        padding: const EdgeInsets.all(14),
        child: const Center(
          child: Text(
            'Selecciona un elemento en el lienzo para configurar sus datos, enlaces, Heartbeat y Conexión SSH/Web.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
          ),
        ),
      );
    }

    final host = Map<String, dynamic>.from((selectedNode['host'] as Map?) ?? {});
    final nodeId = selectedNode['id'] as int;
    final nodeEdges = edges
        .where(
          (e) =>
              e['source_node_id'] == nodeId || e['target_node_id'] == nodeId,
        )
        .toList();

    return Container(
      width: 345,
      decoration: const BoxDecoration(
        color: AppTheme.bgCard,
        border: Border(left: BorderSide(color: AppTheme.border)),
      ),
      child: _DatacenterStyleHostConfigPanel(
        key: ValueKey('dc-panel-${host['id']}-${selectedNode['id']}'),
        host: host,
        stackNode: selectedNode,
        allStackNodes: nodes,
        nodeEdges: nodeEdges,
        hostsList: _hosts,
        canEdit: widget.canEdit,
        onStartLinkMode: () {
          setState(() {
            _isLinkModeActive = true;
            _linkSourceNodeId = nodeId;
          });
        },
        onQuickConnectToNode: (targetNodeId) =>
            _quickCreateEdgeBetweenNodes(nodeId, targetNodeId, nodes),
        onDeleteEdge: (edgeId) async {
          final res = await widget.api.deleteTechStackEdge(edgeId);
          if (mounted) {
            setState(() {
              _overview = res;
              _syncStackCanvasState();
            });
          }
        },
        onOpenSsh: () => _showSshWebConsoleDialog(selectedNode, host),
        onOpenFloatingCharts: () {
          setState(() {
            _showFloatingTechWindow = true;
            _floatingWinMinimized = false;
          });
          if (host['id'] != null) {
            _loadHostTelemetry(host['id'] as int);
          }
        },
        onSaveHostConfig: (payload) async {
          final res = await widget.api.createNetworkHostWithServices(payload);
          if (res['overview'] is Map && mounted) {
            setState(() {
              _overview = Map<String, dynamic>.from(res['overview'] as Map);
              _syncStackCanvasState();
            });
            _showSnack('Elemento ${payload['code']} actualizado.');
          }
        },
      ),
    );
  }

  // ===========================================================================
  // TAB 2: DIAGRAMA LÓGICO DE CONEXIÓN CON MONITORIZACIÓN INTEGRADA (5 CAPAS)
  // ===========================================================================

  Widget _buildLogicalTopologyTab() {
    final allHosts = _hosts;
    final filteredHosts = allHosts.where((h) {
      if (_layerFilter != 'all' && h['logical_layer'] != _layerFilter) {
        return false;
      }
      if (_stateFilter != 'all' && h['nagios_host_state'] != _stateFilter) {
        return false;
      }
      if (_searchQuery.trim().isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final hay =
            '${h['code']} ${h['name']} ${h['hostname']} ${h['heartbeat_ip']} ${h['rack_location_badge']}'
                .toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();

    final selectedHost = allHosts.firstWhere(
      (h) => h['id'] == _selectedHostId,
      orElse: () => allHosts.isNotEmpty ? allHosts.first : <String, dynamic>{},
    );

    final layers = [
      (
        'edge_security',
        'CAPA 1 • WAN / FIREWALLS / PERÍMETRO',
        AppTheme.error,
      ),
      (
        'network_switching',
        'CAPA 2 • SWITCHING CORE / ACCESO & VLANs (SNMP + LLDP)',
        AppTheme.accentCyan,
      ),
      (
        'hypervisors_phys',
        'CAPA 3 • SERVIDORES FÍSICOS DEL RACK / HIPERVISORES VMWARE & PROXMOX / BAREBONE',
        AppTheme.accentBlue,
      ),
      (
        'vms_containers',
        'CAPA 4 • MÁQUINAS VIRTUALES (VMs), DOCKER, LXC & VIPs DE CLÚSTER',
        AppTheme.accentPurple,
      ),
      (
        'services_apps',
        'CAPA 5 • SERVICIOS DE APLICACIÓN Y BASES DE DATOS',
        AppTheme.accentTeal,
      ),
    ];

    return Row(
      children: [
        // Lienzo interactivo de Topología Lógica en 5 Capas
        Expanded(
          flex: 7,
          child: Column(
            children: [
              // Barra de filtros y acciones del Diagrama Lógico
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: const BoxDecoration(
                  color: AppTheme.bgCard,
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 240,
                      height: 34,
                      child: TextField(
                        onChanged: (v) => setState(() => _searchQuery = v),
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          hintText: 'Filtrar nodo por código, IP, Rack...',
                          prefixIcon: Icon(Icons.search, size: 15),
                          contentPadding: EdgeInsets.symmetric(vertical: 0),
                        ),
                      ),
                    ),
                    DropdownButton<String>(
                      value: _layerFilter,
                      underline: const SizedBox.shrink(),
                      dropdownColor: AppTheme.bgElevated,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textPrimary,
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'all',
                          child: Text('Todas las Capas Lógicas (1-5)'),
                        ),
                        DropdownMenuItem(
                          value: 'edge_security',
                          child: Text('Capa 1: Edge / Firewalls'),
                        ),
                        DropdownMenuItem(
                          value: 'network_switching',
                          child: Text('Capa 2: Switches SNMP / VLANs'),
                        ),
                        DropdownMenuItem(
                          value: 'hypervisors_phys',
                          child: Text('Capa 3: Físicos Rack / Hipervisores'),
                        ),
                        DropdownMenuItem(
                          value: 'vms_containers',
                          child: Text('Capa 4: VMs / Contenedores / VIPs'),
                        ),
                      ],
                      onChanged: (v) =>
                          setState(() => _layerFilter = v ?? 'all'),
                    ),
                    DropdownButton<String>(
                      value: _stateFilter,
                      underline: const SizedBox.shrink(),
                      dropdownColor: AppTheme.bgElevated,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textPrimary,
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'all',
                          child: Text('Todos los Estados Nagios'),
                        ),
                        DropdownMenuItem(
                          value: 'UP',
                          child: Text('Solo UP (Online)'),
                        ),
                        DropdownMenuItem(
                          value: 'DOWN',
                          child: Text('Solo DOWN (Caídos)'),
                        ),
                        DropdownMenuItem(
                          value: 'UNREACHABLE',
                          child: Text('Solo UNREACHABLE'),
                        ),
                        DropdownMenuItem(
                          value: 'MAINTENANCE',
                          child: Text('Solo en Mantenimiento'),
                        ),
                      ],
                      onChanged: (v) =>
                          setState(() => _stateFilter = v ?? 'all'),
                    ),
                    if (widget.canEdit)
                      OutlinedButton.icon(
                        onPressed: _showCreateLogicalLinkDialog,
                        icon: const Icon(Icons.add_link_rounded, size: 15),
                        label: const Text(
                          '+ Documentar Enlace Lógico',
                          style: TextStyle(fontSize: 11.5),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(14),
                  children: [
                    // Tarjeta visual de Topología de Enlaces Lógicos con Monitorización Integrada
                    _buildLogicalLinksFlowBanner(allHosts),
                    const SizedBox(height: 14),
                    // Nodos agrupados por Capa Lógica
                    for (final layer in layers) ...[
                      Builder(
                        builder: (context) {
                          final layerHosts = filteredHosts
                              .where((h) => h['logical_layer'] == layer.$1)
                              .toList();
                          if (layerHosts.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return Container(
                            margin: const EdgeInsets.only(bottom: 14),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.bgSecondary,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: layer.$3.withValues(alpha: 0.35),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      _layerIcon(layer.$1),
                                      color: layer.$3,
                                      size: 17,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      layer.$2,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                        color: layer.$3,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                    const Spacer(),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: layer.$3.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        '${layerHosts.length} nodos',
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w700,
                                          color: layer.$3,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: layerHosts
                                      .map((h) => _buildLogicalNodeCard(h))
                                      .toList(),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        // Inspector lateral derecho del Nodo seleccionado (con enlaces a Rack Editor, CMDB y Gráficas)
        Container(
          width: 410,
          decoration: const BoxDecoration(
            color: AppTheme.bgSecondary,
            border: Border(left: BorderSide(color: AppTheme.border)),
          ),
          child: selectedHost.isEmpty
              ? const Center(child: Text('Selecciona un nodo del diagrama'))
              : _buildSelectedNodeInspector(selectedHost),
        ),
      ],
    );
  }

  Widget _buildLogicalLinksFlowBanner(List<Map<String, dynamic>> allHosts) {
    final links = _logicalLinks;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.polyline_rounded,
                size: 16,
                color: AppTheme.accentCyan,
              ),
              const SizedBox(width: 8),
              Text(
                'ENLACES LÓGICOS DOCUMENTADOS Y AUTODESCUBIERTOS CON ESTADO EN VIVO (${links.length})',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              const Text(
                'Haz clic en cualquier enlace para inspeccionar sus extremos',
                style: TextStyle(fontSize: 10.5, color: AppTheme.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 78,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: links.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final lnk = links[index];
                final st = (lnk['status'] as String?) ?? 'UP';
                final col = _nagiosStateColor(st);
                final isSelected =
                    lnk['source_asset_id'] == _selectedHostId ||
                    lnk['target_asset_id'] == _selectedHostId;
                return InkWell(
                  onTap: () {
                    setState(() {
                      _selectedHostId = lnk['target_asset_id'] as int?;
                    });
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 265,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppTheme.accentCyan.withValues(alpha: 0.12)
                          : AppTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? AppTheme.accentCyan
                            : col.withValues(alpha: 0.45),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: col,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${lnk['source_code']}  ➔  ${lnk['target_code']}',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.textPrimary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (widget.canEdit)
                              InkWell(
                                onTap: () async {
                                  final res = await widget.api.deleteLogicalLink(
                                    lnk['id'] as int,
                                  );
                                  setState(() => _overview = res);
                                },
                                child: const Icon(
                                  Icons.close,
                                  size: 13,
                                  color: AppTheme.textMuted,
                                ),
                              ),
                          ],
                        ),
                        Text(
                          '${lnk['source_interface']} ⇄ ${lnk['target_interface']}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: AppTheme.textSecondary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: col.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '${lnk['protocol_label']}',
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                  color: col,
                                ),
                              ),
                            ),
                            const Spacer(),
                            if (lnk['vlan_id'] != null)
                              Text(
                                'VLAN ${lnk['vlan_id']}',
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  color: AppTheme.textMuted,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogicalNodeCard(Map<String, dynamic> host) {
    final id = host['id'] as int;
    final isSelected = _selectedHostId == id;
    final state = (host['nagios_host_state'] as String?) ?? 'UP';
    final stateCol = _nagiosStateColor(state);
    final checks = ((host['service_checks'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final rackId = host['rack_id'] as int?;
    final targetRackDevId = host['target_rack_device_id'] as int?;

    return InkWell(
      onTap: () {
        setState(() => _selectedHostId = id);
        _loadHostTelemetry(id);
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 280,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.bgElevated : AppTheme.bgCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? AppTheme.accentCyan
                : stateCol.withValues(alpha: 0.55),
            width: isSelected ? 2 : 1.2,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: AppTheme.accentCyan.withValues(alpha: 0.18),
                    blurRadius: 10,
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cabecera con Estado Nagios + Código + Latencia
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: stateCol.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: stateCol),
                  ),
                  child: Text(
                    state,
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      color: stateCol,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${host['code']}',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (host['last_ping_ms'] != null)
                  Text(
                    '${host['last_ping_ms']} ms',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.accentTeal,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${host['name']}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            // IP Heartbeat + Multi-IP + Enlace al Rack
            Row(
              children: [
                const Icon(
                  Icons.lan_rounded,
                  size: 12,
                  color: AppTheme.accentCyan,
                ),
                const SizedBox(width: 4),
                Text(
                  '${host['heartbeat_ip']}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
                if (((host['ip_count'] as num?) ?? 1) > 1) ...[
                  const SizedBox(width: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.accentPurple.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '+${(host['ip_count'] as int) - 1} IPs',
                      style: const TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.accentPurple,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 5),
            // Ubicación física en el Rack o Hipervisor Padre
            Row(
              children: [
                const Icon(
                  Icons.view_in_ar_rounded,
                  size: 12,
                  color: AppTheme.warning,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '${host['rack_location_badge']}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppTheme.textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Mini barras de telemetría Prometheus (CPU / RAM)
            Row(
              children: [
                Expanded(
                  child: _buildMiniMetricBar(
                    'CPU',
                    (host['cpu_pct'] as num?)?.toDouble() ?? 0,
                    AppTheme.accentBlue,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildMiniMetricBar(
                    'RAM',
                    (host['ram_pct'] as num?)?.toDouble() ?? 0,
                    AppTheme.accentPurple,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Botones rápidos de Coordinación: Rack Editor / CMDB / Gráficas
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${checks.length} servicios',
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppTheme.textMuted,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (rackId != null && widget.onNavigateToRackDevice != null)
                      InkWell(
                        onTap: () => widget.onNavigateToRackDevice!(
                          rackId,
                          targetRackDevId,
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.accentBlue.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Row(
                            children: [
                              Icon(
                                Icons.dns_rounded,
                                size: 11,
                                color: AppTheme.accentBlue,
                              ),
                              SizedBox(width: 3),
                              Text(
                                'Rack Editor',
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.accentBlue,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(width: 5),
                    if (widget.onNavigateToCmdb != null)
                      InkWell(
                        onTap: () =>
                            widget.onNavigateToCmdb!(host['code'] as String?),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.accentTeal.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'CMDB',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.accentTeal,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniMetricBar(String label, double pct, Color color) {
    final clamped = pct.clamp(0.0, 100.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 9.5, color: AppTheme.textMuted),
            ),
            Text(
              '${clamped.toStringAsFixed(0)}%',
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: clamped / 100.0,
            minHeight: 4,
            backgroundColor: AppTheme.bgPrimary,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }

  Widget _buildSelectedNodeInspector(Map<String, dynamic> host) {
    final checks = ((host['service_checks'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final allIps = ((host['all_ips'] as List?) ?? []).cast<String>();
    final rackId = host['rack_id'] as int?;
    final targetRackDevId = host['target_rack_device_id'] as int?;
    final state = (host['nagios_host_state'] as String?) ?? 'UP';
    final stateCol = _nagiosStateColor(state);

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: stateCol.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: stateCol),
              ),
              child: Text(
                '$state (${host['nagios_state_type']})',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: stateCol,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${host['code']}',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${host['name']}',
          style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 10),
        // Botones de coordinación directa con Rack Editor, CMDB y Gráficas Prometheus
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (widget.canEdit)
              ElevatedButton.icon(
                onPressed: () => _showCreateVirtualMachineWithServicesDialog(
                  existingHost: host,
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentCyan,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.tune_rounded, size: 15),
                label: const Text(
                  'Configurar Host (Alojamiento, Healthchecks & SSH)',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            if (rackId != null && widget.onNavigateToRackDevice != null)
              ElevatedButton.icon(
                onPressed: () =>
                    widget.onNavigateToRackDevice!(rackId, targetRackDevId),
                icon: const Icon(Icons.view_in_ar_rounded, size: 15),
                label: Text(
                  'Abrir en Rack Editor (${host['rack_code']} U${host['start_u']})',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            if (widget.onNavigateToCmdb != null)
              OutlinedButton.icon(
                onPressed: () =>
                    widget.onNavigateToCmdb!(host['code'] as String?),
                icon: const Icon(Icons.hub_rounded, size: 15),
                label: const Text(
                  'Ver Ficha en CMDB',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            OutlinedButton.icon(
              onPressed: () {
                _tabController.animateTo(4);
                _loadHostTelemetry(host['id'] as int);
              },
              icon: const Icon(Icons.show_chart_rounded, size: 15),
              label: const Text(
                'Ver Gráficas Prometheus',
                style: TextStyle(fontSize: 11),
              ),
            ),
            if (host['ssh_enabled'] != false)
              OutlinedButton.icon(
                onPressed: () => _showSshWebConsoleDialog(
                  {
                    'ssh_user': host['ssh_user'] ?? 'root',
                    'ssh_port': host['ssh_port'] ?? 22,
                  },
                  host,
                ),
                icon: const Icon(Icons.terminal_rounded, size: 15),
                label: Text(
                  'Consola SSH (${host['ssh_user'] ?? 'root'}@${host['ssh_host'] ?? host['heartbeat_ip']})',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            if (host['web_https_enabled'] == true &&
                (host['web_https_url'] as String? ?? '').isNotEmpty)
              OutlinedButton.icon(
                onPressed: () {
                  launchUrl(
                    Uri.parse('${host['web_https_url']}'),
                    mode: LaunchMode.externalApplication,
                  );
                },
                icon: const Icon(Icons.open_in_new_rounded, size: 15),
                label: const Text(
                  'Abrir Web HTTPS',
                  style: TextStyle(fontSize: 11),
                ),
              ),
          ],
        ),
        const Divider(height: 22),
        _buildKeyValRow('Hostname / FQDN', '${host['hostname']} (${host['fqdn']})'),
        _buildKeyValRow('Capa Lógica', '${host['logical_layer_label']}'),
        _buildKeyValRow('Ubicación Rack / Host', '${host['rack_location_badge']}'),
        _buildKeyValRow('SO / Plataforma', '${host['os_or_firmware']}'),
        _buildKeyValRow(
          'Responsable / Equipo',
          '${host['responsible_person']} • ${host['owner_team']}',
        ),
        _buildKeyValRow(
          'HostGroups Asociados',
          ((host['host_groups'] as List?) ?? []).join(', '),
        ),
        const SizedBox(height: 8),
        const Text(
          'DIRECCIONES IP SINCRONIZADAS CON CMDB',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            color: AppTheme.accentCyan,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: allIps
              .map(
                (ip) => Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.bgCard,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: ip == host['heartbeat_ip']
                          ? AppTheme.accentCyan
                          : AppTheme.border,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        ip == host['heartbeat_ip']
                            ? Icons.favorite_rounded
                            : Icons.lan_rounded,
                        size: 12,
                        color: ip == host['heartbeat_ip']
                            ? AppTheme.accentCyan
                            : AppTheme.textSecondary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        ip,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
        const Divider(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'HEARTBEATS Y CHEQUEOS NAGIOS (${checks.length})',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: AppTheme.textPrimary,
              ),
            ),
            if (widget.canEdit)
              TextButton.icon(
                onPressed: _showCreateServiceCheckDialog,
                icon: const Icon(Icons.add, size: 14),
                label: const Text('Añadir', style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        ...checks.map((chk) {
          final st = (chk['nagios_state'] as String?) ?? 'OK';
          final col = _nagiosStateColor(st);
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.bgCard,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: col.withValues(alpha: 0.45)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: col.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '$st • ${chk['state_type']} (${chk['attempt_label']})',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                          color: col,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${chk['service_name']}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.play_arrow_rounded, size: 16),
                      tooltip: 'Ejecutar este chequeo ahora',
                      constraints: const BoxConstraints(),
                      padding: EdgeInsets.zero,
                      onPressed: () async {
                        final res = await widget.api
                            .runSingleNetworkServiceCheck(chk['id'] as int);
                        if (res['overview'] is Map) {
                          setState(() {
                            _overview = Map<String, dynamic>.from(
                              res['overview'] as Map,
                            );
                          });
                        }
                        _showSnack(
                          'Chequeo ejecutado: ${chk['service_name']}',
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${chk['status_output']}',
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.textSecondary,
                  ),
                ),
                if (chk['ssl_days_remaining'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.lock_clock_rounded,
                          size: 12,
                          color: AppTheme.accentTeal,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Certificado SSL/TLS válido por ${chk['ssl_days_remaining']} días',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.accentTeal,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildKeyValRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              k,
              style: const TextStyle(
                fontSize: 11,
                color: AppTheme.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              v.isEmpty ? '—' : v,
              style: const TextStyle(
                fontSize: 11,
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 2: MONITOR DE ESTADOS (NAGIOS TAC) & HEARTBEATS MULTI-PROTOCOLO
  // ===========================================================================

  Widget _buildNagiosServiceMonitorTab() {
    final allRows = <Map<String, dynamic>>[];
    for (final h in _hosts) {
      final checks = ((h['service_checks'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      for (final c in checks) {
        allRows.add({...c, 'host': h});
      }
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.monitor_heart_rounded,
                color: AppTheme.accentCyan,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'MATRIZ DE ESTADOS NAGIOS CORE (SOFT/HARD 1/3..3/3) Y HEARTBEATS MULTI-PROTOCOLO (${allRows.length})',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              if (widget.canEdit)
                ElevatedButton.icon(
                  onPressed: _showCreateServiceCheckDialog,
                  icon: const Icon(Icons.add, size: 15),
                  label: const Text(
                    'Añadir Heartbeat HTTP / HTTPS / TCP / SSH / Apache / Nginx / Docker / BBDD',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.bgSecondary,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border),
              ),
              child: ListView.separated(
                itemCount: allRows.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: AppTheme.border),
                itemBuilder: (context, idx) {
                  final row = allRows[idx];
                  final host = Map<String, dynamic>.from(row['host'] as Map);
                  final st = (row['nagios_state'] as String?) ?? 'OK';
                  final col = _nagiosStateColor(st);
                  final hostState =
                      (host['nagios_host_state'] as String?) ?? 'UP';
                  final hostCol = _nagiosStateColor(hostState);

                  return ListTile(
                    dense: true,
                    leading: Container(
                      width: 86,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: col.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: col),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '$st (${row['attempt_label']})',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: col,
                        ),
                      ),
                    ),
                    title: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: hostCol.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${host['code']} [$hostState]',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              color: hostCol,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${row['service_name']}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.bgCard,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: AppTheme.border),
                          ),
                          child: Text(
                            '${row['check_type']}'.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 9.5,
                              fontFamily: 'monospace',
                              color: AppTheme.accentCyan,
                            ),
                          ),
                        ),
                        if (row['ssl_days_remaining'] != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.accentTeal.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'SSL: ${row['ssl_days_remaining']}d',
                              style: const TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.accentTeal,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      'Target: ${row['target_ip_or_url']} • ${row['status_output']}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (row['latency_ms'] != null)
                          Text(
                            '${row['latency_ms']} ms',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.accentTeal,
                            ),
                          ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.refresh_rounded, size: 17),
                          tooltip: 'Forzar chequeo ahora',
                          onPressed: () async {
                            final res = await widget.api
                                .runSingleNetworkServiceCheck(row['id'] as int);
                            if (res['overview'] is Map) {
                              setState(() {
                                _overview = Map<String, dynamic>.from(
                                  res['overview'] as Map,
                                );
                              });
                            }
                            _showSnack(
                              'Chequeo actualizado: ${row['service_name']}',
                            );
                          },
                        ),
                        if (widget.canEdit)
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 17,
                              color: AppTheme.error,
                            ),
                            tooltip: 'Eliminar chequeo',
                            onPressed: () async {
                              final res = await widget.api
                                  .deleteNetworkServiceCheck(row['id'] as int);
                              setState(() => _overview = res);
                            },
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 3: SWITCHES SNMP (IF-MIB + LLDP) Y CONECTORES DE INFRAESTRUCTURA
  // ===========================================================================

  Widget _buildSnmpSwitchesAndConnectorsTab() {
    final swHosts = _hosts
        .where(
          (h) =>
              h['logical_layer'] == 'network_switching' ||
              ((h['snmp_ports_count'] as num?) ?? 0) > 0,
        )
        .toList();
    final selectedSw = swHosts.firstWhere(
      (h) => h['id'] == _selectedSwitchAssetId,
      orElse: () => swHosts.isNotEmpty ? swHosts.first : <String, dynamic>{},
    );
    final swPorts = ((selectedSw['snmp_ports'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 1. Panel Visual de Switch SNMP + LLDP
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.bgSecondary,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.settings_ethernet_rounded,
                        color: AppTheme.accentCyan,
                        size: 20,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'AUTODESCUBRIMIENTO DE SWITCHES POR SNMP (IF-MIB + LLDP-MIB) SIN ALTA MANUAL PUERTO A PUERTO',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (swHosts.isNotEmpty)
                        DropdownButton<int>(
                          value: selectedSw['id'] as int?,
                          dropdownColor: AppTheme.bgElevated,
                          underline: const SizedBox.shrink(),
                          items: swHosts
                              .map(
                                (s) => DropdownMenuItem<int>(
                                  value: s['id'] as int,
                                  child: Text(
                                    '${s['code']} — ${s['name']} (${s['heartbeat_ip']})',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (v) =>
                              setState(() => _selectedSwitchAssetId = v),
                        ),
                      const SizedBox(width: 10),
                      ElevatedButton.icon(
                        onPressed: _showSnmpDiscoveryDialog,
                        icon: const Icon(Icons.radar_rounded, size: 15),
                        label: const Text(
                          'Lanzar SNMP Walk a Switch',
                          style: TextStyle(fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (swPorts.isEmpty)
                const Text(
                  'Pulsa "Lanzar SNMP Walk a Switch" para interrogar todas las bocas IF-MIB y vecinos LLDP.',
                  style: TextStyle(color: AppTheme.textSecondary),
                )
              else ...[
                // Frontal gráfico de 28 bocas del Switch
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.bgPrimary,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: swPorts.map((p) {
                      final isUp = p['oper_status'] == 'up';
                      final hasLldp =
                          ((p['lldp_neighbor_sysname'] as String?) ?? '')
                              .isNotEmpty;
                      final col = isUp ? AppTheme.success : AppTheme.textMuted;
                      return Tooltip(
                        message:
                            '${p['if_name']} (${p['if_alias']})\n'
                            'Estado: ${p['oper_status'].toString().toUpperCase()} • ${p['speed_mbps']} Mbps • VLAN ${p['vlan_id']} (${p['vlan_mode']})\n'
                            'Tráfico: Rx ${p['in_mbps']} Mbps / Tx ${p['out_mbps']} Mbps\n'
                            'Vecino LLDP: ${hasLldp ? "${p['lldp_neighbor_sysname']} (${p['lldp_neighbor_port']})" : "Ninguno"}',
                        child: Container(
                          width: 72,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: isUp
                                ? col.withValues(alpha: 0.14)
                                : AppTheme.bgSecondary,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: hasLldp
                                  ? AppTheme.accentCyan
                                  : col.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(
                                      color: col,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  Text(
                                    '${p['if_name']}',
                                    style: const TextStyle(
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                isUp ? '${p['in_mbps']}M' : 'DOWN',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: col,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                hasLldp
                                    ? '${p['lldp_neighbor_sysname']}'
                                    : 'VLAN ${p['vlan_id']}',
                                style: const TextStyle(
                                  fontSize: 8.5,
                                  color: AppTheme.textSecondary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        // 2. Conectores de Infraestructura (Proxmox, VMware, Docker, Apache, Nginx, BBDD, Exporters)
        Row(
          children: [
            const Icon(Icons.power_rounded, color: AppTheme.accentTeal, size: 20),
            const SizedBox(width: 8),
            Text(
              'CONECTORES ACTIVOS DE VIRTUALIZACIÓN, CONTENEDORES, SERVIDORES WEB Y BBDD (${_connectors.length})',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
            ),
            const Spacer(),
            if (widget.canEdit)
              ElevatedButton.icon(
                onPressed: _showCreateConnectorDialog,
                icon: const Icon(Icons.add, size: 15),
                label: const Text(
                  '+ Nuevo Conector (Proxmox / VMware / Docker / Apache / Nginx / BBDD)',
                  style: TextStyle(fontSize: 11.5),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: _connectors.map((c) {
            return Container(
              width: 350,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.bgSecondary,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.success.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${c['last_sync_status']}'.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.success,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${c['name']}',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${c['connector_type_label']}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.accentCyan,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Endpoint: ${c['endpoint_host']}:${c['endpoint_port']} • Nodo: ${c['linked_asset_code']}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${c['last_sync_summary']}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          final res = await widget.api.syncInfraConnector(
                            c['id'] as int,
                          );
                          setState(() => _overview = res);
                          _showSnack('Conector sincronizado: ${c['name']}');
                        },
                        icon: const Icon(Icons.sync_rounded, size: 14),
                        label: const Text(
                          'Sincronizar Ahora',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      if (widget.canEdit) ...[
                        const SizedBox(width: 6),
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            size: 16,
                            color: AppTheme.error,
                          ),
                          onPressed: () async {
                            final res = await widget.api.deleteInfraConnector(
                              c['id'] as int,
                            );
                            setState(() => _overview = res);
                          },
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  // ===========================================================================
  // TAB 5: GRÁFICAS PROMETHEUS TSDB (COLUMNA IZQUIERDA: DATOS Y GRÁFICAS DEL
  // ELEMENTO SELECCIONADO | COLUMNA DERECHA: LISTA ORGANIZADA DE ELEMENTOS)
  // + BOTÓN PARA VER Y DESCARGAR QUÉ INSTALAR EN FORMATO MARKDOWN (.MD)
  // ===========================================================================

  String _promHostSearch = '';
  String _promCategoryFilter = 'all';

  Widget _buildPrometheusChartsAndAgentsTab() {
    final allHosts = _hosts;
    if (_selectedHostId == null && allHosts.isNotEmpty) {
      _selectedHostId = allHosts.first['id'] as int;
    }
    final selectedHost = allHosts.firstWhere(
      (h) => h['id'] == _selectedHostId,
      orElse: () => allHosts.isNotEmpty ? allHosts.first : <String, dynamic>{},
    );

    final rawPts = ((_telemetryData?['points'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final pts = rawPts.isNotEmpty
        ? rawPts
        : (selectedHost.isNotEmpty
              ? _buildFallbackSeriesFromMini(selectedHost)
              : <Map<String, dynamic>>[]);

    final promQueries = Map<String, dynamic>.from(
      (_telemetryData?['promql_examples'] as Map?) ?? {},
    );
    final checks = ((selectedHost['service_checks'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    // Filtrado y organización de la columna derecha de elementos
    final filteredRightHosts = allHosts.where((h) {
      if (_promCategoryFilter != 'all') {
        final layer = '${h['logical_layer'] ?? ''}';
        if (_promCategoryFilter == 'apps' && layer != 'services_apps') {
          return false;
        }
        if (_promCategoryFilter == 'Compute' &&
            layer != 'virtualization_compute' &&
            layer != 'physical_rack') {
          return false;
        }
        if (_promCategoryFilter == 'net' &&
            layer != 'network_switching' &&
            layer != 'perimeter_security') {
          return false;
        }
      }
      if (_promHostSearch.trim().isNotEmpty) {
        final q = _promHostSearch.trim().toLowerCase();
        final hay =
            '${h['code']} ${h['name']} ${h['heartbeat_ip']} ${h['os_or_firmware']} ${h['asset_class_label']}'
                .toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();

    final hostState = (selectedHost['nagios_host_state'] as String?) ?? 'UP';
    final hostStateCol = _nagiosStateColor(hostState);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // =====================================================================
        // COLUMNA IZQUIERDA (EXPANDED): DATOS DEL ELEMENTO SELECCIONADO +
        // GRÁFICAS PROMETHEUS EN CUADRÍCULA 2X2 + CHEQUEOS + BOTÓN MARKDOWN.MD
        // =====================================================================
        Expanded(
          child: selectedHost.isEmpty
              ? const Center(
                  child: Text(
                    'Selecciona un elemento en la columna de la derecha para ver sus datos y gráficas Prometheus.',
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // 1. Cabecera organizada con todos los datos clave del elemento + Botón Qué Instalar (.md)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.bgSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: hostStateCol.withValues(
                                        alpha: 0.16,
                                      ),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: hostStateCol),
                                    ),
                                    child: Text(
                                      hostState,
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w900,
                                        color: hostStateCol,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${selectedHost['code']} — ${selectedHost['name']}',
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w900,
                                          color: AppTheme.textPrimary,
                                        ),
                                      ),
                                      Text(
                                        'IP: ${selectedHost['heartbeat_ip']} • ${selectedHost['asset_class_label']} • ${selectedHost['rack_location_badge']}',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontFamily: 'monospace',
                                          color: AppTheme.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  // Selector de ventana temporal (1h, 6h, 24h, 7d)
                                  for (final hrs in [1, 6, 24, 168])
                                    ChoiceChip(
                                      label: Text(
                                        hrs == 168 ? '7d' : '${hrs}h',
                                        style: const TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      selected: _telemetryRangeHours == hrs,
                                      onSelected: (_) {
                                        setState(
                                          () => _telemetryRangeHours = hrs,
                                        );
                                        if (_selectedHostId != null) {
                                          _loadHostTelemetry(_selectedHostId!);
                                        }
                                      },
                                    ),
                                  // BOTÓN PARA VER Y DESCARGAR EN MARKDOWN.MD QUÉ INSTALAR PARA MONITORIZAR
                                  ElevatedButton.icon(
                                    onPressed: () =>
                                        _showWhatToInstallMarkdownDialog(
                                          selectedHost,
                                        ),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppTheme.accentBlue,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 9,
                                      ),
                                    ),
                                    icon: const Icon(
                                      Icons.download_for_offline_rounded,
                                      size: 16,
                                    ),
                                    label: const Text(
                                      'Qué instalar para monitorizar (.md)',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const Divider(height: 18),
                          // Píldoras de resumen técnico del elemento seleccionado
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              _buildTechMetricBadge(
                                'CPU Actual',
                                '${selectedHost['cpu_pct'] ?? 0}%',
                                AppTheme.accentBlue,
                              ),
                              _buildTechMetricBadge(
                                'Memoria RAM',
                                '${selectedHost['ram_pct'] ?? 0}%',
                                AppTheme.accentPurple,
                              ),
                              _buildTechMetricBadge(
                                'Uso Disco',
                                '${selectedHost['disk_pct'] ?? 0}%',
                                AppTheme.warning,
                              ),
                              _buildTechMetricBadge(
                                'Latencia Ping',
                                '${selectedHost['last_ping_ms'] ?? '-'} ms',
                                AppTheme.accentTeal,
                              ),
                              _buildTechMetricBadge(
                                'SO / Plataforma',
                                '${selectedHost['os_or_firmware'] ?? '-'}',
                                AppTheme.accentCyan,
                              ),
                              _buildTechMetricBadge(
                                'Responsable / Equipo',
                                '${selectedHost['owner_team'] ?? '-'}',
                                AppTheme.textSecondary,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 2. Cuadrícula 2x2 perfectamente alineada con las 4 Gráficas Prometheus del elemento
                    if (_loadingTelemetry)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(36),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _buildTelemetryChartCard(
                              title: '1. USO DE CPU (%) & MEMORIA RAM (%)',
                              promQl:
                                  '${promQueries['cpu'] ?? 'node_cpu_seconds_total / node_memory_MemAvailable_bytes'}',
                              points: pts,
                              metricKeyA: 'cpu_pct',
                              labelA: 'CPU %',
                              colorA: AppTheme.accentBlue,
                              metricKeyB: 'ram_pct',
                              labelB: 'RAM %',
                              colorB: AppTheme.accentPurple,
                              unit: '%',
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildTelemetryChartCard(
                              title: '2. LATENCIA DEL HEARTBEAT ICMP/HTTP (MS)',
                              promQl:
                                  '${promQueries['latency'] ?? 'probe_duration_seconds * 1000'}',
                              points: pts,
                              metricKeyA: 'latency_ms',
                              labelA: 'RTT ms',
                              colorA: AppTheme.accentTeal,
                              unit: 'ms',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _buildTelemetryChartCard(
                              title:
                                  '3. TRÁFICO DE RED RX / TX (MBPS - IF-MIB / NODE_EXPORTER)',
                              promQl:
                                  '${promQueries['switch_traffic'] ?? 'rate(node_network_receive_bytes_total[5m])'}',
                              points: pts,
                              metricKeyA: 'rx_mbps',
                              labelA: 'RX (Mbps)',
                              colorA: AppTheme.accentCyan,
                              metricKeyB: 'tx_mbps',
                              labelB: 'TX (Mbps)',
                              colorB: AppTheme.warning,
                              unit: 'Mbps',
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildTelemetryChartCard(
                              title:
                                  '4. PETICIONES WEB (REQ/S) & OCUPACIÓN DE DISCO (%)',
                              promQl: 'rackdoc_host_disk_usage_percent',
                              points: pts,
                              metricKeyA: 'web_req_per_sec',
                              labelA: 'Web req/s',
                              colorA: AppTheme.success,
                              metricKeyB: 'disk_pct',
                              labelB: 'Disco %',
                              colorB: AppTheme.error,
                              unit: '',
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 14),

                    // 3. Ficha de Servicios Monitorizados y Datos Técnicos del Elemento Seleccionado
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.bgSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'CHEQUEOS ACTIVOS Y SERVICIOS DEL ELEMENTO (${checks.length})',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w900,
                                  color: AppTheme.accentCyan,
                                ),
                              ),
                              if (selectedHost['ssh_enabled'] != false &&
                                  selectedHost['connect_enabled'] != false)
                                OutlinedButton.icon(
                                  onPressed: () => _showSshWebConsoleDialog(
                                    {
                                      'ssh_user':
                                          selectedHost['ssh_user'] ?? 'root',
                                      'ssh_port':
                                          selectedHost['ssh_port'] ?? 22,
                                    },
                                    selectedHost,
                                  ),
                                  icon: const Icon(
                                    Icons.terminal_rounded,
                                    size: 14,
                                  ),
                                  label: Text(
                                    'Conectar SSH (${selectedHost['ssh_user'] ?? 'root'}@${selectedHost['heartbeat_ip']})',
                                    style: const TextStyle(fontSize: 10.5),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (checks.isEmpty)
                            const Text(
                              'Este elemento no tiene chequeos activos configurados.',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.textMuted,
                              ),
                            )
                          else
                            for (final chk in checks)
                              Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: AppTheme.bgCard,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: AppTheme.border),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.circle,
                                      size: 9,
                                      color: _nagiosStateColor(
                                        (chk['nagios_state'] as String?) ??
                                            'OK',
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '${chk['service_name']} [${chk['check_type'].toString().toUpperCase()}] ➔ ${chk['target_ip_or_url']}',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '${chk['status_output']}',
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        color: AppTheme.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),

        // =====================================================================
        // COLUMNA DERECHA (FIJA 360PX): DIRECTORIO ORGANIZADO DE ELEMENTOS
        // Al pulsar sobre cualquiera, sus datos y gráficas aparecen a la izquierda
        // =====================================================================
        Container(
          width: 360,
          decoration: const BoxDecoration(
            color: AppTheme.bgCard,
            border: Border(left: BorderSide(color: AppTheme.border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'ELEMENTOS / HOSTS (${filteredRightHosts.length})',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w900,
                            color: AppTheme.textPrimary,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const Text(
                          'Pulsa para ver gráficas',
                          style: TextStyle(
                            fontSize: 9.8,
                            color: AppTheme.accentBlue,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      onChanged: (v) => setState(() => _promHostSearch = v),
                      style: const TextStyle(fontSize: 11.5),
                      decoration: InputDecoration(
                        hintText: 'Buscar por código, nombre o IP...',
                        prefixIcon: const Icon(Icons.search, size: 16),
                        isDense: true,
                        filled: true,
                        fillColor: AppTheme.bgSecondary,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: AppTheme.border),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final cat in [
                            ('all', 'Todos (${allHosts.length})'),
                            ('apps', 'VMs / Apps / BBDD'),
                            ('Compute', 'Físicos / Hiperv.'),
                            ('net', 'Switches / Red'),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 5),
                              child: ChoiceChip(
                                label: Text(
                                  cat.$2,
                                  style: const TextStyle(fontSize: 9.8),
                                ),
                                selected: _promCategoryFilter == cat.$1,
                                onSelected: (_) => setState(
                                  () => _promCategoryFilter = cat.$1,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(10),
                  itemCount: filteredRightHosts.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, idx) {
                    final h = filteredRightHosts[idx];
                    final hid = h['id'] as int;
                    final isSel = hid == selectedHost['id'];
                    final st = (h['nagios_host_state'] as String?) ?? 'UP';
                    final stCol = _nagiosStateColor(st);

                    return InkWell(
                      borderRadius: BorderRadius.circular(9),
                      onTap: () {
                        setState(() => _selectedHostId = hid);
                        _loadHostTelemetry(hid);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isSel
                              ? AppTheme.accentBlue.withValues(alpha: 0.12)
                              : AppTheme.bgSecondary,
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                            color: isSel
                                ? AppTheme.accentBlue
                                : AppTheme.border,
                            width: isSel ? 1.8 : 1.0,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
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
                                Expanded(
                                  child: Text(
                                    '${h['code']}',
                                    style: TextStyle(
                                      fontSize: 11.2,
                                      fontWeight: FontWeight.w900,
                                      color: isSel
                                          ? AppTheme.accentBlue
                                          : AppTheme.textPrimary,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  '${h['heartbeat_ip']}',
                                  style: const TextStyle(
                                    fontSize: 9.8,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.accentTeal,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${h['name']}',
                              style: const TextStyle(
                                fontSize: 10.2,
                                color: AppTheme.textSecondary,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'CPU ${h['cpu_pct'] ?? 0}% • RAM ${h['ram_pct'] ?? 0}%',
                                  style: const TextStyle(
                                    fontSize: 9.2,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.textMuted,
                                  ),
                                ),
                                Text(
                                  '${h['last_ping_ms'] ?? '-'} ms',
                                  style: const TextStyle(
                                    fontSize: 9.2,
                                    fontFamily: 'monospace',
                                    color: AppTheme.accentCyan,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTechMetricBadge(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: const TextStyle(
              fontSize: 10,
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  String _buildMonitoringInstallMarkdown(Map<String, dynamic> host) {
    final code = '${host['code'] ?? 'HOST'}';
    final name = '${host['name'] ?? 'Sistema'}';
    final ip = '${host['heartbeat_ip'] ?? '10.0.0.10'}';
    final os = '${host['os_or_firmware'] ?? 'Linux / Windows'}';
    final cls = '${host['asset_class_label'] ?? 'Servidor / VM'}';

    return '''# Guía de Instalación de Agentes y Exporters para Monitorización en Prometheus y RackDoc

## 1. Ficha del Elemento Seleccionado
- **Código CMDB / Host**: `$code`
- **Nombre**: $name
- **Dirección IP Principal**: `$ip`
- **Tipo de Elemento**: $cls
- **SO / Firmware**: $os
- **Fichero de Service Discovery en RackDoc**: `/app/data/prometheus/targets_dynamic.json` (actualizado automáticamente cada vez que guardas un elemento en RackDoc).

---

## 2. Linux (Ubuntu / Debian / RHEL / Proxmox VE) — `prometheus-node-exporter (:9100)`
Expone uso de CPU, Memoria RAM, Carga de sistema, Espacio e I/O de Discos, Tráfico de Interfaces de Red y estado de unidades `systemd`.

```bash
# En Ubuntu / Debian / Proxmox VE ($ip):
sudo apt-get update && sudo apt-get install -y prometheus-node-exporter
sudo systemctl enable --now prometheus-node-exporter

# En RHEL / Rocky / AlmaLinux:
sudo dnf install -y golang-github-prometheus-node-exporter
sudo systemctl enable --now node_exporter

# Verificar que responde métricas en el puerto 9100:
curl -s http://$ip:9100/metrics | head -n 20
```

---

## 3. Windows Server (Active Directory / IIS / SQL Server / Hyper-V) — `windows_exporter (:9182)`
Expone CPU, Memoria RAM, Discos NTFS, Servicios de Windows, IIS y contadores de Hyper-V/AD.

```powershell
# Ejecutar en PowerShell como Administrador en $ip:
Invoke-WebRequest -Uri "https://github.com/prometheus-community/windows_exporter/releases/latest/download/windows_exporter-0.27.3-amd64.msi" -OutFile C:\\windows_exporter.msi
msiexec /i C:\\windows_exporter.msi ENABLED_COLLECTORS="cpu,cs,logical_disk,net,os,service,system,memory" LISTEN_PORT=9182 /qn

# Verificar respuesta:
Invoke-WebRequest -Uri "http://localhost:9182/metrics" -UseBasicParsing
```

---

## 4. Switches, Routers y Firewalls (Cisco, Aruba, FortiGate, MikroTik) — `SNMPv2c/v3 + LLDP (:161/UDP)`
Permite a RackDoc descubrir todas las bocas (`IF-MIB`) y vecinos (`LLDP-MIB`) de una sola vez sin alta manual.

```text
! Configuración en Switch Cisco IOS / Catalyst / Aruba ($ip):
snmp-server community public RO
snmp-server location "CPD Principal RackDoc"
lldp run
```

---

## 5. Servidores Web Apache HTTPd & Nginx
Permite medir peticiones por segundo (`req/s`), workers activos y conexiones concurrentes.

```nginx
# En Nginx (/etc/nginx/conf.d/status.conf):
location /nginx_status {
    stub_status on;
    allow 10.0.0.0/8;
    allow 127.0.0.1;
    deny all;
}
```

```apache
# En Apache (/etc/apache2/mods-enabled/status.conf):
ExtendedStatus On
<Location "/server-status">
    SetHandler server-status
    Require ip 10.0.0.0/8 127.0.0.1
</Location>
```

---

## 6. Bases de Datos (PostgreSQL / MySQL / Redis) y Docker Engine
```bash
# PostgreSQL Exporter (:9187):
DATA_SOURCE_NAME="postgresql://postgres:password@$ip:5432/postgres?sslmode=disable" prometheus-postgres-exporter

# Redis Exporter (:9121):
prometheus-redis-exporter --redis.addr="redis://$ip:6379"

# Docker Engine (/etc/docker/daemon.json -> puerto 9323):
# { "metrics-addr": "0.0.0.0:9323", "experimental": true }
```
''';
  }

  Future<void> _downloadMarkdownGuide(
    String markdownContent,
    String filename,
  ) async {
    try {
      await Clipboard.setData(ClipboardData(text: markdownContent));
      final uri = Uri.dataFromString(
        markdownContent,
        mimeType: 'text/markdown',
        encoding: utf8,
      );
      await launchUrl(uri, webOnlyWindowName: '_blank');
      _showSnack(
        'Descargando $filename (y copiado al portapapeles en formato Markdown .md)',
      );
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: markdownContent));
      _showSnack(
        'Contenido Markdown (.md) copiado al portapapeles listo para guardar como $filename',
      );
    }
  }

  Future<void> _showWhatToInstallMarkdownDialog(
    Map<String, dynamic> host,
  ) async {
    final code = '${host['code'] ?? 'host'}'.toLowerCase();
    final filename = 'guia_monitorizacion_$code.md';
    final mdText = _buildMonitoringInstallMarkdown(host);

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                '¿Qué instalar para monitorizar ${host['code'] ?? "un elemento"}? ($filename)',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
        content: SizedBox(
          width: 760,
          height: 520,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.bgPrimary,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.border),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                mdText,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'monospace',
                  color: AppTheme.textPrimary,
                  height: 1.45,
                ),
              ),
            ),
          ),
        ),
        actions: [
          OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: mdText));
              _showSnack('Documento Markdown copiado al portapapeles');
            },
            icon: const Icon(Icons.copy_rounded, size: 15),
            label: const Text('Copiar Markdown'),
          ),
          ElevatedButton.icon(
            onPressed: () => _downloadMarkdownGuide(mdText, filename),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentBlue,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.download_rounded, size: 16),
            label: Text('Descargar $filename'),
          ),
        ],
      ),
    );
  }

  Widget _buildTelemetryChartCard({
    required String title,
    required String promQl,
    required List<Map<String, dynamic>> points,
    required String metricKeyA,
    required String labelA,
    required Color colorA,
    String? metricKeyB,
    String? labelB,
    Color? colorB,
    required String unit,
  }) {
    final valsA = points
        .map((p) => (p[metricKeyA] as num?)?.toDouble() ?? 0.0)
        .toList();
    final lastA = valsA.isNotEmpty ? valsA.last : 0.0;
    final maxA = valsA.isNotEmpty ? valsA.reduce(math.max) : 0.0;
    final minA = valsA.isNotEmpty ? valsA.reduce(math.min) : 0.0;
    final avgA = valsA.isNotEmpty
        ? valsA.reduce((a, b) => a + b) / valsA.length
        : 0.0;

    final valsB = metricKeyB != null
        ? points
              .map((p) => (p[metricKeyB] as num?)?.toDouble() ?? 0.0)
              .toList()
        : <double>[];
    final lastB = valsB.isNotEmpty ? valsB.last : null;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: colorA.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  '$labelA: ${lastA.toStringAsFixed(1)} $unit',
                  style: TextStyle(
                    fontSize: 10.2,
                    fontWeight: FontWeight.w800,
                    color: colorA,
                  ),
                ),
              ),
              if (lastB != null && labelB != null && colorB != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colorB.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    '$labelB: ${lastB.toStringAsFixed(1)} $unit',
                    style: TextStyle(
                      fontSize: 10.2,
                      fontWeight: FontWeight.w800,
                      color: colorB,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'PromQL: $promQl',
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontFamily: 'monospace',
                    color: AppTheme.textMuted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                'Máx ${maxA.toStringAsFixed(1)}$unit • Media ${avgA.toStringAsFixed(1)}$unit • Mín ${minA.toStringAsFixed(1)}$unit',
                style: const TextStyle(
                  fontSize: 9.2,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 165,
            width: double.infinity,
            child: CustomPaint(
              painter: _PrometheusSeriesChartPainter(
                points: points,
                keyA: metricKeyA,
                colorA: colorA,
                keyB: metricKeyB,
                colorB: colorB,
                unit: unit,
                warnThreshold: unit == '%' ? 75.0 : null,
                critThreshold: unit == '%' ? 90.0 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 5: AVISOS DE ALARMAS (MATRIZ 4 COLUMNAS ESTILO ACTIVE DIRECTORY + DRAG & DROP + SMTP)
  // ===========================================================================

  Widget _buildAlertsContactsAndMaintenanceTab() {
    if (_hostGroups.isNotEmpty &&
        (_selectedAlertHostGroupId == null ||
            !_hostGroups.any((hg) => hg['id'] == _selectedAlertHostGroupId))) {
      _selectedAlertHostGroupId = _hostGroups.first['id'] as int;
    }
    if (_alertContactGroups.isNotEmpty &&
        (_selectedAlertUserGroupId == null ||
            !_alertContactGroups.any(
              (cg) => cg['id'] == _selectedAlertUserGroupId,
            ))) {
      _selectedAlertUserGroupId = _alertContactGroups.first['id'] as int;
    }
    if (_alertContacts.isNotEmpty &&
        (_selectedAlertContactId == null ||
            !_alertContacts.any((c) => c['id'] == _selectedAlertContactId))) {
      _selectedAlertContactId = _alertContacts.first['id'] as int;
    }

    final smtp = _smtpConfig;
    final smtpHost = (smtp['smtp_host'] as String? ?? '').trim();
    final smtpEnabled = smtp['enabled'] != false;
    final smtpConfigured = smtpHost.isNotEmpty && smtpEnabled;

    return Column(
      children: [
        // 1. Barra superior: Servidor SMTP + Sincronización Active Directory/Control de Acceso + Altas a Medida
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: const BoxDecoration(
            color: AppTheme.bgSecondary,
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Botón Principal: Dar de Alta / Configurar Servidor para Mandar Correos (SMTP)
              ElevatedButton.icon(
                onPressed: _showSmtpServerConfigDialog,
                style: ElevatedButton.styleFrom(
                  backgroundColor: smtpConfigured
                      ? AppTheme.accentTeal
                      : AppTheme.accentBlue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                ),
                icon: const Icon(Icons.mark_email_unread_rounded, size: 16),
                label: Text(
                  smtpConfigured
                      ? '✉️ Servidor Correo SMTP (${smtp['smtp_host']}:${smtp['smtp_port']}) • Activo'
                      : '✉️ Dar de Alta Servidor Correo SMTP',
                  style: const TextStyle(
                    fontSize: 11.2,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  await _loadOverview();
                  _showSnack(
                    'Usuarios y Grupos sincronizados con Control de Acceso (Local + Active Directory).',
                  );
                },
                icon: const Icon(
                  Icons.sync_rounded,
                  size: 15,
                  color: AppTheme.accentPurple,
                ),
                label: const Text(
                  'Sincronizar Control de Acceso & AD',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                ),
              ),
              if (widget.canEdit) ...[
                OutlinedButton.icon(
                  onPressed: () => _showCreateHostGroupDialog(),
                  icon: const Icon(
                    Icons.dns_rounded,
                    size: 14,
                    color: AppTheme.accentCyan,
                  ),
                  label: const Text(
                    '+ Grupo de Host',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _showCreateContactGroupDialog(),
                  icon: const Icon(
                    Icons.groups_rounded,
                    size: 15,
                    color: AppTheme.accentBlue,
                  ),
                  label: const Text(
                    '+ Grupo Usuarios (AD/Local/Medida)',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _showCreateContactDialog(),
                  icon: const Icon(
                    Icons.person_add_alt_1_rounded,
                    size: 14,
                    color: AppTheme.success,
                  ),
                  label: const Text(
                    '+ Usuario / Contacto',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _showCreateMaintenanceDialog,
                  icon: const Icon(Icons.build_circle_rounded, size: 14),
                  label: const Text(
                    '+ Mantenimiento',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
              OutlinedButton.icon(
                onPressed: () async {
                  final res = await widget.api.triggerTestAlert(
                    assetId: _selectedHostId,
                  );
                  setState(() => _overview = res);
                  _showSnack(
                    'Correo/Alerta de prueba disparado y registrado en la bitácora.',
                  );
                },
                icon: const Icon(
                  Icons.send_rounded,
                  size: 14,
                  color: AppTheme.warning,
                ),
                label: const Text(
                  'Probar Envío Alarma',
                  style: TextStyle(fontSize: 11),
                ),
              ),
              IconButton(
                tooltip: _showAlertBottomLogs
                    ? 'Ocultar Bitácora Inferior'
                    : 'Mostrar Bitácora y Mantenimientos',
                onPressed: () => setState(
                  () => _showAlertBottomLogs = !_showAlertBottomLogs,
                ),
                icon: Icon(
                  _showAlertBottomLogs
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_up_rounded,
                  size: 18,
                ),
              ),
            ],
          ),
        ),
        // Banner explicativo del flujo izquierda -> derecha con Drag & Drop
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: AppTheme.accentBlue.withValues(alpha: 0.07),
            border: const Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: const Row(
            children: [
              Icon(
                Icons.drag_indicator_rounded,
                size: 15,
                color: AppTheme.accentBlue,
              ),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Flujo Active Directory & Alarmas (Izquierda → Derecha):  [1. Grupo de Host]  ➔  [2. Hosts del Grupo]  ⬅(Arrastra y suelta)⬅  [3. Grupo de Usuarios (con su correo)]  ➔  [4. Usuario (con su correo, grupos MemberOf y hosts que le avisan)].',
                  style: TextStyle(
                    fontSize: 10.6,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        // 2. Matriz Principal de 4 Columnas (Izquierda a Derecha)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // COLUMNA 1: GRUPOS DE HOST (DROP TARGET)
                Expanded(
                  flex: 24,
                  child: _buildAlertsCol1HostGroups(),
                ),
                _buildAlertsFlowConnectorArrow('contiene\nhosts ➔'),
                // COLUMNA 2: HOSTS DEL GRUPO SELECCIONADO (DROP TARGET)
                Expanded(
                  flex: 25,
                  child: _buildAlertsCol2HostsInGroup(),
                ),
                _buildAlertsFlowConnectorArrow('⬅ arrastra\npara alarmar'),
                // COLUMNA 3: GRUPOS DE USUARIOS (AD / LOCAL / A MEDIDA) — DRAGGABLE
                Expanded(
                  flex: 25,
                  child: _buildAlertsCol3UserGroups(),
                ),
                _buildAlertsFlowConnectorArrow('miembros\n& AD ➔'),
                // COLUMNA 4: USUARIOS + FICHA ACTIVE DIRECTORY (MEMBEROF & HOSTS QUE LE ENVÍAN ALARMAS)
                Expanded(
                  flex: 26,
                  child: _buildAlertsCol4UsersAndAdCard(),
                ),
              ],
            ),
          ),
        ),
        // 3. Barra inferior plegable: Ventanas de Mantenimiento y Bitácora de Correos Enviados
        if (_showAlertBottomLogs) _buildAlertsBottomMaintenanceAndLogsBar(),
      ],
    );
  }

  Widget _buildAlertsFlowConnectorArrow(String label) {
    return SizedBox(
      width: 44,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              decoration: BoxDecoration(
                color: AppTheme.bgCard,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppTheme.border),
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 8.2,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textMuted,
                  height: 1.15,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // COLUMNA 1 (IZQUIERDA): GRUPOS DE HOST (DROP TARGET DE GRUPOS/USUARIOS)
  // ---------------------------------------------------------------------------
  Widget _buildAlertsCol1HostGroups() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: const BoxDecoration(
              color: AppTheme.bgCard,
              borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
              border: Border(bottom: BorderSide(color: AppTheme.border)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.accentCyan.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    '1',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.accentCyan,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'GRUPOS DE HOST (${_hostGroups.length})',
                    style: const TextStyle(
                      fontSize: 11.2,
                      fontWeight: FontWeight.w900,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.canEdit)
                  IconButton(
                    tooltip: 'Nuevo Grupo de Host',
                    constraints: const BoxConstraints(),
                    padding: EdgeInsets.zero,
                    onPressed: () => _showCreateHostGroupDialog(),
                    icon: const Icon(
                      Icons.add_circle_outline_rounded,
                      size: 16,
                      color: AppTheme.accentCyan,
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            color: AppTheme.accentCyan.withValues(alpha: 0.05),
            child: const Text(
              '💡 Suelta aquí un Grupo de Usuarios (Col 3) o Usuario (Col 4) para asignarle las alarmas de todo el grupo.',
              style: TextStyle(fontSize: 9.5, color: AppTheme.textSecondary),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _hostGroups.length,
              itemBuilder: (ctx, i) {
                final hg = _hostGroups[i];
                final hgId = hg['id'] as int;
                final isSelected = hgId == _selectedAlertHostGroupId;
                final memberCodes =
                    ((hg['member_codes'] as List?) ?? []).cast<String>();

                // Buscar regla de enrutamiento para este HostGroup
                final hgRules = _notificationRules
                    .where(
                      (r) =>
                          r['scope_type'] == 'host_group' &&
                          r['host_group_id'] == hgId,
                    )
                    .toList();
                final assignedCgIds = <int>{};
                final assignedContactIds = <int>{};
                for (final r in hgRules) {
                  for (final id in ((r['contact_group_ids'] as List?) ?? [])) {
                    assignedCgIds.add(id as int);
                  }
                  for (final id in ((r['contact_ids'] as List?) ?? [])) {
                    assignedContactIds.add(id as int);
                  }
                }

                return DragTarget<String>(
                  onWillAcceptWithDetails: (details) =>
                      widget.canEdit &&
                      (details.data.startsWith('ug:') ||
                          details.data.startsWith('u:')),
                  onAcceptWithDetails: (details) => _handleDropRecipientOnTarget(
                    dragToken: details.data,
                    scopeType: 'host_group',
                    hostGroupId: hgId,
                    targetName: '${hg['name']} (${hg['code']})',
                  ),
                  builder: (ctx, candidateData, rejectedData) {
                    final isHoveringDrop = candidateData.isNotEmpty;
                    return GestureDetector(
                      onTap: () =>
                          setState(() => _selectedAlertHostGroupId = hgId),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isHoveringDrop
                              ? AppTheme.accentTeal.withValues(alpha: 0.14)
                              : (isSelected
                                    ? AppTheme.accentCyan.withValues(
                                        alpha: 0.09,
                                      )
                                    : AppTheme.bgPrimary),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isHoveringDrop
                                ? AppTheme.accentTeal
                                : (isSelected
                                      ? AppTheme.accentCyan
                                      : AppTheme.border),
                            width: (isHoveringDrop || isSelected) ? 1.8 : 1.0,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.folder_special_rounded,
                                  size: 16,
                                  color: AppTheme.accentCyan,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    '${hg['name']}',
                                    style: const TextStyle(
                                      fontSize: 11.4,
                                      fontWeight: FontWeight.w800,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (widget.canEdit)
                                  IconButton(
                                    tooltip: 'Editar HostGroup y sus Hosts',
                                    constraints: const BoxConstraints(),
                                    padding: const EdgeInsets.only(left: 4),
                                    onPressed: () =>
                                        _showCreateHostGroupDialog(existing: hg),
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 14,
                                      color: AppTheme.textMuted,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                Text(
                                  '${hg['code']}',
                                  style: const TextStyle(
                                    fontSize: 9.8,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.textMuted,
                                  ),
                                ),
                                const Spacer(),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppTheme.bgElevated,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '${memberCodes.length} hosts',
                                    style: const TextStyle(
                                      fontSize: 9.2,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 7),
                            // Destinatarios de Alarma asignados a este HostGroup
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: AppTheme.bgSecondary,
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(
                                  color: isHoveringDrop
                                      ? AppTheme.accentTeal
                                      : AppTheme.border.withValues(alpha: 0.8),
                                ),
                              ),
                              child: (assignedCgIds.isEmpty &&
                                      assignedContactIds.isEmpty)
                                  ? const Text(
                                      '📥 Arrastra aquí un Grupo de Usuarios para asignar alarmas',
                                      style: TextStyle(
                                        fontSize: 9.4,
                                        fontStyle: FontStyle.italic,
                                        color: AppTheme.textMuted,
                                      ),
                                    )
                                  : Wrap(
                                      spacing: 4,
                                      runSpacing: 4,
                                      children: [
                                        ...assignedCgIds.map((cgId) {
                                          final cg = _alertContactGroups
                                              .where((g) => g['id'] == cgId)
                                              .firstOrNull;
                                          if (cg == null) {
                                            return const SizedBox.shrink();
                                          }
                                          return _buildAssignedRecipientPill(
                                            label: '👥 ${cg['name']}',
                                            email: '${cg['group_email'] ?? ''}',
                                            color: AppTheme.accentTeal,
                                            onRemove: widget.canEdit
                                                ? () =>
                                                      _removeRecipientFromTarget(
                                                        scopeType: 'host_group',
                                                        hostGroupId: hgId,
                                                        removeCgId: cgId,
                                                      )
                                                : null,
                                          );
                                        }),
                                        ...assignedContactIds.map((cId) {
                                          final c = _alertContacts
                                              .where((u) => u['id'] == cId)
                                              .firstOrNull;
                                          if (c == null) {
                                            return const SizedBox.shrink();
                                          }
                                          return _buildAssignedRecipientPill(
                                            label: '👤 ${c['full_name']}',
                                            email: '${c['email'] ?? ''}',
                                            color: AppTheme.accentPurple,
                                            onRemove: widget.canEdit
                                                ? () =>
                                                      _removeRecipientFromTarget(
                                                        scopeType: 'host_group',
                                                        hostGroupId: hgId,
                                                        removeContactId: cId,
                                                      )
                                                : null,
                                          );
                                        }),
                                      ],
                                    ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // COLUMNA 2: HOSTS DEL GRUPO SELECCIONADO (DROP TARGET INDIVIDUAL POR HOST)
  // ---------------------------------------------------------------------------
  Widget _buildAlertsCol2HostsInGroup() {
    final selectedHg = _hostGroups
        .where((hg) => hg['id'] == _selectedAlertHostGroupId)
        .firstOrNull;
    final memberAssetIds =
        ((selectedHg?['member_asset_ids'] as List?) ?? []).cast<int>().toSet();
    final groupHosts = selectedHg == null
        ? _hosts
        : _hosts.where((h) => memberAssetIds.contains(h['id'] as int)).toList();

    // Grupos heredados del HostGroup padre
    final inheritedCgIds = <int>{};
    if (selectedHg != null) {
      for (final r in _notificationRules.where(
        (r) =>
            r['scope_type'] == 'host_group' &&
            r['host_group_id'] == selectedHg['id'],
      )) {
        for (final id in ((r['contact_group_ids'] as List?) ?? [])) {
          inheritedCgIds.add(id as int);
        }
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: const BoxDecoration(
              color: AppTheme.bgCard,
              borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
              border: Border(bottom: BorderSide(color: AppTheme.border)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.accentBlue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    '2',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.accentBlue,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    selectedHg != null
                        ? 'HOSTS EN ${selectedHg['code']} (${groupHosts.length})'
                        : 'HOSTS (${groupHosts.length})',
                    style: const TextStyle(
                      fontSize: 11.2,
                      fontWeight: FontWeight.w900,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            color: AppTheme.accentBlue.withValues(alpha: 0.05),
            child: const Text(
              '💡 Cada Host hereda las alarmas de su HostGroup y también admite arrastrarle un Grupo o Usuario directo.',
              style: TextStyle(fontSize: 9.5, color: AppTheme.textSecondary),
            ),
          ),
          Expanded(
            child: groupHosts.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Este Grupo de Host aún no tiene máquinas asignadas.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: groupHosts.length,
                    itemBuilder: (ctx, i) {
                      final h = groupHosts[i];
                      final assetId = h['id'] as int;
                      final nagiosState =
                          (h['nagios_host_state'] as String?) ?? 'UP';
                      final stateColor = nagiosState == 'UP'
                          ? AppTheme.success
                          : (nagiosState == 'DOWN'
                                ? AppTheme.error
                                : AppTheme.warning);

                      // Reglas directas para este Host individual
                      final hostRules = _notificationRules
                          .where(
                            (r) =>
                                r['scope_type'] == 'single_host' &&
                                r['asset_id'] == assetId,
                          )
                          .toList();
                      final directCgIds = <int>{};
                      final directContactIds = <int>{};
                      for (final r in hostRules) {
                        for (final id
                            in ((r['contact_group_ids'] as List?) ?? [])) {
                          directCgIds.add(id as int);
                        }
                        for (final id in ((r['contact_ids'] as List?) ?? [])) {
                          directContactIds.add(id as int);
                        }
                      }

                      return DragTarget<String>(
                        onWillAcceptWithDetails: (details) =>
                            widget.canEdit &&
                            (details.data.startsWith('ug:') ||
                                details.data.startsWith('u:')),
                        onAcceptWithDetails: (details) =>
                            _handleDropRecipientOnTarget(
                              dragToken: details.data,
                              scopeType: 'single_host',
                              assetId: assetId,
                              targetName: 'Host ${h['code']}',
                            ),
                        builder: (ctx, candidateData, rejectedData) {
                          final isHoveringDrop = candidateData.isNotEmpty;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(9),
                            decoration: BoxDecoration(
                              color: isHoveringDrop
                                  ? AppTheme.accentTeal.withValues(alpha: 0.14)
                                  : AppTheme.bgPrimary,
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(
                                color: isHoveringDrop
                                    ? AppTheme.accentTeal
                                    : AppTheme.border,
                                width: isHoveringDrop ? 1.8 : 1.0,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: stateColor,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        '${h['code']} • ${h['name']}',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w800,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Text(
                                      '${h['heartbeat_ip'] ?? ''}',
                                      style: const TextStyle(
                                        fontSize: 9.5,
                                        fontFamily: 'monospace',
                                        color: AppTheme.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Wrap(
                                  spacing: 4,
                                  runSpacing: 4,
                                  children: [
                                    ...inheritedCgIds.map((cgId) {
                                      final cg = _alertContactGroups
                                          .where((g) => g['id'] == cgId)
                                          .firstOrNull;
                                      if (cg == null) {
                                        return const SizedBox.shrink();
                                      }
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppTheme.accentCyan.withValues(
                                            alpha: 0.10,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          border: Border.all(
                                            color: AppTheme.accentCyan
                                                .withValues(alpha: 0.35),
                                          ),
                                        ),
                                        child: Text(
                                          '↪ Hereda: ${cg['name']}',
                                          style: const TextStyle(
                                            fontSize: 8.9,
                                            fontWeight: FontWeight.w700,
                                            color: AppTheme.accentCyan,
                                          ),
                                        ),
                                      );
                                    }),
                                    ...directCgIds.map((cgId) {
                                      final cg = _alertContactGroups
                                          .where((g) => g['id'] == cgId)
                                          .firstOrNull;
                                      if (cg == null) {
                                        return const SizedBox.shrink();
                                      }
                                      return _buildAssignedRecipientPill(
                                        label: '🎯 Directo: ${cg['name']}',
                                        email: '${cg['group_email'] ?? ''}',
                                        color: AppTheme.accentTeal,
                                        onRemove: widget.canEdit
                                            ? () => _removeRecipientFromTarget(
                                                scopeType: 'single_host',
                                                assetId: assetId,
                                                removeCgId: cgId,
                                              )
                                            : null,
                                      );
                                    }),
                                    ...directContactIds.map((cId) {
                                      final c = _alertContacts
                                          .where((u) => u['id'] == cId)
                                          .firstOrNull;
                                      if (c == null) {
                                        return const SizedBox.shrink();
                                      }
                                      return _buildAssignedRecipientPill(
                                        label: '👤 Directo: ${c['full_name']}',
                                        email: '${c['email'] ?? ''}',
                                        color: AppTheme.accentPurple,
                                        onRemove: widget.canEdit
                                            ? () => _removeRecipientFromTarget(
                                                scopeType: 'single_host',
                                                assetId: assetId,
                                                removeContactId: cId,
                                              )
                                            : null,
                                      );
                                    }),
                                    if (inheritedCgIds.isEmpty &&
                                        directCgIds.isEmpty &&
                                        directContactIds.isEmpty)
                                      const Text(
                                        'Arrastra aquí un grupo o usuario para alerta específica',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontStyle: FontStyle.italic,
                                          color: AppTheme.textMuted,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // COLUMNA 3: GRUPOS DE USUARIOS (AD / LOCAL / A MEDIDA) — DRAGGABLE
  // ---------------------------------------------------------------------------
  Widget _buildAlertsCol3UserGroups() {
    final filteredGroups = _alertContactGroups.where((cg) {
      if (_alertGroupSourceFilter == 'all') return true;
      return (cg['source_type'] as String? ?? 'custom') ==
          _alertGroupSourceFilter;
    }).toList();

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: const BoxDecoration(
              color: AppTheme.bgCard,
              borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
              border: Border(bottom: BorderSide(color: AppTheme.border)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.accentPurple.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    '3',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.accentPurple,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'GRUPOS DE USUARIOS (${filteredGroups.length})',
                    style: const TextStyle(
                      fontSize: 11.2,
                      fontWeight: FontWeight.w900,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.canEdit)
                  IconButton(
                    tooltip: 'Crear Grupo de Usuarios a Medida o AD',
                    constraints: const BoxConstraints(),
                    padding: EdgeInsets.zero,
                    onPressed: () => _showCreateContactGroupDialog(),
                    icon: const Icon(
                      Icons.add_circle_outline_rounded,
                      size: 16,
                      color: AppTheme.accentPurple,
                    ),
                  ),
              ],
            ),
          ),
          // Filtros de origen: Todos | Active Directory | Locales | A Medida
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppTheme.border)),
            ),
            child: Wrap(
              spacing: 5,
              runSpacing: 4,
              children: [
                _buildSourceFilterChip('all', 'Todos'),
                _buildSourceFilterChip('ad', 'Active Directory'),
                _buildSourceFilterChip('local', 'Locales'),
                _buildSourceFilterChip('custom', 'A Medida'),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: filteredGroups.length,
              itemBuilder: (ctx, i) {
                final cg = filteredGroups[i];
                final cgId = cg['id'] as int;
                final isSelected = cgId == _selectedAlertUserGroupId;
                final srcType = (cg['source_type'] as String?) ?? 'custom';
                final srcBadge = (cg['source_badge'] as String?) ?? 'A Medida';
                final memberIds =
                    ((cg['member_contact_ids'] as List?) ?? []).cast<int>();
                final alertHgs =
                    ((cg['alerting_host_group_codes'] as List?) ?? [])
                        .cast<String>();

                final cardBody = GestureDetector(
                  onTap: () => setState(() {
                    _selectedAlertUserGroupId = cgId;
                    _showAllUsersInCol4 = false;
                    if (memberIds.isNotEmpty &&
                        !memberIds.contains(_selectedAlertContactId)) {
                      _selectedAlertContactId = memberIds.first;
                    }
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppTheme.accentPurple.withValues(alpha: 0.09)
                          : AppTheme.bgPrimary,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isSelected
                            ? AppTheme.accentPurple
                            : AppTheme.border,
                        width: isSelected ? 1.8 : 1.0,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.drag_indicator_rounded,
                              size: 15,
                              color: AppTheme.accentPurple,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                '${cg['name']}',
                                style: const TextStyle(
                                  fontSize: 11.3,
                                  fontWeight: FontWeight.w800,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            _buildOriginBadge(srcType, srcBadge),
                            if (widget.canEdit) ...[
                              const SizedBox(width: 4),
                              InkWell(
                                onTap: () => _showCreateContactGroupDialog(
                                  existing: cg,
                                ),
                                child: const Icon(
                                  Icons.edit_outlined,
                                  size: 14,
                                  color: AppTheme.textMuted,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 5),
                        // Correo propio del Grupo de Usuarios
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.bgSecondary,
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: AppTheme.border),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.alternate_email_rounded,
                                size: 12,
                                color: AppTheme.accentCyan,
                              ),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  (cg['group_email'] as String? ?? '')
                                          .isNotEmpty
                                      ? 'Correo grupo: ${cg['group_email']}'
                                      : 'Sin correo de lista (usa correo de cada miembro)',
                                  style: const TextStyle(
                                    fontSize: 9.8,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w700,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            Text(
                              '👥 ${memberIds.length} miembros',
                              style: const TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                            const Spacer(),
                            if (alertHgs.isNotEmpty)
                              Text(
                                '🔔 Recibe de: ${alertHgs.join(", ")}',
                                style: const TextStyle(
                                  fontSize: 9.0,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.accentTeal,
                                ),
                              )
                            else
                              const Text(
                                'Arrastra a Col 1 o Col 2',
                                style: TextStyle(
                                  fontSize: 9.0,
                                  color: AppTheme.textMuted,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );

                if (!widget.canEdit) return cardBody;
                return Draggable<String>(
                  data: 'ug:$cgId',
                  feedback: Material(
                    elevation: 8,
                    borderRadius: BorderRadius.circular(10),
                    color: AppTheme.accentPurple,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.groups_rounded,
                            size: 16,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Asignar Grupo: ${cg['name']} (${cg['group_email']})',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  childWhenDragging: Opacity(opacity: 0.45, child: cardBody),
                  child: cardBody,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // COLUMNA 4 (DERECHA): USUARIOS + FICHA ACTIVE DIRECTORY (MEMBEROF & HOSTS)
  // ---------------------------------------------------------------------------
  Widget _buildAlertsCol4UsersAndAdCard() {
    final selectedCg = _alertContactGroups
        .where((cg) => cg['id'] == _selectedAlertUserGroupId)
        .firstOrNull;
    final groupMemberIds =
        ((selectedCg?['member_contact_ids'] as List?) ?? [])
            .cast<int>()
            .toSet();

    final visibleUsers = (_showAllUsersInCol4 || selectedCg == null)
        ? _alertContacts
        : _alertContacts
              .where((c) => groupMemberIds.contains(c['id'] as int))
              .toList();

    final selectedUser =
        _alertContacts
            .where((c) => c['id'] == _selectedAlertContactId)
            .firstOrNull ??
        (visibleUsers.isNotEmpty ? visibleUsers.first : null);

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: const BoxDecoration(
              color: AppTheme.bgCard,
              borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
              border: Border(bottom: BorderSide(color: AppTheme.border)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.success.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    '4',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.success,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    _showAllUsersInCol4
                        ? 'TODOS LOS USUARIOS (${visibleUsers.length})'
                        : 'USUARIOS DEL GRUPO (${visibleUsers.length})',
                    style: const TextStyle(
                      fontSize: 11.2,
                      fontWeight: FontWeight.w900,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => setState(
                    () => _showAllUsersInCol4 = !_showAllUsersInCol4,
                  ),
                  child: Text(
                    _showAllUsersInCol4 ? 'Ver solo grupo' : 'Ver todos',
                    style: const TextStyle(
                      fontSize: 9.8,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (widget.canEdit) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Nuevo Usuario / Contacto',
                    constraints: const BoxConstraints(),
                    padding: EdgeInsets.zero,
                    onPressed: () => _showCreateContactDialog(),
                    icon: const Icon(
                      Icons.person_add_alt_1_rounded,
                      size: 15,
                      color: AppTheme.success,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Lista superior de usuarios (también arrastrables individualmente)
          Expanded(
            flex: 5,
            child: visibleUsers.isEmpty
                ? const Center(
                    child: Text(
                      'Sin usuarios en este grupo. Pulsa "Ver todos" o edita el grupo.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 10.5, color: AppTheme.textMuted),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: visibleUsers.length,
                    itemBuilder: (ctx, i) {
                      final c = visibleUsers[i];
                      final cId = c['id'] as int;
                      final isSelected = selectedUser?['id'] == cId;
                      final srcType = (c['source_type'] as String?) ?? 'custom';
                      final srcBadge =
                          (c['source_badge'] as String?) ?? 'A Medida';
                      final hostCodes =
                          ((c['alerting_host_codes'] as List?) ?? [])
                              .cast<String>();

                      final userTile = GestureDetector(
                        onTap: () =>
                            setState(() => _selectedAlertContactId = cId),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppTheme.success.withValues(alpha: 0.09)
                                : AppTheme.bgPrimary,
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(
                              color: isSelected
                                  ? AppTheme.success
                                  : AppTheme.border,
                              width: isSelected ? 1.8 : 1.0,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.person_rounded,
                                    size: 15,
                                    color: AppTheme.success,
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: Text(
                                      '${c['full_name']}',
                                      style: const TextStyle(
                                        fontSize: 11.0,
                                        fontWeight: FontWeight.w800,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  _buildOriginBadge(srcType, srcBadge),
                                  if (widget.canEdit) ...[
                                    const SizedBox(width: 4),
                                    InkWell(
                                      onTap: () =>
                                          _showCreateContactDialog(existing: c),
                                      child: const Icon(
                                        Icons.edit_outlined,
                                        size: 13.5,
                                        color: AppTheme.textMuted,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 3),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.mail_outline_rounded,
                                    size: 11,
                                    color: AppTheme.accentCyan,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      '${c['email']}',
                                      style: const TextStyle(
                                        fontSize: 9.6,
                                        fontFamily: 'monospace',
                                        fontWeight: FontWeight.w700,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Text(
                                    '🔔 ${hostCodes.length} hosts',
                                    style: const TextStyle(
                                      fontSize: 9.0,
                                      fontWeight: FontWeight.w800,
                                      color: AppTheme.accentTeal,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );

                      if (!widget.canEdit) return userTile;
                      return Draggable<String>(
                        data: 'u:$cId',
                        feedback: Material(
                          elevation: 8,
                          borderRadius: BorderRadius.circular(9),
                          color: AppTheme.success,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Text(
                              '👤 Asignar Usuario: ${c['full_name']} (${c['email']})',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                        childWhenDragging: Opacity(
                          opacity: 0.45,
                          child: userTile,
                        ),
                        child: userTile,
                      );
                    },
                  ),
          ),
          // Ficha Inferior estilo Active Directory ("MemberOf" y "Hosts que le envían alarmas")
          if (selectedUser != null)
            Expanded(
              flex: 6,
              child: _buildActiveDirectoryUserInspector(selectedUser),
            ),
        ],
      ),
    );
  }

  Widget _buildActiveDirectoryUserInspector(Map<String, dynamic> user) {
    final memberOfGroups =
        ((user['member_of_groups'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
    final alertingHgs =
        ((user['alerting_host_group_codes'] as List?) ?? []).cast<String>();
    final alertingHosts =
        ((user['alerting_host_codes'] as List?) ?? []).cast<String>();

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: const BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(11)),
        border: Border(top: BorderSide(color: AppTheme.border, width: 1.2)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.badge_rounded,
                  size: 15,
                  color: AppTheme.accentBlue,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    'FICHA ACTIVE DIRECTORY: ${user['full_name']}',
                    style: const TextStyle(
                      fontSize: 10.6,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.accentBlue,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'DN / Origen: ${user['ad_dn'] ?? user['role_title'] ?? ''}',
              style: const TextStyle(
                fontSize: 9.0,
                fontFamily: 'monospace',
                color: AppTheme.textMuted,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              'Correo personal: ${user['email']} • Horario: ${user['schedule_period'] ?? '24x7'}',
              style: const TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 7),
            const Text(
              '1. GRUPOS A LOS QUE PERTENECE (MemberOf):',
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w900,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            if (memberOfGroups.isEmpty)
              const Text(
                'No pertenece a ningún grupo todavía.',
                style: TextStyle(fontSize: 9.2, color: AppTheme.textMuted),
              )
            else
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: memberOfGroups
                    .map(
                      (g) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.accentPurple.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(
                            color: AppTheme.accentPurple.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Text(
                          '👥 ${g['name']} (${g['group_email']})',
                          style: const TextStyle(
                            fontSize: 8.8,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.accentPurple,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            const SizedBox(height: 8),
            const Text(
              '2. HOSTS Y GRUPOS DE HOST QUE LE ENVÍAN ALARMAS:',
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w900,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            if (alertingHgs.isEmpty && alertingHosts.isEmpty)
              const Text(
                'Ningún Host asignado aún. Arrastra su Grupo (Col 3) o este Usuario (Col 4) hacia un Grupo de Host (Col 1) o Host (Col 2).',
                style: TextStyle(fontSize: 9.0, color: AppTheme.textMuted),
              )
            else
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  ...alertingHgs.map(
                    (hgc) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.accentCyan.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '📁 $hgc',
                        style: const TextStyle(
                          fontSize: 8.8,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.accentCyan,
                        ),
                      ),
                    ),
                  ),
                  ...alertingHosts.map(
                    (hc) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.accentTeal.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '🖥️ $hc',
                        style: const TextStyle(
                          fontSize: 8.8,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.accentTeal,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceFilterChip(String key, String label) {
    final selected = _alertGroupSourceFilter == key;
    return InkWell(
      onTap: () => setState(() => _alertGroupSourceFilter = key),
      borderRadius: BorderRadius.circular(5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.accentPurple.withValues(alpha: 0.15)
              : AppTheme.bgPrimary,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: selected ? AppTheme.accentPurple : AppTheme.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 9.2,
            fontWeight: FontWeight.w800,
            color: selected ? AppTheme.accentPurple : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildOriginBadge(String srcType, String srcBadge) {
    final Color c = srcType == 'ad'
        ? AppTheme.accentBlue
        : (srcType == 'local' ? AppTheme.accentTeal : AppTheme.warning);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        srcBadge,
        style: TextStyle(
          fontSize: 8.4,
          fontWeight: FontWeight.w800,
          color: c,
        ),
      ),
    );
  }

  Widget _buildAssignedRecipientPill({
    required String label,
    required String email,
    required Color color,
    VoidCallback? onRemove,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              email.isNotEmpty ? '$label ($email)' : label,
              style: TextStyle(
                fontSize: 8.9,
                fontWeight: FontWeight.w800,
                color: color,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onRemove != null) ...[
            const SizedBox(width: 4),
            InkWell(
              onTap: onRemove,
              child: Icon(Icons.close_rounded, size: 12, color: color),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _handleDropRecipientOnTarget({
    required String dragToken,
    required String scopeType,
    int? hostGroupId,
    int? assetId,
    required String targetName,
  }) async {
    final isGroup = dragToken.startsWith('ug:');
    final id = int.tryParse(dragToken.split(':').last);
    if (id == null) return;

    final res = await widget.api.createNotificationRule({
      'name': 'Enrutamiento AD/Alarma -> $targetName',
      'description': 'Asignado arrastrando en Matriz Active Directory',
      'enabled': true,
      'scope_type': scopeType,
      'host_group_id': hostGroupId,
      'asset_id': assetId,
      'contact_group_ids': isGroup ? [id] : <int>[],
      'contact_ids': isGroup ? <int>[] : [id],
      'send_email': true,
      'send_webhook': true,
      'only_on_hard_state': true,
    });
    setState(() => _overview = res);
    _showSnack('Alarma asignada a $targetName.');
  }

  Future<void> _removeRecipientFromTarget({
    required String scopeType,
    int? hostGroupId,
    int? assetId,
    int? removeCgId,
    int? removeContactId,
  }) async {
    final matchingRules = _notificationRules.where((r) {
      if (scopeType == 'host_group') {
        return r['scope_type'] == 'host_group' &&
            r['host_group_id'] == hostGroupId;
      }
      return r['scope_type'] == 'single_host' && r['asset_id'] == assetId;
    }).toList();

    final currentCgIds = <int>{};
    final currentContactIds = <int>{};
    for (final r in matchingRules) {
      for (final id in ((r['contact_group_ids'] as List?) ?? [])) {
        currentCgIds.add(id as int);
      }
      for (final id in ((r['contact_ids'] as List?) ?? [])) {
        currentContactIds.add(id as int);
      }
    }
    if (removeCgId != null) currentCgIds.remove(removeCgId);
    if (removeContactId != null) currentContactIds.remove(removeContactId);

    final res = await widget.api.createNotificationRule({
      'name': 'Enrutamiento Actualizado',
      'description': '__REPLACE__',
      'enabled': true,
      'scope_type': scopeType,
      'host_group_id': hostGroupId,
      'asset_id': assetId,
      'contact_group_ids': currentCgIds.toList(),
      'contact_ids': currentContactIds.toList(),
      'send_email': true,
      'send_webhook': true,
      'only_on_hard_state': true,
    });
    setState(() => _overview = res);
  }

  Widget _buildAlertsBottomMaintenanceAndLogsBar() {
    return Container(
      height: 125,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: AppTheme.bgSecondary,
        border: Border(top: BorderSide(color: AppTheme.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Ventanas de mantenimiento
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '🛠️ VENTANAS DE MANTENIMIENTO (${_maintenanceWindows.length})',
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.accentCyan,
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: ListView(
                    children: _maintenanceWindows
                        .map(
                          (w) => Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.build_circle_rounded,
                                  size: 13,
                                  color: w['is_active'] == true
                                      ? AppTheme.accentCyan
                                      : AppTheme.textMuted,
                                ),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: Text(
                                    '${w['title']} (${w['is_active'] == true ? "ACTIVA" : "FINALIZADA"}) • ${w['reason']}',
                                    style: const TextStyle(fontSize: 10),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (w['is_active'] == true && widget.canEdit)
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                      ),
                                      minimumSize: Size.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: () async {
                                      final res = await widget.api
                                          .stopMaintenanceWindow(
                                            w['id'] as int,
                                          );
                                      setState(() => _overview = res);
                                    },
                                    child: const Text(
                                      'Finalizar',
                                      style: TextStyle(fontSize: 9.5),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 20),
          // Bitácora de envíos de correo / webhook
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '📨 BITÁCORA DE CORREOS Y AVISOS ENVIADOS (${_alertLogs.length})',
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.warning,
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: ListView(
                    children: _alertLogs
                        .take(12)
                        .map(
                          (lg) => Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(
                              '• [${lg['event_state']}] ${lg['asset_code']} ➔ ${lg['recipients_summary']} (${lg['delivery_status']})',
                              style: const TextStyle(fontSize: 9.8),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 6: AUTOMATIZACIÓN ANSIBLE, WEBHOOKS & GUÍA PARA AGENTES IA
  // ===========================================================================

  Widget _buildAnsibleWebhooksAndAiDocsTab() {
    final apiKey =
        (_summary['automation_api_key_hint'] as String?) ??
        'rackdoc-ansible-secret-key-2026';

    final playbookUpsert = '''---
# Playbook Ansible: Alta / Actualización de Host en RackDoc + CMDB + Prometheus SD
- name: Registrar Servidor en RackDoc Red & Host y Prometheus
  hosts: all
  tasks:
    - name: Notificar alta a RackDoc Webhook
      ansible.builtin.uri:
        url: "http://localhost:8180/api/v1/automation/webhook/host-upsert"
        method: POST
        headers:
          X-API-Key: "$apiKey"
        body_format: json
        body:
          code: "{{ inventory_hostname | upper }}"
          hostname: "{{ ansible_hostname }}"
          fqdn: "{{ ansible_fqdn }}"
          asset_class: "virtual_machine"
          environment: "production"
          primary_ip: "{{ ansible_default_ipv4.address }}"
          host_rack_device_code: "SRV-ESXI-01"
          host_groups:
            - "HG-WEB-APACHE-NGINX"
          exporters:
            - type: "node_exporter"
              port: 9100
            - type: "nginx"
              port: 8080
              url: "http://{{ ansible_default_ipv4.address }}:8080/nginx_status"
          heartbeats:
            - name: "Portal Corporativo HTTPS"
              type: "https"
              port: 443
              url: "https://{{ ansible_fqdn }}/health"''';

    final playbookMaint = '''---
# Playbook Ansible: Ventana de Mantenimiento Automática (pre_tasks / post_tasks)
- name: Despliegue sin Falsas Alarmas
  hosts: webservers
  pre_tasks:
    - name: Activar modo Mantenimiento en RackDoc
      ansible.builtin.uri:
        url: "http://localhost:8180/api/v1/automation/webhook/maintenance"
        method: POST
        headers:
          X-API-Key: "$apiKey"
        body_format: json
        body:
          action: "start"
          title: "Despliegue Ansible Release"
          duration_minutes: 45
          host_group_code: "HG-WEB-APACHE-NGINX"
      delegate_to: localhost
      run_once: true
  post_tasks:
    - name: Desactivar modo Mantenimiento en RackDoc
      ansible.builtin.uri:
        url: "http://localhost:8180/api/v1/automation/webhook/maintenance"
        method: POST
        headers:
          X-API-Key: "$apiKey"
        body_format: json
        body:
          action: "stop"
          host_group_code: "HG-WEB-APACHE-NGINX"
      delegate_to: localhost
      run_once: true''';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.bgSecondary,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.smart_toy_rounded,
                    color: AppTheme.accentCyan,
                    size: 20,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'AUTOMATIZACIÓN VÍA ANSIBLE WEBHOOKS Y MANIFIESTO PARA AGENTES DE IA',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Documentación completa en el repositorio: docs/AUTOMATION_ANSIBLE_PROMETHEUS_AGENTS.md • Todos los webhooks regeneran automáticamente el Service Discovery de Prometheus.',
                style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  _buildCodeSnippetCard(
                    '1. Playbook Ansible: Alta / Actualización de Host + Prometheus SD',
                    playbookUpsert,
                  ),
                  _buildCodeSnippetCard(
                    '2. Playbook Ansible: Ventanas de Mantenimiento (start / stop)',
                    playbookMaint,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (_aiContextManifest != null)
                _buildCodeSnippetCard(
                  '3. Manifiesto JSON en Vivo para Agentes IA (GET /api/v1/automation/ai-context)',
                  const JsonEncoder.withIndent('  ').convert(_aiContextManifest),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCodeSnippetCard(String title, String code) {
    return Container(
      width: 520,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.accentCyan,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy_rounded, size: 15),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code));
                  _showSnack('Copiado al portapapeles');
                },
              ),
            ],
          ),
          Container(
            height: 250,
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.bgPrimary,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                code,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // DIÁLOGO DE CONFIGURACIÓN / ALTA DE ELEMENTO ESTILO DATACENTER FLOOR
  // ===========================================================================

  Future<void> _showCreateVirtualMachineWithServicesDialog({
    bool attachToCurrentStack = false,
    Map<String, dynamic>? existingHost,
    String? initialAssetClass,
    Offset? initialDropPosition,
  }) async {
    final isEdit = existingHost != null;
    final activeStack = _activeStack;
    final stackNodes = ((activeStack['nodes'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final stackEdges = ((activeStack['edges'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    Map<String, dynamic>? matchedStackNode;
    if (isEdit) {
      for (final n in stackNodes) {
        if ((n['host'] as Map?)?['id'] == existingHost['id']) {
          matchedStackNode = n;
          break;
        }
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.bgCard,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppTheme.border),
        ),
        child: SizedBox(
          width: 470,
          height: 760,
          child: _DatacenterStyleHostConfigPanel(
            host: existingHost ??
                <String, dynamic>{
                  'code': 'ELEM-${DateTime.now().millisecondsSinceEpoch % 1000}',
                  'name': 'Nuevo Sistema / Servidor / VM',
                  'hostname': 'srv-app-01',
                  'fqdn': 'srv-app-01.hq.local',
                  'asset_class': initialAssetClass ?? 'virtual_machine',
                  'os_or_firmware': 'Ubuntu Server 24.04 LTS',
                  'heartbeat_ip': '10.20.20.160',
                  'hosting_mode': 'cluster_pool',
                  'cluster_or_pool_name':
                      'VMware vSphere / ESXi Cluster (HA / DRS)',
                  'monitoring_enabled': true,
                  'connect_enabled': true,
                  'ssh_enabled': true,
                  'ssh_user': 'root',
                  'ssh_port': 22,
                },
            stackNode: matchedStackNode,
            allStackNodes: stackNodes,
            nodeEdges: matchedStackNode != null
                ? stackEdges
                      .where(
                        (e) =>
                            e['source_node_id'] == matchedStackNode!['id'] ||
                            e['target_node_id'] == matchedStackNode['id'],
                      )
                      .toList()
                : const [],
            hostsList: _hosts,
            canEdit: widget.canEdit,
            isModalDialog: true,
            isNewElement: !isEdit,
            onCloseModal: () => Navigator.pop(ctx),
            onOpenSsh: isEdit
                ? () {
                    Navigator.pop(ctx);
                    _showSshWebConsoleDialog(
                      matchedStackNode ?? {'ssh_user': 'root', 'ssh_port': 22},
                      existingHost,
                    );
                  }
                : null,
            onSaveHostConfig: (payload) async {
              try {
                final res = await widget.api.createNetworkHostWithServices(
                  payload,
                );
                if (res['overview'] is Map) {
                  final created = Map<String, dynamic>.from(
                    (res['created_host'] as Map?) ?? {},
                  );
                  final newAssetId = created['asset_id'] as int?;
                  if (!isEdit &&
                      attachToCurrentStack &&
                      _selectedStackId != null &&
                      newAssetId != null) {
                    final dropPos =
                        initialDropPosition ?? const Offset(0.32, 0.34);
                    final stackUpdated = await widget.api.createTechStackNode({
                      'stack_id': _selectedStackId,
                      'asset_id': newAssetId,
                      'role_layer': 'app_middleware',
                      'custom_label': '${payload['name']}',
                      'pos_x': dropPos.dx.clamp(0.02, 0.86),
                      'pos_y': dropPos.dy.clamp(0.03, 0.84),
                      'width_px': 236.0,
                      'height_px': 134.0,
                      'ssh_enabled':
                          payload['connect_enabled'] == true &&
                          payload['ssh_enabled'] == true,
                      'ssh_user': payload['ssh_user'] ?? 'root',
                      'ssh_port': payload['ssh_port'] ?? 22,
                    });
                    if (mounted) {
                      setState(() {
                        _overview = stackUpdated;
                        _selectedHostId = newAssetId;
                        _syncStackCanvasState();
                      });
                    }
                  } else if (mounted) {
                    setState(() {
                      _overview = Map<String, dynamic>.from(
                        res['overview'] as Map,
                      );
                      if (newAssetId != null) {
                        _selectedHostId = newAssetId;
                      }
                      _syncStackCanvasState();
                    });
                  }
                  if (_selectedHostId != null) {
                    _loadHostTelemetry(_selectedHostId!);
                  }
                }
                if (ctx.mounted) Navigator.pop(ctx);
                _showSnack(
                  isEdit
                      ? 'Configuración de ${payload['code']} guardada.'
                      : 'Elemento ${payload['code']} añadido y sincronizado con CMDB y Prometheus.',
                );
              } catch (e) {
                _showSnack('Error al guardar elemento: $e', isError: true);
              }
            },
          ),
        ),
      ),
    );
  }

  Future<void> _showCreateTechStackDialog() async {
    final codeCtrl = TextEditingController(text: 'STACK-WEB-MICROSERVICIOS');
    final nameCtrl = TextEditingController(
      text: 'Stack 3: Frontales Web, API Gateway & Base de Datos',
    );
    final serviceCtrl = TextEditingController(
      text: 'Plataforma Digital & APIs',
    );
    final descCtrl = TextEditingController(
      text: 'Esquema lógico de balanceo, frontales web y clúster de datos.',
    );

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Crear Nuevo Stack Tecnológico / Esquema de Negocio'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: codeCtrl,
                decoration: const InputDecoration(
                  labelText: 'Código del Stack (ej. STACK-PORTAL-B2B)',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Nombre del Stack Tecnológico',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: serviceCtrl,
                decoration: const InputDecoration(
                  labelText: 'Servicio de Negocio',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: descCtrl,
                decoration: const InputDecoration(labelText: 'Descripción'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final res = await widget.api.upsertTechStackDiagram({
                'code': codeCtrl.text.trim(),
                'name': nameCtrl.text.trim(),
                'business_service': serviceCtrl.text.trim(),
                'description': descCtrl.text.trim(),
              });
              setState(() {
                _overview = res;
                final stacks = _techStacks;
                if (stacks.isNotEmpty) {
                  _selectedStackId = stacks.last['id'] as int;
                }
              });
              _showSnack('Stack Tecnológico creado.');
            },
            child: const Text('Crear Stack'),
          ),
        ],
      ),
    );
  }

  Future<void> _showSshWebConsoleDialog(
    Map<String, dynamic> sn,
    Map<String, dynamic> host,
  ) async {
    final assetId = host['id'] as int;
    final ip = (host['heartbeat_ip'] as String?) ?? '127.0.0.1';
    final sshUser = (sn['ssh_user'] as String?) ?? 'root';
    final sshPort = (sn['ssh_port'] as int?) ?? 22;
    final sshCmd = sshPort == 22
        ? 'ssh $sshUser@$ip'
        : 'ssh -p $sshPort $sshUser@$ip';
    final sshUri = 'ssh://$sshUser@$ip:$sshPort';
    final cmdCtrl = TextEditingController(
      text: 'uptime && df -h / && free -m && ss -tulpn',
    );
    String consoleOutput =
        'Conectando a $sshUser@$ip:$sshPort (${host['code']})...';
    bool runningCmd = true;

    // Ejecutar diagnóstico inicial
    widget.api
        .executeHostSshConsole({
          'asset_id': assetId,
          'command': cmdCtrl.text,
          'ssh_user': sshUser,
          'ssh_port': sshPort,
        })
        .then((res) {
          consoleOutput = (res['output'] as String?) ?? '';
          runningCmd = false;
        });

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) {
          if (runningCmd) {
            Future<void>.delayed(const Duration(milliseconds: 350), () {
              if (ctx.mounted) setModal(() => runningCmd = false);
            });
          }
          return AlertDialog(
            title: Row(
              children: [
                const Icon(
                  Icons.terminal_rounded,
                  color: AppTheme.accentCyan,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Consola Remota SSH — ${host['code']} ($sshCmd)',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 680,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () {
                          launchUrl(
                            Uri.parse(sshUri),
                            mode: LaunchMode.externalApplication,
                          );
                        },
                        icon: const Icon(Icons.open_in_new_rounded, size: 15),
                        label: Text(
                          'Abrir Cliente SSH del Sistema ($sshUri)',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: sshCmd));
                          _showSnack('Comando "$sshCmd" copiado');
                        },
                        icon: const Icon(Icons.copy_rounded, size: 14),
                        label: Text(
                          'Copiar "$sshCmd"',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: cmdCtrl,
                          style: const TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                          decoration: const InputDecoration(
                            labelText:
                                'Comando Remoto SSH a Ejecutar en el Host',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: () async {
                          final res = await widget.api.executeHostSshConsole({
                            'asset_id': assetId,
                            'command': cmdCtrl.text.trim(),
                            'ssh_user': sshUser,
                            'ssh_port': sshPort,
                          });
                          setModal(() {
                            consoleOutput = (res['output'] as String?) ?? '';
                          });
                        },
                        icon: const Icon(Icons.play_arrow_rounded, size: 16),
                        label: const Text('Ejecutar'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    height: 260,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        consoleOutput,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: Color(0xFF4ADE80),
                          height: 1.35,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cerrar Consola'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showSnmpDiscoveryDialog() async {
    final ipCtrl = TextEditingController(text: '10.20.10.2');
    final commCtrl = TextEditingController(text: 'public');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Autodescubrir Switch por SNMP (IF-MIB + LLDP-MIB)'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Interroga todas las bocas del Switch, velocidades, VLANs, caudal y vecinos LLDP sin tener que dar de alta puerto a puerto, y los sincroniza con el Rack Editor.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ipCtrl,
                decoration: const InputDecoration(
                  labelText: 'IP de Gestión del Switch',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: commCtrl,
                decoration: const InputDecoration(
                  labelText: 'Comunidad SNMPv2c / Usuario SNMPv3',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              final res = await widget.api.runSnmpSwitchDiscovery({
                'target_ip': ipCtrl.text.trim(),
                'community': commCtrl.text.trim(),
                'sync_ports_to_rack_device': true,
              });
              if (res['overview'] is Map) {
                setState(() {
                  _overview = Map<String, dynamic>.from(res['overview'] as Map);
                });
              }
              final disc = Map<String, dynamic>.from(
                (res['discovery'] as Map?) ?? {},
              );
              _showSnack(
                'Switch descubierto (${disc['asset_code']}): ${disc['discovered_ports_count']} bocas y ${disc['lldp_neighbors_count']} vecinos LLDP sincronizados.',
              );
            },
            icon: const Icon(Icons.radar_rounded, size: 16),
            label: const Text('Ejecutar SNMP Walk'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCreateServiceCheckDialog() async {
    if (_hosts.isEmpty) return;
    int assetId = _selectedHostId ?? (_hosts.first['id'] as int);
    String checkType = 'https';
    final customTypeCtrl = TextEditingController();
    final nameCtrl = TextEditingController(
      text: 'Portal HTTPS & Validez Certificado SSL',
    );
    final urlCtrl = TextEditingController(
      text: 'https://portal.empresa.local/health',
    );
    final portCtrl = TextEditingController(text: '443');
    final expectedStatusCtrl = TextEditingController(text: '200');
    bool isEnabled = true;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text('Añadir Servicio, Exporter o Heartbeat'),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: assetId,
                  decoration: const InputDecoration(
                    labelText: 'Host / VM Destino',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: _hosts
                      .map(
                        (h) => DropdownMenuItem<int>(
                          value: h['id'] as int,
                          child: Text('${h['code']} — ${h['name']}'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setModal(() => assetId = v ?? assetId),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: checkType,
                  decoration: const InputDecoration(
                    labelText: 'Protocolo / Conector / Servicio',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'https',
                      child: Text('HTTPS + Validez Certificado SSL/TLS'),
                    ),
                    DropdownMenuItem(
                      value: 'http',
                      child: Text('HTTP Web Status Code'),
                    ),
                    DropdownMenuItem(
                      value: 'icmp',
                      child: Text('ICMP Ping Heartbeat'),
                    ),
                    DropdownMenuItem(value: 'tcp', child: Text('Puerto TCP')),
                    DropdownMenuItem(value: 'udp', child: Text('Puerto UDP')),
                    DropdownMenuItem(
                      value: 'ssh',
                      child: Text('SSH Banner (:22)'),
                    ),
                    DropdownMenuItem(
                      value: 'snmp',
                      child: Text('SNMP Agente (:161/UDP)'),
                    ),
                    DropdownMenuItem(
                      value: 'apache',
                      child: Text('Apache HTTPd (mod_status)'),
                    ),
                    DropdownMenuItem(
                      value: 'nginx',
                      child: Text('Nginx (stub_status)'),
                    ),
                    DropdownMenuItem(
                      value: 'docker',
                      child: Text('Docker Engine (:9323)'),
                    ),
                    DropdownMenuItem(
                      value: 'postgres',
                      child: Text('PostgreSQL (:5432)'),
                    ),
                    DropdownMenuItem(
                      value: 'mysql',
                      child: Text('MySQL / MariaDB (:3306)'),
                    ),
                    DropdownMenuItem(
                      value: 'redis',
                      child: Text('Redis Cache (:6379)'),
                    ),
                    DropdownMenuItem(
                      value: 'node_exporter',
                      child: Text('Prometheus Linux Node Exporter (:9100)'),
                    ),
                    DropdownMenuItem(
                      value: 'windows_exporter',
                      child: Text('Prometheus Windows Exporter (:9182)'),
                    ),
                    DropdownMenuItem(
                      value: '__CUSTOM__',
                      child: Text(
                        '✨ Otro Servicio / Conector Personalizado (Escribir a medida)...',
                      ),
                    ),
                  ],
                  onChanged: (v) =>
                      setModal(() => checkType = v ?? checkType),
                ),
                if (checkType == '__CUSTOM__') ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: customTypeCtrl,
                    decoration: const InputDecoration(
                      labelText:
                          'Identificador de Conector / Protocolo Personalizado',
                      hintText:
                          'Ej: rabbitmq, kafka, tomcat_jmx, custom_exporter, grpc...',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nombre del Servicio / Heartbeat',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: urlCtrl,
                        decoration: const InputDecoration(
                          labelText: 'IP o URL / Endpoint de Destino',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: portCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Puerto',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: expectedStatusCtrl,
                        decoration: const InputDecoration(
                          labelText: 'HTTP Code',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: isEnabled,
                  onChanged: (v) => setModal(() => isEnabled = v),
                  title: const Text(
                    'Activar Heartbeat / Scrape en Prometheus',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text(
                    'Puedes dejar el servicio registrado como desactivado si aún está en mantenimiento.',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () async {
                final resolvedType = checkType == '__CUSTOM__'
                    ? (customTypeCtrl.text.trim().isEmpty
                          ? 'custom_exporter'
                          : customTypeCtrl.text.trim())
                    : checkType;
                Navigator.pop(ctx);
                final res = await widget.api.createNetworkServiceCheck({
                  'asset_id': assetId,
                  'service_name': nameCtrl.text.trim(),
                  'check_type': resolvedType,
                  'target_ip_or_url': urlCtrl.text.trim(),
                  'port': int.tryParse(portCtrl.text.trim()) ?? 443,
                  'expected_status_code':
                      int.tryParse(expectedStatusCtrl.text.trim()) ?? 200,
                  'enabled': isEnabled,
                });
                setState(() => _overview = res);
                _showSnack('Servicio / Heartbeat registrado.');
              },
              child: const Text('Guardar Servicio'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreateLogicalLinkDialog() async {
    if (_hosts.length < 2) return;
    int srcId = _hosts.first['id'] as int;
    int dstId = _hosts[1]['id'] as int;
    final srcIfCtrl = TextEditingController(text: 'Gi1/0/10');
    final dstIfCtrl = TextEditingController(text: 'eth0');
    final protoCtrl = TextEditingController(text: '10GbE / HTTPS / LLDP');

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text('Documentar Enlace Lógico de Conexión'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: srcId,
                  decoration: const InputDecoration(labelText: 'Nodo Origen'),
                  items: _hosts
                      .map(
                        (h) => DropdownMenuItem<int>(
                          value: h['id'] as int,
                          child: Text('${h['code']} — ${h['name']}'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setModal(() => srcId = v ?? srcId),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  initialValue: dstId,
                  decoration: const InputDecoration(labelText: 'Nodo Destino'),
                  items: _hosts
                      .map(
                        (h) => DropdownMenuItem<int>(
                          value: h['id'] as int,
                          child: Text('${h['code']} — ${h['name']}'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setModal(() => dstId = v ?? dstId),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: srcIfCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Interfaz Origen',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: dstIfCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Interfaz Destino',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: protoCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Protocolo / Etiqueta del Enlace',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final res = await widget.api.createLogicalLink({
                  'source_asset_id': srcId,
                  'target_asset_id': dstId,
                  'source_interface': srcIfCtrl.text.trim(),
                  'target_interface': dstIfCtrl.text.trim(),
                  'protocol_label': protoCtrl.text.trim(),
                });
                setState(() => _overview = res);
                _showSnack('Enlace lógico añadido al diagrama.');
              },
              child: const Text('Añadir al Diagrama'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreateConnectorDialog() async {
    String connType = 'proxmox';
    final nameCtrl = TextEditingController(text: 'Nuevo Conector Proxmox / Docker');
    final hostCtrl = TextEditingController(text: '10.20.10.25');
    final portCtrl = TextEditingController(text: '8006');
    final userCtrl = TextEditingController(text: 'root@pam');

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text('Registrar Conector de Infraestructura'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: connType,
                  decoration: const InputDecoration(
                    labelText: 'Tipo de Conector',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'proxmox',
                      child: Text('Proxmox VE API (QEMU / LXC)'),
                    ),
                    DropdownMenuItem(
                      value: 'vmware_esxi',
                      child: Text('VMware vSphere / ESXi'),
                    ),
                    DropdownMenuItem(
                      value: 'docker_engine',
                      child: Text('Docker Engine / Portainer'),
                    ),
                    DropdownMenuItem(
                      value: 'apache_status',
                      child: Text('Apache HTTPd (mod_status)'),
                    ),
                    DropdownMenuItem(
                      value: 'nginx_status',
                      child: Text('Nginx (stub_status)'),
                    ),
                    DropdownMenuItem(
                      value: 'postgres_db',
                      child: Text('PostgreSQL / MySQL Database'),
                    ),
                    DropdownMenuItem(
                      value: 'snmp_switch',
                      child: Text('Switch SNMPv2c/v3 (IF-MIB + LLDP)'),
                    ),
                  ],
                  onChanged: (v) => setModal(() => connType = v ?? connType),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nombre Descriptivo',
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: hostCtrl,
                        decoration: const InputDecoration(
                          labelText: 'IP o Hostname',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: portCtrl,
                        decoration: const InputDecoration(labelText: 'Puerto'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: userCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Usuario / Token / Comunidad SNMP',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final res = await widget.api.createInfraConnector({
                  'name': nameCtrl.text.trim(),
                  'connector_type': connType,
                  'endpoint_host': hostCtrl.text.trim(),
                  'endpoint_port': int.tryParse(portCtrl.text.trim()) ?? 8006,
                  'auth_username_or_community': userCtrl.text.trim(),
                  'linked_asset_id': _selectedHostId,
                });
                setState(() => _overview = res);
                _showSnack('Conector creado y sincronizado con Prometheus.');
              },
              child: const Text('Registrar Conector'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSmtpServerConfigDialog() async {
    final smtp = _smtpConfig;
    final hostCtrl = TextEditingController(
      text: (smtp['smtp_host'] as String?)?.isNotEmpty == true
          ? '${smtp['smtp_host']}'
          : 'smtp.corp.local',
    );
    final portCtrl = TextEditingController(
      text: '${smtp['smtp_port'] ?? 587}',
    );
    final userCtrl = TextEditingController(
      text: (smtp['smtp_username'] as String?) ?? 'alertas@corp.local',
    );
    final passCtrl = TextEditingController(text: '');
    final fromCtrl = TextEditingController(
      text: (smtp['from_email'] as String?)?.isNotEmpty == true
          ? '${smtp['from_email']}'
          : 'RackDoc Monitor <alertas@corp.local>',
    );
    final webhookCtrl = TextEditingController(
      text: (smtp['global_webhook_url'] as String?) ?? '',
    );
    bool useTls = smtp['use_tls'] != false;
    bool enabled = smtp['enabled'] != false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.mark_email_unread_rounded, color: AppTheme.accentBlue),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Alta y Configuración del Servidor de Correo SMTP',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Activar Envío de Correos SMTP en Alarmas',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    subtitle: const Text(
                      'Envía al correo concreto del Grupo de Usuarios y/o al correo personal de cada Usuario asignado.',
                      style: TextStyle(fontSize: 11),
                    ),
                    value: enabled,
                    onChanged: (v) => setModal(() => enabled = v),
                  ),
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: hostCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Servidor SMTP (Host / IP / Relay)',
                            hintText: 'smtp.office365.com o mail.corp.local',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: portCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Puerto',
                            hintText: '587 / 465 / 25',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Usar STARTTLS / TLS Seguro',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: useTls,
                    onChanged: (v) => setModal(() => useTls = v),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: userCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Usuario SMTP',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: passCtrl,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Contraseña / App Token',
                            hintText: '(Dejar vacío para conservar)',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: fromCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Remitente (From Email)',
                      hintText: 'RackDoc Noc <alertas@corp.local>',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: webhookCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Webhook Global Opcional (Teams / Slack / Telegram)',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final res = await widget.api.updateSmtpAlertConfig({
                  'smtp_host': hostCtrl.text.trim(),
                  'smtp_port': int.tryParse(portCtrl.text.trim()) ?? 587,
                  'use_tls': useTls,
                  'smtp_username': userCtrl.text.trim(),
                  'smtp_password': passCtrl.text,
                  'from_email': fromCtrl.text.trim(),
                  'global_webhook_url': webhookCtrl.text.trim(),
                  'enabled': enabled,
                });
                final testRes = await widget.api.triggerTestAlert(
                  assetId: _selectedHostId,
                );
                if (mounted) {
                  setState(() => _overview = testRes.isNotEmpty ? testRes : res);
                  _showSnack(
                    'Servidor SMTP guardado y correo de prueba disparado.',
                  );
                }
              },
              icon: const Icon(Icons.send_rounded, size: 15),
              label: const Text('Guardar y Enviar Prueba'),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                final res = await widget.api.updateSmtpAlertConfig({
                  'smtp_host': hostCtrl.text.trim(),
                  'smtp_port': int.tryParse(portCtrl.text.trim()) ?? 587,
                  'use_tls': useTls,
                  'smtp_username': userCtrl.text.trim(),
                  'smtp_password': passCtrl.text,
                  'from_email': fromCtrl.text.trim(),
                  'global_webhook_url': webhookCtrl.text.trim(),
                  'enabled': enabled,
                });
                setState(() => _overview = res);
                _showSnack('Servidor de correo SMTP configurado.');
              },
              icon: const Icon(Icons.save_rounded, size: 15),
              label: const Text('Guardar Servidor SMTP'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreateContactDialog({Map<String, dynamic>? existing}) async {
    String sourceOrigin = (existing?['source_type'] as String?) ?? 'custom';
    final codeCtrl = TextEditingController(
      text: (existing?['code'] as String?) ?? 'USR-NUEVO-OPS',
    );
    final nameCtrl = TextEditingController(
      text: (existing?['full_name'] as String?) ?? '',
    );
    final emailCtrl = TextEditingController(
      text: (existing?['email'] as String?) ?? '',
    );
    final roleCtrl = TextEditingController(
      text: (existing?['role_title'] as String?) ?? 'Ingeniero SRE / Guardia',
    );
    final scheduleCtrl = TextEditingController(
      text: (existing?['schedule_period'] as String?) ?? '24x7',
    );
    final selectedGroupIds = <int>{
      ...(((existing?['member_of_group_ids'] as List?) ?? []).cast<int>()),
      if (existing == null && _selectedAlertUserGroupId != null)
        _selectedAlertUserGroupId!,
    };

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: Text(
            existing != null
                ? 'Editar Usuario / Contacto (${existing['full_name']})'
                : 'Añadir Usuario / Contacto de Alarma (AD / Local / A Medida)',
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: sourceOrigin,
                    decoration: const InputDecoration(
                      labelText: 'Origen de la Cuenta (Control de Acceso / AD / Medida)',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'ad',
                        child: Text('Active Directory (LDAP / corp.local)'),
                      ),
                      DropdownMenuItem(
                        value: 'local',
                        child: Text('Usuario Local (Control de Acceso)'),
                      ),
                      DropdownMenuItem(
                        value: 'custom',
                        child: Text('Contacto Externo / A Medida'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setModal(() {
                        sourceOrigin = v;
                        if (existing == null) {
                          codeCtrl.text = v == 'ad'
                              ? 'USR-AD-NUEVO'
                              : (v == 'local'
                                    ? 'USR-LOCAL-NUEVO'
                                    : 'USR-CUSTOM-NUEVO');
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: codeCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Código Único / sAMAccountName',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: scheduleCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Horario (24x7 / Laboral)',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Nombre Completo del Usuario',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: emailCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Correo Electrónico Concreto del Usuario',
                      hintText: 'usuario@empresa.local',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: roleCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Rol / DN Active Directory / Departamento',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Pertenece a los Grupos de Usuarios (MemberOf):',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _alertContactGroups.map((cg) {
                      final gid = cg['id'] as int;
                      final isMember = selectedGroupIds.contains(gid);
                      return FilterChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          '${cg['name']} (${cg['group_email']})',
                          style: const TextStyle(fontSize: 10.5),
                        ),
                        selected: isMember,
                        onSelected: (val) => setModal(() {
                          if (val) {
                            selectedGroupIds.add(gid);
                          } else {
                            selectedGroupIds.remove(gid);
                          }
                        }),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (existing != null)
              TextButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  final res = await widget.api.deleteAlertContact(
                    existing['id'] as int,
                  );
                  setState(() => _overview = res);
                },
                icon: const Icon(
                  Icons.delete_outline,
                  size: 15,
                  color: AppTheme.error,
                ),
                label: const Text(
                  'Eliminar',
                  style: TextStyle(color: AppTheme.error),
                ),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final prefix = sourceOrigin == 'ad'
                    ? '[Active Directory] '
                    : (sourceOrigin == 'local' ? '[Usuario Local] ' : '');
                final rawRole = roleCtrl.text.trim();
                final finalRole = rawRole.startsWith('[')
                    ? rawRole
                    : '$prefix$rawRole';

                var res = await widget.api.upsertAlertContact({
                  'code': codeCtrl.text.trim(),
                  'full_name': nameCtrl.text.trim(),
                  'email': emailCtrl.text.trim(),
                  'role_title': finalRole,
                  'schedule_period': scheduleCtrl.text.trim().isNotEmpty
                      ? scheduleCtrl.text.trim()
                      : '24x7',
                });

                // Actualizar membresía MemberOf en los grupos de usuarios
                final updatedContacts =
                    ((res['alert_contacts'] as List?) ?? [])
                        .map((e) => Map<String, dynamic>.from(e as Map))
                        .toList();
                final savedUser = updatedContacts
                    .where(
                      (u) =>
                          (u['code'] as String? ?? '').toUpperCase() ==
                          codeCtrl.text.trim().toUpperCase(),
                    )
                    .firstOrNull;
                if (savedUser != null) {
                  final cid = savedUser['id'] as int;
                  for (final cg in _alertContactGroups) {
                    final gid = cg['id'] as int;
                    final members =
                        ((cg['member_contact_ids'] as List?) ?? [])
                            .cast<int>()
                            .toSet();
                    final shouldHave = selectedGroupIds.contains(gid);
                    if (shouldHave && !members.contains(cid)) {
                      members.add(cid);
                      res = await widget.api.upsertAlertContactGroup({
                        'code': cg['code'],
                        'name': cg['name'],
                        'description': cg['description'] ?? '',
                        'group_email': cg['group_email'] ?? '',
                        'channel_webhook_url': cg['channel_webhook_url'] ?? '',
                        'member_contact_ids': members.toList(),
                      });
                    } else if (!shouldHave && members.contains(cid)) {
                      members.remove(cid);
                      res = await widget.api.upsertAlertContactGroup({
                        'code': cg['code'],
                        'name': cg['name'],
                        'description': cg['description'] ?? '',
                        'group_email': cg['group_email'] ?? '',
                        'channel_webhook_url': cg['channel_webhook_url'] ?? '',
                        'member_contact_ids': members.toList(),
                      });
                    }
                  }
                }
                setState(() => _overview = res);
              },
              child: const Text('Guardar Usuario'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreateContactGroupDialog({
    Map<String, dynamic>? existing,
  }) async {
    String sourceOrigin = (existing?['source_type'] as String?) ?? 'custom';
    final codeCtrl = TextEditingController(
      text: (existing?['code'] as String?) ?? 'CG-GUARDIA-24X7',
    );
    final nameCtrl = TextEditingController(
      text: (existing?['name'] as String?) ?? 'Equipo Guardia 24x7',
    );
    final emailCtrl = TextEditingController(
      text: (existing?['group_email'] as String?) ?? 'guardia24x7@empresa.local',
    );
    final descCtrl = TextEditingController(
      text: (existing?['description'] as String?) ?? '',
    );
    final selectedMemberIds = <int>{
      ...(((existing?['member_contact_ids'] as List?) ?? []).cast<int>()),
    };

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: Text(
            existing != null
                ? 'Editar Grupo de Usuarios (${existing['name']})'
                : 'Crear Grupo de Usuarios (AD / Local / A Medida)',
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: sourceOrigin,
                    decoration: const InputDecoration(
                      labelText: 'Origen del Grupo',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'ad',
                        child: Text('Grupo Active Directory (OU=Groups,DC=corp,DC=local)'),
                      ),
                      DropdownMenuItem(
                        value: 'local',
                        child: Text('Grupo Local de Control de Acceso'),
                      ),
                      DropdownMenuItem(
                        value: 'custom',
                        child: Text('Grupo de Guardia a Medida'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setModal(() {
                        sourceOrigin = v;
                        if (existing == null) {
                          codeCtrl.text = v == 'ad'
                              ? 'CG-AD-NUEVO'
                              : (v == 'local'
                                    ? 'CG-LOCAL-NUEVO'
                                    : 'CG-CUSTOM-NUEVO');
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: codeCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Código del Grupo',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Nombre del Grupo (AD / Local / Guardia)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: emailCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Correo Concreto del Grupo (Lista de Distribución)',
                      hintText: 'grupo-alertas@empresa.local',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: descCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Descripción / DN de Active Directory',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Usuarios Miembros de este Grupo:',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _alertContacts.map((c) {
                      final cid = c['id'] as int;
                      final isSel = selectedMemberIds.contains(cid);
                      return FilterChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          '${c['full_name']} (${c['email']})',
                          style: const TextStyle(fontSize: 10.5),
                        ),
                        selected: isSel,
                        onSelected: (v) => setModal(() {
                          if (v) {
                            selectedMemberIds.add(cid);
                          } else {
                            selectedMemberIds.remove(cid);
                          }
                        }),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (existing != null)
              TextButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  final res = await widget.api.deleteAlertContactGroup(
                    existing['id'] as int,
                  );
                  setState(() => _overview = res);
                },
                icon: const Icon(
                  Icons.delete_outline,
                  size: 15,
                  color: AppTheme.error,
                ),
                label: const Text(
                  'Eliminar',
                  style: TextStyle(color: AppTheme.error),
                ),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final prefix = sourceOrigin == 'ad'
                    ? '[Active Directory] '
                    : (sourceOrigin == 'local' ? '[Grupo Local] ' : '');
                final rawDesc = descCtrl.text.trim();
                final finalDesc = rawDesc.startsWith('[')
                    ? rawDesc
                    : '$prefix$rawDesc';

                final res = await widget.api.upsertAlertContactGroup({
                  'code': codeCtrl.text.trim(),
                  'name': nameCtrl.text.trim(),
                  'description': finalDesc,
                  'group_email': emailCtrl.text.trim(),
                  'member_contact_ids': selectedMemberIds.toList(),
                });
                setState(() => _overview = res);
              },
              child: const Text('Guardar Grupo'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreateHostGroupDialog({
    Map<String, dynamic>? existing,
  }) async {
    final codeCtrl = TextEditingController(
      text: (existing?['code'] as String?) ?? 'HG-PRODUCCION-CRITICA',
    );
    final nameCtrl = TextEditingController(
      text: (existing?['name'] as String?) ?? 'Hosts Críticos Producción',
    );
    final selectedHostIds = <int>{
      ...(((existing?['member_asset_ids'] as List?) ?? []).cast<int>()),
      if (existing == null && _selectedHostId != null) _selectedHostId!,
    };

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: Text(
            existing != null
                ? 'Editar Grupo de Host (${existing['name']})'
                : 'Crear Grupo de Hosts (HostGroup)',
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: codeCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Código del HostGroup',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Nombre del HostGroup',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Hosts / Sistemas incluidos en este Grupo:',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _hosts.map((h) {
                      final hid = h['id'] as int;
                      final isSel = selectedHostIds.contains(hid);
                      return FilterChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          '${h['code']} (${h['heartbeat_ip'] ?? ''})',
                          style: const TextStyle(fontSize: 10.2),
                        ),
                        selected: isSel,
                        onSelected: (v) => setModal(() {
                          if (v) {
                            selectedHostIds.add(hid);
                          } else {
                            selectedHostIds.remove(hid);
                          }
                        }),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (existing != null)
              TextButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  final res = await widget.api.deleteHostGroup(
                    existing['id'] as int,
                  );
                  setState(() => _overview = res);
                },
                icon: const Icon(
                  Icons.delete_outline,
                  size: 15,
                  color: AppTheme.error,
                ),
                label: const Text(
                  'Eliminar',
                  style: TextStyle(color: AppTheme.error),
                ),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final res = await widget.api.upsertHostGroup({
                  'code': codeCtrl.text.trim(),
                  'name': nameCtrl.text.trim(),
                  'member_asset_ids': selectedHostIds.toList(),
                });
                setState(() => _overview = res);
              },
              child: const Text('Guardar HostGroup'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreateMaintenanceDialog() async {
    final titleCtrl = TextEditingController(
      text: 'Ventana de Mantenimiento Programada',
    );
    final reasonCtrl = TextEditingController(
      text: 'Actualización de parches y reinicio controlado',
    );
    final minsCtrl = TextEditingController(text: '60');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Activar Ventana de Mantenimiento (Silenciar Avisos)'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(labelText: 'Título'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: reasonCtrl,
                decoration: const InputDecoration(labelText: 'Motivo'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: minsCtrl,
                decoration: const InputDecoration(
                  labelText: 'Duración (minutos)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final res = await widget.api.createMaintenanceWindow({
                'title': titleCtrl.text.trim(),
                'reason': reasonCtrl.text.trim(),
                'scope_type': 'single_host',
                'asset_id': _selectedHostId,
                'duration_minutes': int.tryParse(minsCtrl.text.trim()) ?? 60,
              });
              setState(() => _overview = res);
              _showSnack('Ventana de mantenimiento activada.');
            },
            child: const Text('Activar Mantenimiento'),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// PANEL DE CONFIGURACIÓN DE ELEMENTO / HOST ESTILO DATACENTER FLOOR
// (USADO TANTO EN EL PANEL DERECHO DEL STACK COMO EN EL MODAL "+ AÑADIR ELEMENTO")
// =============================================================================

class _DatacenterStyleHostConfigPanel extends StatefulWidget {
  final Map<String, dynamic> host;
  final Map<String, dynamic>? stackNode;
  final List<Map<String, dynamic>> allStackNodes;
  final List<Map<String, dynamic>> nodeEdges;
  final List<Map<String, dynamic>> hostsList;
  final bool canEdit;
  final bool isModalDialog;
  final bool isNewElement;
  final VoidCallback? onCloseModal;
  final VoidCallback? onStartLinkMode;
  final ValueChanged<int>? onQuickConnectToNode;
  final ValueChanged<int>? onDeleteEdge;
  final VoidCallback? onOpenSsh;
  final VoidCallback? onOpenFloatingCharts;
  final Future<void> Function(Map<String, dynamic> payload) onSaveHostConfig;

  const _DatacenterStyleHostConfigPanel({
    super.key,
    required this.host,
    this.stackNode,
    required this.allStackNodes,
    required this.nodeEdges,
    required this.hostsList,
    required this.canEdit,
    this.isModalDialog = false,
    this.isNewElement = false,
    this.onCloseModal,
    this.onStartLinkMode,
    this.onQuickConnectToNode,
    this.onDeleteEdge,
    this.onOpenSsh,
    this.onOpenFloatingCharts,
    required this.onSaveHostConfig,
  });

  @override
  State<_DatacenterStyleHostConfigPanel> createState() =>
      _DatacenterStyleHostConfigPanelState();
}

class _DatacenterStyleHostConfigPanelState
    extends State<_DatacenterStyleHostConfigPanel> {
  late String _assetClass;
  late final TextEditingController _customClassCtrl;
  late final TextEditingController _codeCtrl;
  late final TextEditingController _nameCtrl;
  late final TextEditingController _ipCtrl;
  late final TextEditingController _fqdnCtrl;
  late final TextEditingController _osCtrl;

  late String _hostingMode;
  late String _clusterPreset;
  late final TextEditingController _customClusterCtrl;
  late String _parentAssetCode;

  // Sección A: Heartbeat (Background Monitoring) — idéntico al panel de Datacenter
  late bool _hbEnabled;
  late bool _hbIcmp;
  late bool _hbSsh;
  late bool _hbHttp;
  late String _hbHttpScheme;
  late bool _hbTcp;
  late bool _hbUdp;
  late bool _hbSnmp;

  late bool _expNode;
  late bool _expWin;
  late bool _expNginx;
  late bool _expApache;
  late bool _expDocker;
  late bool _expPostgres;
  late bool _expMysql;
  late bool _expRedis;

  late final TextEditingController _hbSshPortCtrl;
  late final TextEditingController _hbHttpUrlCtrl;
  late final TextEditingController _hbHttpPortCtrl;
  late final TextEditingController _hbTcpPortCtrl;
  late final TextEditingController _hbTcpNameCtrl;
  late final TextEditingController _hbUdpPortCtrl;
  late final TextEditingController _hbSnmpCommCtrl;

  final List<Map<String, dynamic>> _customChecks = [];
  bool _showAddCustomCheckRow = false;
  final TextEditingController _customChkNameCtrl = TextEditingController(
    text: 'Servicio Custom',
  );
  final TextEditingController _customChkTypeCtrl = TextEditingController(
    text: 'tcp',
  );
  final TextEditingController _customChkPortCtrl = TextEditingController(
    text: '8443',
  );
  final TextEditingController _customChkUrlCtrl = TextEditingController();

  // Sección B: Conectar (Ejecutado desde el Frontend) — idéntico al panel de Datacenter
  late bool _connEnabled;
  late bool _connSsh;
  late bool _connHttp;
  late bool _connHttps;
  late final TextEditingController _connSshHostCtrl;
  late final TextEditingController _connSshPortCtrl;
  late final TextEditingController _connSshUserCtrl;
  late final TextEditingController _connHttpUrlCtrl;
  late final TextEditingController _connHttpsUrlCtrl;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final h = widget.host;
    final checks = ((h['service_checks'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    const presetClasses = {
      'virtual_machine',
      'container',
      'physical_server',
      'vip_cluster',
      'network_security',
      'storage_san_nas',
      'custom',
    };
    String rawClass = (h['asset_class'] as String?) ?? 'virtual_machine';
    if (rawClass == 'container_lxc') rawClass = 'container';
    if (rawClass == 'cluster_vip') rawClass = 'vip_cluster';
    _assetClass = presetClasses.contains(rawClass) ? rawClass : 'custom';
    _customClassCtrl = TextEditingController(
      text: (h['custom_asset_class_label'] as String?) ?? '',
    );

    _codeCtrl = TextEditingController(
      text: (h['code'] as String?) ?? 'ELEM-01',
    );
    _nameCtrl = TextEditingController(
      text: (h['name'] as String?) ?? 'Servidor / Servicio',
    );
    _ipCtrl = TextEditingController(
      text: (h['heartbeat_ip'] as String?) ?? '10.20.20.160',
    );
    _fqdnCtrl = TextEditingController(
      text: (h['fqdn'] as String?) ?? (h['hostname'] as String?) ?? '',
    );
    _osCtrl = TextEditingController(
      text: (h['os_or_firmware'] as String?) ?? 'Ubuntu Server 24.04 LTS',
    );

    _hostingMode = (h['hosting_mode'] as String?) ?? 'cluster_pool';
    if (!const {
      'cluster_pool',
      'physical_rack_server',
      'standalone',
    }.contains(_hostingMode)) {
      _hostingMode = 'cluster_pool';
    }

    const presetClusters = [
      'VMware vSphere / ESXi Cluster (HA / DRS)',
      'Proxmox VE HA Cluster (KVM / LXC)',
      'Microsoft Hyper-V Failover Cluster',
      'Kubernetes / OpenShift / Docker Swarm',
      'Nutanix AHV / KVM Cluster',
      'custom_cluster',
    ];
    final existingCluster =
        (h['cluster_or_pool_name'] as String?) ??
        (h['hypervisor_or_platform'] as String?) ??
        'VMware vSphere / ESXi Cluster (HA / DRS)';
    _clusterPreset = presetClusters.contains(existingCluster)
        ? existingCluster
        : 'custom_cluster';
    _customClusterCtrl = TextEditingController(
      text: _clusterPreset == 'custom_cluster'
          ? existingCluster
          : 'Clúster Virtualización CPD',
    );

    final hypervisors = widget.hostsList
        .where(
          (x) =>
              x['logical_layer'] == 'hypervisors_phys' ||
              x['logical_layer'] == 'network_switching',
        )
        .toList();
    _parentAssetCode =
        (h['parent_asset_code'] as String?) ??
        (hypervisors.isNotEmpty ? '${hypervisors.first['code']}' : '');
    if (_parentAssetCode.isNotEmpty &&
        !hypervisors.any((x) => x['code'] == _parentAssetCode)) {
      _parentAssetCode = hypervisors.isNotEmpty
          ? '${hypervisors.first['code']}'
          : '';
    }

    bool hasChk(String t) => checks.any(
      (c) => (c['check_type'] as String? ?? '').toLowerCase() == t,
    );
    Map<String, dynamic>? findChk(String t) {
      for (final c in checks) {
        if ((c['check_type'] as String? ?? '').toLowerCase() == t) return c;
      }
      return null;
    }

    _hbEnabled = h['monitoring_enabled'] != false;
    _hbIcmp = widget.isNewElement
        ? true
        : (hasChk('icmp') || checks.isEmpty);
    _hbSsh = widget.isNewElement ? true : hasChk('ssh');
    _hbHttp = widget.isNewElement
        ? true
        : (hasChk('https') || hasChk('http'));
    _hbHttpScheme = hasChk('http') && !hasChk('https') ? 'http' : 'https';
    _hbTcp = hasChk('tcp');
    _hbUdp = hasChk('udp');
    _hbSnmp = hasChk('snmp');

    _expNode = widget.isNewElement ? true : hasChk('node_exporter');
    _expWin = hasChk('windows_exporter');
    _expNginx = hasChk('nginx');
    _expApache = hasChk('apache');
    _expDocker = hasChk('docker');
    _expPostgres = hasChk('postgres');
    _expMysql = hasChk('mysql');
    _expRedis = hasChk('redis');

    final httpChk = findChk('https') ?? findChk('http');
    _hbSshPortCtrl = TextEditingController(
      text: '${findChk('ssh')?['port'] ?? 22}',
    );
    _hbHttpUrlCtrl = TextEditingController(
      text:
          (httpChk?['target_ip_or_url'] as String?) ??
          'https://${_ipCtrl.text}/health',
    );
    _hbHttpPortCtrl = TextEditingController(
      text: '${httpChk?['port'] ?? (_hbHttpScheme == 'https' ? 443 : 80)}',
    );
    _hbTcpPortCtrl = TextEditingController(
      text: '${findChk('tcp')?['port'] ?? 8080}',
    );
    _hbTcpNameCtrl = TextEditingController(
      text: (findChk('tcp')?['service_name'] as String?) ?? 'Puerto TCP App',
    );
    _hbUdpPortCtrl = TextEditingController(
      text: '${findChk('udp')?['port'] ?? 53}',
    );
    _hbSnmpCommCtrl = TextEditingController(text: 'public');

    const stdTypes = {
      'icmp',
      'ssh',
      'http',
      'https',
      'tcp',
      'udp',
      'snmp',
      'node_exporter',
      'windows_exporter',
      'nginx',
      'apache',
      'docker',
      'postgres',
      'mysql',
      'redis',
    };
    for (final c in checks) {
      final ct = (c['check_type'] as String? ?? '').toLowerCase();
      if (!stdTypes.contains(ct)) {
        _customChecks.add({
          'name': c['service_name'] ?? 'Servicio Custom',
          'type': ct.isEmpty ? 'tcp' : ct,
          'port': c['port'] ?? 8443,
          'url': c['target_ip_or_url'] ?? _ipCtrl.text,
        });
      }
    }

    _connEnabled = h['connect_enabled'] != false;
    _connSsh = h['ssh_enabled'] != false;
    _connHttp = h['web_http_enabled'] == true;
    _connHttps = h['web_https_enabled'] != false;

    _connSshHostCtrl = TextEditingController(
      text: (h['ssh_host'] as String?) ?? _ipCtrl.text,
    );
    _connSshPortCtrl = TextEditingController(
      text: '${h['ssh_port'] ?? 22}',
    );
    _connSshUserCtrl = TextEditingController(
      text: (h['ssh_user'] as String?) ?? 'root',
    );
    _connHttpUrlCtrl = TextEditingController(
      text: (h['web_http_url'] as String?) ?? 'http://${_ipCtrl.text}/',
    );
    _connHttpsUrlCtrl = TextEditingController(
      text: (h['web_https_url'] as String?) ?? 'https://${_ipCtrl.text}/',
    );
  }

  Map<String, dynamic> _buildSavePayload() {
    final ip = _ipCtrl.text.trim();
    final exporters = <Map<String, dynamic>>[];
    final heartbeats = <Map<String, dynamic>>[];

    if (_hbEnabled) {
      if (_expNode) exporters.add({'type': 'node_exporter', 'port': 9100});
      if (_expWin) exporters.add({'type': 'windows_exporter', 'port': 9182});
      if (_expNginx) {
        exporters.add({
          'type': 'nginx',
          'port': 8080,
          'url': 'http://$ip:8080/nginx_status',
        });
      }
      if (_expApache) {
        exporters.add({
          'type': 'apache',
          'port': 8080,
          'url': 'http://$ip:8080/server-status?auto',
        });
      }
      if (_expDocker) {
        exporters.add({
          'type': 'docker',
          'port': 9323,
          'url': 'http://$ip:9323/metrics',
        });
      }

      if (_hbSsh) {
        final sp = int.tryParse(_hbSshPortCtrl.text.trim()) ?? 22;
        heartbeats.add({
          'name': 'SSH Gestión (:$sp)',
          'type': 'ssh',
          'port': sp,
          'url': ip,
        });
      }
      if (_hbHttp) {
        final hp =
            int.tryParse(_hbHttpPortCtrl.text.trim()) ??
            (_hbHttpScheme == 'https' ? 443 : 80);
        heartbeats.add({
          'name': _hbHttpScheme == 'https'
              ? 'Endpoint HTTPS + SSL'
              : 'Endpoint HTTP (:$hp)',
          'type': _hbHttpScheme,
          'port': hp,
          'expected_status_code': 200,
          'url': _hbHttpUrlCtrl.text.trim().isNotEmpty
              ? _hbHttpUrlCtrl.text.trim()
              : '$_hbHttpScheme://$ip:$hp/',
        });
      }
      if (_hbTcp) {
        final tp = int.tryParse(_hbTcpPortCtrl.text.trim()) ?? 8080;
        heartbeats.add({
          'name': _hbTcpNameCtrl.text.trim().isNotEmpty
              ? _hbTcpNameCtrl.text.trim()
              : 'Puerto TCP :$tp',
          'type': 'tcp',
          'port': tp,
          'url': ip,
        });
      }
      if (_hbUdp) {
        final up = int.tryParse(_hbUdpPortCtrl.text.trim()) ?? 53;
        heartbeats.add({
          'name': 'Puerto UDP :$up',
          'type': 'udp',
          'port': up,
          'url': ip,
        });
      }
      if (_hbSnmp) {
        heartbeats.add({
          'name': 'Agente SNMP (:161/UDP)',
          'type': 'snmp',
          'port': 161,
          'url': ip,
          'check_config': {'community': _hbSnmpCommCtrl.text.trim()},
        });
      }
      if (_expPostgres) {
        heartbeats.add({
          'name': 'PostgreSQL (:5432)',
          'type': 'postgres',
          'port': 5432,
          'url': ip,
        });
      }
      if (_expMysql) {
        heartbeats.add({
          'name': 'MySQL / MariaDB (:3306)',
          'type': 'mysql',
          'port': 3306,
          'url': ip,
        });
      }
      if (_expRedis) {
        heartbeats.add({
          'name': 'Redis Cache (:6379)',
          'type': 'redis',
          'port': 6379,
          'url': ip,
        });
      }
      for (final c in _customChecks) {
        heartbeats.add({
          'name': c['name'],
          'type': c['type'],
          'port': c['port'],
          'url': c['url'],
        });
      }
    }

    final effCluster = _hostingMode == 'cluster_pool'
        ? (_clusterPreset == 'custom_cluster'
              ? _customClusterCtrl.text.trim()
              : _clusterPreset)
        : (_hostingMode == 'standalone'
              ? (_customClusterCtrl.text.trim().isNotEmpty
                    ? _customClusterCtrl.text.trim()
                    : 'Independiente / Barebone / Cloud')
              : 'Alojado en Servidor Físico del Rack');

    return {
      if (!widget.isNewElement && widget.host['id'] != null)
        'asset_id': widget.host['id'],
      'code': _codeCtrl.text.trim(),
      'name': _nameCtrl.text.trim(),
      'hostname': _codeCtrl.text.trim().toLowerCase(),
      'fqdn': _fqdnCtrl.text.trim().isNotEmpty
          ? _fqdnCtrl.text.trim()
          : '${_codeCtrl.text.trim().toLowerCase()}.hq.local',
      'asset_class': _assetClass,
      'custom_asset_class_label': _assetClass == 'custom'
          ? _customClassCtrl.text.trim()
          : '',
      'environment': 'production',
      'criticality': 'high',
      'os_or_firmware': _osCtrl.text.trim(),
      'hosting_mode': _hostingMode,
      'cluster_or_pool_name': effCluster,
      'hypervisor_or_platform': effCluster,
      'cpu_cores': (widget.host['cpu_cores'] as int?) ?? 4,
      'ram_gb': (widget.host['ram_gb'] as num?)?.toDouble() ?? 16.0,
      'storage_gb': 120.0,
      'primary_ip': ip,
      'additional_ips': const [],
      'parent_asset_code': _hostingMode == 'physical_rack_server'
          ? _parentAssetCode
          : '',
      'host_groups': (widget.host['host_groups'] as List?) ?? const [],
      'monitoring_enabled': _hbEnabled,
      'enable_icmp_ping': _hbIcmp,
      'replace_checks': !widget.isNewElement,
      'exporters': exporters,
      'heartbeats': heartbeats,
      'connect_enabled': _connEnabled,
      'ssh_enabled': _connSsh,
      'ssh_host': _connSshHostCtrl.text.trim().isNotEmpty
          ? _connSshHostCtrl.text.trim()
          : ip,
      'ssh_user': _connSshUserCtrl.text.trim().isNotEmpty
          ? _connSshUserCtrl.text.trim()
          : 'root',
      'ssh_port': int.tryParse(_connSshPortCtrl.text.trim()) ?? 22,
      'web_http_enabled': _connHttp,
      'web_http_url': _connHttpUrlCtrl.text.trim(),
      'web_https_enabled': _connHttps,
      'web_https_url': _connHttpsUrlCtrl.text.trim(),
    };
  }

  InputDecoration _compactDeco(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(7)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hypervisors = widget.hostsList
        .where(
          (x) =>
              x['logical_layer'] == 'hypervisors_phys' ||
              x['logical_layer'] == 'network_switching',
        )
        .toList();
    final otherNodes = widget.allStackNodes
        .where((n) => n['id'] != widget.stackNode?['id'])
        .toList();

    return Column(
      children: [
        // Cabecera compacta estilo Datacenter Element Settings
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: const BoxDecoration(
            color: AppTheme.bgSecondary,
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.tune_rounded,
                size: 16,
                color: AppTheme.accentCyan,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  widget.isNewElement
                      ? 'NUEVO ELEMENTO / HOST (CONFIGURACIÓN)'
                      : 'ELEMENT SETTINGS • ${_codeCtrl.text}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.textPrimary,
                    letterSpacing: 0.3,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.onOpenFloatingCharts != null)
                IconButton(
                  tooltip: 'Abrir Ventana Flotante de Gráficas Prometheus',
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  icon: const Icon(
                    Icons.analytics_outlined,
                    size: 16,
                    color: AppTheme.accentTeal,
                  ),
                  onPressed: widget.onOpenFloatingCharts,
                ),
              if (widget.isModalDialog && widget.onCloseModal != null)
                IconButton(
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.only(left: 4),
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: widget.onCloseModal,
                ),
            ],
          ),
        ),
        // Cuerpo desplazable con el mismo formato limpio y compacto del Datacenter
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(11),
            children: [
              // 1. Tipo + ID + Name + IP + FQDN
              DropdownButtonFormField<String>(
                initialValue: _assetClass,
                isExpanded: true,
                decoration: _compactDeco('Tipo de Elemento / Sistema'),
                items: const [
                  DropdownMenuItem(
                    value: 'virtual_machine',
                    child: Text(
                      '🖥️ Máquina Virtual (VM)',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'container',
                    child: Text(
                      '📦 Contenedor / Pod (Docker / K8s / LXC)',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'physical_server',
                    child: Text(
                      '🗄️ Servidor Físico / Barebone',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'vip_cluster',
                    child: Text(
                      '⚖️ Balanceador / VIP / API Gateway',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'network_security',
                    child: Text(
                      '🛡️ Switch / Firewall / Router / WAF',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'storage_san_nas',
                    child: Text(
                      '💾 Storage SAN / NAS / Backup',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'custom',
                    child: Text(
                      '✨ Otro / Personalizado (Escribir)...',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.accentCyan,
                      ),
                    ),
                  ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _assetClass = v);
                },
              ),
              if (_assetClass == 'custom') ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _customClassCtrl,
                  style: const TextStyle(fontSize: 11.5),
                  decoration: _compactDeco(
                    'Tipo Personalizado',
                    hint: 'Ej: Sonda IoT, Centralita VoIP, Appliance...',
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _codeCtrl,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                      decoration: _compactDeco('ID / Código *'),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _nameCtrl,
                      style: const TextStyle(fontSize: 11.5),
                      decoration: _compactDeco('Name / Rol *'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ipCtrl,
                      onChanged: (v) {
                        if (widget.isNewElement) {
                          _connSshHostCtrl.text = v.trim();
                          _hbHttpUrlCtrl.text =
                              '$_hbHttpScheme://${v.trim()}/health';
                          _connHttpUrlCtrl.text = 'http://${v.trim()}/';
                          _connHttpsUrlCtrl.text = 'https://${v.trim()}/';
                        }
                      },
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                      ),
                      decoration: _compactDeco('IP Address / Host *'),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: TextField(
                      controller: _fqdnCtrl,
                      style: const TextStyle(fontSize: 11.5),
                      decoration: _compactDeco('FQDN / DNS'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _osCtrl,
                style: const TextStyle(fontSize: 11.5),
                decoration: _compactDeco('OS / Hypervisor / Firmware'),
              ),
              const SizedBox(height: 10),

              // 2. Ubicación / Alojamiento compacto (Clúster sin máquina concreta | Rack Físico | Independiente)
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: AppTheme.bgSecondary,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'ALOJAMIENTO (¿Dónde reside este elemento?)',
                      style: TextStyle(
                        fontSize: 9.8,
                        fontWeight: FontWeight.w900,
                        color: AppTheme.accentPurple,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      children: [
                        ChoiceChip(
                          label: const Text(
                            '☁️ Clúster (Sin máquina fija)',
                            style: TextStyle(fontSize: 10.2),
                          ),
                          selected: _hostingMode == 'cluster_pool',
                          onSelected: (_) =>
                              setState(() => _hostingMode = 'cluster_pool'),
                        ),
                        ChoiceChip(
                          label: const Text(
                            '🗄️ Máquina del Rack',
                            style: TextStyle(fontSize: 10.2),
                          ),
                          selected: _hostingMode == 'physical_rack_server',
                          onSelected: (_) => setState(
                            () => _hostingMode = 'physical_rack_server',
                          ),
                        ),
                        ChoiceChip(
                          label: const Text(
                            '🌐 Independiente',
                            style: TextStyle(fontSize: 10.2),
                          ),
                          selected: _hostingMode == 'standalone',
                          onSelected: (_) =>
                              setState(() => _hostingMode = 'standalone'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_hostingMode == 'cluster_pool') ...[
                      DropdownButtonFormField<String>(
                        initialValue: _clusterPreset,
                        isExpanded: true,
                        decoration: _compactDeco(
                          'Clúster VMware / Proxmox / Hyper-V / K8s',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'VMware vSphere / ESXi Cluster (HA / DRS)',
                            child: Text(
                              'VMware vSphere / ESXi Cluster (HA / DRS)',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'Proxmox VE HA Cluster (KVM / LXC)',
                            child: Text(
                              'Proxmox VE HA Cluster (KVM / LXC)',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'Microsoft Hyper-V Failover Cluster',
                            child: Text(
                              'Microsoft Hyper-V Failover Cluster',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'Kubernetes / OpenShift / Docker Swarm',
                            child: Text(
                              'Kubernetes / OpenShift / Docker Swarm',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'Nutanix AHV / KVM Cluster',
                            child: Text(
                              'Nutanix AHV / KVM Cluster',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'custom_cluster',
                            child: Text(
                              '✨ Otro Clúster (Escribir)...',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                        onChanged: (v) => setState(
                          () => _clusterPreset = v ?? _clusterPreset,
                        ),
                      ),
                      if (_clusterPreset == 'custom_cluster') ...[
                        const SizedBox(height: 7),
                        TextField(
                          controller: _customClusterCtrl,
                          style: const TextStyle(fontSize: 11),
                          decoration: _compactDeco(
                            'Nombre del Clúster / Pool',
                          ),
                        ),
                      ],
                    ] else if (_hostingMode == 'physical_rack_server') ...[
                      DropdownButtonFormField<String>(
                        initialValue: _parentAssetCode.isEmpty
                            ? null
                            : _parentAssetCode,
                        isExpanded: true,
                        decoration: _compactDeco(
                          'Máquina Física del Rack Editor',
                        ),
                        items: hypervisors
                            .map(
                              (x) => DropdownMenuItem<String>(
                                value: '${x['code']}',
                                child: Text(
                                  '${x['code']} — ${x['name']}',
                                  style: const TextStyle(fontSize: 11),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _parentAssetCode = v ?? ''),
                      ),
                    ] else ...[
                      TextField(
                        controller: _customClusterCtrl,
                        style: const TextStyle(fontSize: 11),
                        decoration: _compactDeco(
                          'Sala / Cloud / Ubicación (Opcional)',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // 3. Enlaces en el Lienzo (Conectar con cualquier elemento cuando estamos en el Stack)
              if (widget.stackNode != null) ...[
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: AppTheme.bgSecondary,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'ENLACES EN EL STACK (${widget.nodeEdges.length})',
                            style: const TextStyle(
                              fontSize: 9.8,
                              fontWeight: FontWeight.w900,
                              color: AppTheme.accentCyan,
                            ),
                          ),
                          if (widget.canEdit &&
                              widget.onStartLinkMode != null)
                            InkWell(
                              onTap: widget.onStartLinkMode,
                              child: const Text(
                                '🔗 Clic para enlazar en lienzo',
                                style: TextStyle(
                                  fontSize: 9.8,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.warning,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (widget.canEdit &&
                          otherNodes.isNotEmpty &&
                          widget.onQuickConnectToNode != null) ...[
                        const SizedBox(height: 6),
                        DropdownButtonFormField<int>(
                          isExpanded: true,
                          decoration: _compactDeco(
                            '+ Conectar directamente con otro elemento...',
                          ),
                          items: otherNodes.map((n) {
                            final nh = Map<String, dynamic>.from(
                              (n['host'] as Map?) ?? {},
                            );
                            return DropdownMenuItem<int>(
                              value: n['id'] as int,
                              child: Text(
                                '➔ ${nh['code']} (${n['custom_label'] ?? nh['name']})',
                                style: const TextStyle(fontSize: 10.8),
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          }).toList(),
                          onChanged: (targetId) {
                            if (targetId != null) {
                              widget.onQuickConnectToNode!(targetId);
                            }
                          },
                        ),
                      ],
                      if (widget.nodeEdges.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        for (final e in widget.nodeEdges)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.sync_alt_rounded,
                                  size: 12,
                                  color: AppTheme.accentCyan,
                                ),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: Text(
                                    '${e['protocol_label']} (:${e['target_port'] ?? 443})',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: AppTheme.textSecondary,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (widget.canEdit &&
                                    widget.onDeleteEdge != null)
                                  InkWell(
                                    onTap: () =>
                                        widget.onDeleteEdge!(e['id'] as int),
                                    child: const Icon(
                                      Icons.close,
                                      size: 13,
                                      color: AppTheme.error,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],

              // ===============================================================
              // SECCIÓN A: HEARTBEAT (BACKGROUND MONITORING) — ESTILO DATACENTER
              // ===============================================================
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.bgSecondary,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: _hbEnabled
                        ? AppTheme.success.withValues(alpha: 0.65)
                        : AppTheme.border,
                    width: _hbEnabled ? 1.4 : 1.0,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _hbEnabled
                                ? AppTheme.success
                                : AppTheme.textMuted,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            _hbEnabled
                                ? 'Heartbeat: ACTIVO (Background)'
                                : 'Heartbeat: DESACTIVADO',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              color: _hbEnabled
                                  ? AppTheme.success
                                  : AppTheme.textSecondary,
                            ),
                          ),
                        ),
                        Switch.adaptive(
                          value: _hbEnabled,
                          activeThumbColor: AppTheme.success,
                          onChanged: (v) => setState(() => _hbEnabled = v),
                        ),
                      ],
                    ),
                    if (_hbEnabled) ...[
                      const SizedBox(height: 6),
                      const Text(
                        'Protocolos Heartbeat & Exporters Prometheus:',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        children: [
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'ICMP Ping',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _hbIcmp,
                            onSelected: (v) => setState(() => _hbIcmp = v),
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'SSH',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _hbSsh,
                            onSelected: (v) => setState(() => _hbSsh = v),
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'HTTP/HTTPS',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _hbHttp,
                            onSelected: (v) => setState(() => _hbHttp = v),
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'TCP',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _hbTcp,
                            onSelected: (v) => setState(() => _hbTcp = v),
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'UDP',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _hbUdp,
                            onSelected: (v) => setState(() => _hbUdp = v),
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'SNMP',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _hbSnmp,
                            onSelected: (v) => setState(() => _hbSnmp = v),
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'Node Exp :9100',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _expNode,
                            onSelected: (v) => setState(() => _expNode = v),
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'Win Exp :9182',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _expWin,
                            onSelected: (v) => setState(() => _expWin = v),
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'Nginx',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _expNginx,
                            onSelected: (v) => setState(() => _expNginx = v),
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'Apache',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _expApache,
                            onSelected: (v) => setState(() => _expApache = v),
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'Docker',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _expDocker,
                            onSelected: (v) => setState(() => _expDocker = v),
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'PostgreSQL',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _expPostgres,
                            onSelected: (v) =>
                                setState(() => _expPostgres = v),
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'MySQL',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _expMysql,
                            onSelected: (v) => setState(() => _expMysql = v),
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'Redis',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _expRedis,
                            onSelected: (v) => setState(() => _expRedis = v),
                          ),
                          ActionChip(
                            visualDensity: VisualDensity.compact,
                            avatar: const Icon(
                              Icons.add,
                              size: 13,
                              color: AppTheme.accentCyan,
                            ),
                            label: const Text(
                              'Personalizado',
                              style: TextStyle(
                                fontSize: 10.2,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.accentCyan,
                              ),
                            ),
                            onPressed: () => setState(
                              () => _showAddCustomCheckRow =
                                  !_showAddCustomCheckRow,
                            ),
                          ),
                        ],
                      ),
                      if (_hbHttp) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            SizedBox(
                              width: 82,
                              child: DropdownButtonFormField<String>(
                                initialValue: _hbHttpScheme,
                                decoration: _compactDeco('Proto'),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'https',
                                    child: Text(
                                      'HTTPS',
                                      style: TextStyle(fontSize: 10.5),
                                    ),
                                  ),
                                  DropdownMenuItem(
                                    value: 'http',
                                    child: Text(
                                      'HTTP',
                                      style: TextStyle(fontSize: 10.5),
                                    ),
                                  ),
                                ],
                                onChanged: (v) => setState(
                                  () => _hbHttpScheme = v ?? 'https',
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: TextField(
                                controller: _hbHttpUrlCtrl,
                                style: const TextStyle(fontSize: 10.8),
                                decoration: _compactDeco('HTTP/S URL Check'),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (_hbTcp) ...[
                        const SizedBox(height: 7),
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: _hbTcpNameCtrl,
                                style: const TextStyle(fontSize: 10.8),
                                decoration: _compactDeco('Nombre TCP'),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: TextField(
                                controller: _hbTcpPortCtrl,
                                style: const TextStyle(fontSize: 10.8),
                                decoration: _compactDeco('Puerto TCP'),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (_hbUdp) ...[
                        const SizedBox(height: 7),
                        TextField(
                          controller: _hbUdpPortCtrl,
                          style: const TextStyle(fontSize: 10.8),
                          decoration: _compactDeco('Puerto UDP Check'),
                        ),
                      ],
                      if (_hbSnmp) ...[
                        const SizedBox(height: 7),
                        TextField(
                          controller: _hbSnmpCommCtrl,
                          style: const TextStyle(fontSize: 10.8),
                          decoration: _compactDeco('Comunidad SNMP (:161)'),
                        ),
                      ],
                      if (_showAddCustomCheckRow) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppTheme.bgCard,
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(
                              color: AppTheme.accentCyan.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    flex: 2,
                                    child: TextField(
                                      controller: _customChkNameCtrl,
                                      style: const TextStyle(fontSize: 10.5),
                                      decoration: _compactDeco('Servicio'),
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: TextField(
                                      controller: _customChkTypeCtrl,
                                      style: const TextStyle(fontSize: 10.5),
                                      decoration: _compactDeco('Proto'),
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  SizedBox(
                                    width: 64,
                                    child: TextField(
                                      controller: _customChkPortCtrl,
                                      style: const TextStyle(fontSize: 10.5),
                                      decoration: _compactDeco('Port'),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _customChkUrlCtrl,
                                      style: const TextStyle(fontSize: 10.5),
                                      decoration: _compactDeco(
                                        'Target / URL (opcional)',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  ElevatedButton(
                                    onPressed: () {
                                      final nm = _customChkNameCtrl.text.trim();
                                      if (nm.isEmpty) return;
                                      setState(() {
                                        _customChecks.add({
                                          'name': nm,
                                          'type': _customChkTypeCtrl.text
                                              .trim(),
                                          'port':
                                              int.tryParse(
                                                _customChkPortCtrl.text.trim(),
                                              ) ??
                                              8443,
                                          'url':
                                              _customChkUrlCtrl.text
                                                  .trim()
                                                  .isNotEmpty
                                              ? _customChkUrlCtrl.text.trim()
                                              : _ipCtrl.text.trim(),
                                        });
                                        _showAddCustomCheckRow = false;
                                      });
                                    },
                                    child: const Text(
                                      '+ Añadir',
                                      style: TextStyle(fontSize: 10.5),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (_customChecks.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: _customChecks.asMap().entries.map((entry) {
                            final idx = entry.key;
                            final c = entry.value;
                            return InputChip(
                              visualDensity: VisualDensity.compact,
                              label: Text(
                                '${c['name']} (${c['type']}:${c['port']})',
                                style: const TextStyle(fontSize: 9.8),
                              ),
                              onDeleted: () =>
                                  setState(() => _customChecks.removeAt(idx)),
                            );
                          }).toList(),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // ===============================================================
              // SECCIÓN B: CONECTAR (EJECUTADO DESDE EL FRONTEND) — ESTILO DATACENTER
              // ===============================================================
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.bgSecondary,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: _connEnabled
                        ? AppTheme.accentBlue.withValues(alpha: 0.65)
                        : AppTheme.border,
                    width: _connEnabled ? 1.4 : 1.0,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.terminal_rounded,
                          size: 15,
                          color: _connEnabled
                              ? AppTheme.accentBlue
                              : AppTheme.textMuted,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            _connEnabled
                                ? 'Conectar: ACTIVO (Frontend)'
                                : 'Conectar: DESACTIVADO',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              color: _connEnabled
                                  ? AppTheme.accentBlue
                                  : AppTheme.textSecondary,
                            ),
                          ),
                        ),
                        Switch.adaptive(
                          value: _connEnabled,
                          activeThumbColor: AppTheme.accentBlue,
                          onChanged: (v) => setState(() => _connEnabled = v),
                        ),
                      ],
                    ),
                    if (_connEnabled) ...[
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 6,
                        runSpacing: 5,
                        children: [
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'SSH',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _connSsh,
                            onSelected: (v) => setState(() => _connSsh = v),
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'HTTP',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _connHttp,
                            onSelected: (v) => setState(() => _connHttp = v),
                          ),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text(
                              'HTTPS',
                              style: TextStyle(fontSize: 10.2),
                            ),
                            selected: _connHttps,
                            onSelected: (v) => setState(() => _connHttps = v),
                          ),
                        ],
                      ),
                      if (_connSsh) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: _connSshHostCtrl,
                                style: const TextStyle(fontSize: 10.8),
                                decoration: _compactDeco('SSH Host'),
                              ),
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: TextField(
                                controller: _connSshUserCtrl,
                                style: const TextStyle(fontSize: 10.8),
                                decoration: _compactDeco('User'),
                              ),
                            ),
                            const SizedBox(width: 5),
                            SizedBox(
                              width: 62,
                              child: TextField(
                                controller: _connSshPortCtrl,
                                style: const TextStyle(fontSize: 10.8),
                                decoration: _compactDeco('Port'),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (_connHttp) ...[
                        const SizedBox(height: 7),
                        TextField(
                          controller: _connHttpUrlCtrl,
                          style: const TextStyle(fontSize: 10.8),
                          decoration: _compactDeco('HTTP URL'),
                        ),
                      ],
                      if (_connHttps) ...[
                        const SizedBox(height: 7),
                        TextField(
                          controller: _connHttpsUrlCtrl,
                          style: const TextStyle(fontSize: 10.8),
                          decoration: _compactDeco('HTTPS URL'),
                        ),
                      ],
                      const SizedBox(height: 8),
                      // Botones de lanzamiento directo idénticos a Datacenter
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (_connSsh && widget.onOpenSsh != null)
                            OutlinedButton.icon(
                              onPressed: widget.onOpenSsh,
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                              ),
                              icon: const Icon(
                                Icons.terminal_rounded,
                                size: 13,
                                color: AppTheme.accentCyan,
                              ),
                              label: const Text(
                                'Conectar por SSH',
                                style: TextStyle(fontSize: 10.2),
                              ),
                            ),
                          if (_connHttps)
                            OutlinedButton.icon(
                              onPressed: () {
                                final u = _connHttpsUrlCtrl.text.trim();
                                if (u.isNotEmpty) {
                                  launchUrl(
                                    Uri.parse(u),
                                    mode: LaunchMode.externalApplication,
                                  );
                                }
                              },
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                              ),
                              icon: const Icon(
                                Icons.open_in_browser_rounded,
                                size: 13,
                              ),
                              label: const Text(
                                'Abrir HTTPS',
                                style: TextStyle(fontSize: 10.2),
                              ),
                            ),
                          if (_connHttp)
                            OutlinedButton.icon(
                              onPressed: () {
                                final u = _connHttpUrlCtrl.text.trim();
                                if (u.isNotEmpty) {
                                  launchUrl(
                                    Uri.parse(u),
                                    mode: LaunchMode.externalApplication,
                                  );
                                }
                              },
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                              ),
                              icon: const Icon(Icons.public_rounded, size: 13),
                              label: const Text(
                                'Abrir HTTP',
                                style: TextStyle(fontSize: 10.2),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        // Barra inferior de guardado estilo Datacenter Settings
        if (widget.canEdit)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              color: AppTheme.bgSecondary,
              border: Border(top: BorderSide(color: AppTheme.border)),
            ),
            child: ElevatedButton.icon(
              onPressed: _saving
                  ? null
                  : () async {
                      setState(() => _saving = true);
                      try {
                        await widget.onSaveHostConfig(_buildSavePayload());
                      } finally {
                        if (mounted) setState(() => _saving = false);
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accentBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.check_circle_outline_rounded, size: 16),
              label: Text(
                widget.isNewElement
                    ? 'Añadir Elemento y Aplicar Configuración'
                    : 'Aplicar Cambios del Elemento',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// =============================================================================
// CUADRÍCULA ARQUITECTÓNICA 2D LIBRE (COMO EN DATACENTER FLOOR VIEW)
// =============================================================================

class _StackArchitecturalGridPainter extends CustomPainter {
  final double scale;

  _StackArchitecturalGridPainter({required this.scale});

  @override
  void paint(Canvas canvas, Size size) {
    final step = (28.0 * scale).clamp(18.0, 56.0);
    final minorPaint = Paint()
      ..color = AppTheme.border.withValues(alpha: 0.22)
      ..strokeWidth = 0.7;
    final majorPaint = Paint()
      ..color = AppTheme.border.withValues(alpha: 0.45)
      ..strokeWidth = 1.0;

    int col = 0;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        (col % 4 == 0) ? majorPaint : minorPaint,
      );
      col++;
    }
    int row = 0;
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        (row % 4 == 0) ? majorPaint : minorPaint,
      );
      row++;
    }
  }

  @override
  bool shouldRepaint(covariant _StackArchitecturalGridPainter oldDelegate) =>
      oldDelegate.scale != scale;
}

// =============================================================================
// CUSTOM PAINTER DE SERIES TEMPORALES DE PROMETHEUS AFINADO
// (CURVAS SUAVES BÉZIER, EJES Y/X, UMBRALES WARNING/CRITICAL Y PUNTOS EN VIVO)
// =============================================================================

class _PrometheusSeriesChartPainter extends CustomPainter {
  final List<Map<String, dynamic>> points;
  final String keyA;
  final Color colorA;
  final String? keyB;
  final Color? colorB;
  final String unit;
  final double? warnThreshold;
  final double? critThreshold;

  _PrometheusSeriesChartPainter({
    required this.points,
    required this.keyA,
    required this.colorA,
    this.keyB,
    this.colorB,
    this.unit = '',
    this.warnThreshold,
    this.critThreshold,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    const leftPad = 34.0;
    const bottomPad = 15.0;
    const topPad = 6.0;
    final chartW = math.max(20.0, size.width - leftPad - 4.0);
    final chartH = math.max(20.0, size.height - bottomPad - topPad);

    double maxVal = unit == '%' ? 100.0 : 1.0;
    for (final p in points) {
      final va = (p[keyA] as num?)?.toDouble() ?? 0.0;
      if (va > maxVal) maxVal = va;
      if (keyB != null) {
        final vb = (p[keyB] as num?)?.toDouble() ?? 0.0;
        if (vb > maxVal) maxVal = vb;
      }
    }
    if (unit != '%') {
      maxVal = math.max(maxVal * 1.18, 5.0);
    }

    final gridPaint = Paint()
      ..color = AppTheme.border.withValues(alpha: 0.38)
      ..strokeWidth = 0.8;

    // Líneas guía horizontales + etiquetas de escala en el eje Y
    for (int i = 0; i <= 3; i++) {
      final frac = i / 3.0;
      final y = topPad + chartH * frac;
      canvas.drawLine(
        Offset(leftPad, y),
        Offset(leftPad + chartW, y),
        gridPaint,
      );
      final val = maxVal * (1.0 - frac);
      final lbl = val >= 10
          ? '${val.toStringAsFixed(0)}$unit'
          : '${val.toStringAsFixed(1)}$unit';
      final tp = TextPainter(
        text: TextSpan(
          text: lbl,
          style: const TextStyle(
            fontSize: 8.2,
            fontFamily: 'monospace',
            color: AppTheme.textMuted,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(math.max(0, leftPad - tp.width - 4), y - 5));
    }

    // Líneas de umbral Warning / Critical si aplican
    if (warnThreshold != null && warnThreshold! <= maxVal) {
      final wy = topPad + chartH * (1.0 - (warnThreshold! / maxVal));
      canvas.drawLine(
        Offset(leftPad, wy),
        Offset(leftPad + chartW, wy),
        Paint()
          ..color = AppTheme.warning.withValues(alpha: 0.45)
          ..strokeWidth = 1.0,
      );
    }
    if (critThreshold != null && critThreshold! <= maxVal) {
      final cy = topPad + chartH * (1.0 - (critThreshold! / maxVal));
      canvas.drawLine(
        Offset(leftPad, cy),
        Offset(leftPad + chartW, cy),
        Paint()
          ..color = AppTheme.error.withValues(alpha: 0.45)
          ..strokeWidth = 1.0,
      );
    }

    // Etiquetas de tiempo en el eje X (inicio, medio, ahora)
    final xIndices = [0, points.length ~/ 2, points.length - 1];
    for (final idx in xIndices) {
      final rawTs =
          (points[idx]['timestamp'] as String?) ??
          (points[idx]['label'] as String?) ??
          '';
      final shortTs = rawTs.length >= 16
          ? rawTs.substring(11, 16)
          : (rawTs.isNotEmpty ? rawTs : (idx == points.length - 1 ? 'Ahora' : ''));
      if (shortTs.isEmpty) continue;
      final x = leftPad + (idx / (points.length - 1)) * chartW;
      final tp = TextPainter(
        text: TextSpan(
          text: shortTs,
          style: const TextStyle(
            fontSize: 8.0,
            fontFamily: 'monospace',
            color: AppTheme.textMuted,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(
          (x - tp.width / 2).clamp(leftPad, leftPad + chartW - tp.width),
          topPad + chartH + 2,
        ),
      );
    }

    final chartRect = Rect.fromLTWH(leftPad, topPad, chartW, chartH);
    _drawSmoothSeries(canvas, chartRect, keyA, colorA, maxVal);
    if (keyB != null && colorB != null) {
      _drawSmoothSeries(canvas, chartRect, keyB!, colorB!, maxVal);
    }
  }

  void _drawSmoothSeries(
    Canvas canvas,
    Rect rect,
    String key,
    Color color,
    double maxVal,
  ) {
    final coords = <Offset>[];
    for (int i = 0; i < points.length; i++) {
      final v = (points[i][key] as num?)?.toDouble() ?? 0.0;
      final x = rect.left + (i / (points.length - 1)) * rect.width;
      final y =
          rect.bottom - ((v / maxVal).clamp(0.0, 1.0) * rect.height);
      coords.add(Offset(x, y));
    }
    if (coords.length < 2) return;

    final path = Path()..moveTo(coords.first.dx, coords.first.dy);
    for (int i = 0; i < coords.length - 1; i++) {
      final p0 = coords[i];
      final p1 = coords[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      path.cubicTo(midX, p0.dy, midX, p1.dy, p1.dx, p1.dy);
    }

    final fillPath = Path.from(path)
      ..lineTo(coords.last.dx, rect.bottom)
      ..lineTo(coords.first.dx, rect.bottom)
      ..close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.34),
          color.withValues(alpha: 0.08),
          color.withValues(alpha: 0.01),
        ],
      ).createShader(rect);
    canvas.drawPath(fillPath, fillPaint);

    final strokePaint = Paint()
      ..color = color
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, strokePaint);

    // Punto brillante en el valor actual (última muestra)
    final lastPt = coords.last;
    canvas.drawCircle(
      lastPt,
      4.5,
      Paint()..color = color.withValues(alpha: 0.28),
    );
    canvas.drawCircle(lastPt, 2.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _PrometheusSeriesChartPainter oldDelegate) =>
      true;
}

class _TechStackEdgesPainter extends CustomPainter {
  final List<Map<String, dynamic>> nodes;
  final List<Map<String, dynamic>> edges;
  final Map<int, Offset> nodePositions;
  final Map<int, Size> nodeSizes;
  final Size canvasSize;
  final int? liveSourceNodeId;
  final String? liveSourceSide;
  final Offset? liveMousePos;

  _TechStackEdgesPainter({
    required this.nodes,
    required this.edges,
    this.nodePositions = const {},
    this.nodeSizes = const {},
    required this.canvasSize,
    this.liveSourceNodeId,
    this.liveSourceSide,
    this.liveMousePos,
  });

  Offset _sidePoint(Rect r, String? side) {
    switch (side) {
      case 'top':
        return r.topCenter;
      case 'bottom':
        return r.bottomCenter;
      case 'left':
        return r.centerLeft;
      case 'right':
        return r.centerRight;
      default:
        return r.centerRight;
    }
  }

  void _drawCurvedArrow(
    Canvas canvas,
    Offset start,
    Offset end,
    Color color, {
    double strokeWidth = 2.3,
  }) {
    final path = Path()..moveTo(start.dx, start.dy);
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    if (dx.abs() >= dy.abs()) {
      path.cubicTo(
        start.dx + dx * 0.45,
        start.dy,
        start.dx + dx * 0.55,
        end.dy,
        end.dx,
        end.dy,
      );
    } else {
      path.cubicTo(
        start.dx,
        start.dy + dy * 0.45,
        end.dx,
        start.dy + dy * 0.55,
        end.dx,
        end.dy,
      );
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke,
    );

    final angle = math.atan2(dy, dx);
    const arrowLen = 9.5;
    const arrowAng = 0.48;
    final p1 = Offset(
      end.dx - arrowLen * math.cos(angle - arrowAng),
      end.dy - arrowLen * math.sin(angle - arrowAng),
    );
    final p2 = Offset(
      end.dx - arrowLen * math.cos(angle + arrowAng),
      end.dy - arrowLen * math.sin(angle + arrowAng),
    );
    final arrowPath = Path()
      ..moveTo(end.dx, end.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();
    canvas.drawPath(
      arrowPath,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final nodesById = <int, Map<String, dynamic>>{};
    for (final n in nodes) {
      nodesById[n['id'] as int] = n;
    }

    for (final e in edges) {
      final src = nodesById[e['source_node_id'] as int];
      final dst = nodesById[e['target_node_id'] as int];
      if (src == null || dst == null) continue;

      final srcId = src['id'] as int;
      final dstId = dst['id'] as int;
      final sPos =
          nodePositions[srcId] ??
          Offset(
            ((src['pos_x'] as num?)?.toDouble() ?? 0.2),
            ((src['pos_y'] as num?)?.toDouble() ?? 0.3),
          );
      final dPos =
          nodePositions[dstId] ??
          Offset(
            ((dst['pos_x'] as num?)?.toDouble() ?? 0.5),
            ((dst['pos_y'] as num?)?.toDouble() ?? 0.3),
          );
      final sSize =
          nodeSizes[srcId] ??
          Size(
            (src['width_px'] as num?)?.toDouble() ?? 220.0,
            (src['height_px'] as num?)?.toDouble() ?? 124.0,
          );
      final dSize =
          nodeSizes[dstId] ??
          Size(
            (dst['width_px'] as num?)?.toDouble() ?? 220.0,
            (dst['height_px'] as num?)?.toDouble() ?? 124.0,
          );

      final sRect = Rect.fromLTWH(
        sPos.dx * canvasSize.width,
        sPos.dy * canvasSize.height,
        sSize.width,
        sSize.height,
      );
      final dRect = Rect.fromLTWH(
        dPos.dx * canvasSize.width,
        dPos.dy * canvasSize.height,
        dSize.width,
        dSize.height,
      );

      Offset start = sRect.centerRight;
      Offset end = dRect.centerLeft;
      final edgeNotes = (e['notes'] as String?) ?? '';
      if (edgeNotes.startsWith('side:') && edgeNotes.contains('->')) {
        final parts = edgeNotes.substring(5).split('->');
        if (parts.length == 2) {
          start = _sidePoint(sRect, parts[0].trim());
          end = _sidePoint(dRect, parts[1].trim());
        }
      } else {
        final sCandidates = [
          sRect.centerRight,
          sRect.centerLeft,
          sRect.bottomCenter,
          sRect.topCenter,
        ];
        final dCandidates = [
          dRect.centerLeft,
          dRect.centerRight,
          dRect.topCenter,
          dRect.bottomCenter,
        ];

        double bestDist = double.infinity;
        for (final sc in sCandidates) {
          for (final dc in dCandidates) {
            final dist = (sc - dc).distanceSquared;
            if (dist < bestDist) {
              bestDist = dist;
              start = sc;
              end = dc;
            }
          }
        }
      }

      final isDown = (e['status'] as String?) == 'DOWN';
      final color = isDown ? AppTheme.error : AppTheme.accentCyan;
      _drawCurvedArrow(canvas, start, end, color);
    }

    // Si hay un cuadrado lateral seleccionado, dibujamos la flecha de unión en vivo hacia el ratón
    if (liveSourceNodeId != null && liveMousePos != null) {
      final src = nodesById[liveSourceNodeId!];
      if (src != null) {
        final sPos =
            nodePositions[liveSourceNodeId!] ??
            Offset(
              ((src['pos_x'] as num?)?.toDouble() ?? 0.2),
              ((src['pos_y'] as num?)?.toDouble() ?? 0.3),
            );
        final sSize =
            nodeSizes[liveSourceNodeId!] ??
            Size(
              (src['width_px'] as num?)?.toDouble() ?? 220.0,
              (src['height_px'] as num?)?.toDouble() ?? 124.0,
            );
        final sRect = Rect.fromLTWH(
          sPos.dx * canvasSize.width,
          sPos.dy * canvasSize.height,
          sSize.width,
          sSize.height,
        );
        final start = _sidePoint(sRect, liveSourceSide);
        _drawCurvedArrow(
          canvas,
          start,
          liveMousePos!,
          AppTheme.warning,
          strokeWidth: 2.6,
        );
        canvas.drawCircle(
          start,
          4.5,
          Paint()..color = AppTheme.warning,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TechStackEdgesPainter oldDelegate) => true;
}

class _MiniSparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;

  _MiniSparklinePainter({required this.values, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    double maxV = 1.0;
    for (final v in values) {
      if (v > maxV) maxV = v;
    }
    maxV = math.max(maxV * 1.15, 10.0);

    final pts = <Offset>[];
    for (int i = 0; i < values.length; i++) {
      final x = (i / (values.length - 1)) * size.width;
      final y =
          size.height - ((values[i] / maxV).clamp(0.0, 1.0) * size.height);
      pts.add(Offset(x, y));
    }

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (int i = 0; i < pts.length - 1; i++) {
      final midX = (pts[i].dx + pts[i + 1].dx) / 2;
      path.cubicTo(midX, pts[i].dy, midX, pts[i + 1].dy, pts[i + 1].dx, pts[i + 1].dy);
    }

    final fillPath = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.28),
            color.withValues(alpha: 0.02),
          ],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke,
    );
    canvas.drawCircle(pts.last, 2.2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _MiniSparklinePainter oldDelegate) => true;
}

