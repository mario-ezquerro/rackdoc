import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/api_client.dart';

class CmdbView extends StatefulWidget {
  final RackDocApiClient api;
  final bool canEdit;
  final void Function(int rackId, int? deviceId)? onNavigateToRackDevice;
  final VoidCallback? onExportExcel;

  const CmdbView({
    super.key,
    required this.api,
    required this.canEdit,
    this.onNavigateToRackDevice,
    this.onExportExcel,
  });

  @override
  State<CmdbView> createState() => _CmdbViewState();
}

class _CmdbViewState extends State<CmdbView> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _overview;

  // Sub-pestaña activa dentro del módulo CMDB:
  // 'inventory' | 'verifier' | 'subnets_ipam' | 'hypervisor_tree'
  String _activeTab = 'inventory';

  // Filtros de '1. Inventario CMDB & Multi-IP'
  final TextEditingController _searchCtrl = TextEditingController();
  String _classFilter = 'all';
  String _envFilter = 'all';
  bool _onlyMultiIp = false;
  int? _expandedAssetId;
  int? _runningHeartbeatAssetId;

  // Estado de '2. Verificador Manual de IPs Libres y Escáner de Rangos CIDR (ej. 1.1.1.1/24)'
  final TextEditingController _verifyIpCtrl = TextEditingController(
    text: '10.20.20.0/24',
  );
  int? _verifySelectedSubnetId;
  final int _verifyCountLimit = 254;
  bool _verifyingIp = false;
  Map<String, dynamic>? _verificationReport;
  String? _verifyError;
  String _scanResultFilter = 'all';
  final Set<String> _selectedDiscoveredIps = {};
  final Set<String> _dismissedScanIps = {};
  String _bulkImportAssetClass = 'virtual_machine';
  bool _alsoRegisterScannedSubnet = true;
  bool _importingDiscovered = false;

  // Estado de '3. Subredes, VLANs & Mapa Visual IPAM'
  int? _selectedIpamSubnetId;

  static const Map<String, String> _assetClassLabels = {
    'virtual_machine': 'Máquina Virtual (VM)',
    'container_lxc': 'Contenedor / LXC / K8s',
    'physical_server': 'Servidor / Host Físico',
    'cluster_vip': 'Cluster HA / Balanceador VIP',
    'virtual_appliance': 'Appliance Virtual (vApp)',
    'cloud_instance': 'Instancia Cloud / VPS',
    'network_security': 'Electrónica de Red / Firewall',
    'storage_san_nas': 'Almacenamiento SAN / NAS',
    'floor_endpoint': 'Dispositivo de Planta / IoT',
    'other_machine': 'Otro Equipo / Máquina',
  };

  static const Map<String, String> _ipRoleLabels = {
    'mgmt_heartbeat': 'Gestión / Manager (Heartbeat)',
    'ilo_idrac': 'OOB / iDRAC / iLO / IPMI',
    'primary_service': 'Producción / Servicio Principal',
    'secondary_service': 'Servicio Secundario / App',
    'vip_cluster': 'VIP Flotante / Cluster HA',
    'storage': 'Almacenamiento (iSCSI / NFS)',
    'backup': 'Red de Backup / Contingencia',
    'vmotion_replication': 'vMotion / Réplica / Sync',
    'public_wan': 'IP Pública / WAN / DMZ',
    'reserved': 'Reserva IPAM',
  };

  @override
  void initState() {
    super.initState();
    _loadOverview();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _verifyIpCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadOverview({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await widget.api.fetchCmdbOverview();
      if (!mounted) return;
      final subnets = (data['subnets'] as List? ?? []);
      setState(() {
        _overview = data;
        if (subnets.isNotEmpty) {
          final firstSubId = (subnets.first as Map)['id'] as int?;
          _verifySelectedSubnetId ??= firstSubId;
          _selectedIpamSubnetId ??= firstSubId;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _assets {
    final raw = (_overview?['assets'] as List?) ?? [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  List<Map<String, dynamic>> get _subnets {
    final raw = (_overview?['subnets'] as List?) ?? [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  List<Map<String, dynamic>> get _physicalHosts {
    final raw = (_overview?['physical_hosts'] as List?) ?? [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  List<Map<String, dynamic>> get _filteredAssets {
    final q = _searchCtrl.text.trim().toLowerCase();
    return _assets.where((a) {
      if (_classFilter != 'all') {
        final ac = (a['asset_class'] ?? '').toString();
        if (_classFilter == 'vms_only' &&
            ac != 'virtual_machine' &&
            ac != 'virtual_appliance') {
          return false;
        } else if (_classFilter == 'containers_clusters' &&
            ac != 'container_lxc' &&
            ac != 'cluster_vip') {
          return false;
        } else if (_classFilter != 'vms_only' &&
            _classFilter != 'containers_clusters' &&
            ac != _classFilter) {
          return false;
        }
      }
      if (_envFilter != 'all' &&
          (a['environment'] ?? '').toString() != _envFilter) {
        return false;
      }
      if (_onlyMultiIp && ((a['ip_count'] as int? ?? 0) <= 1)) {
        return false;
      }
      if (q.isNotEmpty) {
        final code = (a['code'] ?? '').toString().toLowerCase();
        final name = (a['name'] ?? '').toString().toLowerCase();
        final host = (a['hostname'] ?? '').toString().toLowerCase();
        final fqdn = (a['fqdn'] ?? '').toString().toLowerCase();
        final os = (a['os_or_firmware'] ?? '').toString().toLowerCase();
        final plat = (a['hypervisor_or_platform'] ?? '').toString().toLowerCase();
        final loc = (a['physical_location_label'] ?? '').toString().toLowerCase();
        final ips = ((a['ip_addresses'] as List?) ?? [])
            .map((ip) =>
                '${(ip as Map)['ip_address']} ${ip['fqdn']} ${ip['interface_name']} ${ip['mac_address']}'
                    .toLowerCase())
            .join(' ');
        if (!code.contains(q) &&
            !name.contains(q) &&
            !host.contains(q) &&
            !fqdn.contains(q) &&
            !os.contains(q) &&
            !plat.contains(q) &&
            !loc.contains(q) &&
            !ips.contains(q)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  Future<void> _runManualVerification({
    String? customIp,
    bool onlySuggestFree = false,
  }) async {
    setState(() {
      _verifyingIp = true;
      _verifyError = null;
    });
    try {
      final res = await widget.api.verifyCmdbIp(
        targetIp: customIp ?? _verifyIpCtrl.text.trim(),
        subnetId: _verifySelectedSubnetId,
        countLimit: onlySuggestFree ? 10 : _verifyCountLimit,
        onlySuggestFree: onlySuggestFree,
      );
      if (!mounted) return;
      final rawList = ((res['results'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final autoSelected = <String>{};
      for (final item in rawList) {
        if (item['verdict'] == 'conflict_unregistered') {
          autoSelected.add((item['ip_address'] ?? '').toString());
        }
      }
      setState(() {
        _verificationReport = res;
        _dismissedScanIps.clear();
        _selectedDiscoveredIps
          ..clear()
          ..addAll(autoSelected);
        _scanResultFilter = 'all';
        _verifyingIp = false;
      });
      await _loadOverview(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verifyError = e.toString().replaceFirst('Exception: ', '');
        _verifyingIp = false;
      });
    }
  }

  Future<void> _importSelectedDiscoveredToCmdb(
    List<Map<String, dynamic>> allScanResults,
  ) async {
    final selectedRows = allScanResults
        .where(
          (r) =>
              _selectedDiscoveredIps.contains(
                (r['ip_address'] ?? '').toString(),
              ) &&
              r['documented_in_cmdb'] != true,
        )
        .toList();
    final String? scannedCidr =
        _verificationReport?['scanned_cidr'] as String?;
    final bool cidrAlreadyInCmdb =
        _verificationReport?['cidr_already_in_cmdb'] == true;
    final bool shouldCreateSubnet =
        _alsoRegisterScannedSubnet &&
        scannedCidr != null &&
        scannedCidr.isNotEmpty &&
        !cidrAlreadyInCmdb;

    if (selectedRows.isEmpty && !shouldCreateSubnet) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Marca al menos una IP no registrada en la CMDB (o la casilla de crear subred) para añadirla.',
          ),
        ),
      );
      return;
    }

    setState(() => _importingDiscovered = true);
    try {
      final itemsPayload = selectedRows.map((r) {
        final probes = Map<String, dynamic>.from((r['probes'] as Map?) ?? {});
        final dns = Map<String, dynamic>.from((probes['dns_ptr'] as Map?) ?? {});
        final arp = Map<String, dynamic>.from((probes['arp'] as Map?) ?? {});
        final tcp = Map<String, dynamic>.from((probes['tcp'] as Map?) ?? {});
        final String ptr = (dns['ptr_hostname'] ?? '').toString();
        final String mac = (arp['mac_address'] ?? '').toString();
        final List<int> openPorts = ((tcp['open_ports'] as List?) ?? [])
            .map((e) => (e as num).toInt())
            .toList();
        return {
          'ip_address': (r['ip_address'] ?? '').toString(),
          'hostname': ptr.isNotEmpty ? ptr.split('.').first : '',
          'fqdn': ptr,
          'mac_address': mac,
          'asset_class': _bulkImportAssetClass,
          'environment': 'production',
          'open_ports': openPorts,
          'notes': 'Añadido desde escaneo de rango (${r['summary'] ?? ''})',
        };
      }).toList();

      final updatedOverview = await widget.api.importDiscoveredCmdbHosts(
        registerSubnetCidr: shouldCreateSubnet ? scannedCidr : null,
        subnetName: shouldCreateSubnet ? 'Red $scannedCidr' : null,
        items: itemsPayload,
      );
      if (!mounted) return;
      final int importedCount =
          (updatedOverview['imported_assets_count'] as int?) ??
              itemsPayload.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF15803D),
          content: Text(
            'Se han añadido $importedCount máquina(s)/IP(s) a la CMDB${shouldCreateSubnet ? ' y la subred $scannedCidr' : ''}.',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      );
      setState(() {
        _overview = updatedOverview;
        _importingDiscovered = false;
      });
      await _runManualVerification(onlySuggestFree: false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _importingDiscovered = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error importando en CMDB: $e')),
      );
    }
  }

  Future<void> _triggerAssetHeartbeat(Map<String, dynamic> asset) async {
    final id = asset['id'] as int;
    setState(() => _runningHeartbeatAssetId = id);
    try {
      final res = await widget.api.runCmdbAssetHeartbeat(id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: res['status'] == 'online'
              ? const Color(0xFF15803D)
              : const Color(0xFFB91C1C),
          content: Text(
            '[${asset['code']}] Heartbeat (${res['target']}): ${res['detail']}',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
          ),
        ),
      );
      await _loadOverview(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error en Heartbeat: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _runningHeartbeatAssetId = null);
      }
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
            const Icon(Icons.error_outline, size: 42, color: Colors.redAccent),
            const SizedBox(height: 10),
            Text('Error cargando CMDB: $_error'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _loadOverview,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    final summary = Map<String, dynamic>.from(
      (_overview?['summary'] as Map?) ?? {},
    );

    return Container(
      color: const Color(0xFFF8FAFC),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTopBannerAndKpis(summary),
          _buildNavigationTabs(),
          Expanded(
            child: _buildActiveTabBody(),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBannerAndKpis(Map<String, dynamic> summary) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1E3A8A), Color(0xFF0284C7)],
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.hub_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CMDB & Control de Direccionamiento Multi-IP (Físicos, VMs, Clusters & Cloud)',
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Gestión unificada de servidores físicos, máquinas virtuales, contenedores y VIPs con separación de IP de Gestión (Heartbeat/Manager) e IPs de Operación/Servicio + Verificador Manual Anti-Conflictos.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF475569),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () {
                  setState(() => _activeTab = 'verifier');
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF0369A1),
                  side: const BorderSide(color: Color(0xFF38BDF8), width: 1.4),
                  backgroundColor: const Color(0xFFF0F9FF),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                icon: const Icon(Icons.radar_rounded, size: 17),
                label: const Text(
                  'Verificar IP Libre (Ping + TCP + ARP)',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 8),
              if (widget.onExportExcel != null)
                OutlinedButton.icon(
                  onPressed: widget.onExportExcel,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF15803D),
                    side: const BorderSide(color: Color(0xFF86EFAC)),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  icon: const Icon(Icons.table_view_rounded, size: 17),
                  label: const Text(
                    'Exportar CMDB (.xlsx)',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                  ),
                ),
              if (widget.canEdit) ...[
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => _openAssetEditorDialog(),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1E3A8A),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                  ),
                  icon: const Icon(Icons.add_circle_outline_rounded, size: 17),
                  label: const Text(
                    'Nueva Máquina / VM / CI',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _buildKpiChip(
                icon: Icons.dns_rounded,
                label: 'Total Máquinas (CIs)',
                value: '${summary['total_assets'] ?? 0}',
                color: const Color(0xFF1E3A8A),
              ),
              _buildKpiChip(
                icon: Icons.cloud_queue_rounded,
                label: 'Máquinas Virtuales (VMs)',
                value: '${summary['virtual_machines_count'] ?? 0}',
                color: const Color(0xFF7C3AED),
              ),
              _buildKpiChip(
                icon: Icons.widgets_outlined,
                label: 'Contenedores, Clusters & Cloud',
                value: '${summary['containers_and_clusters_count'] ?? 0}',
                color: const Color(0xFF0284C7),
              ),
              _buildKpiChip(
                icon: Icons.storage_rounded,
                label: 'Equipos Físicos (Rack/Planta)',
                value: '${summary['physical_assets_count'] ?? 0}',
                color: const Color(0xFF0F766E),
              ),
              _buildKpiChip(
                icon: Icons.account_tree_rounded,
                label: 'Hosts con Múltiples IPs (>1 IP)',
                value: '${summary['multi_ip_assets_count'] ?? 0}',
                color: const Color(0xFFD97706),
              ),
              _buildKpiChip(
                icon: Icons.lan_rounded,
                label: 'IPs Documentadas / Subredes',
                value:
                    '${summary['total_ip_addresses'] ?? 0} IPs en ${summary['total_subnets'] ?? 0} VLANs',
                color: const Color(0xFF15803D),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildKpiChip({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF475569),
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  color: color,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationTabs() {
    final tabs = [
      (
        'inventory',
        Icons.view_list_rounded,
        '1. Inventario CMDB & Multi-IP (Físicos, VMs, Clusters, Cloud)',
      ),
      (
        'verifier',
        Icons.radar_rounded,
        '2. Verificador Manual de IPs Libres (Control Anti-Conflictos)',
      ),
      (
        'subnets_ipam',
        Icons.grid_on_rounded,
        '3. Subredes, VLANs & Mapa IPAM (.1 a .254)',
      ),
      (
        'hypervisor_tree',
        Icons.account_tree_outlined,
        '4. Topología Hipervisores Físicos ➔ VMs & Servicios',
      ),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFFF1F5F9),
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: tabs.map((t) {
            final isSelected = _activeTab == t.$1;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _activeTab = t.$1),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFF0F172A) : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected
                          ? const Color(0xFF0F172A)
                          : const Color(0xFFCBD5E1),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        t.$2,
                        size: 16,
                        color: isSelected
                            ? const Color(0xFF38BDF8)
                            : const Color(0xFF475569),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        t.$3,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              isSelected ? FontWeight.w800 : FontWeight.w600,
                          color: isSelected
                              ? Colors.white
                              : const Color(0xFF334155),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildActiveTabBody() {
    switch (_activeTab) {
      case 'verifier':
        return _buildManualIpVerifierTab();
      case 'subnets_ipam':
        return _buildSubnetsAndIpamGridTab();
      case 'hypervisor_tree':
        return _buildHypervisorTreeTab();
      case 'inventory':
      default:
        return _buildInventoryTab();
    }
  }

  // ===========================================================================
  // PESTAÑA 1: INVENTARIO CMDB & MULTI-IP (FÍSICOS, VMs, CONTENEDORES, CLUSTERS)
  // ===========================================================================
  Widget _buildInventoryTab() {
    final items = _filteredAssets;
    return Column(
      children: [
        // Barra de búsqueda y filtros por tipo de máquina
        Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: SizedBox(
                      height: 38,
                      child: TextField(
                        controller: _searchCtrl,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(fontSize: 12.5),
                        decoration: InputDecoration(
                          hintText:
                              'Buscar por Hostname, FQDN, cualquier IP (Gestión, Servicio, VIP, iDRAC), MAC, SO o Hipervisor...',
                          prefixIcon: const Icon(Icons.search, size: 18),
                          suffixIcon: _searchCtrl.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 16),
                                  onPressed: () {
                                    _searchCtrl.clear();
                                    setState(() {});
                                  },
                                )
                              : null,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilterChip(
                    selected: _onlyMultiIp,
                    label: const Text(
                      'Solo Hosts Multi-IP (>1 IP)',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onSelected: (v) => setState(() => _onlyMultiIp = v),
                  ),
                  const SizedBox(width: 10),
                  DropdownButtonHideUnderline(
                    child: Container(
                      height: 38,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: DropdownButton<String>(
                        value: _envFilter,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF0F172A),
                          fontWeight: FontWeight.w700,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text('Entorno: Todos'),
                          ),
                          DropdownMenuItem(
                            value: 'production',
                            child: Text('Producción (PROD)'),
                          ),
                          DropdownMenuItem(
                            value: 'preprod',
                            child: Text('Preproducción (PRE)'),
                          ),
                          DropdownMenuItem(
                            value: 'dev',
                            child: Text('Desarrollo (DEV)'),
                          ),
                          DropdownMenuItem(
                            value: 'mgmt',
                            child: Text('Gestión (MGMT)'),
                          ),
                          DropdownMenuItem(
                            value: 'dr',
                            child: Text('Contingencia (DR)'),
                          ),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _envFilter = v);
                        },
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildClassFilterPill('all', 'Todos (${_assets.length})'),
                    _buildClassFilterPill(
                      'vms_only',
                      'Máquinas Virtuales (VMs)',
                    ),
                    _buildClassFilterPill(
                      'containers_clusters',
                      'Contenedores & Clusters VIP',
                    ),
                    _buildClassFilterPill(
                      'physical_server',
                      'Servidores Físicos (Rack)',
                    ),
                    _buildClassFilterPill(
                      'cloud_instance',
                      'Cloud / VPS Externos',
                    ),
                    _buildClassFilterPill(
                      'network_security',
                      'Switches, Routers & Firewalls',
                    ),
                    _buildClassFilterPill(
                      'storage_san_nas',
                      'Cabinas SAN / NAS',
                    ),
                    _buildClassFilterPill(
                      'floor_endpoint',
                      'Equipos de Planta',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const Center(
                  child: Text(
                    'No hay máquinas o activos que coincidan con el filtro actual.',
                    style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: items.length,
                  itemBuilder: (ctx, idx) => _buildAssetCard(items[idx]),
                ),
        ),
      ],
    );
  }

  Widget _buildClassFilterPill(String key, String label) {
    final active = _classFilter == key;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        selected: active,
        label: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            color: active ? Colors.white : const Color(0xFF334155),
          ),
        ),
        selectedColor: const Color(0xFF1E3A8A),
        backgroundColor: const Color(0xFFF1F5F9),
        onSelected: (_) => setState(() => _classFilter = key),
      ),
    );
  }

  Color _classBadgeColor(String assetClass) {
    switch (assetClass) {
      case 'virtual_machine':
      case 'virtual_appliance':
        return const Color(0xFF7C3AED);
      case 'container_lxc':
        return const Color(0xFF0284C7);
      case 'cluster_vip':
        return const Color(0xFFD97706);
      case 'cloud_instance':
        return const Color(0xFF4F46E5);
      case 'physical_server':
        return const Color(0xFF0F766E);
      case 'network_security':
        return const Color(0xFF1E3A8A);
      case 'storage_san_nas':
        return const Color(0xFF9333EA);
      default:
        return const Color(0xFF475569);
    }
  }

  Color _ipRoleColor(String role) {
    switch (role) {
      case 'mgmt_heartbeat':
        return const Color(0xFF0284C7);
      case 'ilo_idrac':
        return const Color(0xFF7C3AED);
      case 'primary_service':
        return const Color(0xFF15803D);
      case 'secondary_service':
        return const Color(0xFF0D9488);
      case 'vip_cluster':
        return const Color(0xFFD97706);
      case 'storage':
      case 'backup':
      case 'vmotion_replication':
        return const Color(0xFF4F46E5);
      case 'public_wan':
        return const Color(0xFFBE123C);
      default:
        return const Color(0xFF475569);
    }
  }

  Widget _buildAssetCard(Map<String, dynamic> asset) {
    final int assetId = asset['id'] as int;
    final String code = (asset['code'] ?? '').toString();
    final String name = (asset['name'] ?? '').toString();
    final String hostname = (asset['hostname'] ?? '').toString();
    final String fqdn = (asset['fqdn'] ?? '').toString();
    final String assetClass = (asset['asset_class'] ?? '').toString();
    final String classLabel =
        (asset['asset_class_label'] ?? _assetClassLabels[assetClass] ?? assetClass)
            .toString();
    final String syncSource = (asset['sync_source'] ?? 'cmdb').toString();
    final String status = (asset['status'] ?? 'unmonitored').toString();
    final double? pingMs = (asset['last_ping_ms'] as num?)?.toDouble();
    final List<Map<String, dynamic>> ips = ((asset['ip_addresses'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final bool isExpanded = _expandedAssetId == assetId;
    final Color badgeColor = _classBadgeColor(assetClass);

    final int cores = (asset['cpu_cores'] as int?) ?? 0;
    final double ramGb = (asset['ram_gb'] as num?)?.toDouble() ?? 0.0;
    final double storageGb = (asset['storage_gb'] as num?)?.toDouble() ?? 0.0;
    final String os = (asset['os_or_firmware'] ?? '').toString();
    final String locLabel = (asset['physical_location_label'] ?? '').toString();
    final int? rackId = asset['rack_id'] as int?;
    final int? rackDevId =
        (asset['rack_device_id'] as int?) ?? (asset['host_rack_device_id'] as int?);

    Color statusColor = const Color(0xFF64748B);
    String statusText = 'SIN MONITORIZAR';
    if (status == 'online') {
      statusColor = const Color(0xFF16A34A);
      statusText =
          'ONLINE${pingMs != null ? ' (${pingMs.toStringAsFixed(1)} ms)' : ''}';
    } else if (status == 'offline') {
      statusColor = const Color(0xFFDC2626);
      statusText = 'CAÍDO / OFFLINE';
    } else if (status == 'warning') {
      statusColor = const Color(0xFFD97706);
      statusText = 'WARNING';
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: isExpanded
              ? const Color(0xFF38BDF8)
              : const Color(0xFFE2E8F0),
          width: isExpanded ? 1.6 : 1.0,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cabecera del activo
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Badge Clase (VM, Servidor Físico, Cluster, Contenedor, Cloud)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: badgeColor.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Text(
                    classLabel.toUpperCase(),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      color: badgeColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: syncSource == 'cmdb'
                        ? const Color(0xFFF3E8FF)
                        : const Color(0xFFE0F2FE),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    syncSource == 'cmdb'
                        ? 'NATIVO CMDB (Virtual / Lógico / Cloud)'
                        : syncSource == 'rack_device'
                            ? 'SINCRONIZADO RACK 42U'
                            : 'SINCRONIZADO PLANTA',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      color: syncSource == 'cmdb'
                          ? const Color(0xFF6B21A8)
                          : const Color(0xFF0369A1),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            code,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              name,
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1E293B),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          if (hostname.isNotEmpty)
                            Text(
                              'Hostname: $hostname',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF475569),
                              ),
                            ),
                          if (fqdn.isNotEmpty)
                            Text(
                              'FQDN: $fqdn',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF0369A1),
                              ),
                            ),
                          if (os.isNotEmpty)
                            Text(
                              'SO/FW: $os',
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFF475569),
                              ),
                            ),
                          if (cores > 0 || ramGb > 0)
                            Text(
                              'Recursos: ${cores}vCPU • ${ramGb.toStringAsFixed(0)}GB RAM${storageGb > 0 ? ' • ${storageGb.toStringAsFixed(0)}GB Disco' : ''}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF334155),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                // Indicador de estado Heartbeat y botón de chequeo rápido
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: statusColor.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        statusText,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w900,
                          color: statusColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'Comprobar Heartbeat en su IP de Gestión ahora',
                  onPressed: _runningHeartbeatAssetId == assetId
                      ? null
                      : () => _triggerAssetHeartbeat(asset),
                  icon: _runningHeartbeatAssetId == assetId
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(
                          Icons.network_ping_rounded,
                          size: 18,
                          color: Color(0xFF0284C7),
                        ),
                ),
                if (rackId != null && widget.onNavigateToRackDevice != null)
                  TextButton.icon(
                    onPressed: () =>
                        widget.onNavigateToRackDevice!(rackId, rackDevId),
                    icon: const Icon(Icons.developer_board_rounded, size: 15),
                    label: Text(
                      locLabel,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Text(
                      locLabel,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ),
                if (widget.canEdit) ...[
                  IconButton(
                    tooltip: 'Añadir otra IP a esta máquina',
                    onPressed: () => _openAddSingleIpDialog(asset),
                    icon: const Icon(
                      Icons.add_link_rounded,
                      size: 19,
                      color: Color(0xFF15803D),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Editar máquina y sus múltiples IPs',
                    onPressed: () => _openAssetEditorDialog(existing: asset),
                    icon: const Icon(
                      Icons.edit_outlined,
                      size: 18,
                      color: Color(0xFF1E3A8A),
                    ),
                  ),
                  if (syncSource == 'cmdb')
                    IconButton(
                      tooltip: 'Eliminar máquina de la CMDB',
                      onPressed: () => _confirmDeleteAsset(asset),
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        size: 18,
                        color: Color(0xFFDC2626),
                      ),
                    ),
                ],
                IconButton(
                  tooltip: isExpanded ? 'Contraer detalle' : 'Ver detalle de IPs',
                  onPressed: () => setState(
                    () => _expandedAssetId = isExpanded ? null : assetId,
                  ),
                  icon: Icon(
                    isExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Tira visual con todas las IPs de la máquina (diferenciando Gestión/Heartbeat de Servicio/VIP/Backup/iDRAC)
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                ...ips.map((ip) => _buildIpBadgePill(asset, ip)),
                if (widget.canEdit)
                  ActionChip(
                    avatar: const Icon(
                      Icons.add_rounded,
                      size: 15,
                      color: Color(0xFF1E3A8A),
                    ),
                    label: const Text(
                      'Añadir IP (Servicio / VIP / Backup)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1E3A8A),
                      ),
                    ),
                    backgroundColor: const Color(0xFFEFF6FF),
                    side: const BorderSide(color: Color(0xFFBFDBFE)),
                    onPressed: () => _openAddSingleIpDialog(asset),
                  ),
              ],
            ),
            if (isExpanded) ...[
              const Divider(height: 20),
              _buildExpandedIpTableForAsset(asset, ips),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildIpBadgePill(
    Map<String, dynamic> asset,
    Map<String, dynamic> ip,
  ) {
    final String addr = (ip['ip_address'] ?? '').toString();
    final String role = (ip['ip_role'] ?? 'primary_service').toString();
    final String iface = (ip['interface_name'] ?? 'eth0').toString();
    final bool isHb = ip['is_heartbeat_ip'] == true;
    final int? vlan = ip['vlan_id'] as int?;
    final String ipFqdn = (ip['fqdn'] ?? '').toString();
    final Color c = _ipRoleColor(role);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        _verifyIpCtrl.text = addr;
        setState(() => _activeTab = 'verifier');
        _runManualVerification(customIp: addr);
      },
      child: Tooltip(
        message:
            'Clic para verificar IP $addr con Ping + TCP + ARP + DNS\nInterfaz: $iface${ipFqdn.isNotEmpty ? ' • DNS: $ipFqdn' : ''}',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isHb ? c : c.withValues(alpha: 0.35),
              width: isHb ? 1.5 : 1.0,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isHb ? Icons.monitor_heart_rounded : Icons.lan_outlined,
                size: 14,
                color: c,
              ),
              const SizedBox(width: 6),
              Text(
                addr,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: c,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: c.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  isHb
                      ? 'HEARTBEAT / MGMT'
                      : (_ipRoleLabels[role] ?? role).toUpperCase(),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    color: c,
                  ),
                ),
              ),
              if (vlan != null) ...[
                const SizedBox(width: 5),
                Text(
                  'VLAN $vlan',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF475569),
                  ),
                ),
              ],
              const SizedBox(width: 5),
              Text(
                '($iface)',
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFF64748B),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedIpTableForAsset(
    Map<String, dynamic> asset,
    List<Map<String, dynamic>> ips,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.settings_ethernet_rounded,
              size: 16,
              color: Color(0xFF1E3A8A),
            ),
            const SizedBox(width: 6),
            Text(
              'Desglose de Interfaces de Red e IPs de ${asset['code']} (${ips.length} IPs configuradas)',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F172A),
              ),
            ),
            const Spacer(),
            Text(
              'Propietario: ${asset['owner_team'] ?? '-'} • Resp: ${asset['responsible_person'] ?? '-'}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
            ),
          ],
        ),
        if ((asset['notes'] ?? '').toString().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'Notas: ${asset['notes']}',
            style: const TextStyle(
              fontSize: 11.5,
              fontStyle: FontStyle.italic,
              color: Color(0xFF475569),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Table(
          border: TableBorder.all(color: const Color(0xFFE2E8F0)),
          columnWidths: const {
            0: FlexColumnWidth(1.4),
            1: FlexColumnWidth(1.2),
            2: FlexColumnWidth(1.6),
            3: FlexColumnWidth(0.9),
            4: FlexColumnWidth(1.6),
            5: FlexColumnWidth(1.2),
            6: FlexColumnWidth(1.8),
            7: IntrinsicColumnWidth(),
          },
          children: [
            const TableRow(
              decoration: BoxDecoration(color: Color(0xFFF1F5F9)),
              children: [
                _TableHeaderCell('Dirección IP'),
                _TableHeaderCell('Interfaz'),
                _TableHeaderCell('Función / Rol de la IP'),
                _TableHeaderCell('VLAN'),
                _TableHeaderCell('FQDN / DNS Asociado'),
                _TableHeaderCell('MAC Address'),
                _TableHeaderCell('Notas / Última Verificación'),
                _TableHeaderCell('Acciones'),
              ],
            ),
            ...ips.map((ip) {
              final ipId = ip['id'] as int?;
              final addr = (ip['ip_address'] ?? '').toString();
              final isHb = ip['is_heartbeat_ip'] == true;
              return TableRow(
                children: [
                  _TableBodyCell(
                    addr,
                    mono: true,
                    bold: true,
                  ),
                  _TableBodyCell((ip['interface_name'] ?? '').toString()),
                  _TableBodyCell(
                    '${ip['ip_role_label'] ?? ip['ip_role']}${isHb ? ' ★ [HEARTBEAT]' : ''}',
                    bold: isHb,
                  ),
                  _TableBodyCell('${ip['vlan_id'] ?? '-'}'),
                  _TableBodyCell((ip['fqdn'] ?? '-').toString()),
                  _TableBodyCell(
                    (ip['mac_address'] ?? '-').toString(),
                    mono: true,
                  ),
                  _TableBodyCell(
                    (ip['notes'] ?? ip['last_verification_detail'] ?? '')
                        .toString(),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Copiar IP $addr',
                          icon: const Icon(Icons.copy, size: 15),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: addr));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('IP $addr copiada al portapapeles'),
                              ),
                            );
                          },
                        ),
                        IconButton(
                          tooltip: 'Sondear esta IP en el Verificador Manual',
                          icon: const Icon(
                            Icons.radar_rounded,
                            size: 16,
                            color: Color(0xFF0284C7),
                          ),
                          onPressed: () {
                            _verifyIpCtrl.text = addr;
                            setState(() => _activeTab = 'verifier');
                            _runManualVerification(customIp: addr);
                          },
                        ),
                        if (widget.canEdit && ipId != null && ips.length > 1)
                          IconButton(
                            tooltip: 'Liberar / Quitar esta IP secundaria',
                            icon: const Icon(
                              Icons.remove_circle_outline,
                              size: 16,
                              color: Colors.redAccent,
                            ),
                            onPressed: () async {
                              await widget.api.deleteCmdbIp(ipId);
                              await _loadOverview(silent: true);
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              );
            }),
          ],
        ),
      ],
    );
  }

  // ===========================================================================
  // PESTAÑA 2: VERIFICADOR MANUAL DE IPs Y ESCÁNER DE RANGOS CIDR (ej. 1.1.1.1/24)
  // ===========================================================================
  Widget _buildManualIpVerifierTab() {
    final allResults = ((_verificationReport?['results'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((r) => !_dismissedScanIps.contains((r['ip_address'] ?? '').toString()))
        .toList();

    final int conflictCount = allResults
        .where((r) => r['verdict'] == 'conflict_unregistered')
        .length;
    final int freeCount = allResults
        .where((r) => r['verdict'] == 'free_confirmed')
        .length;
    final int activeInCmdbCount = allResults
        .where((r) => r['verdict'] == 'active_in_network')
        .length;
    final int noResponseCount = allResults
        .where((r) => r['verdict'] == 'no_response')
        .length;

    final filteredResults = allResults.where((r) {
      if (_scanResultFilter == 'all') return true;
      return (r['verdict'] ?? '').toString() == _scanResultFilter;
    }).toList();

    final String? suggestedFree =
        _verificationReport?['suggested_free_ip'] as String?;
    final String? scannedCidr =
        _verificationReport?['scanned_cidr'] as String?;
    final bool cidrAlreadyInCmdb =
        _verificationReport?['cidr_already_in_cmdb'] == true;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Panel de control manual
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFCBD5E1)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.verified_user_rounded,
                      color: Color(0xFF0284C7),
                      size: 22,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Escáner y Verificador Manual de IPs, Rangos y Redes CIDR (ej. 1.1.1.1/24) con Incorporación Selectiva a la CMDB',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Introduce una IP concreta (10.20.20.45), un rango (10.20.20.1-50) o una red CIDR completa (ej. 1.1.1.1/24 o 10.20.20.0/24). '
                  'El sistema analizará en paralelo todo el rango con 4 sondas reales (Ping ICMP + Puertos TCP + Caché ARP MAC + DNS PTR) '
                  'y te permitirá decidir qué equipos o IPs encontradas quieres añadir a la CMDB y cuáles descartar.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF475569),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 360,
                      child: TextField(
                        controller: _verifyIpCtrl,
                        onSubmitted: (_) =>
                            _runManualVerification(onlySuggestFree: false),
                        style: const TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w800,
                        ),
                        decoration: InputDecoration(
                          labelText:
                              'IP, Rango o Red CIDR (ej. 1.1.1.1/24, 10.20.20.0/24 o 10.20.20.1-50)',
                          prefixIcon: const Icon(Icons.radar_rounded, size: 18),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          isDense: true,
                        ),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _verifyingIp
                          ? null
                          : () => _runManualVerification(onlySuggestFree: false),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF0F172A),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                      icon: _verifyingIp
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.play_arrow_rounded, size: 18),
                      label: Text(
                        _verifyingIp
                            ? 'Analizando Rango en Red...'
                            : 'Analizar IP / Rango CIDR Ahora',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      height: 36,
                      width: 1,
                      color: const Color(0xFFE2E8F0),
                    ),
                    const SizedBox(width: 8),
                    DropdownButtonHideUnderline(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFCBD5E1)),
                        ),
                        child: DropdownButton<int>(
                          value: _verifySelectedSubnetId,
                          hint: const Text('Seleccionar Subred VLAN'),
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A),
                          ),
                          items: _subnets.map((s) {
                            return DropdownMenuItem<int>(
                              value: s['id'] as int,
                              child: Text('${s['cidr']} — ${s['name']}'),
                            );
                          }).toList(),
                          onChanged: (v) =>
                              setState(() => _verifySelectedSubnetId = v),
                        ),
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _verifyingIp
                          ? null
                          : () => _runManualVerification(onlySuggestFree: true),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFDCFCE7),
                        foregroundColor: const Color(0xFF166534),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                      icon: const Icon(Icons.auto_fix_high_rounded, size: 17),
                      label: const Text(
                        'Sugerir Próximas IPs Libres en Subred',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_verifyError != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFECACA)),
                    ),
                    child: Text(
                      'Error: $_verifyError',
                      style: const TextStyle(
                        color: Color(0xFFB91C1C),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
                if (suggestedFree != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0FDF4),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF86EFAC)),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle_rounded,
                          color: Color(0xFF15803D),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Primera IP Libre Confirmada en el análisis: $suggestedFree (0 respuestas en Ping, TCP, ARP y DNS + Libre en CMDB)',
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF14532D),
                              fontSize: 13,
                            ),
                          ),
                        ),
                        if (widget.canEdit) ...[
                          FilledButton.icon(
                            onPressed: () =>
                                _openAssignVerifiedIpToExistingAssetDialog(
                              suggestedFree,
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF15803D),
                            ),
                            icon: const Icon(Icons.add_link_rounded, size: 16),
                            label: const Text('Asignar a Host Existente'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () => _openAssetEditorDialog(
                              prefilledIp: suggestedFree,
                            ),
                            icon: const Icon(Icons.add_box_outlined, size: 16),
                            label: const Text('Crear Nueva VM/Host con esta IP'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                // Barra de Filtros e Incorporación Selectiva a la CMDB tras escanear un rango
                if (allResults.isNotEmpty) ...[
                  const Divider(height: 24),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text(
                        'Filtrar resultados del rango:',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      _buildScanFilterChip(
                        'all',
                        'Todos (${allResults.length})',
                        const Color(0xFF0F172A),
                      ),
                      _buildScanFilterChip(
                        'conflict_unregistered',
                        'Detectados en Red NO en CMDB ($conflictCount)',
                        const Color(0xFFB91C1C),
                      ),
                      _buildScanFilterChip(
                        'free_confirmed',
                        'IPs Libres Confirmadas ($freeCount)',
                        const Color(0xFF15803D),
                      ),
                      _buildScanFilterChip(
                        'active_in_network',
                        'Ya en CMDB y Activos ($activeInCmdbCount)',
                        const Color(0xFF1D4ED8),
                      ),
                      _buildScanFilterChip(
                        'no_response',
                        'En CMDB Sin Respuesta ($noResponseCount)',
                        const Color(0xFFB45309),
                      ),
                    ],
                  ),
                  if (widget.canEdit) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                      ),
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Icon(
                            Icons.playlist_add_check_rounded,
                            color: Color(0xFF1E3A8A),
                          ),
                          Text(
                            'Seleccionados para añadir a CMDB: ${_selectedDiscoveredIps.length}',
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          OutlinedButton(
                            onPressed: () {
                              setState(() {
                                _selectedDiscoveredIps.clear();
                                for (final r in allResults) {
                                  if (r['verdict'] == 'conflict_unregistered') {
                                    _selectedDiscoveredIps.add(
                                      (r['ip_address'] ?? '').toString(),
                                    );
                                  }
                                }
                              });
                            },
                            child: Text(
                              'Marcar Detectados en Red ($conflictCount)',
                              style: const TextStyle(fontSize: 11.5),
                            ),
                          ),
                          OutlinedButton(
                            onPressed: () => setState(
                              () => _selectedDiscoveredIps.clear(),
                            ),
                            child: const Text(
                              'Desmarcar Todos',
                              style: TextStyle(fontSize: 11.5),
                            ),
                          ),
                          DropdownButtonHideUnderline(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFFCBD5E1),
                                ),
                              ),
                              child: DropdownButton<String>(
                                value: _bulkImportAssetClass,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF0F172A),
                                ),
                                items: _assetClassLabels.entries.map((e) {
                                  return DropdownMenuItem<String>(
                                    value: e.key,
                                    child: Text('Crear como: ${e.value}'),
                                  );
                                }).toList(),
                                onChanged: (v) {
                                  if (v != null) {
                                    setState(() => _bulkImportAssetClass = v);
                                  }
                                },
                              ),
                            ),
                          ),
                          if (scannedCidr != null &&
                              scannedCidr.isNotEmpty &&
                              !cidrAlreadyInCmdb)
                            FilterChip(
                              selected: _alsoRegisterScannedSubnet,
                              label: Text(
                                'Registrar también subred $scannedCidr en IPAM',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              onSelected: (v) => setState(
                                () => _alsoRegisterScannedSubnet = v,
                              ),
                            ),
                          FilledButton.icon(
                            onPressed: _importingDiscovered
                                ? null
                                : () =>
                                    _importSelectedDiscoveredToCmdb(allResults),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF1E3A8A),
                            ),
                            icon: _importingDiscovered
                                ? const SizedBox(
                                    width: 15,
                                    height: 15,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.library_add_check_rounded,
                                    size: 16,
                                  ),
                            label: Text(
                              'Añadir Seleccionados (${_selectedDiscoveredIps.length}) a la CMDB',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (filteredResults.isEmpty && !_verifyingIp)
            Container(
              padding: const EdgeInsets.all(32),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: const Column(
                children: [
                  Icon(
                    Icons.network_check_rounded,
                    size: 46,
                    color: Color(0xFF94A3B8),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Introduce una IP, rango o red CIDR (ej. 1.1.1.1/24 o 10.20.20.0/24) y pulsa "Analizar IP / Rango CIDR Ahora".',
                    style: TextStyle(
                      fontSize: 13,
                      color: Color(0xFF64748B),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            )
          else
            ...filteredResults.map(_buildSingleVerificationResultCard),
        ],
      ),
    );
  }

  Widget _buildScanFilterChip(String key, String label, Color color) {
    final active = _scanResultFilter == key;
    return ChoiceChip(
      selected: active,
      selectedColor: color,
      backgroundColor: Colors.white,
      label: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: active ? FontWeight.w900 : FontWeight.w700,
          color: active ? Colors.white : color,
        ),
      ),
      onSelected: (_) => setState(() => _scanResultFilter = key),
    );
  }

  Widget _buildSingleVerificationResultCard(Map<String, dynamic> r) {
    final String ip = (r['ip_address'] ?? '').toString();
    final String verdict = (r['verdict'] ?? '').toString();
    final String verdictLabel = (r['verdict_label'] ?? '').toString();
    final String recommendation = (r['recommendation'] ?? '').toString();
    final bool documentedInCmdb = r['documented_in_cmdb'] == true;
    final bool isSelectedForImport = _selectedDiscoveredIps.contains(ip);
    final Map<String, dynamic> probes = Map<String, dynamic>.from(
      (r['probes'] as Map?) ?? {},
    );
    final Map<String, dynamic> icmp = Map<String, dynamic>.from(
      (probes['icmp'] as Map?) ?? {},
    );
    final Map<String, dynamic> tcp = Map<String, dynamic>.from(
      (probes['tcp'] as Map?) ?? {},
    );
    final Map<String, dynamic> arp = Map<String, dynamic>.from(
      (probes['arp'] as Map?) ?? {},
    );
    final Map<String, dynamic> dns = Map<String, dynamic>.from(
      (probes['dns_ptr'] as Map?) ?? {},
    );
    final List<Map<String, dynamic>> owners =
        ((r['cmdb_owners'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();

    Color borderCol = const Color(0xFF86EFAC);
    Color headerBg = const Color(0xFFF0FDF4);
    Color badgeCol = const Color(0xFF15803D);
    IconData vIcon = Icons.check_circle_rounded;

    if (verdict == 'conflict_unregistered') {
      borderCol = const Color(0xFFFCA5A5);
      headerBg = const Color(0xFFFEF2F2);
      badgeCol = const Color(0xFFB91C1C);
      vIcon = Icons.warning_amber_rounded;
    } else if (verdict == 'active_in_network') {
      borderCol = const Color(0xFF93C5FD);
      headerBg = const Color(0xFFEFF6FF);
      badgeCol = const Color(0xFF1D4ED8);
      vIcon = Icons.info_rounded;
    } else if (verdict == 'no_response') {
      borderCol = const Color(0xFFFCD34D);
      headerBg = const Color(0xFFFFFBEB);
      badgeCol = const Color(0xFFB45309);
      vIcon = Icons.help_outline_rounded;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderCol, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: headerBg,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(9),
              ),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.canEdit && !documentedInCmdb)
                  Checkbox(
                    value: isSelectedForImport,
                    activeColor: const Color(0xFF1E3A8A),
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selectedDiscoveredIps.add(ip);
                        } else {
                          _selectedDiscoveredIps.remove(ip);
                        }
                      });
                    },
                  ),
                Icon(vIcon, color: badgeCol, size: 20),
                Text(
                  ip,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'monospace',
                    color: badgeCol,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: badgeCol,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    verdictLabel,
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                ),
                Text(
                  '(${r['elapsed_ms'] ?? '--'} ms)',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF475569),
                  ),
                ),
                if (widget.canEdit && !documentedInCmdb) ...[
                  FilledButton.icon(
                    onPressed: () async {
                      await _importSelectedDiscoveredToCmdb([r]);
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: verdict == 'conflict_unregistered'
                          ? const Color(0xFFB91C1C)
                          : const Color(0xFF1E3A8A),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.add_task_rounded, size: 15),
                    label: const Text(
                      'Añadir a CMDB (1 clic)',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _openAssetEditorDialog(
                      prefilledIp: ip,
                      prefilledFqdn: (dns['ptr_hostname'] ?? '').toString(),
                      prefilledMac: (arp['mac_address'] ?? '').toString(),
                    ),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.edit_note_rounded, size: 15),
                    label: const Text(
                      'Editar y Añadir a CMDB',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        _openAssignVerifiedIpToExistingAssetDialog(ip),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.add_link_rounded, size: 15),
                    label: const Text(
                      'Vincular a Host Existente',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                ],
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _dismissedScanIps.add(ip);
                      _selectedDiscoveredIps.remove(ip);
                    });
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF64748B),
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.close_rounded, size: 15),
                  label: const Text(
                    'Descartar / No añadir',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  recommendation,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1E293B),
                  ),
                ),
                if (owners.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: owners.map((o) {
                      return Chip(
                        avatar: const Icon(Icons.computer, size: 15),
                        label: Text(
                          'Asignada en CMDB a: ${o['asset_code']} — ${o['asset_name']} [${o['ip_role_label']}]',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _buildProbeResultBox(
                        title: '1. Sonda ICMP Ping',
                        active: icmp['alive'] == true,
                        detail: (icmp['detail'] ?? '').toString(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildProbeResultBox(
                        title: '2. Sonda Puertos TCP',
                        active: tcp['alive'] == true,
                        detail: (tcp['detail'] ?? '').toString(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildProbeResultBox(
                        title: '3. Caché ARP / MAC L2',
                        active: arp['alive'] == true,
                        detail: (arp['detail'] ?? '').toString(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildProbeResultBox(
                        title: '4. DNS Inverso (PTR)',
                        active: dns['has_ptr'] == true,
                        detail: (dns['detail'] ?? '').toString(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProbeResultBox({
    required String title,
    required bool active,
    required String detail,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: active ? const Color(0xFFEFF6FF) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? const Color(0xFF60A5FA) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                active
                    ? Icons.sensors_rounded
                    : Icons.sensors_off_rounded,
                size: 15,
                color: active
                    ? const Color(0xFF1D4ED8)
                    : const Color(0xFF64748B),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: active
                        ? const Color(0xFF1E3A8A)
                        : const Color(0xFF475569),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            style: const TextStyle(fontSize: 11, color: Color(0xFF334155)),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // PESTAÑA 3: SUBREDES, VLANs Y MAPA VISUAL IPAM (.1 a .254)
  // ===========================================================================
  Widget _buildSubnetsAndIpamGridTab() {
    final subnets = _subnets;
    final selectedSubnet = subnets.firstWhere(
      (s) => s['id'] == _selectedIpamSubnetId,
      orElse: () => subnets.isNotEmpty ? subnets.first : <String, dynamic>{},
    );

    final String cidr = (selectedSubnet['cidr'] ?? '10.20.20.0/24').toString();
    final String basePrefix = cidr.contains('.')
        ? cidr.split('/')[0].rsplitThreeOctets()
        : '10.20.20';
    final List<Map<String, dynamic>> allocatedList =
        ((selectedSubnet['allocated_ips'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
    final Map<String, Map<String, dynamic>> allocatedByIp = {
      for (final item in allocatedList)
        (item['ip_address'] ?? '').toString(): item,
    };
    final String gwIp = (selectedSubnet['gateway'] ?? '').toString();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Columna izquierda: Lista de Subredes / VLANs
        Container(
          width: 340,
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(right: BorderSide(color: Color(0xFFE2E8F0))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    const Icon(
                      Icons.lan_rounded,
                      size: 18,
                      color: Color(0xFF1E3A8A),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Subredes & VLANs (IPAM)',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    if (widget.canEdit)
                      FilledButton.tonalIcon(
                        onPressed: _openCreateSubnetDialog,
                        icon: const Icon(Icons.add, size: 15),
                        label: const Text(
                          'Nueva VLAN',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(10),
                  itemCount: subnets.length,
                  itemBuilder: (ctx, i) {
                    final s = subnets[i];
                    final id = s['id'] as int;
                    final isSel = id == selectedSubnet['id'];
                    final double pct =
                        (s['usage_percent'] as num?)?.toDouble() ?? 0.0;
                    return Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 8),
                      color: isSel
                          ? const Color(0xFFEFF6FF)
                          : const Color(0xFFF8FAFC),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(
                          color: isSel
                              ? const Color(0xFF2563EB)
                              : const Color(0xFFE2E8F0),
                          width: isSel ? 1.5 : 1.0,
                        ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () =>
                            setState(() => _selectedIpamSubnetId = id),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    (s['cidr'] ?? '').toString(),
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w900,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  const Spacer(),
                                  if (s['vlan_id'] != null)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1E3A8A),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        'VLAN ${s['vlan_id']}',
                                        style: const TextStyle(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w800,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                (s['name'] ?? '').toString(),
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF334155),
                                ),
                              ),
                              const SizedBox(height: 6),
                              LinearProgressIndicator(
                                value: (pct / 100.0).clamp(0.0, 1.0),
                                backgroundColor: const Color(0xFFE2E8F0),
                                color: pct > 80
                                    ? Colors.redAccent
                                    : const Color(0xFF0284C7),
                                minHeight: 6,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Ocupadas: ${s['occupied_count']} / ${s['total_usable']} (${pct.toStringAsFixed(1)}%) • GW: ${s['gateway'] ?? '-'}',
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  color: Color(0xFF64748B),
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
          ),
        ),
        // Lienzo derecho: Mapa Visual de las 254 IPs de la Subred (.1 a .254)
        Expanded(
          child: selectedSubnet.isEmpty
              ? const Center(child: Text('Selecciona o crea una subred'))
              : Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Mapa Visual de Direcciones IP: ${selectedSubnet['cidr']} — ${selectedSubnet['name']}',
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Haz clic en cualquier casilla (.1 a .254): si está ocupada verás su Máquina y Rol; si está libre podrás verificarla con Ping+TCP+ARP o asignarla a un Host.',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    color: Color(0xFF475569),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: () {
                              setState(() {
                                _verifySelectedSubnetId =
                                    selectedSubnet['id'] as int?;
                                _activeTab = 'verifier';
                              });
                              _runManualVerification(onlySuggestFree: true);
                            },
                            icon: const Icon(Icons.radar_rounded, size: 16),
                            label: const Text(
                              'Sugerir y Verificar Próxima IP Libre de esta VLAN',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: GridView.builder(
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 68,
                              mainAxisSpacing: 6,
                              crossAxisSpacing: 6,
                              childAspectRatio: 1.35,
                            ),
                            itemCount: 254,
                            itemBuilder: (ctx, idx) {
                              final octet = idx + 1;
                              final ipStr = '$basePrefix.$octet';
                              final isGw = ipStr == gwIp;
                              final alloc = allocatedByIp[ipStr];
                              final bool isOccupied = alloc != null;
                              final bool isHb =
                                  alloc?['is_heartbeat_ip'] == true;

                              Color bg = const Color(0xFFF8FAFC);
                              Color border = const Color(0xFFE2E8F0);
                              Color txt = const Color(0xFF475569);

                              if (isGw) {
                                bg = const Color(0xFFFEF3C7);
                                border = const Color(0xFFF59E0B);
                                txt = const Color(0xFF92400E);
                              } else if (isOccupied) {
                                bg = isHb
                                    ? const Color(0xFFE0F2FE)
                                    : const Color(0xFFDCFCE7);
                                border = isHb
                                    ? const Color(0xFF0284C7)
                                    : const Color(0xFF16A34A);
                                txt = isHb
                                    ? const Color(0xFF075985)
                                    : const Color(0xFF14532D);
                              }

                              return Tooltip(
                                message: isGw
                                    ? '$ipStr • GATEWAY DE SUBRED'
                                    : isOccupied
                                        ? '$ipStr • OCUPADA por ${alloc['asset_code']} (${alloc['asset_name']})\nRol: ${alloc['ip_role_label']} (${alloc['interface_name']})'
                                        : '$ipStr • LIBRE en CMDB (Clic para verificar en red o asignar)',
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(6),
                                  onTap: () => _onTapIpamCell(
                                    ipStr: ipStr,
                                    subnet: selectedSubnet,
                                    allocated: alloc,
                                    isGateway: isGw,
                                  ),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: bg,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: border),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 3,
                                    ),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          '.$octet',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w900,
                                            fontFamily: 'monospace',
                                            color: txt,
                                          ),
                                        ),
                                        Text(
                                          isGw
                                              ? 'GW'
                                              : isOccupied
                                                  ? (alloc['asset_code'] ?? '')
                                                      .toString()
                                                  : 'Libre',
                                          style: TextStyle(
                                            fontSize: 8.5,
                                            fontWeight: FontWeight.w700,
                                            color: txt,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  void _onTapIpamCell({
    required String ipStr,
    required Map<String, dynamic> subnet,
    required Map<String, dynamic>? allocated,
    required bool isGateway,
  }) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Dirección IP $ipStr (${subnet['cidr']})'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isGateway)
                const Text(
                  'Esta IP es la Puerta de Enlace (Gateway) configurada para esta subred.',
                  style: TextStyle(fontWeight: FontWeight.w700),
                )
              else if (allocated != null) ...[
                Text(
                  'Asignada en CMDB a: ${allocated['asset_code']} — ${allocated['asset_name']}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text('Rol de la IP: ${allocated['ip_role_label']}'),
                Text('Interfaz: ${allocated['interface_name']}'),
                if ((allocated['fqdn'] ?? '').toString().isNotEmpty)
                  Text('FQDN / DNS: ${allocated['fqdn']}'),
              ] else
                const Text(
                  'Esta dirección IP figura como LIBRE en la CMDB.\n'
                  'Antes de asignarla a una máquina, te recomendamos lanzar el Verificador Manual (Ping + Puertos TCP + ARP + DNS) para confirmar que nadie la esté usando sin documentar.',
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar'),
          ),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _verifyIpCtrl.text = ipStr;
              setState(() => _activeTab = 'verifier');
              _runManualVerification(customIp: ipStr);
            },
            icon: const Icon(Icons.radar_rounded, size: 16),
            label: const Text('Verificar ahora en Red (Ping + TCP + ARP)'),
          ),
          if (widget.canEdit && allocated == null && !isGateway) ...[
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _openAssignVerifiedIpToExistingAssetDialog(
                  ipStr,
                  defaultSubnetId: subnet['id'] as int?,
                  defaultVlan: subnet['vlan_id'] as int?,
                  defaultGw: (subnet['gateway'] ?? '').toString(),
                );
              },
              icon: const Icon(Icons.add_link_rounded, size: 16),
              label: const Text('Asignar a Host Existente'),
            ),
            FilledButton.tonalIcon(
              onPressed: () {
                Navigator.pop(ctx);
                _openAssetEditorDialog(prefilledIp: ipStr);
              },
              icon: const Icon(Icons.add_box_outlined, size: 16),
              label: const Text('Nueva VM/Host'),
            ),
          ],
        ],
      ),
    );
  }

  // ===========================================================================
  // PESTAÑA 4: TOPOLOGÍA HIPERVISORES FÍSICOS ➔ VMs, CONTENEDORES Y CLUSTERS
  // ===========================================================================
  Widget _buildHypervisorTreeTab() {
    final hosts = _physicalHosts.where((h) => h['category'] == 'server').toList();
    final standaloneAssets = _assets
        .where(
          (a) =>
              a['sync_source'] == 'cmdb' &&
              (a['host_rack_device_id'] == null),
        )
        .toList();

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Relación Hipervisores / Servidores Físicos del Rack ➔ Máquinas Virtuales, Contenedores y Clusters Alojados',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w900,
            color: Color(0xFF0F172A),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Permite visualizar qué Máquinas Virtuales (VMs), Contenedores o Clusters dependen de cada servidor físico del Rack, además de las instancias Cloud o autónomas que no están en ningún rack.',
          style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
        ),
        const SizedBox(height: 14),
        ...hosts.map((h) {
          final int rDevId = h['rack_device_id'] as int;
          final hostedAssets = _assets
              .where(
                (a) =>
                    a['sync_source'] == 'cmdb' &&
                    a['host_rack_device_id'] == rDevId,
              )
              .toList();

          return Card(
            elevation: 0,
            margin: const EdgeInsets.only(bottom: 14),
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: Color(0xFFCBD5E1)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F766E).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.dns_rounded,
                          color: Color(0xFF0F766E),
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'HOST FÍSICO / HIPERVISOR: ${h['code']} — ${h['name']}',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text(
                              'Ubicación: Rack ${h['rack_code']} (U${h['start_u']}) • IP Gestión Host: ${h['ip_address']} • VMs/CIs alojados: ${hostedAssets.length}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFF475569),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (widget.canEdit)
                        OutlinedButton.icon(
                          onPressed: () => _openAssetEditorDialog(
                            defaultHostRackDeviceId: rDevId,
                          ),
                          icon: const Icon(Icons.add, size: 15),
                          label: const Text(
                            'Crear VM / Contenedor en este Host',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (hostedAssets.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(left: 12),
                      child: Text(
                        'Sin máquinas virtuales vinculadas actualmente a este servidor físico.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    )
                  else
                    ...hostedAssets.map((vm) => _buildAssetCard(vm)),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 10),
        Card(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0xFFCBD5E1)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF4F46E5).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.cloud_done_rounded,
                        color: Color(0xFF4F46E5),
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'MÁQUINAS AUTÓNOMAS, CLOUD, CLUSTERS EXTERNOS Y OTROS CIs (Sin Rack Físico Local)',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            'Máquinas gestionadas directamente en la CMDB que corren en Cloud (AWS/Azure/GCP), clusters externos o sedes sin rack (${standaloneAssets.length} máquinas)',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFF475569),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.canEdit)
                      OutlinedButton.icon(
                        onPressed: () => _openAssetEditorDialog(),
                        icon: const Icon(Icons.add, size: 15),
                        label: const Text(
                          'Añadir Máquina Autónoma / Cloud',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                ...standaloneAssets.map((vm) => _buildAssetCard(vm)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // DIÁLOGOS DE CREACIÓN / EDICIÓN DE MÁQUINAS (CON MÚLTIPLES IPs) Y SUBREDES
  // ===========================================================================
  Future<void> _openAssignVerifiedIpToExistingAssetDialog(
    String ipAddress, {
    int? defaultSubnetId,
    int? defaultVlan,
    String defaultGw = '',
  }) async {
    if (_assets.isEmpty) return;
    int selectedAssetId = _assets.first['id'] as int;
    String selectedRole = 'primary_service';
    final ifaceCtrl = TextEditingController(text: 'eth1');
    final fqdnCtrl = TextEditingController();
    final notesCtrl = TextEditingController(
      text: 'Asignada tras verificación manual en CMDB',
    );
    bool isHb = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text('Asignar IP Libre ($ipAddress) a una Máquina de la CMDB'),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: selectedAssetId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Seleccionar Máquina / Host / VM destino',
                    border: OutlineInputBorder(),
                  ),
                  items: _assets.map((a) {
                    return DropdownMenuItem<int>(
                      value: a['id'] as int,
                      child: Text(
                        '[${a['code']}] ${a['name']} (${a['asset_class_label']})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) setModalState(() => selectedAssetId = v);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedRole,
                  decoration: const InputDecoration(
                    labelText: 'Función / Rol de esta IP en la máquina',
                    border: OutlineInputBorder(),
                  ),
                  items: _ipRoleLabels.entries.map((e) {
                    return DropdownMenuItem<String>(
                      value: e.key,
                      child: Text(e.value),
                    );
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setModalState(() {
                        selectedRole = v;
                        if (v == 'mgmt_heartbeat') isHb = true;
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: ifaceCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Interfaz (ej. eth1, ens224, vip0)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: fqdnCtrl,
                        decoration: const InputDecoration(
                          labelText: 'FQDN / DNS específico de esta IP',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                CheckboxListTile(
                  value: isHb,
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Usar esta IP como IP principal de Gestión / Heartbeat de la máquina',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  onChanged: (v) => setModalState(() => isHb = v ?? false),
                ),
                TextField(
                  controller: notesCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Notas',
                    border: OutlineInputBorder(),
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
            FilledButton.icon(
              onPressed: () async {
                await widget.api.addCmdbAssetIp(selectedAssetId, {
                  'subnet_id': defaultSubnetId,
                  'ip_address': ipAddress,
                  'gateway': defaultGw,
                  'vlan_id': defaultVlan,
                  'ip_role': selectedRole,
                  'interface_name': ifaceCtrl.text.trim(),
                  'fqdn': fqdnCtrl.text.trim(),
                  'is_heartbeat_ip': isHb,
                  'notes': notesCtrl.text.trim(),
                });
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                await _loadOverview(silent: true);
              },
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Asignar IP al Host'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openAddSingleIpDialog(Map<String, dynamic> asset) async {
    final ipCtrl = TextEditingController();
    final ifaceCtrl = TextEditingController(
      text: 'eth${(asset['ip_count'] as int? ?? 1)}',
    );
    final fqdnCtrl = TextEditingController();
    final macCtrl = TextEditingController();
    final vlanCtrl = TextEditingController(text: '20');
    final gwCtrl = TextEditingController(text: '10.20.20.1');
    final notesCtrl = TextEditingController();
    String selectedRole = 'primary_service';
    bool isHb = false;
    Map<String, dynamic>? liveCheckResult;
    bool checkingNow = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(
            'Añadir Nueva IP a ${asset['code']} (${asset['name']})',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
          ),
          content: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: ipCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Nueva Dirección IP (ej. 10.20.20.55)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: checkingNow
                            ? null
                            : () async {
                                final candidate = ipCtrl.text.trim();
                                if (candidate.isEmpty) return;
                                setModalState(() => checkingNow = true);
                                try {
                                  final r = await widget.api.verifyCmdbIp(
                                    targetIp: candidate,
                                  );
                                  final list = (r['results'] as List?) ?? [];
                                  if (list.isNotEmpty) {
                                    setModalState(() {
                                      liveCheckResult = Map<String, dynamic>.from(
                                        list.first as Map,
                                      );
                                    });
                                  }
                                } finally {
                                  setModalState(() => checkingNow = false);
                                }
                              },
                        icon: checkingNow
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.radar_rounded, size: 16),
                        label: const Text('Verificar si está Libre'),
                      ),
                    ],
                  ),
                  if (liveCheckResult != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: liveCheckResult!['can_safely_assign'] == true
                            ? const Color(0xFFF0FDF4)
                            : const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: liveCheckResult!['can_safely_assign'] == true
                              ? const Color(0xFF86EFAC)
                              : const Color(0xFFFCA5A5),
                        ),
                      ),
                      child: Text(
                        '${liveCheckResult!['verdict_label']}\n${liveCheckResult!['summary']}',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: liveCheckResult!['can_safely_assign'] == true
                              ? const Color(0xFF14532D)
                              : const Color(0xFFB91C1C),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedRole,
                    decoration: const InputDecoration(
                      labelText: 'Rol de la IP (Servicio, VIP, Storage, Backup, Gestión...)',
                      border: OutlineInputBorder(),
                    ),
                    items: _ipRoleLabels.entries.map((e) {
                      return DropdownMenuItem<String>(
                        value: e.key,
                        child: Text(e.value),
                      );
                    }).toList(),
                    onChanged: (v) {
                      if (v != null) setModalState(() => selectedRole = v);
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: ifaceCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Interfaz (eth1, ens224, vip0...)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: vlanCtrl,
                          decoration: const InputDecoration(
                            labelText: 'VLAN ID',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: gwCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Gateway',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: fqdnCtrl,
                          decoration: const InputDecoration(
                            labelText: 'FQDN / DNS asociado a esta IP',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: macCtrl,
                          decoration: const InputDecoration(
                            labelText: 'MAC Address (opcional)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: isHb,
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Marcar como la IP de Gestión / Heartbeat de esta máquina',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onChanged: (v) => setModalState(() => isHb = v ?? false),
                  ),
                  TextField(
                    controller: notesCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Notas de la interfaz / servicio',
                      border: OutlineInputBorder(),
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
            FilledButton.icon(
              onPressed: () async {
                if (ipCtrl.text.trim().isEmpty) return;
                await widget.api.addCmdbAssetIp(asset['id'] as int, {
                  'ip_address': ipCtrl.text.trim(),
                  'ip_role': selectedRole,
                  'interface_name': ifaceCtrl.text.trim(),
                  'vlan_id': int.tryParse(vlanCtrl.text.trim()),
                  'gateway': gwCtrl.text.trim(),
                  'fqdn': fqdnCtrl.text.trim(),
                  'mac_address': macCtrl.text.trim(),
                  'is_heartbeat_ip': isHb,
                  'notes': notesCtrl.text.trim(),
                });
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                await _loadOverview(silent: true);
              },
              icon: const Icon(Icons.save_rounded, size: 16),
              label: const Text('Guardar Nueva IP'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openAssetEditorDialog({
    Map<String, dynamic>? existing,
    String? prefilledIp,
    String? prefilledFqdn,
    String? prefilledMac,
    int? defaultHostRackDeviceId,
  }) async {
    final bool isEdit = existing != null;
    final codeCtrl = TextEditingController(
      text: (existing?['code'] ?? 'VM-APP-02').toString(),
    );
    final nameCtrl = TextEditingController(
      text: (existing?['name'] ?? '').toString(),
    );
    final hostCtrl = TextEditingController(
      text: (existing?['hostname'] ?? '').toString(),
    );
    final fqdnCtrl = TextEditingController(
      text: (existing?['fqdn'] ?? prefilledFqdn ?? '').toString(),
    );
    final osCtrl = TextEditingController(
      text: (existing?['os_or_firmware'] ?? 'Ubuntu Server 24.04 LTS').toString(),
    );
    final cpuCtrl = TextEditingController(
      text: '${existing?['cpu_cores'] ?? 8}',
    );
    final ramCtrl = TextEditingController(
      text: '${existing?['ram_gb'] ?? 32}',
    );
    final diskCtrl = TextEditingController(
      text: '${existing?['storage_gb'] ?? 250}',
    );
    final platCtrl = TextEditingController(
      text: (existing?['hypervisor_or_platform'] ?? 'VMware vSphere 8.0').toString(),
    );
    final teamCtrl = TextEditingController(
      text: (existing?['owner_team'] ?? 'Sistemas & Virtualización').toString(),
    );
    final respCtrl = TextEditingController(
      text: (existing?['responsible_person'] ?? 'Alex Geng').toString(),
    );
    final notesCtrl = TextEditingController(
      text: (existing?['notes'] ?? '').toString(),
    );

    String assetClass =
        (existing?['asset_class'] ?? 'virtual_machine').toString();
    String environment = (existing?['environment'] ?? 'production').toString();
    String criticality = (existing?['criticality'] ?? 'high').toString();
    int? hostRackDeviceId =
        (existing?['host_rack_device_id'] as int?) ?? defaultHostRackDeviceId;
    bool monitoringEnabled = existing?['monitoring_enabled'] ?? true;
    String monitorMethod = (existing?['monitor_method'] ?? 'icmp').toString();
    final monitorPortCtrl = TextEditingController(
      text: '${existing?['monitor_port'] ?? 22}',
    );

    List<Map<String, dynamic>> ipDrafts = [];
    if (isEdit && existing['ip_addresses'] is List) {
      ipDrafts = (existing['ip_addresses'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } else {
      ipDrafts = [
        {
          'ip_address': prefilledIp ?? '10.20.1.150',
          'ip_role': 'mgmt_heartbeat',
          'interface_name': 'eth0 (Mgmt)',
          'vlan_id': 10,
          'gateway': '10.20.1.1',
          'fqdn': prefilledFqdn ?? '',
          'mac_address': prefilledMac ?? '',
          'is_heartbeat_ip': true,
          'notes': 'IP de Gestión / Heartbeat',
        },
        {
          'ip_address': '10.20.20.150',
          'ip_role': 'primary_service',
          'interface_name': 'eth1 (Prod Service)',
          'vlan_id': 20,
          'gateway': '10.20.20.1',
          'fqdn': '',
          'mac_address': '',
          'is_heartbeat_ip': false,
          'notes': 'IP de Servicio / Producción',
        },
      ];
    }

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(
            isEdit
                ? 'Editar Máquina / CI en CMDB: ${existing['code']}'
                : 'Alta en CMDB: Nueva Máquina Virtual, Contenedor, Cluster o Activo Multi-IP',
            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900),
          ),
          content: SizedBox(
            width: 780,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: codeCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Código CI (ej. VM-ERP-02, CLU-WEB-VIP)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: nameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Nombre Descriptivo de la Máquina / Servicio',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _assetClassLabels.containsKey(assetClass)
                              ? assetClass
                              : 'virtual_machine',
                          decoration: const InputDecoration(
                            labelText: 'Tipo / Clase de Máquina',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: _assetClassLabels.entries.map((e) {
                            return DropdownMenuItem<String>(
                              value: e.key,
                              child: Text(e.value),
                            );
                          }).toList(),
                          onChanged: (v) {
                            if (v != null) setModalState(() => assetClass = v);
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<int?>(
                          initialValue: _physicalHosts.any(
                                    (h) =>
                                        h['rack_device_id'] ==
                                        hostRackDeviceId,
                                  )
                              ? hostRackDeviceId
                              : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText:
                                'Servidor Físico Padre / Hipervisor en Rack (Opcional)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text(
                                'Autónoma / Cloud / Sin Host Físico en Rack',
                              ),
                            ),
                            ..._physicalHosts.map((h) {
                              return DropdownMenuItem<int?>(
                                value: h['rack_device_id'] as int,
                                child: Text(
                                  '${h['code']} (${h['name']}) — Rack ${h['rack_code']} U${h['start_u']}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }),
                          ],
                          onChanged: (v) =>
                              setModalState(() => hostRackDeviceId = v),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: hostCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Hostname',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: fqdnCtrl,
                          decoration: const InputDecoration(
                            labelText: 'FQDN Principal',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: environment,
                          decoration: const InputDecoration(
                            labelText: 'Entorno',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'production',
                              child: Text('Producción'),
                            ),
                            DropdownMenuItem(
                              value: 'preprod',
                              child: Text('Preproducción'),
                            ),
                            DropdownMenuItem(
                              value: 'dev',
                              child: Text('Desarrollo'),
                            ),
                            DropdownMenuItem(
                              value: 'mgmt',
                              child: Text('Gestión'),
                            ),
                            DropdownMenuItem(
                              value: 'dr',
                              child: Text('Contingencia DR'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) setModalState(() => environment = v);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: osCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Sistema Operativo / Firmware',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: cpuCtrl,
                          decoration: const InputDecoration(
                            labelText: 'vCPUs / Cores',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: ramCtrl,
                          decoration: const InputDecoration(
                            labelText: 'RAM (GB)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: diskCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Disco (GB)',
                            border: OutlineInputBorder(),
                            isDense: true,
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
                          controller: platCtrl,
                          decoration: const InputDecoration(
                            labelText:
                                'Plataforma (VMware, Proxmox, K8s, AWS, Hyper-V)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: teamCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Equipo Propietario',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: respCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Persona Responsable',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: SwitchListTile(
                          value: monitoringEnabled,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'Heartbeat Activo sobre su IP de Gestión',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          onChanged: (v) =>
                              setModalState(() => monitoringEnabled = v),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 150,
                        child: DropdownButtonFormField<String>(
                          initialValue: monitorMethod,
                          decoration: const InputDecoration(
                            labelText: 'Método Heartbeat',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: const [
                            DropdownMenuItem(value: 'icmp', child: Text('ICMP Ping')),
                            DropdownMenuItem(value: 'ssh', child: Text('SSH')),
                            DropdownMenuItem(value: 'https', child: Text('HTTPS')),
                            DropdownMenuItem(value: 'http', child: Text('HTTP')),
                            DropdownMenuItem(value: 'tcp', child: Text('TCP Puerto')),
                            DropdownMenuItem(value: 'snmp', child: Text('SNMP')),
                          ],
                          onChanged: (v) {
                            if (v != null) {
                              setModalState(() => monitorMethod = v);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 100,
                        child: TextField(
                          controller: monitorPortCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Puerto',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 22),
                  Row(
                    children: [
                      const Icon(
                        Icons.lan_rounded,
                        size: 18,
                        color: Color(0xFF1E3A8A),
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Direcciones IP de la Máquina (IP de Gestión/Heartbeat + IPs de Producción/Servicio/VIP/Backup)',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () {
                          setModalState(() {
                            ipDrafts.add({
                              'ip_address': '',
                              'ip_role': 'secondary_service',
                              'interface_name': 'eth${ipDrafts.length}',
                              'vlan_id': 20,
                              'gateway': '10.20.20.1',
                              'fqdn': '',
                              'mac_address': '',
                              'is_heartbeat_ip': false,
                              'notes': '',
                            });
                          });
                        },
                        icon: const Icon(Icons.add, size: 15),
                        label: const Text('Añadir otra Interfaz / IP'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ...ipDrafts.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final item = entry.value;
                    final bool isHb = item['is_heartbeat_ip'] == true;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isHb
                            ? const Color(0xFFF0F9FF)
                            : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isHb
                              ? const Color(0xFF38BDF8)
                              : const Color(0xFFCBD5E1),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              initialValue: (item['ip_address'] ?? '').toString(),
                              decoration: const InputDecoration(
                                labelText: 'Dirección IP',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (v) => item['ip_address'] = v,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: DropdownButtonFormField<String>(
                              initialValue: _ipRoleLabels.containsKey(item['ip_role'])
                                  ? item['ip_role'] as String
                                  : 'primary_service',
                              decoration: const InputDecoration(
                                labelText: 'Rol de IP',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: _ipRoleLabels.entries.map((e) {
                                return DropdownMenuItem<String>(
                                  value: e.key,
                                  child: Text(
                                    e.value,
                                    style: const TextStyle(fontSize: 11.5),
                                  ),
                                );
                              }).toList(),
                              onChanged: (v) {
                                if (v != null) {
                                  setModalState(() => item['ip_role'] = v);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              initialValue:
                                  (item['interface_name'] ?? '').toString(),
                              decoration: const InputDecoration(
                                labelText: 'Interfaz',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (v) => item['interface_name'] = v,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              initialValue: (item['fqdn'] ?? '').toString(),
                              decoration: const InputDecoration(
                                labelText: 'FQDN / DNS de esta IP',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (v) => item['fqdn'] = v,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Tooltip(
                            message:
                                'Marcar como IP principal de Gestión / Heartbeat',
                            child: InkWell(
                              onTap: () {
                                setModalState(() {
                                  for (final d in ipDrafts) {
                                    d['is_heartbeat_ip'] = false;
                                  }
                                  item['is_heartbeat_ip'] = true;
                                });
                              },
                              child: Chip(
                                backgroundColor: isHb
                                    ? const Color(0xFF0284C7)
                                    : const Color(0xFFE2E8F0),
                                label: Text(
                                  isHb ? '★ Heartbeat' : 'Servicio',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    color: isHb
                                        ? Colors.white
                                        : const Color(0xFF475569),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (ipDrafts.length > 1)
                            IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: Colors.redAccent,
                              ),
                              onPressed: () {
                                setModalState(() => ipDrafts.removeAt(idx));
                              },
                            ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  TextField(
                    controller: notesCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Notas técnicas / Aplicaciones / Observaciones CMDB',
                      border: OutlineInputBorder(),
                      isDense: true,
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
            FilledButton.icon(
              onPressed: () async {
                final payload = {
                  'code': codeCtrl.text.trim(),
                  'name': nameCtrl.text.trim(),
                  'hostname': hostCtrl.text.trim(),
                  'fqdn': fqdnCtrl.text.trim(),
                  'asset_class': assetClass,
                  'environment': environment,
                  'criticality': criticality,
                  'os_or_firmware': osCtrl.text.trim(),
                  'cpu_cores': int.tryParse(cpuCtrl.text.trim()) ?? 0,
                  'ram_gb': double.tryParse(ramCtrl.text.trim()) ?? 0.0,
                  'storage_gb': double.tryParse(diskCtrl.text.trim()) ?? 0.0,
                  'hypervisor_or_platform': platCtrl.text.trim(),
                  'owner_team': teamCtrl.text.trim(),
                  'responsible_person': respCtrl.text.trim(),
                  'host_rack_device_id': hostRackDeviceId,
                  'monitoring_enabled': monitoringEnabled,
                  'monitor_method': monitorMethod,
                  'monitor_port': int.tryParse(monitorPortCtrl.text.trim()) ?? 22,
                  'notes': notesCtrl.text.trim(),
                  'ip_addresses': ipDrafts
                      .where(
                        (d) =>
                            (d['ip_address'] ?? '').toString().trim().isNotEmpty,
                      )
                      .toList(),
                };
                try {
                  if (isEdit) {
                    await widget.api.updateCmdbAsset(
                      existing['id'] as int,
                      payload,
                    );
                  } else {
                    await widget.api.createCmdbAsset(payload);
                  }
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                  await _loadOverview(silent: true);
                } catch (e) {
                  if (!ctx.mounted) return;
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text('Error guardando en CMDB: $e')),
                  );
                }
              },
              icon: const Icon(Icons.save_rounded, size: 16),
              label: Text(isEdit ? 'Guardar Cambios' : 'Crear Máquina en CMDB'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteAsset(Map<String, dynamic> asset) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Eliminar ${asset['code']} de la CMDB?'),
        content: Text(
          'Se dará de baja "${asset['name']}" y todas sus direcciones IP quedarán liberadas en la CMDB.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.api.deleteCmdbAsset(asset['id'] as int);
      await _loadOverview(silent: true);
    }
  }

  Future<void> _openCreateSubnetDialog() async {
    final cidrCtrl = TextEditingController(text: '10.20.40.0/24');
    final nameCtrl = TextEditingController(
      text: 'VLAN 40 — Nueva Red de Servicios',
    );
    final vlanCtrl = TextEditingController(text: '40');
    final gwCtrl = TextEditingController(text: '10.20.40.1');
    final dnsCtrl = TextEditingController(text: '10.20.1.5');
    final notesCtrl = TextEditingController();
    String env = 'production';

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Registrar Nueva Subred / VLAN en IPAM'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: cidrCtrl,
                decoration: const InputDecoration(
                  labelText: 'Bloque CIDR (ej. 10.20.40.0/24)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Nombre Descriptivo de la Subred / VLAN',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: vlanCtrl,
                      decoration: const InputDecoration(
                        labelText: 'VLAN ID',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: gwCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Gateway',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: dnsCtrl,
                decoration: const InputDecoration(
                  labelText: 'Servidores DNS',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: notesCtrl,
                decoration: const InputDecoration(
                  labelText: 'Notas',
                  border: OutlineInputBorder(),
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
          FilledButton.icon(
            onPressed: () async {
              await widget.api.createCmdbSubnet({
                'cidr': cidrCtrl.text.trim(),
                'name': nameCtrl.text.trim(),
                'vlan_id': int.tryParse(vlanCtrl.text.trim()),
                'gateway': gwCtrl.text.trim(),
                'dns_servers': dnsCtrl.text.trim(),
                'environment': env,
                'notes': notesCtrl.text.trim(),
              });
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              await _loadOverview(silent: true);
            },
            icon: const Icon(Icons.save, size: 16),
            label: const Text('Guardar Subred'),
          ),
        ],
      ),
    );
  }
}

class _TableHeaderCell extends StatelessWidget {
  final String text;
  const _TableHeaderCell(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w900,
          color: Color(0xFF334155),
        ),
      ),
    );
  }
}

class _TableBodyCell extends StatelessWidget {
  final String text;
  final bool mono;
  final bool bold;
  const _TableBodyCell(
    this.text, {
    this.mono = false,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontFamily: mono ? 'monospace' : null,
          fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
          color: const Color(0xFF1E293B),
        ),
      ),
    );
  }
}

extension _IpPrefixStringExt on String {
  String rsplitThreeOctets() {
    final parts = split('.');
    if (parts.length >= 3) {
      return '${parts[0]}.${parts[1]}.${parts[2]}';
    }
    return this;
  }
}
