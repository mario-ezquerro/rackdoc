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
  Map<String, dynamic>? _hoveredStackNode;
  int? _selectedHostId;
  int? _selectedSwitchAssetId;
  int _telemetryRangeHours = 6;
  Map<String, dynamic>? _telemetryData;
  bool _loadingTelemetry = false;

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
        _overview = data;
        _loading = false;
        final stacks = _techStacks;
        if (stacks.isNotEmpty &&
            (_selectedStackId == null ||
                !stacks.any((st) => st['id'] == _selectedStackId))) {
          _selectedStackId = stacks.first['id'] as int;
        }
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
                      onPressed: _showCreateVirtualMachineWithServicesDialog,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accentBlue,
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.add_to_queue_rounded, size: 15),
                      label: const Text(
                        '+ Nueva Máquina Virtual / Host',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _showCreateServiceCheckDialog,
                      icon: const Icon(Icons.monitor_heart_rounded, size: 15),
                      label: const Text(
                        '+ Añadir Servicio a Host',
                        style: TextStyle(fontSize: 11.5),
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
  // TAB 1: STACKS TECNOLÓGICOS & ESQUEMAS DE LÓGICA DE NEGOCIO (LIENZO 2D + HOVER PROMETHEUS + SSH)
  // ===========================================================================

  Widget _buildTechStacksCanvasTab() {
    final stacks = _techStacks;
    final activeStack = stacks.firstWhere(
      (s) => s['id'] == _selectedStackId,
      orElse: () => stacks.isNotEmpty ? stacks.first : <String, dynamic>{},
    );
    final nodes = ((activeStack['nodes'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final edges = ((activeStack['edges'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    return Column(
      children: [
        // Barra de control de Stacks Tecnológicos / Esquemas de Negocio
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
            alignment: WrapAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.layers_rounded,
                    size: 18,
                    color: AppTheme.accentCyan,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'STACK TECNOLÓGICO:',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (stacks.isNotEmpty)
                    DropdownButton<int>(
                      value: activeStack['id'] as int?,
                      dropdownColor: AppTheme.bgElevated,
                      underline: const SizedBox.shrink(),
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.accentBlue,
                      ),
                      items: stacks
                          .map(
                            (st) => DropdownMenuItem<int>(
                              value: st['id'] as int,
                              child: Text(
                                '${st['name']} (${st['nodes_count']} nodos)',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() {
                        _selectedStackId = v;
                        _hoveredStackNode = null;
                      }),
                    ),
                ],
              ),
              if (widget.canEdit)
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _showCreateTechStackDialog,
                      icon: const Icon(Icons.create_new_folder_rounded, size: 15),
                      label: const Text(
                        '+ Nuevo Stack Tecnológico',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                    if (activeStack.isNotEmpty) ...[
                      OutlinedButton.icon(
                        onPressed: () =>
                            _showAddNodeToStackDialog(activeStack['id'] as int),
                        icon: const Icon(Icons.add_box_rounded, size: 15),
                        label: const Text(
                          '+ Añadir Host Existente al Lienzo',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: () =>
                            _showCreateVirtualMachineWithServicesDialog(
                              attachToCurrentStack: true,
                            ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.accentBlue,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.add_to_queue_rounded, size: 15),
                        label: const Text(
                          '+ Crear Nueva VM / BBDD en este Stack',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: nodes.length >= 2
                            ? () => _showCreateTechStackEdgeDialog(
                                activeStack['id'] as int,
                                nodes,
                              )
                            : null,
                        icon: const Icon(Icons.trending_flat_rounded, size: 16),
                        label: const Text(
                          '+ Conectar Nodos (Dibujar Flecha ➔)',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ],
                ),
            ],
          ),
        ),
        // Lienzo 2D Interactivo con Drag & Drop + Hover de Gráficas Prometheus + SSH
        Expanded(
          child: activeStack.isEmpty
              ? const Center(
                  child: Text('Crea un Stack Tecnológico para empezar'),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final cw = math.max(constraints.maxWidth, 980.0);
                    final ch = math.max(constraints.maxHeight, 560.0);
                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SingleChildScrollView(
                        child: SizedBox(
                          width: cw,
                          height: ch,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              // 1. Columnas guía de Lógica de Negocio (Swimlanes)
                              Row(
                                children: [
                                  _buildSwimlaneColumn(
                                    '1. ENTRADA / VIP / WAF / PERÍMETRO',
                                    AppTheme.accentCyan,
                                  ),
                                  _buildSwimlaneColumn(
                                    '2. FRONTALES WEB BALANCEADOS (NGINX / APACHE)',
                                    AppTheme.accentBlue,
                                  ),
                                  _buildSwimlaneColumn(
                                    '3. LÓGICA DE NEGOCIO / MICROSERVICIOS / DOCKER',
                                    AppTheme.accentPurple,
                                  ),
                                  _buildSwimlaneColumn(
                                    '4. BASES DE DATOS / CACHÉ / INFRAESTRUCTURA',
                                    AppTheme.accentTeal,
                                  ),
                                ],
                              ),
                              // 2. Pintor de Flechas Curvas de Lógica de Negocio con Estado en Vivo
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: _TechStackEdgesPainter(
                                    nodes: nodes,
                                    edges: edges,
                                    canvasSize: Size(cw, ch),
                                  ),
                                ),
                              ),
                              // 3. Nodos Arrastrables (Drag & Drop) con Hover de Gráficas Prometheus y Botón SSH
                              for (final sn in nodes)
                                _buildDraggableStackNodeCard(
                                  sn: sn,
                                  canvasWidth: cw,
                                  canvasHeight: ch,
                                ),
                              // 4. Leyenda e instrucciones en esquina inferior izquierda
                              Positioned(
                                left: 12,
                                bottom: 10,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppTheme.bgSecondary.withValues(
                                      alpha: 0.94,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: AppTheme.border),
                                  ),
                                  child: Text(
                                    '💡 Arrastra cualquier nodo para diseñar tu esquema • Posa el ratón encima para ver Gráficas Prometheus y Estado en Vivo • Pulsa "SSH" para abrir consola remota (${edges.length} conexiones activas)',
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.textSecondary,
                                    ),
                                  ),
                                ),
                              ),
                              // 5. Panel Flotante en Vivo al posar el ratón (Hover) con Gráficas Prometheus TSDB y SSH
                              if (_hoveredStackNode != null)
                                Positioned(
                                  right: 16,
                                  bottom: 14,
                                  child: _buildStackNodePrometheusHoverPanel(
                                    _hoveredStackNode!,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildSwimlaneColumn(String title, Color color) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.035),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.22)),
        ),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(11),
                ),
              ),
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: color,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDraggableStackNodeCard({
    required Map<String, dynamic> sn,
    required double canvasWidth,
    required double canvasHeight,
  }) {
    final host = Map<String, dynamic>.from((sn['host'] as Map?) ?? {});
    final px = ((sn['pos_x'] as num?)?.toDouble() ?? 0.2).clamp(0.02, 0.84);
    final py = ((sn['pos_y'] as num?)?.toDouble() ?? 0.3).clamp(0.07, 0.78);
    final left = px * canvasWidth;
    final top = py * canvasHeight;

    final state = (host['nagios_host_state'] as String?) ?? 'UP';
    final stateCol = _nagiosStateColor(state);
    final mini = Map<String, dynamic>.from((host['mini_series'] as Map?) ?? {});
    final cpuSeries = ((mini['cpu'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList();
    final checks = ((host['service_checks'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final isHovered =
        _hoveredStackNode != null && _hoveredStackNode!['id'] == sn['id'];
    final rackId = host['rack_id'] as int?;
    final targetRackDevId = host['target_rack_device_id'] as int?;

    return Positioned(
      left: left,
      top: top,
      child: MouseRegion(
        onEnter: (_) => setState(() {
          _hoveredStackNode = sn;
          _selectedHostId = host['id'] as int?;
        }),
        child: GestureDetector(
          onTap: () {
            setState(() {
              _hoveredStackNode = sn;
              _selectedHostId = host['id'] as int?;
            });
          },
          onPanUpdate: widget.canEdit
              ? (details) {
                  final newPx = ((left + details.delta.dx) / canvasWidth).clamp(
                    0.02,
                    0.84,
                  );
                  final newPy = ((top + details.delta.dy) / canvasHeight).clamp(
                    0.07,
                    0.78,
                  );
                  setState(() {
                    sn['pos_x'] = newPx;
                    sn['pos_y'] = newPy;
                  });
                }
              : null,
          onPanEnd: widget.canEdit
              ? (_) async {
                  final res = await widget.api.moveTechStackNode(
                    sn['id'] as int,
                    {
                      'pos_x': sn['pos_x'],
                      'pos_y': sn['pos_y'],
                    },
                  );
                  if (mounted) setState(() => _overview = res);
                }
              : null,
          child: Container(
            width: 232,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.bgSecondary,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: isHovered ? AppTheme.accentBlue : stateCol,
                width: isHovered ? 2.2 : 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: (isHovered ? AppTheme.accentBlue : stateCol).withValues(
                    alpha: 0.18,
                  ),
                  blurRadius: isHovered ? 14 : 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Fila 1: Badge Nagios + Código + Latencia + Quitar del lienzo
                Row(
                  children: [
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
                          fontSize: 11.5,
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
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.accentTeal,
                        ),
                      ),
                    if (widget.canEdit) ...[
                      const SizedBox(width: 4),
                      InkWell(
                        onTap: () async {
                          final res = await widget.api.deleteTechStackNode(
                            sn['id'] as int,
                          );
                          setState(() {
                            _overview = res;
                            if (_hoveredStackNode?['id'] == sn['id']) {
                              _hoveredStackNode = null;
                            }
                          });
                        },
                        child: const Icon(
                          Icons.close,
                          size: 13,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                // Etiqueta de Rol en el Stack Tecnológico
                Text(
                  '${sn['custom_label']}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.accentBlue,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${host['heartbeat_ip']} • ${host['rack_location_badge']}',
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontFamily: 'monospace',
                    color: AppTheme.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                // Mini-Gráfica Sparkline Prometheus en vivo integrada en la tarjeta
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'CPU ${host['cpu_pct']}% • RAM ${host['ram_pct']}%',
                            style: const TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 3),
                          SizedBox(
                            height: 20,
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
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Barra de acciones rápidas del nodo: SSH / Gráficas Prometheus / Rack / Servicios
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    InkWell(
                      onTap: () => _showSshWebConsoleDialog(sn, host),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.terminal_rounded,
                              size: 11,
                              color: Color(0xFF38BDF8),
                            ),
                            SizedBox(width: 4),
                            Text(
                              'SSH',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    InkWell(
                      onTap: () {
                        setState(() => _selectedHostId = host['id'] as int);
                        _tabController.animateTo(4);
                        _loadHostTelemetry(host['id'] as int);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.warning.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.show_chart_rounded,
                              size: 11,
                              color: AppTheme.warning,
                            ),
                            SizedBox(width: 3),
                            Text(
                              'Prometheus',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.warning,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (rackId != null && widget.onNavigateToRackDevice != null)
                      InkWell(
                        onTap: () => widget.onNavigateToRackDevice!(
                          rackId,
                          targetRackDevId,
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2.5,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.accentBlue.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: const Text(
                            'Rack',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.accentBlue,
                            ),
                          ),
                        ),
                      ),
                    Text(
                      '${checks.length} chk',
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
        ),
      ),
    );
  }

  Widget _buildStackNodePrometheusHoverPanel(Map<String, dynamic> sn) {
    final host = Map<String, dynamic>.from((sn['host'] as Map?) ?? {});
    final mini = Map<String, dynamic>.from((host['mini_series'] as Map?) ?? {});
    final cpuList = ((mini['cpu'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList();
    final ramList = ((mini['ram'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList();
    final latList = ((mini['latency'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList();
    final trafList = ((mini['traffic'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList();
    final checks = ((host['service_checks'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final state = (host['nagios_host_state'] as String?) ?? 'UP';
    final stateCol = _nagiosStateColor(state);

    return Material(
      elevation: 10,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.bgSecondary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.accentBlue, width: 1.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: stateCol.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: stateCol),
                  ),
                  child: Text(
                    state,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: stateCol,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${host['code']} — ${sn['custom_label']}',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 15),
                  constraints: const BoxConstraints(),
                  padding: EdgeInsets.zero,
                  onPressed: () => setState(() => _hoveredStackNode = null),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              'IPs: ${(host['all_ips'] as List?)?.join(", ") ?? host['heartbeat_ip']} • ${host['rack_location_badge']}',
              style: const TextStyle(
                fontSize: 10.5,
                fontFamily: 'monospace',
                color: AppTheme.textSecondary,
              ),
            ),
            const Divider(height: 16),
            const Text(
              'TELEMETRÍA EN VIVO ALMACENADA EN PROMETHEUS TSDB:',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: AppTheme.accentCyan,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _buildHoverMiniChartBox(
                    'CPU (${host['cpu_pct']}%)',
                    cpuList,
                    AppTheme.accentBlue,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildHoverMiniChartBox(
                    'RAM (${host['ram_pct']}%)',
                    ramList,
                    AppTheme.accentPurple,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _buildHoverMiniChartBox(
                    'Latencia (${host['last_ping_ms'] ?? 1.2} ms)',
                    latList,
                    AppTheme.accentTeal,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildHoverMiniChartBox(
                    'Tráfico Red (Mbps)',
                    trafList,
                    AppTheme.warning,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'ESTADOS NAGIOS DE SERVICIOS (${checks.length}):',
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            ...checks.take(4).map((c) {
              final cst = (c['nagios_state'] as String?) ?? 'OK';
              final ccol = _nagiosStateColor(cst);
              return Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  children: [
                    Icon(Icons.circle, size: 7, color: ccol),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        '${c['service_name']}: ${c['status_output']}',
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
              );
            }),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ElevatedButton.icon(
                  onPressed: () => _showSshWebConsoleDialog(sn, host),
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
                    size: 14,
                    color: Color(0xFF38BDF8),
                  ),
                  label: Text(
                    'Conectar SSH (${sn['ssh_user']}@${host['heartbeat_ip']})',
                    style: const TextStyle(fontSize: 10.5),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() => _selectedHostId = host['id'] as int);
                    _tabController.animateTo(4);
                    _loadHostTelemetry(host['id'] as int);
                  },
                  icon: const Icon(Icons.multiline_chart_rounded, size: 14),
                  label: const Text(
                    'Abrir Gráficas Prometheus',
                    style: TextStyle(fontSize: 10.5),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHoverMiniChartBox(
    String label,
    List<double> values,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 26,
            width: double.infinity,
            child: CustomPaint(
              painter: _MiniSparklinePainter(values: values, color: color),
            ),
          ),
        ],
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
            OutlinedButton.icon(
              onPressed: () => _showSshWebConsoleDialog(
                {'ssh_user': 'root', 'ssh_port': 22},
                host,
              ),
              icon: const Icon(Icons.terminal_rounded, size: 15),
              label: const Text(
                'Consola SSH',
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
  // TAB 4: GRÁFICAS PROMETHEUS TSDB & QUÉ INSTALAR EN CADA HOST
  // ===========================================================================

  Widget _buildPrometheusChartsAndAgentsTab() {
    final pts = ((_telemetryData?['points'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final promQueries = Map<String, dynamic>.from(
      (_telemetryData?['promql_examples'] as Map?) ?? {},
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Selector de Host y ventana temporal para Prometheus TSDB
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.bgSecondary,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          child: Wrap(
            spacing: 14,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.local_fire_department_rounded,
                    color: AppTheme.warning,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'SERIES TEMPORALES PROMETHEUS TSDB — HOST:',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(width: 10),
                  DropdownButton<int>(
                    value: _selectedHostId,
                    dropdownColor: AppTheme.bgElevated,
                    underline: const SizedBox.shrink(),
                    items: _hosts
                        .map(
                          (h) => DropdownMenuItem<int>(
                            value: h['id'] as int,
                            child: Text(
                              '${h['code']} — ${h['name']} (${h['heartbeat_ip']})',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _selectedHostId = v);
                      _loadHostTelemetry(v);
                    },
                  ),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final hrs in [1, 6, 24, 168])
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: ChoiceChip(
                        label: Text(hrs == 168 ? '7d' : '${hrs}h'),
                        selected: _telemetryRangeHours == hrs,
                        onSelected: (_) {
                          setState(() => _telemetryRangeHours = hrs);
                          if (_selectedHostId != null) {
                            _loadHostTelemetry(_selectedHostId!);
                          }
                        },
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (_loadingTelemetry)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(),
            ),
          )
        else ...[
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              _buildTelemetryChartCard(
                title: 'USO DE CPU (%) & MEMORIA RAM (%)',
                promQl: '${promQueries['cpu'] ?? ''}',
                points: pts,
                metricKeyA: 'cpu_pct',
                labelA: 'CPU %',
                colorA: AppTheme.accentBlue,
                metricKeyB: 'ram_pct',
                labelB: 'RAM %',
                colorB: AppTheme.accentPurple,
                unit: '%',
              ),
              _buildTelemetryChartCard(
                title: 'LATENCIA DEL HEARTBEAT (MS)',
                promQl: '${promQueries['latency'] ?? ''}',
                points: pts,
                metricKeyA: 'latency_ms',
                labelA: 'Ping / HTTP ms',
                colorA: AppTheme.accentTeal,
                unit: 'ms',
              ),
              _buildTelemetryChartCard(
                title: 'TRÁFICO DE RED RX / TX (MBPS - IF-MIB / NODE_EXPORTER)',
                promQl: '${promQueries['switch_traffic'] ?? ''}',
                points: pts,
                metricKeyA: 'rx_mbps',
                labelA: 'Rx Entrante (Mbps)',
                colorA: AppTheme.accentCyan,
                metricKeyB: 'tx_mbps',
                labelB: 'Tx Saliente (Mbps)',
                colorB: AppTheme.warning,
                unit: 'Mbps',
              ),
              _buildTelemetryChartCard(
                title: 'PETICIONES WEB APACHE / NGINX (REQ/S) & DISCO (%)',
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
            ],
          ),
        ],
        const SizedBox(height: 20),
        // Guía interactiva de Qué instalar en cada ordenador/host para monitorizarlo con Prometheus y RackDoc
        _buildWhatToInstallInHostsSection(),
      ],
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
    final lastA = points.isNotEmpty
        ? (points.last[metricKeyA] as num?)?.toDouble() ?? 0
        : 0;
    final lastB = (points.isNotEmpty && metricKeyB != null)
        ? (points.last[metricKeyB] as num?)?.toDouble() ?? 0
        : null;

    return Container(
      width: 520,
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
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '$labelA: ${lastA.toStringAsFixed(1)} $unit',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: colorA,
                ),
              ),
              if (lastB != null && labelB != null && colorB != null) ...[
                const SizedBox(width: 10),
                Text(
                  '$labelB: ${lastB.toStringAsFixed(1)} $unit',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: colorB,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 3),
          Text(
            'PromQL: $promQl',
            style: const TextStyle(
              fontSize: 10,
              fontFamily: 'monospace',
              color: AppTheme.textMuted,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 150,
            width: double.infinity,
            child: CustomPaint(
              painter: _PrometheusSeriesChartPainter(
                points: points,
                keyA: metricKeyA,
                colorA: colorA,
                keyB: metricKeyB,
                colorB: colorB,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWhatToInstallInHostsSection() {
    final guides = [
      (
        'Linux (Ubuntu / Debian / RHEL / Proxmox)',
        'Prometheus Node Exporter (:9100)',
        'Expone CPU, RAM, Carga, Discos, I/O, Interfaces de Red y estado de servicios systemd.',
        '''# Ubuntu / Debian / Proxmox VE:
sudo apt-get update && sudo apt-get install -y prometheus-node-exporter
sudo systemctl enable --now prometheus-node-exporter
# Verifica que responde en el puerto 9100:
curl -s http://localhost:9100/metrics | head -n 20''',
      ),
      (
        'Windows Server (AD / SQL / IIS / Hyper-V)',
        'Prometheus Windows Exporter (:9182)',
        'Expone CPU, Memoria, Discos NTFS, Servicios de Windows, IIS y contadores de Active Directory.',
        '''# PowerShell (Administrador) en Windows Server:
Invoke-WebRequest -Uri "https://github.com/prometheus-community/windows_exporter/releases/latest/download/windows_exporter-0.27.3-amd64.msi" -OutFile C:\\windows_exporter.msi
msiexec /i C:\\windows_exporter.msi ENABLED_COLLECTORS="cpu,cs,logical_disk,net,os,service,system,memory" LISTEN_PORT=9182 /qn''',
      ),
      (
        'Switches, Routers y Firewalls (Cisco, Aruba, FortiGate)',
        'SNMPv2c / SNMPv3 + LLDP (:161/UDP)',
        'Permite a RackDoc descubrir todas las bocas (IF-MIB) y vecinos (LLDP-MIB) de una sola vez sin alta manual.',
        '''! Configuración en Switch Cisco IOS / Catalyst / Aruba:
snmp-server community public RO
snmp-server location "CPD Principal RackDoc"
lldp run''',
      ),
      (
        'Apache HTTPd & Nginx Web Servers',
        'mod_status (/server-status?auto) & stub_status (/nginx_status)',
        'Permite medir peticiones por segundo (req/s), workers ocupados/libres y conexiones activas.',
        '''# En Nginx (/etc/nginx/conf.d/status.conf):
location /nginx_status {
    stub_status on;
    allow 10.0.0.0/8;
    deny all;
}
# En Apache (/etc/apache2/mods-enabled/status.conf):
ExtendedStatus On
<Location "/server-status">
    SetHandler server-status
    Require ip 10.0.0.0/8
</Location>''',
      ),
      (
        'Docker Engine / Contenedores',
        'Docker Daemon Metrics (:9323/metrics)',
        'Expone contenedores en ejecución, parados, unhealthy, CPU y memoria por contenedor.',
        '''// En /etc/docker/daemon.json:
{
  "metrics-addr": "0.0.0.0:9323",
  "experimental": true
}
// Reiniciar servicio: sudo systemctl restart docker''',
      ),
    ];

    return Container(
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
              Icon(Icons.terminal_rounded, color: AppTheme.accentCyan, size: 20),
              SizedBox(width: 8),
              Text(
                '¿QUÉ HAY QUE INSTALAR EN CADA HOST PARA QUE PROMETHEUS Y RACKDOC LO MONITORICEN?',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Cuando das de alta un Host desde este interfaz o mediante Ansible, RackDoc actualiza automáticamente /app/data/prometheus/targets_dynamic.json para que Prometheus lo raspee cada 15s.',
            style: TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: guides.map((g) {
              return Container(
                width: 510,
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
                            g.$1,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.accentCyan,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy_rounded, size: 15),
                          tooltip: 'Copiar comandos',
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: g.$4));
                            _showSnack('Comandos copiados al portapapeles');
                          },
                        ),
                      ],
                    ),
                    Text(
                      g.$2,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      g.$3,
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppTheme.bgPrimary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: SelectableText(
                        g.$4,
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontFamily: 'monospace',
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 5: AVISOS DE ALARMAS (PERSONAS, GRUPOS, HOSTGROUPS) & MANTENIMIENTO
  // ===========================================================================

  Widget _buildAlertsContactsAndMaintenanceTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Barra de acciones rápidas de Alarmas y Mantenimiento
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            if (widget.canEdit) ...[
              ElevatedButton.icon(
                onPressed: _showCreateContactDialog,
                icon: const Icon(Icons.person_add_alt_1_rounded, size: 15),
                label: const Text('+ Nueva Persona (Contacto)'),
              ),
              ElevatedButton.icon(
                onPressed: _showCreateContactGroupDialog,
                icon: const Icon(Icons.groups_rounded, size: 15),
                label: const Text('+ Nuevo Grupo de Personas'),
              ),
              ElevatedButton.icon(
                onPressed: _showCreateHostGroupDialog,
                icon: const Icon(Icons.folder_special_rounded, size: 15),
                label: const Text('+ Nuevo Grupo de Hosts'),
              ),
              ElevatedButton.icon(
                onPressed: _showCreateRoutingRuleDialog,
                icon: const Icon(Icons.alt_route_rounded, size: 15),
                label: const Text('+ Nueva Regla de Enrutamiento'),
              ),
              OutlinedButton.icon(
                onPressed: _showCreateMaintenanceDialog,
                icon: const Icon(Icons.build_circle_rounded, size: 15),
                label: const Text('+ Ventana de Mantenimiento'),
              ),
            ],
            OutlinedButton.icon(
              onPressed: () async {
                final res = await widget.api.triggerTestAlert(
                  assetId: _selectedHostId,
                );
                setState(() => _overview = res);
                _showSnack(
                  'Alerta de prueba disparada y registrada en la bitácora.',
                );
              },
              icon: const Icon(
                Icons.notification_important_rounded,
                size: 15,
                color: AppTheme.warning,
              ),
              label: const Text('Disparar Alerta de Prueba'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // 1. Reglas de Enrutamiento (Host / HostGroup -> Persona / Grupo de Personas)
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
              Text(
                'MATRIZ DE REGLAS DE ENRUTAMIENTO DE ALARMAS (${_notificationRules.length})',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.accentCyan,
                ),
              ),
              const SizedBox(height: 8),
              ..._notificationRules.map(
                (r) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.notifications_active_rounded,
                    color: AppTheme.accentCyan,
                    size: 18,
                  ),
                  title: Text(
                    '${r['name']}  •  Origen: [${r['host_group_name']}]',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    'Avisa a Grupos: ${(r['contact_group_names'] as List).join(", ")} | Personas: ${(r['contact_names'] as List).join(", ")}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  trailing: widget.canEdit
                      ? IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            size: 16,
                            color: AppTheme.error,
                          ),
                          onPressed: () async {
                            final res = await widget.api.deleteNotificationRule(
                              r['id'] as int,
                            );
                            setState(() => _overview = res);
                          },
                        )
                      : null,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        // 2. Personas, Grupos de Personas y Grupos de Hosts en 3 columnas
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            // Personas
            Container(
              width: 340,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.bgSecondary,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'PERSONAS / CONTACTOS (${_alertContacts.length})',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ..._alertContacts.map(
                    (c) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${c['full_name']} (${c['schedule_period']})',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        '${c['email']}\n${c['role_title']}',
                        style: const TextStyle(fontSize: 10.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Grupos de Personas
            Container(
              width: 340,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.bgSecondary,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'GRUPOS DE PERSONAS (${_alertContactGroups.length})',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ..._alertContactGroups.map(
                    (cg) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${cg['name']} (${cg['code']})',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        'Correo: ${cg['group_email']}\nMiembros: ${(cg['member_names'] as List).join(", ")}',
                        style: const TextStyle(fontSize: 10.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Grupos de Hosts
            Container(
              width: 340,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.bgSecondary,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'GRUPOS DE HOSTS / EQUIPOS (${_hostGroups.length})',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ..._hostGroups.map(
                    (hg) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${hg['name']} (${hg['code']})',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        'Equipos: ${(hg['member_codes'] as List).join(", ")}',
                        style: const TextStyle(fontSize: 10.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // 3. Ventanas de Mantenimiento y Bitácora de Avisos
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
              Text(
                'VENTANAS DE MANTENIMIENTO ACTIVAS E HISTÓRICAS (${_maintenanceWindows.length}) & BITÁCORA DE AVISOS (${_alertLogs.length})',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.accentCyan,
                ),
              ),
              const SizedBox(height: 8),
              ..._maintenanceWindows.map(
                (w) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    Icons.build_circle_rounded,
                    color: w['is_active'] == true
                        ? AppTheme.accentCyan
                        : AppTheme.textMuted,
                  ),
                  title: Text(
                    '${w['title']} (${w['is_active'] == true ? "ACTIVA" : "FINALIZADA"})',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    'Creada por: ${w['created_by']} • Motivo: ${w['reason']} • Fin: ${w['ends_at']}',
                    style: const TextStyle(fontSize: 10.5),
                  ),
                  trailing: (w['is_active'] == true && widget.canEdit)
                      ? OutlinedButton(
                          onPressed: () async {
                            final res = await widget.api.stopMaintenanceWindow(
                              w['id'] as int,
                            );
                            setState(() => _overview = res);
                          },
                          child: const Text(
                            'Finalizar Mantenimiento',
                            style: TextStyle(fontSize: 10.5),
                          ),
                        )
                      : null,
                ),
              ),
              const Divider(height: 18),
              ..._alertLogs.take(10).map(
                (lg) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.mark_email_read_rounded,
                    size: 16,
                    color: AppTheme.warning,
                  ),
                  title: Text(
                    '[${lg['event_state']}] ${lg['asset_code']} — ${lg['service_name']}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    'Destinatarios: ${lg['recipients_summary']} (${lg['delivery_status']})\n${lg['detail']}',
                    style: const TextStyle(fontSize: 10.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
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
  // DIÁLOGOS MODALES DE CREACIÓN Y DESCUBRIMIENTO
  // ===========================================================================

  Future<void> _showCreateVirtualMachineWithServicesDialog({
    bool attachToCurrentStack = false,
  }) async {
    String assetClass = 'virtual_machine';
    String hypervisorPlatform = 'VMware vSphere / Proxmox VE';
    final codeCtrl = TextEditingController(text: 'VM-APP-NUEVA-01');
    final nameCtrl = TextEditingController(
      text: 'Servidor de Aplicaciones & Portal Web',
    );
    final hostnameCtrl = TextEditingController(text: 'vm-app-nueva-01');
    final fqdnCtrl = TextEditingController(text: 'vm-app-nueva-01.hq.local');
    final osCtrl = TextEditingController(text: 'Ubuntu Server 24.04 LTS');
    final primaryIpCtrl = TextEditingController(text: '10.20.20.160');
    final extraIpsCtrl = TextEditingController(text: '');
    final cpuCtrl = TextEditingController(text: '4');
    final ramCtrl = TextEditingController(text: '16');
    final diskCtrl = TextEditingController(text: '120');

    final hypervisorCandidates = _hosts
        .where(
          (h) =>
              h['logical_layer'] == 'hypervisors_phys' ||
              h['logical_layer'] == 'network_switching',
        )
        .toList();
    String parentAssetCode = hypervisorCandidates.isNotEmpty
        ? (hypervisorCandidates.first['code'] as String)
        : '';

    String selectedHostGroupCode = _hostGroups.isNotEmpty
        ? (_hostGroups.first['code'] as String)
        : 'HG-WEB-APACHE-NGINX';

    bool enableNodeExporter = true;
    bool enableWindowsExporter = false;
    bool enableSshCheck = true;
    bool enableHttpsCheck = true;
    final httpsUrlCtrl = TextEditingController(
      text: 'https://vm-app-nueva-01.hq.local/health',
    );
    bool enableNginxCheck = false;
    bool enableApacheCheck = false;
    bool enableDockerCheck = false;
    bool enablePostgresCheck = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Row(
            children: [
              Icon(
                Icons.add_to_queue_rounded,
                color: AppTheme.accentBlue,
                size: 22,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Alta de Máquina Virtual / Host + Servicios + Prometheus',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Crea la Máquina Virtual o Host, registra sus IPs en la 6. CMDB, la enlaza a su Hipervisor/Servidor del Rack en el Diagrama Lógico y activa sus chequeos y métricas en Prometheus en un solo paso.',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: assetClass,
                          decoration: const InputDecoration(
                            labelText: 'Clase de Equipo / Máquina',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'virtual_machine',
                              child: Text(
                                'Máquina Virtual (VMware / Proxmox / Hyper-V / KVM)',
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'container',
                              child: Text(
                                'Contenedor / Pod (Docker / LXC / K8s)',
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'physical_server',
                              child: Text('Servidor Físico / Barebone'),
                            ),
                            DropdownMenuItem(
                              value: 'vip_cluster',
                              child: Text('IP Virtual (VIP) / Balanceador HA'),
                            ),
                            DropdownMenuItem(
                              value: 'network_security',
                              child: Text('Switch / Router / Firewall'),
                            ),
                          ],
                          onChanged: (v) =>
                              setModal(() => assetClass = v ?? assetClass),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: hypervisorPlatform,
                          decoration: const InputDecoration(
                            labelText: 'Plataforma / Hipervisor',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'VMware vSphere / Proxmox VE',
                              child: Text('VMware vSphere / ESXi'),
                            ),
                            DropdownMenuItem(
                              value: 'Proxmox VE Cluster (KVM/LXC)',
                              child: Text('Proxmox VE (QEMU / LXC)'),
                            ),
                            DropdownMenuItem(
                              value: 'Microsoft Hyper-V / KVM',
                              child: Text('Microsoft Hyper-V / KVM'),
                            ),
                            DropdownMenuItem(
                              value: 'Docker Engine / Kubernetes',
                              child: Text('Docker Engine / Portainer / K8s'),
                            ),
                            DropdownMenuItem(
                              value: 'Barebone / Cloud Externo',
                              child: Text('Barebone Dedicado / Cloud'),
                            ),
                          ],
                          onChanged: (v) => setModal(
                            () => hypervisorPlatform = v ?? hypervisorPlatform,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: codeCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Código Único (ej. VM-ERP-02)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: nameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Nombre Descriptivo de la Máquina',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: hostnameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Hostname',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: fqdnCtrl,
                          decoration: const InputDecoration(
                            labelText: 'FQDN DNS',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: osCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Sistema Operativo',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: primaryIpCtrl,
                          decoration: const InputDecoration(
                            labelText: 'IP Principal (Heartbeat / Gestión)',
                            prefixIcon: Icon(Icons.favorite_rounded, size: 15),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: extraIpsCtrl,
                          decoration: const InputDecoration(
                            labelText:
                                'IPs Adicionales Servicio/VIP (separadas por coma)',
                            hintText: 'Ej: 172.16.30.50, 10.20.20.245',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: cpuCtrl,
                          decoration: const InputDecoration(
                            labelText: 'vCPU Cores',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: ramCtrl,
                          decoration: const InputDecoration(
                            labelText: 'RAM (GB)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: diskCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Disco (GB)',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (hypervisorCandidates.isNotEmpty)
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: parentAssetCode,
                            decoration: const InputDecoration(
                              labelText:
                                  'Alojada en Servidor Físico del Rack / Padre',
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text(
                                  'Barebone Externo (Sin Rack Físico)',
                                ),
                              ),
                              ...hypervisorCandidates.map(
                                (h) => DropdownMenuItem<String>(
                                  value: h['code'] as String,
                                  child: Text(
                                    '${h['code']} (${h['rack_location_badge']})',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                            onChanged: (v) =>
                                setModal(() => parentAssetCode = v ?? ''),
                          ),
                        ),
                      const SizedBox(width: 10),
                      if (_hostGroups.isNotEmpty)
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: selectedHostGroupCode,
                            decoration: const InputDecoration(
                              labelText: 'Grupo de Hosts (Alertas)',
                            ),
                            items: _hostGroups
                                .map(
                                  (hg) => DropdownMenuItem<String>(
                                    value: hg['code'] as String,
                                    child: Text(
                                      '${hg['name']} (${hg['code']})',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) => setModal(
                              () => selectedHostGroupCode =
                                  v ?? selectedHostGroupCode,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const Divider(height: 22),
                  const Text(
                    'SERVICIOS, EXPORTERS PROMETHEUS Y HEARTBEATS A MONITORIZAR EN ESTA MÁQUINA:',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.accentCyan,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      FilterChip(
                        label: const Text(
                          'Linux Node Exporter (:9100)',
                          style: TextStyle(fontSize: 11),
                        ),
                        selected: enableNodeExporter,
                        onSelected: (v) =>
                            setModal(() => enableNodeExporter = v),
                      ),
                      FilterChip(
                        label: const Text(
                          'Windows Exporter (:9182)',
                          style: TextStyle(fontSize: 11),
                        ),
                        selected: enableWindowsExporter,
                        onSelected: (v) =>
                            setModal(() => enableWindowsExporter = v),
                      ),
                      FilterChip(
                        label: const Text(
                          'SSH (:22)',
                          style: TextStyle(fontSize: 11),
                        ),
                        selected: enableSshCheck,
                        onSelected: (v) => setModal(() => enableSshCheck = v),
                      ),
                      FilterChip(
                        label: const Text(
                          'HTTPS + Validez SSL (:443)',
                          style: TextStyle(fontSize: 11),
                        ),
                        selected: enableHttpsCheck,
                        onSelected: (v) => setModal(() => enableHttpsCheck = v),
                      ),
                      FilterChip(
                        label: const Text(
                          'Nginx stub_status (:8080)',
                          style: TextStyle(fontSize: 11),
                        ),
                        selected: enableNginxCheck,
                        onSelected: (v) => setModal(() => enableNginxCheck = v),
                      ),
                      FilterChip(
                        label: const Text(
                          'Apache mod_status (:8080)',
                          style: TextStyle(fontSize: 11),
                        ),
                        selected: enableApacheCheck,
                        onSelected: (v) =>
                            setModal(() => enableApacheCheck = v),
                      ),
                      FilterChip(
                        label: const Text(
                          'Docker Engine (:9323)',
                          style: TextStyle(fontSize: 11),
                        ),
                        selected: enableDockerCheck,
                        onSelected: (v) =>
                            setModal(() => enableDockerCheck = v),
                      ),
                      FilterChip(
                        label: const Text(
                          'PostgreSQL (:5432)',
                          style: TextStyle(fontSize: 11),
                        ),
                        selected: enablePostgresCheck,
                        onSelected: (v) =>
                            setModal(() => enablePostgresCheck = v),
                      ),
                    ],
                  ),
                  if (enableHttpsCheck) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: httpsUrlCtrl,
                      decoration: const InputDecoration(
                        labelText:
                            'URL del Endpoint HTTPS a monitorizar (con chequeo de días SSL)',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                final primaryIp = primaryIpCtrl.text.trim();
                final hostname = hostnameCtrl.text.trim();
                if (primaryIp.isEmpty || hostname.isEmpty) {
                  _showSnack(
                    'El Hostname y la IP Principal son obligatorios.',
                    isError: true,
                  );
                  return;
                }
                Navigator.pop(ctx);

                final extraIps = extraIpsCtrl.text
                    .split(',')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .map(
                      (ip) => {
                        'ip_address': ip,
                        'ip_role': 'primary_service',
                        'interface_name': 'eth1',
                      },
                    )
                    .toList();

                final exporters = <Map<String, dynamic>>[];
                if (enableNodeExporter) {
                  exporters.add({'type': 'node_exporter', 'port': 9100});
                }
                if (enableWindowsExporter) {
                  exporters.add({'type': 'windows_exporter', 'port': 9182});
                }
                if (enableNginxCheck) {
                  exporters.add({
                    'type': 'nginx',
                    'port': 8080,
                    'url': 'http://$primaryIp:8080/nginx_status',
                  });
                }
                if (enableApacheCheck) {
                  exporters.add({
                    'type': 'apache',
                    'port': 8080,
                    'url': 'http://$primaryIp:8080/server-status?auto',
                  });
                }
                if (enableDockerCheck) {
                  exporters.add({
                    'type': 'docker',
                    'port': 9323,
                    'url': 'http://$primaryIp:9323/metrics',
                  });
                }

                final heartbeats = <Map<String, dynamic>>[];
                if (enableSshCheck) {
                  heartbeats.add({
                    'name': 'Acceso SSH Gestión (:22)',
                    'type': 'ssh',
                    'port': 22,
                    'url': primaryIp,
                  });
                }
                if (enableHttpsCheck) {
                  heartbeats.add({
                    'name': 'Portal HTTPS & Certificado SSL',
                    'type': 'https',
                    'port': 443,
                    'url': httpsUrlCtrl.text.trim().isNotEmpty
                        ? httpsUrlCtrl.text.trim()
                        : 'https://$primaryIp',
                  });
                }
                if (enablePostgresCheck) {
                  heartbeats.add({
                    'name': 'Base de Datos PostgreSQL (:5432)',
                    'type': 'postgres',
                    'port': 5432,
                    'url': primaryIp,
                  });
                }

                try {
                  final res = await widget.api.createNetworkHostWithServices({
                    'code': codeCtrl.text.trim(),
                    'name': nameCtrl.text.trim(),
                    'hostname': hostname,
                    'fqdn': fqdnCtrl.text.trim(),
                    'asset_class': assetClass,
                    'environment': 'production',
                    'criticality': 'high',
                    'os_or_firmware': osCtrl.text.trim(),
                    'hypervisor_or_platform': hypervisorPlatform,
                    'cpu_cores': int.tryParse(cpuCtrl.text.trim()) ?? 4,
                    'ram_gb': double.tryParse(ramCtrl.text.trim()) ?? 16,
                    'storage_gb': double.tryParse(diskCtrl.text.trim()) ?? 120,
                    'primary_ip': primaryIp,
                    'additional_ips': extraIps,
                    'parent_asset_code': parentAssetCode,
                    'host_groups': selectedHostGroupCode.isNotEmpty
                        ? [selectedHostGroupCode]
                        : [],
                    'exporters': exporters,
                    'heartbeats': heartbeats,
                  });
                  if (res['overview'] is Map) {
                    final created = Map<String, dynamic>.from(
                      (res['created_host'] as Map?) ?? {},
                    );
                    final newAssetId = created['asset_id'] as int?;
                    if (attachToCurrentStack &&
                        _selectedStackId != null &&
                        newAssetId != null) {
                      final stackUpdated = await widget.api.createTechStackNode(
                        {
                          'stack_id': _selectedStackId,
                          'asset_id': newAssetId,
                          'role_layer': 'web_frontend',
                          'custom_label': nameCtrl.text.trim(),
                          'pos_x': 0.34,
                          'pos_y': 0.36,
                        },
                      );
                      setState(() {
                        _overview = stackUpdated;
                        _selectedHostId = newAssetId;
                      });
                    } else {
                      setState(() {
                        _overview = Map<String, dynamic>.from(
                          res['overview'] as Map,
                        );
                        if (newAssetId != null) {
                          _selectedHostId = newAssetId;
                        }
                      });
                    }
                    if (_selectedHostId != null) {
                      _loadHostTelemetry(_selectedHostId!);
                    }
                  }
                  _showSnack(
                    'Máquina ${codeCtrl.text.trim()} creada en Red & Host, CMDB y Prometheus SD.',
                  );
                } catch (e) {
                  _showSnack('Error al crear máquina: $e', isError: true);
                }
              },
              icon: const Icon(Icons.check_circle_rounded, size: 16),
              label: const Text(
                'Crear Máquina, Sincronizar CMDB y Monitorizar',
              ),
            ),
          ],
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

  Future<void> _showAddNodeToStackDialog(int stackId) async {
    if (_hosts.isEmpty) return;
    int assetId = _selectedHostId ?? (_hosts.first['id'] as int);
    String roleLayer = 'web_frontend';
    final labelCtrl = TextEditingController(text: 'Frontal Web / Nodo Stack');
    final sshUserCtrl = TextEditingController(text: 'root');
    final sshPortCtrl = TextEditingController(text: '22');

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text('Añadir Host / VM / BBDD al Lienzo del Stack'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: assetId,
                  decoration: const InputDecoration(
                    labelText: 'Host / VM / Frontal / Base de Datos',
                  ),
                  items: _hosts
                      .map(
                        (h) => DropdownMenuItem<int>(
                          value: h['id'] as int,
                          child: Text(
                            '${h['code']} — ${h['name']} (${h['heartbeat_ip']})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setModal(() => assetId = v ?? assetId),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: roleLayer,
                  decoration: const InputDecoration(
                    labelText: 'Columna / Rol en el Stack Tecnológico',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'ingress_vip',
                      child: Text('Columna 1: Entrada / VIP / Firewall / WAF'),
                    ),
                    DropdownMenuItem(
                      value: 'web_frontend',
                      child: Text(
                        'Columna 2: Frontal Web Balanceado (Nginx / Apache)',
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'app_middleware',
                      child: Text(
                        'Columna 3: Lógica de Negocio / App / Docker',
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'database_cache',
                      child: Text('Columna 4: Base de Datos / Caché / AD'),
                    ),
                  ],
                  onChanged: (v) => setModal(() => roleLayer = v ?? roleLayer),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: labelCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Etiqueta Funcional en el Diagrama',
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: sshUserCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Usuario SSH',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: sshPortCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Puerto SSH',
                        ),
                      ),
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
                final pxMap = {
                  'ingress_vip': 0.06,
                  'web_frontend': 0.32,
                  'app_middleware': 0.58,
                  'database_cache': 0.82,
                };
                final res = await widget.api.createTechStackNode({
                  'stack_id': stackId,
                  'asset_id': assetId,
                  'role_layer': roleLayer,
                  'custom_label': labelCtrl.text.trim(),
                  'pos_x': pxMap[roleLayer] ?? 0.32,
                  'pos_y': 0.35,
                  'ssh_user': sshUserCtrl.text.trim(),
                  'ssh_port': int.tryParse(sshPortCtrl.text.trim()) ?? 22,
                });
                setState(() => _overview = res);
                _showSnack('Nodo añadido al lienzo del Stack.');
              },
              child: const Text('Colocar en Lienzo'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreateTechStackEdgeDialog(
    int stackId,
    List<Map<String, dynamic>> nodes,
  ) async {
    int srcNodeId = nodes.first['id'] as int;
    int dstNodeId = nodes[1]['id'] as int;
    final protoCtrl = TextEditingController(
      text: 'HTTPS :443 / Proxy Pass :8080',
    );
    final portCtrl = TextEditingController(text: '443');

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text(
            'Conectar Nodos en el Stack (Dibujar Flecha de Negocio ➔)',
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: srcNodeId,
                  decoration: const InputDecoration(
                    labelText: 'Nodo Origen (Quién inicia la petición)',
                  ),
                  items: nodes.map((n) {
                    final h = Map<String, dynamic>.from(
                      (n['host'] as Map?) ?? {},
                    );
                    return DropdownMenuItem<int>(
                      value: n['id'] as int,
                      child: Text('${h['code']} — ${n['custom_label']}'),
                    );
                  }).toList(),
                  onChanged: (v) => setModal(() => srcNodeId = v ?? srcNodeId),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  initialValue: dstNodeId,
                  decoration: const InputDecoration(
                    labelText: 'Nodo Destino (Quién recibe el tráfico)',
                  ),
                  items: nodes.map((n) {
                    final h = Map<String, dynamic>.from(
                      (n['host'] as Map?) ?? {},
                    );
                    return DropdownMenuItem<int>(
                      value: n['id'] as int,
                      child: Text('${h['code']} — ${n['custom_label']}'),
                    );
                  }).toList(),
                  onChanged: (v) => setModal(() => dstNodeId = v ?? dstNodeId),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: protoCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Protocolo / Flujo de Negocio',
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
                final res = await widget.api.createTechStackEdge({
                  'stack_id': stackId,
                  'source_node_id': srcNodeId,
                  'target_node_id': dstNodeId,
                  'protocol_label': protoCtrl.text.trim(),
                  'port': int.tryParse(portCtrl.text.trim()) ?? 443,
                });
                setState(() => _overview = res);
                _showSnack('Flecha añadida al Stack Tecnológico.');
              },
              child: const Text('Dibujar Flecha ➔'),
            ),
          ],
        ),
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
    final nameCtrl = TextEditingController(
      text: 'Portal HTTPS & Validez Certificado SSL',
    );
    final urlCtrl = TextEditingController(
      text: 'https://portal.empresa.local/health',
    );
    final portCtrl = TextEditingController(text: '443');

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text('Añadir Heartbeat o Chequeo de Servicio'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: assetId,
                  decoration: const InputDecoration(labelText: 'Host / VM'),
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
                    labelText: 'Protocolo / Conector de Chequeo',
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
                      value: 'node_exporter',
                      child: Text('Prometheus Linux Node Exporter (:9100)'),
                    ),
                    DropdownMenuItem(
                      value: 'windows_exporter',
                      child: Text('Prometheus Windows Exporter (:9182)'),
                    ),
                  ],
                  onChanged: (v) =>
                      setModal(() => checkType = v ?? checkType),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nombre del Servicio / Heartbeat',
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
                          labelText: 'IP o URL de Destino',
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
                final res = await widget.api.createNetworkServiceCheck({
                  'asset_id': assetId,
                  'service_name': nameCtrl.text.trim(),
                  'check_type': checkType,
                  'target_ip_or_url': urlCtrl.text.trim(),
                  'port': int.tryParse(portCtrl.text.trim()) ?? 443,
                });
                setState(() => _overview = res);
                _showSnack('Heartbeat registrado y añadido a Prometheus.');
              },
              child: const Text('Guardar y Monitorizar'),
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

  Future<void> _showCreateContactDialog() async {
    final codeCtrl = TextEditingController(text: 'USR-NUEVO-OPS');
    final nameCtrl = TextEditingController(text: '');
    final emailCtrl = TextEditingController(text: '');
    final roleCtrl = TextEditingController(text: 'Ingeniero SRE / Guardia');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Añadir Persona / Contacto de Alarma'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: codeCtrl,
                decoration: const InputDecoration(labelText: 'Código Único'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Nombre Completo'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: emailCtrl,
                decoration: const InputDecoration(
                  labelText: 'Correo Electrónico de Alerta',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: roleCtrl,
                decoration: const InputDecoration(
                  labelText: 'Rol / Departamento',
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
              final res = await widget.api.upsertAlertContact({
                'code': codeCtrl.text.trim(),
                'full_name': nameCtrl.text.trim(),
                'email': emailCtrl.text.trim(),
                'role_title': roleCtrl.text.trim(),
              });
              setState(() => _overview = res);
            },
            child: const Text('Guardar Persona'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCreateContactGroupDialog() async {
    final codeCtrl = TextEditingController(text: 'CG-GUARDIA-24X7');
    final nameCtrl = TextEditingController(text: 'Equipo Guardia 24x7');
    final emailCtrl = TextEditingController(text: 'guardia24x7@empresa.local');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Crear Grupo de Personas'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: codeCtrl,
                decoration: const InputDecoration(labelText: 'Código del Grupo'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Nombre del Grupo'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: emailCtrl,
                decoration: const InputDecoration(
                  labelText: 'Correo de Lista de Distribución',
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
              final res = await widget.api.upsertAlertContactGroup({
                'code': codeCtrl.text.trim(),
                'name': nameCtrl.text.trim(),
                'group_email': emailCtrl.text.trim(),
                'member_contact_ids': _alertContacts
                    .map((c) => c['id'] as int)
                    .toList(),
              });
              setState(() => _overview = res);
            },
            child: const Text('Guardar Grupo'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCreateHostGroupDialog() async {
    final codeCtrl = TextEditingController(text: 'HG-PRODUCCION-CRITICA');
    final nameCtrl = TextEditingController(text: 'Hosts Críticos Producción');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Crear Grupo de Hosts (HostGroup)'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
              final res = await widget.api.upsertHostGroup({
                'code': codeCtrl.text.trim(),
                'name': nameCtrl.text.trim(),
                'member_asset_ids': _selectedHostId != null
                    ? [_selectedHostId]
                    : [],
              });
              setState(() => _overview = res);
            },
            child: const Text('Guardar HostGroup'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCreateRoutingRuleDialog() async {
    if (_hostGroups.isEmpty || _alertContactGroups.isEmpty) return;
    int hgId = _hostGroups.first['id'] as int;
    int cgId = _alertContactGroups.first['id'] as int;
    final nameCtrl = TextEditingController(
      text: 'Regla Personalizada de Aviso Crítico',
    );

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text('Nueva Regla de Enrutamiento de Alarma'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nombre de la Regla',
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  initialValue: hgId,
                  decoration: const InputDecoration(
                    labelText: 'Grupo de Hosts (HostGroup)',
                  ),
                  items: _hostGroups
                      .map(
                        (hg) => DropdownMenuItem<int>(
                          value: hg['id'] as int,
                          child: Text('${hg['name']} (${hg['code']})'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setModal(() => hgId = v ?? hgId),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  initialValue: cgId,
                  decoration: const InputDecoration(
                    labelText: 'Avisar al Grupo de Personas',
                  ),
                  items: _alertContactGroups
                      .map(
                        (cg) => DropdownMenuItem<int>(
                          value: cg['id'] as int,
                          child: Text('${cg['name']} (${cg['group_email']})'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setModal(() => cgId = v ?? cgId),
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
                final res = await widget.api.createNotificationRule({
                  'name': nameCtrl.text.trim(),
                  'scope_type': 'host_group',
                  'host_group_id': hgId,
                  'contact_group_ids': [cgId],
                });
                setState(() => _overview = res);
              },
              child: const Text('Crear Regla'),
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
// CUSTOM PAINTER DE SERIES TEMPORALES DE PROMETHEUS
// =============================================================================

class _PrometheusSeriesChartPainter extends CustomPainter {
  final List<Map<String, dynamic>> points;
  final String keyA;
  final Color colorA;
  final String? keyB;
  final Color? colorB;

  _PrometheusSeriesChartPainter({
    required this.points,
    required this.keyA,
    required this.colorA,
    this.keyB,
    this.colorB,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final gridPaint = Paint()
      ..color = AppTheme.border.withValues(alpha: 0.45)
      ..strokeWidth = 1;

    for (int i = 0; i <= 4; i++) {
      final y = size.height * (i / 4);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    double maxVal = 1.0;
    for (final p in points) {
      final va = (p[keyA] as num?)?.toDouble() ?? 0.0;
      if (va > maxVal) maxVal = va;
      if (keyB != null) {
        final vb = (p[keyB] as num?)?.toDouble() ?? 0.0;
        if (vb > maxVal) maxVal = vb;
      }
    }
    maxVal = math.max(maxVal * 1.15, 10.0);

    _drawSeries(canvas, size, keyA, colorA, maxVal);
    if (keyB != null && colorB != null) {
      _drawSeries(canvas, size, keyB!, colorB!, maxVal);
    }
  }

  void _drawSeries(
    Canvas canvas,
    Size size,
    String key,
    Color color,
    double maxVal,
  ) {
    final path = Path();
    final fillPath = Path();

    for (int i = 0; i < points.length; i++) {
      final v = (points[i][key] as num?)?.toDouble() ?? 0.0;
      final x = (i / (points.length - 1)) * size.width;
      final y = size.height - ((v / maxVal).clamp(0.0, 1.0) * size.height);
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.28),
          color.withValues(alpha: 0.02),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawPath(fillPath, fillPaint);

    final strokePaint = Paint()
      ..color = color
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _PrometheusSeriesChartPainter oldDelegate) =>
      true;
}

class _TechStackEdgesPainter extends CustomPainter {
  final List<Map<String, dynamic>> nodes;
  final List<Map<String, dynamic>> edges;
  final Size canvasSize;

  _TechStackEdgesPainter({
    required this.nodes,
    required this.edges,
    required this.canvasSize,
  });

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

      final sx =
          ((src['pos_x'] as num?)?.toDouble() ?? 0.2).clamp(0.02, 0.84) *
              canvasSize.width +
          232.0;
      final sy =
          ((src['pos_y'] as num?)?.toDouble() ?? 0.3).clamp(0.07, 0.78) *
              canvasSize.height +
          62.0;
      final dx =
          ((dst['pos_x'] as num?)?.toDouble() ?? 0.5).clamp(0.02, 0.84) *
          canvasSize.width;
      final dy =
          ((dst['pos_y'] as num?)?.toDouble() ?? 0.3).clamp(0.07, 0.78) *
              canvasSize.height +
          62.0;

      final isDown = (e['status'] as String?) == 'DOWN';
      final color = isDown ? AppTheme.error : AppTheme.accentCyan;

      final path = Path()..moveTo(sx, sy);
      final ctrlX1 = sx + (dx - sx) * 0.45;
      final ctrlX2 = sx + (dx - sx) * 0.55;
      path.cubicTo(ctrlX1, sy, ctrlX2, dy, dx, dy);

      final paint = Paint()
        ..color = color
        ..strokeWidth = 2.4
        ..style = PaintingStyle.stroke;
      canvas.drawPath(path, paint);

      // Punta de flecha en el destino
      final arrowPath = Path()
        ..moveTo(dx, dy)
        ..lineTo(dx - 9, dy - 5)
        ..lineTo(dx - 9, dy + 5)
        ..close();
      canvas.drawPath(
        arrowPath,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill,
      );

      // Píldora con etiqueta de protocolo en el punto medio
      final midX = (sx + dx) / 2;
      final midY = (sy + dy) / 2 - 10;
      final label = '${e['protocol_label']}';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final bgRect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(midX, midY),
          width: tp.width + 12,
          height: tp.height + 6,
        ),
        const Radius.circular(6),
      );
      canvas.drawRRect(bgRect, Paint()..color = AppTheme.bgSecondary);
      canvas.drawRRect(
        bgRect,
        Paint()
          ..color = color.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      tp.paint(canvas, Offset(midX - tp.width / 2, midY - tp.height / 2));
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

    final path = Path();
    final fillPath = Path();
    for (int i = 0; i < values.length; i++) {
      final x = (i / (values.length - 1)) * size.width;
      final y =
          size.height - ((values[i] / maxV).clamp(0.0, 1.0) * size.height);
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    canvas.drawPath(
      fillPath,
      Paint()..color = color.withValues(alpha: 0.16),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _MiniSparklinePainter oldDelegate) => true;
}

