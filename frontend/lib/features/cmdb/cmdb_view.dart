import 'package:flutter/material.dart';
import '../../core/widgets/avisos.dart';
import '../../core/theme.dart';
import 'package:flutter/services.dart';
import '../../core/api_client.dart';

class CmdbView extends StatefulWidget {
  final RackDocApiClient api;
  final bool canEdit;
  final void Function(int rackId, int? deviceId)? onNavigateToRackDevice;
  final void Function(int? locationId, int floorId, int floorDeviceId)?
      onNavigateToFloorDevice;
  final void Function(int stackId, int? nodeId)? onNavigateToStackNode;
  final VoidCallback? onExportExcel;

  const CmdbView({
    super.key,
    required this.api,
    required this.canEdit,
    this.onNavigateToRackDevice,
    this.onNavigateToFloorDevice,
    this.onNavigateToStackNode,
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

  // Filtros y Ordenación de '1. Inventario CMDB & Multi-IP' (Vista estilo Excel)
  final TextEditingController _searchCtrl = TextEditingController();
  String _classFilter = 'all';
  String _envFilter = 'all';
  int? _locationFilter; // null = Todas las sedes, -1 = Sin sede asignada
  bool _onlyMultiIp = false;
  int? _expandedAssetId;
  int? _highlightedAssetId;
  int? _runningHeartbeatAssetId;
  String _sortColumn = 'primary_ip';
  bool _sortAscending = true;
  final Set<int> _selectedInventoryAssetIds = {};

  // Estado de '2. Verificador Manual de IPs Libres y Escáner de Rangos CIDR (ej. 1.1.1.1/24)'
  final TextEditingController _verifyIpCtrl = TextEditingController(
    text: '192.168.2.0/24',
  );
  int? _verifySelectedSubnetId;
  final int _verifyCountLimit = 254;
  bool _verifyingIp = false;
  Map<String, dynamic>? _verificationReport;
  String? _verifyError;
  String _scanResultFilter = 'detected_or_cmdb';
  final Set<String> _selectedDiscoveredIps = {};
  final Set<String> _dismissedScanIps = {};
  String _bulkImportAssetClass = 'other_machine';
  int? _bulkImportLocationId;
  bool _alsoRegisterScannedSubnet = true;
  bool _importingDiscovered = false;

  // Estado de '3. Subredes, VLANs & Mapa Visual IPAM'
  int? _selectedIpamSubnetId;
  String _selectedIpamSubBlock24 = 'all';

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

  List<Map<String, dynamic>> get _locations {
    final raw = (_overview?['locations'] as List?) ?? [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  List<Map<String, dynamic>> get _floors {
    final raw = (_overview?['floors'] as List?) ?? [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static const Map<String, String> _floorDeviceTypeLabels = {
    'printer': 'Impresora / Printer (PR)',
    '3d_printer': 'Impresora 3D (3DP)',
    'camera': 'Cámara CCTV / IP (CAM)',
    'access_point': 'Punto de Acceso Wi-Fi (AP)',
    'desktop': 'PC Sobremesa / Workstation (PC)',
    'laptop': 'Portátil / Laptop (LP)',
    'phone': 'Teléfono IP / VoIP (PH)',
    'screen': 'Pantalla / Videowall (SCR)',
    'access_control': 'Control de Acceso / Biometría (BIO)',
    'isp_uplink': 'Router / Fibra Operador ISP (ISP)',
    'ndi_box': 'Codificador Vídeo NDI (NDI)',
    'microphone': 'Micrófono IP / Dante (MIC)',
    'speaker': 'Altavoz IP / Megafonía (SPK)',
    'sensor_temp': 'Sensor Temperatura (°C)',
    'sensor_humidity': 'Sensor Humedad (%RH)',
    'sensor_power_load': 'Sensor Carga Eléctrica (kW)',
  };

  List<Map<String, dynamic>> get _ipCollisions {
    final raw = (_overview?['ip_collisions'] as List?) ?? [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  int _ipToSortableInt(String ip) {
    final parts = ip.trim().split('.');
    if (parts.length != 4) return 0x7FFFFFFF;
    int val = 0;
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return 0x7FFFFFFF;
      val = (val << 8) | n;
    }
    return val;
  }

  String _primaryIpOfAsset(Map<String, dynamic> a) {
    final hb = (a['heartbeat_ip'] ?? '').toString().trim();
    if (hb.isNotEmpty) return hb;
    final ips = (a['ip_addresses'] as List?) ?? [];
    if (ips.isNotEmpty) {
      return ((ips.first as Map)['ip_address'] ?? '').toString().trim();
    }
    return '';
  }

  String _primaryMaskOfAsset(Map<String, dynamic> a) {
    final m = (a['primary_subnet_mask'] ?? '').toString().trim();
    if (m.isNotEmpty) return m;
    final ips = (a['ip_addresses'] as List?) ?? [];
    for (final item in ips) {
      final sm = ((item as Map)['subnet_mask'] ?? '').toString().trim();
      if (sm.isNotEmpty) return sm;
    }
    return '';
  }

  String _primaryMacOfAsset(Map<String, dynamic> a) {
    final ips = (a['ip_addresses'] as List?) ?? [];
    for (final item in ips) {
      final m = ((item as Map)['mac_address'] ?? '').toString().trim();
      if (m.isNotEmpty) return m;
    }
    return '';
  }

  String _primaryVlanOfAsset(Map<String, dynamic> a) {
    final ips = (a['ip_addresses'] as List?) ?? [];
    for (final item in ips) {
      final v = (item as Map)['vlan_id'];
      if (v != null && v.toString().isNotEmpty) return 'VLAN $v';
    }
    return '';
  }

  List<Map<String, dynamic>> get _filteredAssets {
    final q = _searchCtrl.text.trim().toLowerCase();
    final filtered = _assets.where((a) {
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
      if (_locationFilter != null) {
        final int? assetLocId = a['location_id'] as int?;
        if (_locationFilter == -1) {
          if (assetLocId != null) return false;
        } else if (assetLocId != _locationFilter) {
          return false;
        }
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
        final siteLoc = (a['location_label'] ?? '').toString().toLowerCase();
        final stackLbl = (a['primary_stack_label'] ?? '').toString().toLowerCase();
        final primaryMask = _primaryMaskOfAsset(a).toLowerCase();
        final env = (a['environment'] ?? '').toString().toLowerCase();
        final cls = (a['asset_class_label'] ?? _assetClassLabels[a['asset_class']] ?? '')
            .toString()
            .toLowerCase();
        final status = (a['status'] ?? '').toString().toLowerCase();
        final owner = (a['owner_team'] ?? '').toString().toLowerCase();
        final resp = (a['responsible_person'] ?? '').toString().toLowerCase();
        final notes = (a['notes'] ?? '').toString().toLowerCase();
        final resources =
            '${a['cpu_cores'] ?? ''}vcpu ${a['ram_gb'] ?? ''}gb ${a['storage_gb'] ?? ''}gb'
                .toLowerCase();
        final ips = ((a['ip_addresses'] as List?) ?? [])
            .map((ip) =>
                '${(ip as Map)['ip_address']} ${ip['subnet_mask'] ?? ''} ${ip['gateway'] ?? ''} ${ip['fqdn']} ${ip['interface_name']} ${ip['mac_address']} ${ip['ip_role_label']} vlan ${ip['vlan_id'] ?? ''}'
                    .toLowerCase())
            .join(' ');
        final haystack =
            '$code $name $host $fqdn $os $plat $loc $siteLoc $stackLbl $primaryMask $env $cls $status $owner $resp $notes $resources $ips';
        if (!haystack.contains(q)) {
          return false;
        }
      }
      return true;
    }).toList();

    filtered.sort((a, b) {
      int cmp = 0;
      switch (_sortColumn) {
        case 'status':
          cmp = (a['status'] ?? '').toString().compareTo((b['status'] ?? '').toString());
          break;
        case 'code':
          cmp = (a['code'] ?? '').toString().compareTo((b['code'] ?? '').toString());
          break;
        case 'name':
          cmp = (a['name'] ?? '').toString().toLowerCase().compareTo(
                (b['name'] ?? '').toString().toLowerCase(),
              );
          break;
        case 'hostname':
          final ha = ((a['fqdn'] ?? '').toString().isNotEmpty
                  ? a['fqdn']
                  : (a['hostname'] ?? ''))
              .toString()
              .toLowerCase();
          final hb = ((b['fqdn'] ?? '').toString().isNotEmpty
                  ? b['fqdn']
                  : (b['hostname'] ?? ''))
              .toString()
              .toLowerCase();
          cmp = ha.compareTo(hb);
          break;
        case 'primary_ip':
          cmp = _ipToSortableInt(_primaryIpOfAsset(a))
              .compareTo(_ipToSortableInt(_primaryIpOfAsset(b)));
          break;
        case 'subnet_mask':
          cmp = _primaryMaskOfAsset(a).compareTo(_primaryMaskOfAsset(b));
          break;
        case 'site_location':
          cmp = (a['location_label'] ?? '')
              .toString()
              .toLowerCase()
              .compareTo((b['location_label'] ?? '').toString().toLowerCase());
          break;
        case 'mac_vlan':
          cmp = _primaryMacOfAsset(a).compareTo(_primaryMacOfAsset(b));
          break;
        case 'asset_class':
          cmp = (a['asset_class_label'] ?? '').toString().compareTo(
                (b['asset_class_label'] ?? '').toString(),
              );
          break;
        case 'environment':
          cmp = (a['environment'] ?? '').toString().compareTo(
                (b['environment'] ?? '').toString(),
              );
          break;
        case 'os_or_firmware':
          cmp = (a['os_or_firmware'] ?? '').toString().toLowerCase().compareTo(
                (b['os_or_firmware'] ?? '').toString().toLowerCase(),
              );
          break;
        case 'resources':
          final ra = ((a['cpu_cores'] as num?)?.toDouble() ?? 0) * 1000 +
              ((a['ram_gb'] as num?)?.toDouble() ?? 0);
          final rb = ((b['cpu_cores'] as num?)?.toDouble() ?? 0) * 1000 +
              ((b['ram_gb'] as num?)?.toDouble() ?? 0);
          cmp = ra.compareTo(rb);
          break;
        case 'location':
          final la = '${a['physical_location_label'] ?? ''} ${a['primary_stack_label'] ?? ''}'
              .toLowerCase();
          final lb = '${b['physical_location_label'] ?? ''} ${b['primary_stack_label'] ?? ''}'
              .toLowerCase();
          cmp = la.compareTo(lb);
          break;
        case 'owner':
          final oa = '${a['owner_team'] ?? ''} ${a['responsible_person'] ?? ''}'.toLowerCase();
          final ob = '${b['owner_team'] ?? ''} ${b['responsible_person'] ?? ''}'.toLowerCase();
          cmp = oa.compareTo(ob);
          break;
        default:
          cmp = (a['code'] ?? '').toString().compareTo((b['code'] ?? '').toString());
      }
      return _sortAscending ? cmp : -cmp;
    });

    return filtered;
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
      int detectedOrCmdbCount = 0;
      for (final item in rawList) {
        final v = (item['verdict'] ?? '').toString();
        if (v == 'conflict_unregistered') {
          autoSelected.add((item['ip_address'] ?? '').toString());
        }
        if (v != 'free_confirmed') {
          detectedOrCmdbCount++;
        }
      }
      setState(() {
        _verificationReport = res;
        _dismissedScanIps.clear();
        _selectedDiscoveredIps
          ..clear()
          ..addAll(autoSelected);
        // En escaneos de rango (>1 IP), mostrar por defecto solo los dispositivos detectados/CMDB
        // para no inundar la pantalla con las ~240 IPs vacías (salvo que sea búsqueda de libres o 0 detectados)
        if (onlySuggestFree || rawList.length <= 1 || detectedOrCmdbCount == 0) {
          _scanResultFilter = 'all';
        } else {
          _scanResultFilter = 'detected_or_cmdb';
        }
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
    List<Map<String, dynamic>> candidateRows, {
    bool forceDirectRows = false,
  }) async {
    final selectedRows = candidateRows.where((r) {
      if (r['documented_in_cmdb'] == true) return false;
      if (r['verdict'] == 'free_confirmed' && !forceDirectRows) return false;
      if (forceDirectRows) return true;
      return _selectedDiscoveredIps.contains(
        (r['ip_address'] ?? '').toString(),
      );
    }).toList();
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
      ScaffoldMessenger.of(context).aviso('Marca al menos un dispositivo detectado en red (en rojo) para añadirlo a la CMDB.');
      return;
    }

    setState(() => _importingDiscovered = true);
    try {
      final parsedScanned =
          scannedCidr != null ? _ParsedCidrBlock.tryParse(scannedCidr) : null;
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
          'subnet_mask': parsedScanned?.subnetMask ?? '255.255.255.0',
          'location_id': _bulkImportLocationId,
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
        locationId: _bulkImportLocationId,
        items: itemsPayload,
      );
      if (!mounted) return;
      final int importedCount =
          (updatedOverview['imported_assets_count'] as int?) ??
              itemsPayload.length;
      final List<String> importedIps =
          ((updatedOverview['imported_ips'] as List?) ??
                  itemsPayload.map((e) => e['ip_address']).toList())
              .map((e) => e.toString())
              .toList();
      final Map<String, Map<String, dynamic>> importedInfoByIp = {};
      for (final info in ((updatedOverview['imported_assets_info'] as List?) ?? [])) {
        final m = Map<String, dynamic>.from(info as Map);
        final ipKey = (m['ip_address'] ?? '').toString();
        if (ipKey.isNotEmpty) {
          importedInfoByIp[ipKey] = m;
        }
      }

      // Actualizar en caliente las tarjetas del reporte para que pasen de ROJO a VERDE al instante
      // sin relanzar un nuevo escaneo de las 254 IPs en segundo plano
      if (_verificationReport != null) {
        final currentResults = ((_verificationReport!['results'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        for (final r in currentResults) {
          final rIp = (r['ip_address'] ?? '').toString();
          if (importedIps.contains(rIp)) {
            final ownerInfo = importedInfoByIp[rIp] ??
                {
                  'asset_code': 'DISC-${rIp.split('.').last}',
                  'asset_name': 'Equipo Detectado ($rIp)',
                  'ip_role_label': 'Gestión / Manager (Heartbeat)',
                };
            r['documented_in_cmdb'] = true;
            r['verdict'] = 'active_in_network';
            r['verdict_label'] = 'YA EN CMDB Y ACTIVA EN RED';
            r['verdict_severity'] = 'success';
            r['can_safely_assign'] = false;
            r['cmdb_owners'] = [ownerInfo];
            r['recommendation'] =
                'Equipo añadido correctamente a la CMDB [${ownerInfo['asset_code']}] y activo en la red.';
            _selectedDiscoveredIps.remove(rIp);
          }
        }
        _verificationReport!['results'] = currentResults;
        if (shouldCreateSubnet) {
          _verificationReport!['cidr_already_in_cmdb'] = true;
        }
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppPalette.green700,
          content: Text(
            '✓ Añadido(s) $importedCount equipo(s) a la CMDB (estado actualizado en verde)${shouldCreateSubnet ? ' y registrada la subred $scannedCidr' : ''}.',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      );
      final subnets = (updatedOverview['subnets'] as List? ?? []);
      setState(() {
        _overview = updatedOverview;
        if (subnets.isNotEmpty) {
          final firstSubId = (subnets.first as Map)['id'] as int?;
          _verifySelectedSubnetId ??= firstSubId;
          _selectedIpamSubnetId ??= firstSubId;
        }
        _importingDiscovered = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _importingDiscovered = false);
      ScaffoldMessenger.of(context).aviso('Error importando en CMDB: $e');
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
              ? AppPalette.green700
              : AppPalette.red700,
          content: Text(
            '[${asset['code']}] Heartbeat (${res['target']}): ${res['detail']}',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
          ),
        ),
      );
      await _loadOverview(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).aviso('Error en Heartbeat: $e');
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
      color: AppPalette.slate50,
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
        border: Border(bottom: BorderSide(color: AppPalette.slate200)),
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
                    colors: [AppPalette.blue900, AppPalette.sky600],
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
                        color: AppPalette.slate900,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Gestión unificada de servidores físicos, máquinas virtuales, contenedores y VIPs con separación de IP de Gestión (Heartbeat/Manager) e IPs de Operación/Servicio + Verificador Manual Anti-Conflictos.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: AppPalette.slate600,
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
                  foregroundColor: AppPalette.sky700,
                  side: const BorderSide(color: AppPalette.sky400, width: 1.4),
                  backgroundColor: AppPalette.sky50,
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
                    foregroundColor: AppPalette.green700,
                    side: const BorderSide(color: AppPalette.green300),
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
                    backgroundColor: AppPalette.blue900,
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
                color: AppPalette.blue900,
              ),
              _buildKpiChip(
                icon: Icons.cloud_queue_rounded,
                label: 'Máquinas Virtuales (VMs)',
                value: '${summary['virtual_machines_count'] ?? 0}',
                color: AppPalette.violet600,
              ),
              _buildKpiChip(
                icon: Icons.widgets_outlined,
                label: 'Contenedores, Clusters & Cloud',
                value: '${summary['containers_and_clusters_count'] ?? 0}',
                color: AppPalette.sky600,
              ),
              _buildKpiChip(
                icon: Icons.storage_rounded,
                label: 'Equipos Físicos (Rack/Planta)',
                value: '${summary['physical_assets_count'] ?? 0}',
                color: AppPalette.teal700,
              ),
              _buildKpiChip(
                icon: Icons.account_tree_rounded,
                label: 'Hosts con Múltiples IPs (>1 IP)',
                value: '${summary['multi_ip_assets_count'] ?? 0}',
                color: AppPalette.amber600,
              ),
              _buildKpiChip(
                icon: Icons.lan_rounded,
                label: 'IPs Documentadas / Subredes',
                value:
                    '${summary['total_ip_addresses'] ?? 0} IPs en ${summary['total_subnets'] ?? 0} VLANs',
                color: AppPalette.green700,
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
                  color: AppPalette.slate600,
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
        color: AppPalette.slate100,
        border: Border(bottom: BorderSide(color: AppPalette.slate200)),
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
                    color: isSelected ? AppPalette.slate900 : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected
                          ? AppPalette.slate900
                          : AppPalette.slate300,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        t.$2,
                        size: 16,
                        color: isSelected
                            ? AppPalette.sky400
                            : AppPalette.slate600,
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
                              : AppPalette.slate700,
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
  // PESTAÑA 1: INVENTARIO CMDB & MULTI-IP (VISTA TABLA ESTILO EXCEL ORDENABLE)
  // ===========================================================================
  void _onSortInventoryBy(String colKey) {
    setState(() {
      if (_sortColumn == colKey) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumn = colKey;
        _sortAscending = true;
      }
    });
  }

  Future<void> _deleteSelectedInventoryAssets() async {
    if (_selectedInventoryAssetIds.isEmpty) return;
    final count = _selectedInventoryAssetIds.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Eliminar $count equipo(s) y liberar sus IPs'),
        content: Text(
          '¿Confirmas que deseas eliminar los $count equipo(s) seleccionados de la CMDB y dejar todas sus direcciones IP como NO OCUPADAS (Libres) en el mapa IPAM?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.red600,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sí, Eliminar y Liberar IPs'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final ids = _selectedInventoryAssetIds.toList();
    for (final id in ids) {
      try {
        await widget.api.deleteCmdbAsset(id);
      } catch (_) {}
    }
    setState(() {
      _selectedInventoryAssetIds.clear();
    });
    await _loadOverview(silent: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppPalette.green700,
        content: Text(
          'Se han eliminado $count equipo(s) y sus IPs han quedado libres.',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
    );
  }

  void _jumpToIpInIpamMap(String ipAddr) {
    if (ipAddr.isEmpty) return;
    int? targetSubnetId = _selectedIpamSubnetId;
    final prefix3 = ipAddr.rsplitThreeOctets();
    for (final s in _subnets) {
      final cidr = (s['cidr'] ?? '').toString();
      if (cidr.startsWith('$prefix3.')) {
        targetSubnetId = s['id'] as int?;
        break;
      }
    }
    setState(() {
      if (targetSubnetId != null) {
        _selectedIpamSubnetId = targetSubnetId;
      }
      _activeTab = 'subnets_ipam';
    });
  }

  Future<void> _toggleAssetHeartbeatMonitoring(Map<String, dynamic> asset) async {
    final int id = asset['id'] as int;
    final bool currentVal = asset['monitoring_enabled'] ?? true;
    final bool nextVal = !currentVal;
    try {
      await widget.api.updateCmdbAsset(id, {
        'monitoring_enabled': nextVal,
      });
      await _loadOverview(silent: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor:
              nextVal ? AppPalette.green700 : AppPalette.slate600,
          content: Text(
            nextVal
                ? 'Heartbeat ACTIVADO para [${asset['code']}] (${_primaryIpOfAsset(asset)})'
                : 'Heartbeat DESACTIVADO para [${asset['code']}]',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).aviso('Error actualizando Heartbeat: $e');
    }
  }

  Widget _buildIpCollisionsAlertBanner() {
    final collisions = _ipCollisions;
    if (collisions.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppPalette.red50,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFFEF4444), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: AppPalette.red700,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Atención: Se han detectado ${collisions.length} colisión(es) de IP entre equipos de la CMDB y el Rack Editor',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w900,
                    color: AppPalette.red800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...collisions.map((c) {
            final String ipAddr = (c['ip_address'] ?? '').toString();
            final List<Map<String, dynamic>> involved =
                ((c['assets'] as List?) ?? [])
                    .map((e) => Map<String, dynamic>.from(e as Map))
                    .toList();
            final String desc = involved
                .map(
                  (a) =>
                      '[${a['code']}] ${a['name']} (${a['sync_source'] == 'rack_device' ? 'Rack Editor: ${a['physical_location_label']}' : 'CMDB'})',
                )
                .join('  ⚡  ');
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppPalette.red700,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'IP $ipAddr',
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      desc,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF7F1D1D),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.canEdit)
                    FilledButton.icon(
                      onPressed: () => _openResolveCollisionDialog(c),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppPalette.red700,
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.merge_type_rounded, size: 15),
                      label: const Text(
                        'Resolver Colisión / Unificar Equipos',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Future<void> _openResolveCollisionDialog(
    Map<String, dynamic> collision,
  ) async {
    final String ipAddr = (collision['ip_address'] ?? '').toString();
    final List<Map<String, dynamic>> involved =
        ((collision['assets'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
    if (involved.length < 2) return;

    // Priorizar como "keep" el equipo que esté montado físicamente en el Rack Editor
    Map<String, dynamic> primaryAsset = involved.firstWhere(
      (a) => a['sync_source'] == 'rack_device' || a['sync_source'] == 'floor_device',
      orElse: () => involved.first,
    );
    Map<String, dynamic> secondaryAsset = involved.firstWhere(
      (a) => a['id'] != primaryAsset['id'],
      orElse: () => involved[1],
    );

    String action = 'merge'; // 'merge' | 'reassign_or_clear' | 'delete_other'
    int keepId = primaryAsset['id'] as int;
    int otherId = secondaryAsset['id'] as int;

    final String bestName = !(primaryAsset['name'] ?? '')
            .toString()
            .startsWith('Equipo Detectado')
        ? (primaryAsset['name'] ?? '').toString()
        : (secondaryAsset['name'] ?? primaryAsset['name'] ?? '').toString();
    final String bestHost = !(primaryAsset['hostname'] ?? '')
            .toString()
            .startsWith('host-')
        ? (primaryAsset['hostname'] ?? '').toString()
        : (secondaryAsset['hostname'] ?? primaryAsset['hostname'] ?? '')
            .toString();
    final String bestFqdn = (primaryAsset['fqdn'] ?? '').toString().isNotEmpty
        ? (primaryAsset['fqdn'] ?? '').toString()
        : (secondaryAsset['fqdn'] ?? '').toString();

    final nameCtrl = TextEditingController(text: bestName);
    final hostCtrl = TextEditingController(text: bestHost);
    final fqdnCtrl = TextEditingController(text: bestFqdn);
    final newIpCtrl = TextEditingController();
    bool saving = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final keepObj = involved.firstWhere(
            (a) => a['id'] == keepId,
            orElse: () => primaryAsset,
          );
          final otherObj = involved.firstWhere(
            (a) => a['id'] == otherId,
            orElse: () => secondaryAsset,
          );
          return AlertDialog(
            title: Row(
              children: [
                const Icon(
                  Icons.merge_type_rounded,
                  color: AppPalette.red700,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Resolver Colisión de IP $ipAddr (Alinear Rack Editor y CMDB)',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 660,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppPalette.amber50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppPalette.amber300),
                      ),
                      child: Text(
                        'La dirección IP $ipAddr figura simultáneamente en dos registros. Selecciona cómo deseas solucionarlo:',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppPalette.amber800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    ...involved.map((a) {
                      final bool isRack = a['sync_source'] == 'rack_device';
                      return Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isRack
                              ? AppPalette.blue50
                              : AppPalette.slate50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isRack
                                ? const Color(0xFF60A5FA)
                                : AppPalette.slate300,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isRack
                                  ? Icons.developer_board_rounded
                                  : Icons.radar_rounded,
                              size: 18,
                              color: isRack
                                  ? AppPalette.blue700
                                  : AppPalette.slate600,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '[${a['code']}] ${a['name']}',
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  Text(
                                    'Origen: ${isRack ? 'Montado en Rack (${a['physical_location_label']})' : 'Descubierto/Creado en CMDB'} • Hostname/FQDN: ${(a['fqdn'] ?? '').toString().isNotEmpty ? a['fqdn'] : (a['hostname'] ?? '-')} • Estado: ${(a['status'] ?? '').toString().toUpperCase()}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: AppPalette.slate600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    const Divider(height: 18),
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        action == 'merge'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: AppPalette.blue600,
                      ),
                      title: const Text(
                        '1. Es el mismo dispositivo físico: Unificar y alinear en un único equipo (Recomendado)',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w900,
                          color: AppPalette.slate900,
                        ),
                      ),
                      subtitle: const Text(
                        'Conserva la ubicación del Rack Editor y fusiona el estado Online, latencia, MAC, FQDN e IPs secundarias de la CMDB eliminando la fila duplicada.',
                        style: TextStyle(fontSize: 11),
                      ),
                      onTap: () => setModalState(() => action = 'merge'),
                    ),
                    if (action == 'merge') ...[
                      Padding(
                        padding: const EdgeInsets.only(left: 28, top: 6, bottom: 8),
                        child: Column(
                          children: [
                            TextField(
                              controller: nameCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Nombre definitivo del dispositivo unificado',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: hostCtrl,
                                    decoration: const InputDecoration(
                                      labelText: 'Hostname definitivo',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    controller: fqdnCtrl,
                                    decoration: const InputDecoration(
                                      labelText: 'FQDN / DNS definitivo',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        action == 'reassign_or_clear'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: AppPalette.blue600,
                      ),
                      title: const Text(
                        '2. Son equipos distintos: Cambiar o liberar la IP de uno de ellos',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      subtitle: Text(
                        'Mantiene $ipAddr en [${keepObj['code']}] y asigna otra IP (o deja sin IP) a [${otherObj['code']}].',
                        style: const TextStyle(fontSize: 11),
                      ),
                      onTap: () => setModalState(() => action = 'reassign_or_clear'),
                    ),
                    if (action == 'reassign_or_clear') ...[
                      Padding(
                        padding: const EdgeInsets.only(left: 28, top: 6, bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<int>(
                                    initialValue: keepId,
                                    decoration: const InputDecoration(
                                      labelText: 'Equipo que conserva la IP actual',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                    items: involved.map((a) {
                                      return DropdownMenuItem<int>(
                                        value: a['id'] as int,
                                        child: Text('[${a['code']}] ${a['name']}'),
                                      );
                                    }).toList(),
                                    onChanged: (v) {
                                      if (v != null) {
                                        setModalState(() {
                                          keepId = v;
                                          otherId = involved
                                              .firstWhere((a) => a['id'] != v)['id']
                                              as int;
                                        });
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: newIpCtrl,
                              decoration: InputDecoration(
                                labelText:
                                    'Nueva IP para [${otherObj['code']}] (dejar vacío para liberar su IP)',
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        action == 'delete_other'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: AppPalette.red700,
                      ),
                      title: Text(
                        '3. Eliminar directamente el registro duplicado [${otherObj['code']}]',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: AppPalette.red700,
                        ),
                      ),
                      onTap: () => setModalState(() => action = 'delete_other'),
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
                style: FilledButton.styleFrom(
                  backgroundColor: AppPalette.green700,
                ),
                onPressed: saving
                    ? null
                    : () async {
                        setModalState(() => saving = true);
                        try {
                          final updated =
                              await widget.api.resolveCmdbIpCollision({
                            'ip_address': ipAddr,
                            'action': action,
                            'keep_asset_id': keepId,
                            'other_asset_id': otherId,
                            'new_ip_for_other': newIpCtrl.text.trim(),
                            'preferred_name': nameCtrl.text.trim(),
                            'preferred_hostname': hostCtrl.text.trim(),
                            'preferred_fqdn': fqdnCtrl.text.trim(),
                          });
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          if (!mounted) return;
                          setState(() => _overview = updated);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              backgroundColor: AppPalette.green700,
                              content: Text(
                                '✓ Colisión en IP $ipAddr resuelta y datos alineados entre Rack Editor y CMDB.',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          );
                        } catch (e) {
                          if (!ctx.mounted) return;
                          setModalState(() => saving = false);
                          ScaffoldMessenger.of(ctx).aviso('Error resolviendo colisión: $e');
                        }
                      },
                icon: const Icon(Icons.check_circle_outline, size: 16),
                label: const Text('Aplicar Solución Ahora'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildInventoryTab() {
    final items = _filteredAssets;
    final allVisibleSelected = items.isNotEmpty &&
        items.every((a) => _selectedInventoryAssetIds.contains(a['id'] as int));

    return Column(
      children: [
        _buildIpCollisionsAlertBanner(),
        // Barra superior de búsqueda universal, filtros y acciones en lote (estilo Excel)
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: AppPalette.slate300)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: SizedBox(
                      height: 36,
                      child: TextField(
                        controller: _searchCtrl,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(fontSize: 12.5),
                        decoration: InputDecoration(
                          hintText:
                              'Buscar por cualquier dato (Código, Nombre, IP, Máscara 255.255..., Sede/Location, Rack, Stack, MAC, VLAN, SO, Notas)...',
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
                            vertical: 6,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(7),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    selected: _onlyMultiIp,
                    visualDensity: VisualDensity.compact,
                    label: const Text(
                      'Multi-IP (>1 IP)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onSelected: (v) => setState(() => _onlyMultiIp = v),
                  ),
                  const SizedBox(width: 8),
                  // Selector de Sede / Location
                  DropdownButtonHideUnderline(
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        border: Border.all(color: AppPalette.slate300),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: DropdownButton<int?>(
                        value: _locationFilter,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppPalette.slate900,
                          fontWeight: FontWeight.w700,
                        ),
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text('Sede (Location): Todas'),
                          ),
                          const DropdownMenuItem<int?>(
                            value: -1,
                            child: Text('Sin Sede Asignada'),
                          ),
                          ..._locations.map((loc) {
                            return DropdownMenuItem<int?>(
                              value: loc['id'] as int,
                              child: Text(
                                'Sede: ${loc['code']} (${loc['name']})',
                              ),
                            );
                          }),
                        ],
                        onChanged: (v) => setState(() => _locationFilter = v),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButtonHideUnderline(
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        border: Border.all(color: AppPalette.slate300),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: DropdownButton<String>(
                        value: _envFilter,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppPalette.slate900,
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
                  if (widget.canEdit && _selectedInventoryAssetIds.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed: _deleteSelectedInventoryAssets,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppPalette.red600,
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.delete_sweep_rounded, size: 16),
                      label: Text(
                        'Eliminar y Liberar IPs (${_selectedInventoryAssetIds.length})',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _buildClassFilterPill(
                            'all',
                            'Todos (${_assets.length})',
                          ),
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
                          _buildClassFilterPill(
                            'other_machine',
                            'Otros Equipos Detectados',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Mostrando ${items.length} de ${_assets.length} filas • Clic en cualquier cabecera para ordenar ▲▼',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppPalette.slate600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        // Cabecera fija estilo Hoja de Cálculo Excel
        Container(
          decoration: const BoxDecoration(
            color: AppPalette.slate200,
            border: Border(
              bottom: BorderSide(color: AppPalette.slate400, width: 1.5),
            ),
          ),
          child: Row(
            children: [
              if (widget.canEdit)
                Container(
                  width: 34,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    border: Border(right: BorderSide(color: AppPalette.slate300)),
                  ),
                  child: Checkbox(
                    value: allVisibleSelected,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          for (final a in items) {
                            _selectedInventoryAssetIds.add(a['id'] as int);
                          }
                        } else {
                          _selectedInventoryAssetIds.clear();
                        }
                      });
                    },
                  ),
                ),
              _buildExcelSortableHeaderCell('#', null, width: 34),
              _buildExcelSortableHeaderCell(
                'Heartbeat / Ping',
                'status',
                width: 116,
              ),
              _buildExcelSortableHeaderCell('Código', 'code', width: 108),
              _buildExcelSortableHeaderCell(
                'IP Principal (Gestión)',
                'primary_ip',
                width: 142,
              ),
              _buildExcelSortableHeaderCell(
                'Máscara de Red',
                'subnet_mask',
                width: 118,
              ),
              _buildExcelSortableHeaderCell(
                'Sede / Location',
                'site_location',
                flex: 12,
              ),
              _buildExcelSortableHeaderCell(
                'Nombre del Equipo',
                'name',
                flex: 15,
              ),
              _buildExcelSortableHeaderCell(
                'Hostname / FQDN',
                'hostname',
                flex: 13,
              ),
              _buildExcelSortableHeaderCell(
                'MAC / VLAN / +IPs',
                'mac_vlan',
                flex: 12,
              ),
              _buildExcelSortableHeaderCell(
                'Clase / Tipo',
                'asset_class',
                flex: 11,
              ),
              _buildExcelSortableHeaderCell(
                'Posición Rack / Stack',
                'location',
                flex: 16,
              ),
              _buildExcelSortableHeaderCell(
                'SO / Firmware',
                'os_or_firmware',
                flex: 12,
              ),
              _buildExcelSortableHeaderCell(
                'Acciones',
                null,
                width: widget.canEdit ? 174 : 84,
              ),
            ],
          ),
        ),
        // Cuerpo de filas estilo Excel con líneas de cuadrícula
        Expanded(
          child: items.isEmpty
              ? const Center(
                  child: Text(
                    'No hay equipos o activos en la CMDB que coincidan con la búsqueda o filtro actual.',
                    style: TextStyle(color: AppPalette.slate500, fontSize: 13),
                  ),
                )
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (ctx, idx) =>
                      _buildExcelAssetRow(items[idx], idx),
                ),
        ),
      ],
    );
  }

  Widget _buildExcelSortableHeaderCell(
    String label,
    String? colKey, {
    double? width,
    int? flex,
  }) {
    final bool isSorted = colKey != null && _sortColumn == colKey;
    final Widget content = InkWell(
      onTap: colKey != null ? () => _onSortInventoryBy(colKey) : null,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: isSorted ? AppPalette.blue100 : Colors.transparent,
          border: const Border(right: BorderSide(color: AppPalette.slate300)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  color: isSorted
                      ? AppPalette.blue900
                      : AppPalette.slate800,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (colKey != null)
              Icon(
                isSorted
                    ? (_sortAscending
                        ? Icons.arrow_drop_up_rounded
                        : Icons.arrow_drop_down_rounded)
                    : Icons.unfold_more_rounded,
                size: isSorted ? 18 : 13,
                color: isSorted
                    ? AppPalette.blue900
                    : AppPalette.slate500,
              ),
          ],
        ),
      ),
    );
    if (width != null) {
      return SizedBox(width: width, child: content);
    }
    return Expanded(flex: flex ?? 10, child: content);
  }

  Widget _buildExcelBodyCell(
    Widget child, {
    double? width,
    int? flex,
    Alignment alignment = Alignment.centerLeft,
  }) {
    final cell = Container(
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      alignment: alignment,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: AppPalette.slate200)),
      ),
      child: child,
    );
    if (width != null) {
      return SizedBox(width: width, child: cell);
    }
    return Expanded(flex: flex ?? 10, child: cell);
  }

  Widget _buildExcelAssetRow(Map<String, dynamic> asset, int rowIndex) {
    final int assetId = asset['id'] as int;
    final String code = (asset['code'] ?? '').toString();
    final String name = (asset['name'] ?? '').toString();
    final String hostname = (asset['hostname'] ?? '').toString();
    final String fqdn = (asset['fqdn'] ?? '').toString();
    final String assetClass = (asset['asset_class'] ?? '').toString();
    final String classLabel =
        (asset['asset_class_label'] ?? _assetClassLabels[assetClass] ?? assetClass)
            .toString();
    final String status = (asset['status'] ?? 'unmonitored').toString();
    final bool hbEnabled = asset['monitoring_enabled'] ?? true;
    final double? pingMs = (asset['last_ping_ms'] as num?)?.toDouble();
    final List<Map<String, dynamic>> ips = ((asset['ip_addresses'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final String primaryIp = _primaryIpOfAsset(asset);
    final String primaryMask = _primaryMaskOfAsset(asset);
    final String primaryMac = _primaryMacOfAsset(asset);
    final String primaryVlan = _primaryVlanOfAsset(asset);
    final int extraIpsCount = ips.length > 1 ? ips.length - 1 : 0;
    final bool hasIpCollision = asset['has_ip_collision'] == true;

    final String os = (asset['os_or_firmware'] ?? '-').toString();
    final String siteLocLabel = (asset['location_label'] ?? '').toString();
    final String locLabel =
        (asset['physical_location_label'] ?? asset['hypervisor_or_platform'] ?? '-')
            .toString();
    final int? rackId = asset['rack_id'] as int?;
    final int? rackDevId =
        (asset['rack_device_id'] as int?) ?? (asset['host_rack_device_id'] as int?);
    final int? floorId = asset['floor_id'] as int?;
    final int? floorDeviceId = asset['floor_device_id'] as int?;
    final int? assetLocId = asset['location_id'] as int?;
    final int? stackDiagramId = asset['primary_stack_diagram_id'] as int?;
    final int? stackNodeId = asset['primary_stack_node_id'] as int?;
    final String stackLabel = (asset['primary_stack_label'] ?? '').toString();

    final bool isExpanded = _expandedAssetId == assetId;
    final bool isHighlighted = _highlightedAssetId == assetId;
    final bool isSelected = _selectedInventoryAssetIds.contains(assetId);
    final Color badgeColor = _classBadgeColor(assetClass);

    Color statusColor = AppPalette.slate500;
    String statusText = hbEnabled ? 'PEND.' : 'HB OFF';
    if (!hbEnabled) {
      statusColor = AppPalette.slate500;
      statusText = 'HB OFF';
    } else if (status == 'online') {
      statusColor = AppPalette.green600;
      statusText =
          'ONLINE${pingMs != null ? ' ${pingMs.toStringAsFixed(0)}ms' : ''}';
    } else if (status == 'offline') {
      statusColor = AppPalette.red600;
      statusText = 'OFFLINE';
    } else if (status == 'warning') {
      statusColor = AppPalette.amber600;
      statusText = 'WARN';
    }

    final Color rowBg = hasIpCollision
        ? AppPalette.red50
        : isHighlighted
            ? const Color(0xFFFEF9C3)
            : isSelected
                ? AppPalette.sky100
                : isExpanded
                    ? AppPalette.sky50
                    : (rowIndex.isEven ? Colors.white : AppPalette.slate50);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              _highlightedAssetId = assetId;
              _expandedAssetId = isExpanded ? null : assetId;
            });
          },
          child: Container(
            decoration: BoxDecoration(
              color: rowBg,
              border: Border(
                bottom: BorderSide(
                  color: hasIpCollision
                      ? const Color(0xFFF87171)
                      : isHighlighted
                          ? const Color(0xFFEAB308)
                          : AppPalette.slate300,
                  width: (hasIpCollision || isHighlighted) ? 1.5 : 0.8,
                ),
              ),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.canEdit)
                    Container(
                      width: 34,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        border: Border(
                          right: BorderSide(color: AppPalette.slate200),
                        ),
                      ),
                      child: Checkbox(
                        value: isSelected,
                        visualDensity: VisualDensity.compact,
                        onChanged: (v) {
                          setState(() {
                            if (v == true) {
                              _selectedInventoryAssetIds.add(assetId);
                            } else {
                              _selectedInventoryAssetIds.remove(assetId);
                            }
                          });
                        },
                      ),
                    ),
                  _buildExcelBodyCell(
                    Text(
                      '${rowIndex + 1}',
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontFamily: 'monospace',
                        color: AppPalette.slate500,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    width: 34,
                    alignment: Alignment.center,
                  ),
                  _buildExcelBodyCell(
                    InkWell(
                      onTap: widget.canEdit
                          ? () => _toggleAssetHeartbeatMonitoring(asset)
                          : null,
                      child: Tooltip(
                        message: widget.canEdit
                            ? (hbEnabled
                                ? 'Heartbeat ACTIVO (${asset['monitor_method'] ?? 'icmp'}). Clic para desactivar Heartbeat'
                                : 'Heartbeat DESACTIVADO. Clic para activar Heartbeat')
                            : statusText,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: statusColor.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                hbEnabled
                                    ? Icons.monitor_heart_rounded
                                    : Icons.heart_broken_outlined,
                                size: 11,
                                color: statusColor,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  statusText,
                                  style: TextStyle(
                                    fontSize: 9.8,
                                    fontWeight: FontWeight.w900,
                                    color: statusColor,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    width: 116,
                  ),
                  _buildExcelBodyCell(
                    SelectableText(
                      code,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        fontFamily: 'monospace',
                        color: AppPalette.slate900,
                      ),
                    ),
                    width: 108,
                  ),
                  _buildExcelBodyCell(
                    primaryIp.isEmpty
                        ? const Text(
                            'Sin IP',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppPalette.slate400,
                            ),
                          )
                        : Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  onTap: () => _jumpToIpInIpamMap(primaryIp),
                                  child: Row(
                                    children: [
                                      Icon(
                                        hasIpCollision
                                            ? Icons.warning_amber_rounded
                                            : Icons.lan_outlined,
                                        size: 13,
                                        color: hasIpCollision
                                            ? AppPalette.red700
                                            : AppPalette.sky600,
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          primaryIp,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w900,
                                            fontFamily: 'monospace',
                                            color: hasIpCollision
                                                ? AppPalette.red700
                                                : AppPalette.sky700,
                                            decoration:
                                                TextDecoration.underline,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (hasIpCollision && widget.canEdit)
                                Tooltip(
                                  message:
                                      'Colisión de IP detectada. Pulsa para unificar o resolver.',
                                  child: InkWell(
                                    onTap: () {
                                      final col = _ipCollisions.firstWhere(
                                        (c) => c['ip_address'] == primaryIp,
                                        orElse: () => _ipCollisions.first,
                                      );
                                      _openResolveCollisionDialog(col);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppPalette.red700,
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                      child: const Text(
                                        'UNIFICAR',
                                        style: TextStyle(
                                          fontSize: 8.5,
                                          fontWeight: FontWeight.w900,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                    width: 142,
                  ),
                  _buildExcelBodyCell(
                    Text(
                      primaryMask.isEmpty ? '-' : primaryMask,
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                        color: AppPalette.slate700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    width: 118,
                  ),
                  _buildExcelBodyCell(
                    siteLocLabel.isEmpty
                        ? const Text(
                            'Sin Sede',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: AppPalette.slate400,
                            ),
                          )
                        : Row(
                            children: [
                              const Icon(
                                Icons.location_on_outlined,
                                size: 13,
                                color: AppPalette.teal700,
                              ),
                              const SizedBox(width: 3),
                              Expanded(
                                child: Text(
                                  siteLocLabel,
                                  style: const TextStyle(
                                    fontSize: 10.8,
                                    fontWeight: FontWeight.w800,
                                    color: AppPalette.teal700,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                    flex: 12,
                  ),
                  _buildExcelBodyCell(
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: AppPalette.slate800,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    flex: 15,
                  ),
                  _buildExcelBodyCell(
                    Text(
                      fqdn.isNotEmpty
                          ? fqdn
                          : (hostname.isNotEmpty ? hostname : '-'),
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: AppPalette.slate700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    flex: 13,
                  ),
                  _buildExcelBodyCell(
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            [
                              if (primaryMac.isNotEmpty) primaryMac,
                              if (primaryVlan.isNotEmpty) primaryVlan,
                            ].join(' • ').isEmpty
                                ? '-'
                                : [
                                    if (primaryMac.isNotEmpty) primaryMac,
                                    if (primaryVlan.isNotEmpty) primaryVlan,
                                  ].join(' • '),
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontFamily: 'monospace',
                              color: AppPalette.slate600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (extraIpsCount > 0)
                          Container(
                            margin: const EdgeInsets.only(left: 4),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: AppPalette.blue100,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '+$extraIpsCount IP',
                              style: const TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w900,
                                color: AppPalette.blue900,
                              ),
                            ),
                          ),
                      ],
                    ),
                    flex: 12,
                  ),
                  _buildExcelBodyCell(
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        classLabel,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: badgeColor,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    flex: 11,
                  ),
                  // Columna con enlaces directos a Posición de Rack (si tiene) y Posición de Stack Tecnológico (si tiene)
                  _buildExcelBodyCell(
                    Wrap(
                      spacing: 4,
                      runSpacing: 3,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (rackId != null &&
                            widget.onNavigateToRackDevice != null)
                          InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () => widget.onNavigateToRackDevice!(
                              rackId,
                              rackDevId,
                            ),
                            child: Tooltip(
                              message:
                                  'Ir a la posición en el Rack Editor ($locLabel)',
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppPalette.sky100,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: const Color(0xFF7DD3FC),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.developer_board_rounded,
                                      size: 12,
                                      color: AppPalette.sky700,
                                    ),
                                    const SizedBox(width: 3),
                                    Flexible(
                                      child: Text(
                                        locLabel,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w900,
                                          color: AppPalette.sky700,
                                          decoration: TextDecoration.underline,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          )
                        else if (floorDeviceId != null &&
                            floorId != null &&
                            widget.onNavigateToFloorDevice != null)
                          InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () => widget.onNavigateToFloorDevice!(
                              assetLocId,
                              floorId,
                              floorDeviceId,
                            ),
                            child: Tooltip(
                              message:
                                  'Ir a la posición en Datacenter / Planta ($locLabel)',
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFDCFCE7),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: const Color(0xFF86EFAC),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.location_on_rounded,
                                      size: 12,
                                      color: Color(0xFF15803D),
                                    ),
                                    const SizedBox(width: 3),
                                    Flexible(
                                      child: Text(
                                        locLabel,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w900,
                                          color: Color(0xFF15803D),
                                          decoration: TextDecoration.underline,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          )
                        else if (stackDiagramId == null)
                          Text(
                            locLabel,
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: AppPalette.slate500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (stackDiagramId != null &&
                            widget.onNavigateToStackNode != null)
                          InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () => widget.onNavigateToStackNode!(
                              stackDiagramId,
                              stackNodeId,
                            ),
                            child: Tooltip(
                              message:
                                  'Ir a la posición en el Stack Tecnológico ($stackLabel)',
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF3E8FF),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: const Color(0xFFD8B4FE),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.layers_rounded,
                                      size: 12,
                                      color: Color(0xFF7E22CE),
                                    ),
                                    const SizedBox(width: 3),
                                    Flexible(
                                      child: Text(
                                        'Stack: $stackLabel',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w900,
                                          color: Color(0xFF7E22CE),
                                          decoration: TextDecoration.underline,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    flex: 16,
                  ),
                  _buildExcelBodyCell(
                    Text(
                      os,
                      style: const TextStyle(
                        fontSize: 10.8,
                        color: AppPalette.slate700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    flex: 12,
                  ),
                  _buildExcelBodyCell(
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Comprobar Heartbeat ahora',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 26,
                            minHeight: 26,
                          ),
                          onPressed: _runningHeartbeatAssetId == assetId
                              ? null
                              : () => _triggerAssetHeartbeat(asset),
                          icon: _runningHeartbeatAssetId == assetId
                              ? const SizedBox(
                                  width: 13,
                                  height: 13,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.network_ping_rounded,
                                  size: 16,
                                  color: AppPalette.sky600,
                                ),
                        ),
                        if (widget.canEdit) ...[
                          IconButton(
                            tooltip: hbEnabled
                                ? 'Heartbeat Activo (Clic para desactivar)'
                                : 'Heartbeat Desactivado (Clic para activar)',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 26,
                              minHeight: 26,
                            ),
                            onPressed: () =>
                                _toggleAssetHeartbeatMonitoring(asset),
                            icon: Icon(
                              hbEnabled
                                  ? Icons.favorite_rounded
                                  : Icons.heart_broken_outlined,
                              size: 15,
                              color: hbEnabled
                                  ? AppPalette.green600
                                  : AppPalette.slate400,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Añadir otra IP a este equipo',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 26,
                              minHeight: 26,
                            ),
                            onPressed: () => _openAddSingleIpDialog(asset),
                            icon: const Icon(
                              Icons.add_link_rounded,
                              size: 16,
                              color: AppPalette.green700,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Editar equipo, IPs, Máscara, Sede y Heartbeat',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 26,
                              minHeight: 26,
                            ),
                            onPressed: () =>
                                _openAssetEditorDialog(existing: asset),
                            icon: const Icon(
                              Icons.edit_outlined,
                              size: 16,
                              color: AppPalette.blue900,
                            ),
                          ),
                          IconButton(
                            tooltip:
                                'Eliminar equipo de la CMDB y dejar su IP libre (no ocupada)',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 26,
                              minHeight: 26,
                            ),
                            onPressed: () => _confirmDeleteAsset(asset),
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 16,
                              color: AppPalette.red600,
                            ),
                          ),
                        ],
                        IconButton(
                          tooltip: isExpanded
                              ? 'Ocultar desglose de interfaces IP'
                              : 'Desplegar todas las IPs y detalles',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 26,
                            minHeight: 26,
                          ),
                          onPressed: () => setState(
                            () => _expandedAssetId = isExpanded ? null : assetId,
                          ),
                          icon: Icon(
                            isExpanded
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                            size: 17,
                          ),
                        ),
                      ],
                    ),
                    width: widget.canEdit ? 174 : 84,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (isExpanded)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: const BoxDecoration(
              color: AppPalette.slate50,
              border: Border(
                bottom: BorderSide(color: AppPalette.slate400, width: 1.2),
              ),
            ),
            child: _buildExpandedIpTableForAsset(asset, ips),
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
            color: active ? Colors.white : AppPalette.slate700,
          ),
        ),
        selectedColor: AppPalette.blue900,
        backgroundColor: AppPalette.slate100,
        onSelected: (_) => setState(() => _classFilter = key),
      ),
    );
  }

  Color _classBadgeColor(String assetClass) {
    switch (assetClass) {
      case 'virtual_machine':
      case 'virtual_appliance':
        return AppPalette.violet600;
      case 'container_lxc':
        return AppPalette.sky600;
      case 'cluster_vip':
        return AppPalette.amber600;
      case 'cloud_instance':
        return AppPalette.indigo600;
      case 'physical_server':
        return AppPalette.teal700;
      case 'network_security':
        return AppPalette.blue900;
      case 'storage_san_nas':
        return const Color(0xFF9333EA);
      default:
        return AppPalette.slate600;
    }
  }

  Color _ipRoleColor(String role) {
    switch (role) {
      case 'mgmt_heartbeat':
        return AppPalette.sky600;
      case 'ilo_idrac':
        return AppPalette.violet600;
      case 'primary_service':
        return AppPalette.green700;
      case 'secondary_service':
        return AppPalette.teal600;
      case 'vip_cluster':
        return AppPalette.amber600;
      case 'storage':
      case 'backup':
      case 'vmotion_replication':
        return AppPalette.indigo600;
      case 'public_wan':
        return const Color(0xFFBE123C);
      default:
        return AppPalette.slate600;
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

    Color statusColor = AppPalette.slate500;
    String statusText = 'SIN MONITORIZAR';
    if (status == 'online') {
      statusColor = AppPalette.green600;
      statusText =
          'ONLINE${pingMs != null ? ' (${pingMs.toStringAsFixed(1)} ms)' : ''}';
    } else if (status == 'offline') {
      statusColor = AppPalette.red600;
      statusText = 'CAÍDO / OFFLINE';
    } else if (status == 'warning') {
      statusColor = AppPalette.amber600;
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
              ? AppPalette.sky400
              : AppPalette.slate200,
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
                        : AppPalette.sky100,
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
                          : AppPalette.sky700,
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
                              color: AppPalette.slate900,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              name,
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: AppPalette.slate800,
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
                                color: AppPalette.slate600,
                              ),
                            ),
                          if (fqdn.isNotEmpty)
                            Text(
                              'FQDN: $fqdn',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: AppPalette.sky700,
                              ),
                            ),
                          if (os.isNotEmpty)
                            Text(
                              'SO/FW: $os',
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: AppPalette.slate600,
                              ),
                            ),
                          if (cores > 0 || ramGb > 0)
                            Text(
                              'Recursos: ${cores}vCPU • ${ramGb.toStringAsFixed(0)}GB RAM${storageGb > 0 ? ' • ${storageGb.toStringAsFixed(0)}GB Disco' : ''}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: AppPalette.slate700,
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
                          color: AppPalette.sky600,
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
                        color: AppPalette.slate500,
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
                      color: AppPalette.green700,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Editar máquina y sus múltiples IPs',
                    onPressed: () => _openAssetEditorDialog(existing: asset),
                    icon: const Icon(
                      Icons.edit_outlined,
                      size: 18,
                      color: AppPalette.blue900,
                    ),
                  ),
                  if (syncSource == 'cmdb')
                    IconButton(
                      tooltip: 'Eliminar máquina de la CMDB',
                      onPressed: () => _confirmDeleteAsset(asset),
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        size: 18,
                        color: AppPalette.red600,
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
                      color: AppPalette.blue900,
                    ),
                    label: const Text(
                      'Añadir IP (Servicio / VIP / Backup)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.blue900,
                      ),
                    ),
                    backgroundColor: AppPalette.blue50,
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
                    color: AppPalette.slate600,
                  ),
                ),
              ],
              const SizedBox(width: 5),
              Text(
                '($iface)',
                style: const TextStyle(
                  fontSize: 10,
                  color: AppPalette.slate500,
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
    final int? rackId = asset['rack_id'] as int?;
    final int? rackDevId =
        (asset['rack_device_id'] as int?) ?? (asset['host_rack_device_id'] as int?);
    final int? floorId = asset['floor_id'] as int?;
    final int? floorDeviceId = asset['floor_device_id'] as int?;
    final int? assetLocId = asset['location_id'] as int?;
    final int? stackDiagramId = asset['primary_stack_diagram_id'] as int?;
    final int? stackNodeId = asset['primary_stack_node_id'] as int?;
    final String stackLabel = (asset['primary_stack_label'] ?? '').toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Icon(
              Icons.settings_ethernet_rounded,
              size: 16,
              color: AppPalette.blue900,
            ),
            Text(
              'Desglose de Interfaces de Red e IPs de ${asset['code']} (${ips.length} IPs configuradas)',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: AppPalette.slate900,
              ),
            ),
            if ((asset['location_label'] ?? '').toString().isNotEmpty)
              Chip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(
                  Icons.location_on_rounded,
                  size: 14,
                  color: AppPalette.teal700,
                ),
                label: Text(
                  'Sede: ${asset['location_label']}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: AppPalette.teal700,
                  ),
                ),
              ),
            if (rackId != null && widget.onNavigateToRackDevice != null)
              ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(
                  Icons.developer_board_rounded,
                  size: 14,
                  color: AppPalette.sky700,
                ),
                label: Text(
                  'Ir al Rack: ${asset['physical_location_label']}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: AppPalette.sky700,
                  ),
                ),
                onPressed: () =>
                    widget.onNavigateToRackDevice!(rackId, rackDevId),
              ),
            if (floorDeviceId != null &&
                floorId != null &&
                widget.onNavigateToFloorDevice != null)
              ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(
                  Icons.location_on_rounded,
                  size: 14,
                  color: Color(0xFF15803D),
                ),
                label: Text(
                  'Ir a Planta: ${asset['physical_location_label']}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF15803D),
                  ),
                ),
                onPressed: () => widget.onNavigateToFloorDevice!(
                  assetLocId,
                  floorId,
                  floorDeviceId,
                ),
              ),
            if (stackDiagramId != null && widget.onNavigateToStackNode != null)
              ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(
                  Icons.layers_rounded,
                  size: 14,
                  color: Color(0xFF7E22CE),
                ),
                label: Text(
                  'Ir al Stack: $stackLabel',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF7E22CE),
                  ),
                ),
                onPressed: () =>
                    widget.onNavigateToStackNode!(stackDiagramId, stackNodeId),
              ),
            Text(
              'Propietario: ${asset['owner_team'] ?? '-'} • Resp: ${asset['responsible_person'] ?? '-'}',
              style: const TextStyle(fontSize: 11, color: AppPalette.slate500),
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
              color: AppPalette.slate600,
            ),
          ),
        ],
        const SizedBox(height: 8),
        Table(
          border: TableBorder.all(color: AppPalette.slate200),
          columnWidths: const {
            0: FlexColumnWidth(1.3),
            1: FlexColumnWidth(1.2),
            2: FlexColumnWidth(1.0),
            3: FlexColumnWidth(1.6),
            4: FlexColumnWidth(0.7),
            5: FlexColumnWidth(1.4),
            6: FlexColumnWidth(1.2),
            7: FlexColumnWidth(1.5),
            8: IntrinsicColumnWidth(),
          },
          children: [
            const TableRow(
              decoration: BoxDecoration(color: AppPalette.slate100),
              children: [
                _TableHeaderCell('Dirección IP'),
                _TableHeaderCell('Máscara de Red'),
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
              final mask = (ip['subnet_mask'] ?? '255.255.255.0').toString();
              final isHb = ip['is_heartbeat_ip'] == true;
              return TableRow(
                children: [
                  _TableBodyCell(
                    addr,
                    mono: true,
                    bold: true,
                  ),
                  _TableBodyCell(
                    mask,
                    mono: true,
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
                        if (widget.canEdit)
                          IconButton(
                            tooltip:
                                'Editar IP, Máscara de Red, Rol y Heartbeat',
                            icon: const Icon(
                              Icons.edit_outlined,
                              size: 15,
                              color: AppPalette.blue900,
                            ),
                            onPressed: () =>
                                _openAssetEditorDialog(existing: asset),
                          ),
                        IconButton(
                          tooltip: 'Copiar IP $addr',
                          icon: const Icon(Icons.copy, size: 15),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: addr));
                            ScaffoldMessenger.of(context).aviso('IP $addr copiada al portapapeles');
                          },
                        ),
                        IconButton(
                          tooltip: 'Sondear esta IP en el Verificador Manual',
                          icon: const Icon(
                            Icons.radar_rounded,
                            size: 16,
                            color: AppPalette.sky600,
                          ),
                          onPressed: () {
                            _verifyIpCtrl.text = addr;
                            setState(() => _activeTab = 'verifier');
                            _runManualVerification(customIp: addr);
                          },
                        ),
                        if (widget.canEdit && ipId != null)
                          IconButton(
                            tooltip:
                                'Liberar esta IP (dejar como NO OCUPADA en el mapa IPAM)',
                            icon: const Icon(
                              Icons.link_off_rounded,
                              size: 16,
                              color: Colors.redAccent,
                            ),
                            onPressed: () async {
                              await widget.api.deleteCmdbIp(ipId);
                              await _loadOverview(silent: true);
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  backgroundColor: AppPalette.green700,
                                  content: Text(
                                    'IP $addr liberada (marcada como No Ocupada en el mapa IPAM).',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              );
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

    final int detectedOrCmdbCount =
        conflictCount + activeInCmdbCount + noResponseCount;

    final filteredResults = allResults.where((r) {
      if (_scanResultFilter == 'all') return true;
      if (_scanResultFilter == 'detected_or_cmdb') {
        return (r['verdict'] ?? '').toString() != 'free_confirmed';
      }
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
              border: Border.all(color: AppPalette.slate300),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.verified_user_rounded,
                      color: AppPalette.sky600,
                      size: 22,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Escáner y Verificador Manual de IPs, Rangos y Redes CIDR (ej. 1.1.1.1/24) con Incorporación Selectiva a la CMDB',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: AppPalette.slate900,
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
                    color: AppPalette.slate600,
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
                        backgroundColor: AppPalette.slate900,
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
                      color: AppPalette.slate200,
                    ),
                    const SizedBox(width: 8),
                    DropdownButtonHideUnderline(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppPalette.slate50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppPalette.slate300),
                        ),
                        child: DropdownButton<int>(
                          value: _verifySelectedSubnetId,
                          hint: const Text('Seleccionar Subred VLAN'),
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppPalette.slate900,
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
                        backgroundColor: AppPalette.green100,
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
                      color: AppPalette.red50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppPalette.red200),
                    ),
                    child: Text(
                      'Error: $_verifyError',
                      style: const TextStyle(
                        color: AppPalette.red700,
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
                      color: AppPalette.green50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppPalette.green300),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle_rounded,
                          color: AppPalette.green700,
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
                              backgroundColor: AppPalette.green700,
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
                          color: AppPalette.slate900,
                        ),
                      ),
                      _buildScanFilterChip(
                        'detected_or_cmdb',
                        'Equipos Detectados / En CMDB ($detectedOrCmdbCount)',
                        AppPalette.slate900,
                      ),
                      _buildScanFilterChip(
                        'conflict_unregistered',
                        'Detectados NO en CMDB - Rojo ($conflictCount)',
                        AppPalette.red700,
                      ),
                      _buildScanFilterChip(
                        'active_in_network',
                        'En CMDB y Activos - Verde ($activeInCmdbCount)',
                        AppPalette.green700,
                      ),
                      _buildScanFilterChip(
                        'no_response',
                        'En CMDB Sin Respuesta ($noResponseCount)',
                        AppPalette.amber700,
                      ),
                      _buildScanFilterChip(
                        'free_confirmed',
                        'IPs Libres / No Ocupadas ($freeCount)',
                        AppPalette.sky600,
                      ),
                      _buildScanFilterChip(
                        'all',
                        'Ver Rango Completo (${allResults.length})',
                        AppPalette.slate600,
                      ),
                    ],
                  ),
                  if (widget.canEdit) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppPalette.slate50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppPalette.slate300),
                      ),
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Icon(
                            Icons.playlist_add_check_rounded,
                            color: AppPalette.blue900,
                          ),
                          Text(
                            'Seleccionados para añadir a CMDB: ${_selectedDiscoveredIps.length}',
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w900,
                              color: AppPalette.slate900,
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
                                  color: AppPalette.slate300,
                                ),
                              ),
                              child: DropdownButton<String>(
                                value: _bulkImportAssetClass,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppPalette.slate900,
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
                                  color: AppPalette.slate300,
                                ),
                              ),
                              child: DropdownButton<int?>(
                                value: _locations.any(
                                          (l) =>
                                              l['id'] == _bulkImportLocationId,
                                        )
                                    ? _bulkImportLocationId
                                    : null,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppPalette.slate900,
                                ),
                                items: [
                                  const DropdownMenuItem<int?>(
                                    value: null,
                                    child: Text(
                                      'Sede (Location): Sin Sede específica',
                                    ),
                                  ),
                                  ..._locations.map((loc) {
                                    return DropdownMenuItem<int?>(
                                      value: loc['id'] as int,
                                      child: Text(
                                        'Sede: ${loc['code']} (${loc['name']})',
                                      ),
                                    );
                                  }),
                                ],
                                onChanged: (v) =>
                                    setState(() => _bulkImportLocationId = v),
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
                              backgroundColor: AppPalette.blue900,
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
                border: Border.all(color: AppPalette.slate200),
              ),
              child: const Column(
                children: [
                  Icon(
                    Icons.network_check_rounded,
                    size: 46,
                    color: AppPalette.slate400,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Introduce una IP, rango o red CIDR (ej. 1.1.1.1/24 o 10.20.20.0/24) y pulsa "Analizar IP / Rango CIDR Ahora".',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppPalette.slate500,
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

    // Por defecto (free_confirmed): azul/pizarra informativo (IP libre, sin equipo en red)
    Color borderCol = AppPalette.sky200;
    Color headerBg = AppPalette.sky50;
    Color badgeCol = AppPalette.sky600;
    IconData vIcon = Icons.check_circle_outline_rounded;

    if (verdict == 'conflict_unregistered') {
      // ROJO: Dispositivo detectado en red pendiente de añadir a CMDB
      borderCol = AppPalette.red300;
      headerBg = AppPalette.red50;
      badgeCol = AppPalette.red700;
      vIcon = Icons.warning_amber_rounded;
    } else if (verdict == 'active_in_network') {
      // VERDE: Dispositivo añadido a la CMDB y activo en red
      borderCol = AppPalette.green300;
      headerBg = AppPalette.green50;
      badgeCol = AppPalette.green700;
      vIcon = Icons.check_circle_rounded;
    } else if (verdict == 'no_response') {
      borderCol = AppPalette.amber300;
      headerBg = AppPalette.amber50;
      badgeCol = AppPalette.amber700;
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
                if (widget.canEdit &&
                    !documentedInCmdb &&
                    verdict == 'conflict_unregistered')
                  Checkbox(
                    value: isSelectedForImport,
                    activeColor: AppPalette.blue900,
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
                    color: AppPalette.slate600,
                  ),
                ),
                if (widget.canEdit &&
                    !documentedInCmdb &&
                    verdict == 'conflict_unregistered') ...[
                  FilledButton.icon(
                    onPressed: _importingDiscovered
                        ? null
                        : () async {
                            await _importSelectedDiscoveredToCmdb(
                              [r],
                              forceDirectRows: true,
                            );
                          },
                    style: FilledButton.styleFrom(
                      backgroundColor: AppPalette.red700,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.add_task_rounded, size: 15),
                    label: const Text(
                      'Añadir a CMDB (Pasa a Verde)',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
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
                ] else if (widget.canEdit &&
                    !documentedInCmdb &&
                    verdict == 'free_confirmed') ...[
                  OutlinedButton.icon(
                    onPressed: () => _openAssetEditorDialog(prefilledIp: ip),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.add_box_outlined, size: 15),
                    label: const Text(
                      'Asignar IP Libre a Nueva VM/Host',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                ] else if (documentedInCmdb && owners.isNotEmpty) ...[
                  OutlinedButton.icon(
                    onPressed: () {
                      final aid = owners.first['asset_id'] as int?;
                      setState(() {
                        _activeTab = 'inventory';
                        if (aid != null) {
                          _highlightedAssetId = aid;
                          _expandedAssetId = aid;
                        }
                      });
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppPalette.green700,
                      side: const BorderSide(color: AppPalette.green300),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.table_chart_outlined, size: 15),
                    label: const Text(
                      'Ver en Inventario CMDB',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
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
                    foregroundColor: AppPalette.slate500,
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.close_rounded, size: 15),
                  label: const Text(
                    'Ocultar de la lista',
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
                    color: AppPalette.slate800,
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
        color: active ? AppPalette.blue50 : AppPalette.slate50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? const Color(0xFF60A5FA) : AppPalette.slate200,
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
                    ? AppPalette.blue700
                    : AppPalette.slate500,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: active
                        ? AppPalette.blue900
                        : AppPalette.slate600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            style: const TextStyle(fontSize: 11, color: AppPalette.slate700),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // PESTAÑA 3: SUBREDES, VLANs Y MAPA VISUAL IPAM (SEGÚN MÁSCARA REAL /23, /24, /25...)
  // ===========================================================================
  Widget _buildSubnetsAndIpamGridTab() {
    final subnets = _subnets;
    final selectedSubnet = subnets.firstWhere(
      (s) => s['id'] == _selectedIpamSubnetId,
      orElse: () => subnets.isNotEmpty ? subnets.first : <String, dynamic>{},
    );

    final String cidr = (selectedSubnet['cidr'] ?? '10.20.20.0/24').toString();
    final parsedCidr = _ParsedCidrBlock.tryParse(cidr);

    final int prefixLen = (selectedSubnet['prefixlen'] as int?) ??
        parsedCidr?.prefixLen ??
        24;
    final String subnetMask =
        (selectedSubnet['subnet_mask'] ?? parsedCidr?.subnetMask ?? '255.255.255.0')
            .toString();
    final String networkAddress =
        (selectedSubnet['network_address'] ?? parsedCidr?.networkAddress ?? '')
            .toString();
    final String broadcastAddress =
        (selectedSubnet['broadcast_address'] ?? parsedCidr?.broadcastAddress ?? '')
            .toString();
    final String firstUsableIp =
        (selectedSubnet['first_usable_ip'] ?? parsedCidr?.firstUsableIp ?? '')
            .toString();
    final String lastUsableIp =
        (selectedSubnet['last_usable_ip'] ?? parsedCidr?.lastUsableIp ?? '')
            .toString();
    final int totalAddresses = (selectedSubnet['total_addresses'] as int?) ??
        parsedCidr?.totalAddresses ??
        256;
    final int totalUsable = (selectedSubnet['total_usable'] as int?) ??
        parsedCidr?.totalUsable ??
        254;

    // Lista completa de direcciones IP del bloque según su máscara real (incluyendo Dirección de Red y Broadcast)
    List<String> fullAddressList =
        ((selectedSubnet['address_list'] as List?) ?? [])
            .map((e) => e.toString())
            .toList();
    if (fullAddressList.isEmpty && parsedCidr != null) {
      fullAddressList = parsedCidr.buildAddressList(maxLimit: 4096);
    }

    final List<String> subBlocks24 =
        ((selectedSubnet['sub_blocks_24'] as List?) ?? [])
            .map((e) => e.toString())
            .toList();
    if (subBlocks24.isEmpty && prefixLen < 24 && fullAddressList.isNotEmpty) {
      final seen = <String>{};
      for (final ip in fullAddressList) {
        final b24 = ip.rsplitThreeOctets();
        if (seen.add(b24)) {
          subBlocks24.add(b24);
        }
      }
    }

    final String activeBlockFilter =
        (subBlocks24.length > 1 && subBlocks24.contains(_selectedIpamSubBlock24))
            ? _selectedIpamSubBlock24
            : 'all';

    final List<String> displayedAddresses = activeBlockFilter == 'all'
        ? fullAddressList
        : fullAddressList
            .where((ip) => ip.startsWith('$activeBlockFilter.'))
            .toList();

    final List<Map<String, dynamic>> allocatedList =
        ((selectedSubnet['allocated_ips'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
    final Map<String, Map<String, dynamic>> allocatedByIp = {
      for (final item in allocatedList)
        (item['ip_address'] ?? '').toString(): item,
    };
    final String gwIp = (selectedSubnet['gateway'] ?? '').toString();
    final bool multiOctetLabel = prefixLen < 24;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Columna izquierda: Lista de Subredes / VLANs
        Container(
          width: 355,
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(right: BorderSide(color: AppPalette.slate200)),
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
                      color: AppPalette.blue900,
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
                        onPressed: () => _openCreateSubnetDialog(),
                        icon: const Icon(Icons.add, size: 15),
                        label: const Text(
                          'Nueva Red / VLAN',
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
                    final String sMask = (s['subnet_mask'] ?? '').toString();
                    final String sNetAddr =
                        (s['network_address'] ?? '').toString();
                    final String sBcastAddr =
                        (s['broadcast_address'] ?? '').toString();
                    return Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 8),
                      color: isSel
                          ? AppPalette.blue50
                          : AppPalette.slate50,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(
                          color: isSel
                              ? AppPalette.blue600
                              : AppPalette.slate200,
                          width: isSel ? 1.5 : 1.0,
                        ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => setState(() {
                          _selectedIpamSubnetId = id;
                          _selectedIpamSubBlock24 = 'all';
                        }),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      (s['cidr'] ?? '').toString(),
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w900,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ),
                                  if (s['vlan_id'] != null)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppPalette.blue900,
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
                                  if (widget.canEdit) ...[
                                    const SizedBox(width: 4),
                                    InkWell(
                                      borderRadius: BorderRadius.circular(4),
                                      onTap: () =>
                                          _openCreateSubnetDialog(existing: s),
                                      child: const Padding(
                                        padding: EdgeInsets.all(3),
                                        child: Icon(
                                          Icons.edit_outlined,
                                          size: 15,
                                          color: AppPalette.slate600,
                                        ),
                                      ),
                                    ),
                                    InkWell(
                                      borderRadius: BorderRadius.circular(4),
                                      onTap: () => _confirmDeleteSubnet(s),
                                      child: const Padding(
                                        padding: EdgeInsets.all(3),
                                        child: Icon(
                                          Icons.delete_outline,
                                          size: 15,
                                          color: Colors.redAccent,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                (s['name'] ?? '').toString(),
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppPalette.slate700,
                                ),
                              ),
                              if ((s['location_label'] ?? '')
                                  .toString()
                                  .isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.location_on_rounded,
                                      size: 12,
                                      color: AppPalette.teal700,
                                    ),
                                    const SizedBox(width: 3),
                                    Expanded(
                                      child: Text(
                                        'Sede: ${s['location_label']}',
                                        style: const TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w800,
                                          color: AppPalette.teal700,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              const SizedBox(height: 4),
                              Text(
                                'Máscara: $sMask • Red: $sNetAddr • Bcast: $sBcastAddr',
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                  color: AppPalette.slate600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              LinearProgressIndicator(
                                value: (pct / 100.0).clamp(0.0, 1.0),
                                backgroundColor: AppPalette.slate200,
                                color: pct > 80
                                    ? Colors.redAccent
                                    : AppPalette.sky600,
                                minHeight: 6,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Ocupadas: ${s['occupied_count']} / ${s['total_usable']} útiles (${pct.toStringAsFixed(1)}%) • GW: ${s['gateway'] ?? '-'}',
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  color: AppPalette.slate500,
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
        // Lienzo derecho: Mapa Visual de todas las IPs según su máscara (/23 = 512 IPs, /24 = 256 IPs, /25 = 128 IPs, etc.)
        Expanded(
          child: selectedSubnet.isEmpty
              ? const Center(child: Text('Selecciona o crea una subred'))
              : Padding(
                  padding: const EdgeInsets.all(16),
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
                                  'Mostrando las $totalAddresses direcciones de la máscara /$prefixLen ($subnetMask): incluyendo Dirección de Red ($networkAddress), $totalUsable hosts útiles ($firstUsableIp a $lastUsableIp) y Dirección de Broadcast ($broadcastAddress).',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    color: AppPalette.slate600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.tonalIcon(
                            onPressed: () {
                              setState(() {
                                _verifyIpCtrl.text = cidr;
                                _verifySelectedSubnetId =
                                    selectedSubnet['id'] as int?;
                                _activeTab = 'verifier';
                              });
                              _runManualVerification(customIp: cidr);
                            },
                            icon: const Icon(Icons.radar_rounded, size: 16),
                            label: Text(
                              'Escanear Rango $cidr',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () {
                              setState(() {
                                _verifySelectedSubnetId =
                                    selectedSubnet['id'] as int?;
                                _activeTab = 'verifier';
                              });
                              _runManualVerification(onlySuggestFree: true);
                            },
                            icon: const Icon(Icons.auto_fix_high_rounded, size: 15),
                            label: const Text(
                              'Sugerir IP Libre',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // Ficha técnica de la Red según su Máscara (Dirección de Red, Broadcast, Máscara, Rango Útil, Gateway)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: AppPalette.slate50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppPalette.slate300),
                        ),
                        child: Wrap(
                          spacing: 14,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _buildSubnetSpecPill(
                              icon: Icons.tag_rounded,
                              label: 'Máscara',
                              value: '$subnetMask (/$prefixLen)',
                              color: AppPalette.slate900,
                            ),
                            _buildSubnetSpecPill(
                              icon: Icons.hub_rounded,
                              label: 'Dirección de Red (No asignable)',
                              value: networkAddress,
                              color: const Color(0xFF3730A3),
                              bgColor: AppPalette.indigo100,
                            ),
                            _buildSubnetSpecPill(
                              icon: Icons.podcasts_rounded,
                              label: 'Dirección de Broadcast (No asignable)',
                              value: broadcastAddress,
                              color: const Color(0xFF86198F),
                              bgColor: const Color(0xFFFAE8FF),
                            ),
                            _buildSubnetSpecPill(
                              icon: Icons.swap_horiz_rounded,
                              label: 'Rango Hosts Útiles',
                              value: '$firstUsableIp ➔ $lastUsableIp ($totalUsable IPs)',
                              color: AppPalette.sky700,
                            ),
                            _buildSubnetSpecPill(
                              icon: Icons.router_rounded,
                              label: 'Gateway',
                              value: gwIp.isEmpty ? '-' : gwIp,
                              color: AppPalette.amber700,
                              bgColor: AppPalette.amber100,
                            ),
                            _buildSubnetSpecPill(
                              icon: Icons.location_on_rounded,
                              label: 'Sede / Location',
                              value: (selectedSubnet['location_label'] ?? '')
                                      .toString()
                                      .isNotEmpty
                                  ? (selectedSubnet['location_label'])
                                      .toString()
                                  : 'Sin Sede específica',
                              color: AppPalette.teal700,
                              bgColor: const Color(0xFFF0FDFA),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Leyenda de colores + Selector de sub-bloque /24 cuando la máscara es mayor (/23, /22, etc.)
                      Row(
                        children: [
                          Expanded(
                            child: Wrap(
                              spacing: 10,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                _buildLegendDot(
                                  AppPalette.indigo100,
                                  const Color(0xFF4338CA),
                                  'DIR. RED ($networkAddress)',
                                ),
                                _buildLegendDot(
                                  const Color(0xFFFAE8FF),
                                  const Color(0xFFA21CAF),
                                  'BROADCAST ($broadcastAddress)',
                                ),
                                _buildLegendDot(
                                  AppPalette.amber100,
                                  AppPalette.amber500,
                                  'Gateway ($gwIp)',
                                ),
                                _buildLegendDot(
                                  AppPalette.sky100,
                                  AppPalette.sky600,
                                  'Ocupada (Heartbeat)',
                                ),
                                _buildLegendDot(
                                  AppPalette.green100,
                                  AppPalette.green600,
                                  'Ocupada (Servicio/VIP)',
                                ),
                                _buildLegendDot(
                                  AppPalette.slate50,
                                  AppPalette.slate300,
                                  'IP Libre Asignable',
                                ),
                              ],
                            ),
                          ),
                          if (subBlocks24.length > 1)
                            Wrap(
                              spacing: 6,
                              children: [
                                ChoiceChip(
                                  selected: activeBlockFilter == 'all',
                                  label: Text(
                                    'Toda la red /$prefixLen (${fullAddressList.length} IPs)',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  onSelected: (_) => setState(
                                    () => _selectedIpamSubBlock24 = 'all',
                                  ),
                                ),
                                ...subBlocks24.map((b24) {
                                  final isBlockSel = activeBlockFilter == b24;
                                  return ChoiceChip(
                                    selected: isBlockSel,
                                    label: Text(
                                      'Bloque $b24.x (256)',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                    onSelected: (_) => setState(
                                      () => _selectedIpamSubBlock24 = b24,
                                    ),
                                  );
                                }),
                              ],
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppPalette.slate200),
                          ),
                          child: GridView.builder(
                            gridDelegate:
                                SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: multiOctetLabel ? 84 : 72,
                              mainAxisSpacing: 6,
                              crossAxisSpacing: 6,
                              childAspectRatio: multiOctetLabel ? 1.48 : 1.32,
                            ),
                            itemCount: displayedAddresses.length,
                            itemBuilder: (ctx, idx) {
                              final ipStr = displayedAddresses[idx];
                              final bool isNetworkAddr =
                                  ipStr == networkAddress && totalAddresses > 2;
                              final bool isBroadcastAddr =
                                  ipStr == broadcastAddress && totalAddresses > 2;
                              final bool isGw = ipStr == gwIp &&
                                  !isNetworkAddr &&
                                  !isBroadcastAddr;
                              final alloc = allocatedByIp[ipStr];
                              final bool isOccupied = alloc != null;
                              final bool isHb =
                                  alloc?['is_heartbeat_ip'] == true;

                              final parts = ipStr.split('.');
                              final String cellIpLabel =
                                  (multiOctetLabel && parts.length == 4)
                                      ? '.${parts[2]}.${parts[3]}'
                                      : (parts.isNotEmpty
                                          ? '.${parts.last}'
                                          : ipStr);

                              Color bg = AppPalette.slate50;
                              Color border = AppPalette.slate200;
                              Color txt = AppPalette.slate600;
                              String roleBadge = 'Libre';

                              if (isNetworkAddr) {
                                bg = AppPalette.indigo100;
                                border = const Color(0xFF4338CA);
                                txt = const Color(0xFF312E81);
                                roleBadge = 'DIR. RED';
                              } else if (isBroadcastAddr) {
                                bg = const Color(0xFFFAE8FF);
                                border = const Color(0xFFA21CAF);
                                txt = const Color(0xFF701A75);
                                roleBadge = 'BROADCAST';
                              } else if (isGw) {
                                bg = AppPalette.amber100;
                                border = AppPalette.amber500;
                                txt = AppPalette.amber800;
                                roleBadge = 'GATEWAY';
                              } else if (isOccupied) {
                                bg = isHb
                                    ? AppPalette.sky100
                                    : AppPalette.green100;
                                border = isHb
                                    ? AppPalette.sky600
                                    : AppPalette.green600;
                                txt = isHb
                                    ? const Color(0xFF075985)
                                    : const Color(0xFF14532D);
                                roleBadge =
                                    (alloc['asset_code'] ?? '').toString();
                              }

                              final String tooltipMsg = isNetworkAddr
                                  ? '$ipStr • DIRECCIÓN DE RED ($cidr)\nIdentificador de la subred (Todos los bits de host a 0). Reservada por protocolo IPv4; NO asignable a equipos.'
                                  : isBroadcastAddr
                                      ? '$ipStr • DIRECCIÓN DE BROADCAST ($cidr)\nDirección de difusión de la subred (Todos los bits de host a 1). Reservada por protocolo IPv4; NO asignable a equipos.'
                                      : isGw
                                          ? '$ipStr • PUERTA DE ENLACE (GATEWAY) DE LA SUBRED'
                                          : isOccupied
                                              ? '$ipStr • OCUPADA por ${alloc['asset_code']} (${alloc['asset_name']})\nRol: ${alloc['ip_role_label']} (${alloc['interface_name']})'
                                              : '$ipStr • IP LIBRE ASIGNABLE en $cidr (Clic para verificar en red o asignar)';

                              return Tooltip(
                                message: tooltipMsg,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(6),
                                  onTap: () => _onTapIpamCell(
                                    ipStr: ipStr,
                                    subnet: selectedSubnet,
                                    allocated: alloc,
                                    isGateway: isGw,
                                    isNetworkAddress: isNetworkAddr,
                                    isBroadcastAddress: isBroadcastAddr,
                                  ),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: bg,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: border,
                                        width: (isNetworkAddr ||
                                                isBroadcastAddr ||
                                                isGw ||
                                                isOccupied)
                                            ? 1.4
                                            : 1.0,
                                      ),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 2,
                                    ),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          cellIpLabel,
                                          style: TextStyle(
                                            fontSize:
                                                multiOctetLabel ? 10.0 : 11.0,
                                            fontWeight: FontWeight.w900,
                                            fontFamily: 'monospace',
                                            color: txt,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          roleBadge,
                                          style: TextStyle(
                                            fontSize: 8.0,
                                            fontWeight: (isNetworkAddr ||
                                                    isBroadcastAddr ||
                                                    isGw ||
                                                    isOccupied)
                                                ? FontWeight.w900
                                                : FontWeight.w600,
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

  Widget _buildSubnetSpecPill({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    Color? bgColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor ?? Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: color.withValues(alpha: 0.85),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              fontFamily: 'monospace',
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegendDot(Color bg, Color border, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: border, width: 1.4),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          text,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppPalette.slate700,
          ),
        ),
      ],
    );
  }

  Widget _buildDetailInfoRow(String label, String value, {bool mono = false}) {
    if (value.trim().isEmpty || value == '-') return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 155,
            child: Text(
              '$label:',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: AppPalette.slate600,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 12,
                fontFamily: mono ? 'monospace' : null,
                fontWeight: mono ? FontWeight.w800 : FontWeight.w600,
                color: AppPalette.slate900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onTapIpamCell({
    required String ipStr,
    required Map<String, dynamic> subnet,
    required Map<String, dynamic>? allocated,
    required bool isGateway,
    bool isNetworkAddress = false,
    bool isBroadcastAddress = false,
  }) {
    final int? assetId = allocated?['asset_id'] as int?;
    final int? ipId = allocated?['ip_id'] as int?;
    final Map<String, dynamic>? fullAsset = assetId != null
        ? _assets.cast<Map<String, dynamic>?>().firstWhere(
              (a) => a?['id'] == assetId,
              orElse: () => null,
            )
        : null;

    final String status =
        (fullAsset?['status'] ?? allocated?['status'] ?? 'unknown').toString();
    final double? pingMs = ((fullAsset?['last_ping_ms'] ?? allocated?['last_ping_ms']) as num?)
        ?.toDouble();
    final int cores = (fullAsset?['cpu_cores'] ?? allocated?['cpu_cores'] ?? 0) as int? ?? 0;
    final double ramGb =
        ((fullAsset?['ram_gb'] ?? allocated?['ram_gb']) as num?)?.toDouble() ?? 0.0;
    final double storageGb =
        ((fullAsset?['storage_gb'] ?? allocated?['storage_gb']) as num?)?.toDouble() ?? 0.0;
    final String resourcesStr = (cores > 0 || ramGb > 0 || storageGb > 0)
        ? '$cores vCPU • ${ramGb.toStringAsFixed(0)} GB RAM • ${storageGb.toStringAsFixed(0)} GB Disco'
        : '';
    final List<Map<String, dynamic>> allAssetIps =
        ((fullAsset?['ip_addresses'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              allocated != null
                  ? Icons.computer_rounded
                  : Icons.check_box_outline_blank_rounded,
              color: allocated != null
                  ? AppPalette.sky600
                  : AppPalette.green700,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                allocated != null
                    ? 'IP $ipStr — ${allocated['asset_code']} (${allocated['asset_name']})'
                    : 'Dirección IP $ipStr (${subnet['cidr']})',
                style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isNetworkAddress)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppPalette.indigo100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF4338CA)),
                    ),
                    child: Text(
                      'DIRECCIÓN DE RED (${subnet['cidr']} • Máscara ${subnet['subnet_mask']})\n\n'
                      'La dirección $ipStr es la Dirección de Red del bloque CIDR (todos los bits de host a 0). '
                      'Está reservada por el protocolo IPv4 para identificar la subred en las tablas de encaminamiento y NO debe asignarse a ninguna máquina.',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        color: Color(0xFF312E81),
                      ),
                    ),
                  )
                else if (isBroadcastAddress)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFAE8FF),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFA21CAF)),
                    ),
                    child: Text(
                      'DIRECCIÓN DE BROADCAST (${subnet['cidr']} • Máscara ${subnet['subnet_mask']})\n\n'
                      'La dirección $ipStr es la Dirección de Difusión (Broadcast) del bloque CIDR (todos los bits de host a 1). '
                      'Está reservada por el protocolo IPv4 para enviar paquetes a todos los nodos de la subred y NO debe asignarse a ninguna máquina.',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        color: Color(0xFF701A75),
                      ),
                    ),
                  )
                else if (isGateway && allocated == null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppPalette.amber100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppPalette.amber500),
                    ),
                    child: const Text(
                      'Esta IP es la Puerta de Enlace (Gateway) configurada para esta subred.',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  )
                else if (allocated != null) ...[
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
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: status == 'online'
                                    ? AppPalette.green100
                                    : const Color(0xFFFEE2E2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                status == 'online'
                                    ? 'ONLINE${pingMs != null ? ' (${pingMs.toStringAsFixed(1)} ms)' : ''}'
                                    : status.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  color: status == 'online'
                                      ? AppPalette.green700
                                      : AppPalette.red700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: AppPalette.sky100,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                (fullAsset?['asset_class_label'] ??
                                        allocated['asset_class_label'] ??
                                        allocated['asset_class'] ??
                                        'Equipo')
                                    .toString(),
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: AppPalette.sky700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 18),
                        _buildDetailInfoRow(
                          'Código CMDB',
                          (allocated['asset_code'] ?? '').toString(),
                          mono: true,
                        ),
                        _buildDetailInfoRow(
                          'Nombre del Equipo',
                          (allocated['asset_name'] ?? '').toString(),
                        ),
                        _buildDetailInfoRow(
                          'Hostname',
                          (fullAsset?['hostname'] ?? allocated['hostname'] ?? '')
                              .toString(),
                          mono: true,
                        ),
                        _buildDetailInfoRow(
                          'FQDN / DNS',
                          (allocated['fqdn'] ?? fullAsset?['fqdn'] ?? '')
                              .toString(),
                          mono: true,
                        ),
                        _buildDetailInfoRow(
                          'Dirección IP Actual',
                          '$ipStr (${allocated['ip_role_label']})',
                          mono: true,
                        ),
                        _buildDetailInfoRow(
                          'Interfaz / VLAN',
                          '${allocated['interface_name'] ?? 'eth0'}${allocated['vlan_id'] != null ? ' • VLAN ${allocated['vlan_id']}' : ''}',
                          mono: true,
                        ),
                        _buildDetailInfoRow(
                          'MAC Address',
                          (allocated['mac_address'] ?? '').toString(),
                          mono: true,
                        ),
                        _buildDetailInfoRow(
                          'SO / Firmware / Puertos',
                          (fullAsset?['os_or_firmware'] ??
                                  allocated['os_or_firmware'] ??
                                  '')
                              .toString(),
                        ),
                        _buildDetailInfoRow('Recursos Hardware', resourcesStr),
                        _buildDetailInfoRow(
                          'Ubicación / Hipervisor',
                          (fullAsset?['physical_location_label'] ??
                                  fullAsset?['hypervisor_or_platform'] ??
                                  allocated['hypervisor_or_platform'] ??
                                  '')
                              .toString(),
                        ),
                        _buildDetailInfoRow(
                          'Entorno',
                          (fullAsset?['environment'] ??
                                  allocated['environment'] ??
                                  '')
                              .toString()
                              .toUpperCase(),
                        ),
                        _buildDetailInfoRow(
                          'Equipo / Responsable',
                          [
                            (fullAsset?['owner_team'] ??
                                    allocated['owner_team'] ??
                                    '')
                                .toString(),
                            (fullAsset?['responsible_person'] ??
                                    allocated['responsible_person'] ??
                                    '')
                                .toString(),
                          ].where((s) => s.trim().isNotEmpty).join(' • '),
                        ),
                        _buildDetailInfoRow(
                          'Notas',
                          (fullAsset?['notes'] ?? allocated['notes'] ?? '')
                              .toString(),
                        ),
                        if (allAssetIps.length > 1) ...[
                          const Divider(height: 16),
                          const Text(
                            'Todas las IPs configuradas en este equipo:',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: AppPalette.slate700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: allAssetIps.map((ipItem) {
                              return Chip(
                                visualDensity: VisualDensity.compact,
                                label: Text(
                                  '${ipItem['ip_address']} (${ipItem['interface_name']} • ${ipItem['ip_role_label'] ?? ipItem['ip_role']})',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (widget.canEdit) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppPalette.red50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppPalette.red200),
                      ),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Icon(
                            Icons.cleaning_services_rounded,
                            size: 16,
                            color: AppPalette.red700,
                          ),
                          const Text(
                            '¿El equipo ya no está o quieres liberar esta IP?',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: AppPalette.red800,
                            ),
                          ),
                          if (ipId != null)
                            OutlinedButton.icon(
                              onPressed: () async {
                                Navigator.pop(ctx);
                                await widget.api.deleteCmdbIp(ipId);
                                await _loadOverview(silent: true);
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    backgroundColor: AppPalette.green700,
                                    content: Text(
                                      'La IP $ipStr ha quedado marcada como NO OCUPADA (Libre) en el mapa IPAM.',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                );
                              },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppPalette.red700,
                                side: const BorderSide(color: AppPalette.red300),
                                visualDensity: VisualDensity.compact,
                              ),
                              icon: const Icon(Icons.link_off_rounded, size: 15),
                              label: const Text(
                                'Dejar IP como No Ocupada (Liberar IP)',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          if (assetId != null)
                            FilledButton.icon(
                              onPressed: () async {
                                Navigator.pop(ctx);
                                await widget.api.deleteCmdbAsset(assetId);
                                await _loadOverview(silent: true);
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    backgroundColor: AppPalette.green700,
                                    content: Text(
                                      'Equipo ${allocated['asset_code']} eliminado e IP $ipStr marcada como NO OCUPADA (Libre).',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                );
                              },
                              style: FilledButton.styleFrom(
                                backgroundColor: AppPalette.red600,
                                visualDensity: VisualDensity.compact,
                              ),
                              icon: const Icon(
                                Icons.delete_forever_rounded,
                                size: 15,
                              ),
                              label: const Text(
                                'Quitar Equipo de CMDB y Liberar IP',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ] else
                  const Text(
                    'Esta dirección IP de host figura como LIBRE (No Ocupada) en la CMDB.\n'
                    'Puedes verificarla ahora en la red (Ping + Puertos TCP + ARP + DNS) o asignarla directamente a un equipo.',
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar'),
          ),
          if (!isNetworkAddress && !isBroadcastAddress)
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _verifyIpCtrl.text = ipStr;
                setState(() => _activeTab = 'verifier');
                _runManualVerification(customIp: ipStr);
              },
              icon: const Icon(Icons.radar_rounded, size: 16),
              label: const Text('Verificar en Red'),
            ),
          if (allocated != null && assetId != null) ...[
            if (widget.canEdit && fullAsset != null)
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _openAssetEditorDialog(existing: fullAsset);
                },
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Editar Equipo'),
              ),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                setState(() {
                  _classFilter = 'all';
                  _envFilter = 'all';
                  _onlyMultiIp = false;
                  _searchCtrl.clear();
                  _highlightedAssetId = assetId;
                  _expandedAssetId = assetId;
                  _activeTab = 'inventory';
                });
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppPalette.blue900,
              ),
              icon: const Icon(Icons.table_rows_rounded, size: 16),
              label: const Text('Ir a su Casilla en Inventario CMDB'),
            ),
          ],
          if (widget.canEdit &&
              allocated == null &&
              !isGateway &&
              !isNetworkAddress &&
              !isBroadcastAddress) ...[
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
            color: AppPalette.slate900,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Permite visualizar qué Máquinas Virtuales (VMs), Contenedores o Clusters dependen de cada servidor físico del Rack, además de las instancias Cloud o autónomas que no están en ningún rack.',
          style: TextStyle(fontSize: 12, color: AppPalette.slate600),
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
              side: const BorderSide(color: AppPalette.slate300),
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
                          color: AppPalette.teal700.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.dns_rounded,
                          color: AppPalette.teal700,
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
                                color: AppPalette.slate600,
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
                          color: AppPalette.slate500,
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
            side: const BorderSide(color: AppPalette.slate300),
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
                        color: AppPalette.indigo600.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.cloud_done_rounded,
                        color: AppPalette.indigo600,
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
                              color: AppPalette.slate600,
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
    final maskCtrl = TextEditingController(
      text: _primaryMaskOfAsset(asset).isNotEmpty
          ? _primaryMaskOfAsset(asset)
          : '255.255.255.0',
    );
    final ifaceCtrl = TextEditingController(
      text: 'eth${(asset['ip_count'] as int? ?? 1)}',
    );
    final fqdnCtrl = TextEditingController();
    final macCtrl = TextEditingController();
    final vlanCtrl = TextEditingController(text: '20');
    final gwCtrl = TextEditingController(text: '192.168.2.1');
    final notesCtrl = TextEditingController();
    String selectedRole = 'primary_service';
    bool isHb = false;
    bool enableAssetHeartbeat = asset['monitoring_enabled'] ?? true;
    Map<String, dynamic>? liveCheckResult;
    bool checkingNow = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(
            'Añadir / Configurar IP en ${asset['code']} (${asset['name']})',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
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
                        flex: 3,
                        child: TextField(
                          controller: ipCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Dirección IP (ej. 192.168.2.55)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: maskCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Máscara de Red (ej. 255.255.255.0)',
                            border: OutlineInputBorder(),
                            isDense: true,
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
                        label: const Text('Verificar IP'),
                      ),
                    ],
                  ),
                  if (liveCheckResult != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: liveCheckResult!['can_safely_assign'] == true
                            ? AppPalette.green50
                            : AppPalette.red50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: liveCheckResult!['can_safely_assign'] == true
                              ? AppPalette.green300
                              : AppPalette.red300,
                        ),
                      ),
                      child: Text(
                        '${liveCheckResult!['verdict_label']}\n${liveCheckResult!['summary']}',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: liveCheckResult!['can_safely_assign'] == true
                              ? const Color(0xFF14532D)
                              : AppPalette.red700,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedRole,
                    decoration: const InputDecoration(
                      labelText:
                          'Diferenciar Tipo / Rol de la IP (Gestión/Heartbeat, Servicio, VIP, Storage, iDRAC...)',
                      border: OutlineInputBorder(),
                      isDense: true,
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
                            labelText: 'Interfaz (eth1, ens224, vip0...)',
                            border: OutlineInputBorder(),
                            isDense: true,
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
                            isDense: true,
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
                            isDense: true,
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
                            isDense: true,
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
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: isHb,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Usar esta IP como IP principal de Gestión / Heartbeat de la máquina',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    onChanged: (v) => setModalState(() => isHb = v ?? false),
                  ),
                  SwitchListTile(
                    value: enableAssetHeartbeat,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Activar Heartbeat de la conexión para este equipo',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.sky700,
                      ),
                    ),
                    onChanged: (v) =>
                        setModalState(() => enableAssetHeartbeat = v),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: notesCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Notas de la interfaz / servicio',
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
                final cleanIp = ipCtrl.text.trim();
                if (cleanIp.isEmpty) return;
                await widget.api.addCmdbAssetIp(asset['id'] as int, {
                  'ip_address': cleanIp,
                  'subnet_mask': maskCtrl.text.trim().isNotEmpty
                      ? maskCtrl.text.trim()
                      : '255.255.255.0',
                  'ip_role': selectedRole,
                  'interface_name': ifaceCtrl.text.trim(),
                  'vlan_id': int.tryParse(vlanCtrl.text.trim()),
                  'gateway': gwCtrl.text.trim(),
                  'fqdn': fqdnCtrl.text.trim(),
                  'mac_address': macCtrl.text.trim(),
                  'is_heartbeat_ip': isHb,
                  'notes': notesCtrl.text.trim(),
                });
                if (enableAssetHeartbeat !=
                    (asset['monitoring_enabled'] ?? true)) {
                  await widget.api.updateCmdbAsset(asset['id'] as int, {
                    'monitoring_enabled': enableAssetHeartbeat,
                  });
                }
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
    int? selectedLocationId = existing?['location_id'] as int?;
    int? selectedFloorId = existing?['floor_id'] as int?;
    String? selectedFloorDeviceType =
        (existing?['floor_device_type'] ?? '').toString().trim().isNotEmpty
            ? (existing?['floor_device_type']).toString().trim()
            : null;
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
          'ip_address': prefilledIp ?? '192.168.2.150',
          'subnet_mask': '255.255.255.0',
          'ip_role': 'mgmt_heartbeat',
          'interface_name': 'eth0 (Mgmt)',
          'vlan_id': 1,
          'gateway': '192.168.2.1',
          'fqdn': prefilledFqdn ?? '',
          'mac_address': prefilledMac ?? '',
          'is_heartbeat_ip': true,
          'notes': 'IP de Gestión / Heartbeat',
        },
      ];
    }

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(
            isEdit
                ? 'Editar Máquina / CI e Interfaces IP en CMDB: ${existing['code']}'
                : 'Alta en CMDB: Nueva Máquina Virtual, Contenedor, Cluster o Activo Multi-IP',
            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900),
          ),
          content: SizedBox(
            width: 860,
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
                            labelText: 'Código CI (ej. VM-ERP-02, ROU-CORE-01)',
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
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<int?>(
                          initialValue: _locations.any(
                                    (l) => l['id'] == selectedLocationId,
                                  )
                              ? selectedLocationId
                              : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Sede / Location (Opcional)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text('Sin Sede específica / Automática'),
                            ),
                            ..._locations.map((loc) {
                              return DropdownMenuItem<int?>(
                                value: loc['id'] as int,
                                child: Text(
                                  '${loc['code']} — ${loc['name']}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }),
                          ],
                          onChanged: (v) =>
                              setModalState(() => selectedLocationId = v),
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
                            if (v != null) {
                              setModalState(() {
                                assetClass = v;
                                if (v == 'floor_endpoint') {
                                  selectedFloorDeviceType ??= 'printer';
                                  if (selectedFloorId == null &&
                                      _floors.isNotEmpty) {
                                    final locFloor = _floors
                                        .where(
                                          (fl) =>
                                              fl['location_id'] ==
                                              selectedLocationId,
                                        )
                                        .firstOrNull;
                                    selectedFloorId =
                                        (locFloor?['id'] ?? _floors.first['id'])
                                            as int?;
                                  }
                                }
                              });
                            }
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
                  // SECCIÓN DE ALINEACIÓN CON DATACENTER (PLANTAS): IMPRESORA, CÁMARA, WI-FI AP, PC...
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: (selectedFloorDeviceType != null ||
                              selectedFloorId != null ||
                              assetClass == 'floor_endpoint')
                          ? const Color(0xFFF0FDF4)
                          : AppPalette.slate50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: (selectedFloorDeviceType != null ||
                                selectedFloorId != null ||
                                assetClass == 'floor_endpoint')
                            ? const Color(0xFF86EFAC)
                            : AppPalette.slate300,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(
                              Icons.print_rounded,
                              size: 15,
                              color: AppPalette.teal700,
                            ),
                            SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Alineación con 2. Datacenter (Plantas): Indicar si este equipo es Impresora, Cámara, Wi-Fi AP, PC o Sensor en Planta (Mismo elemento)',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w900,
                                  color: AppPalette.slate900,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String?>(
                                initialValue: selectedFloorDeviceType != null &&
                                        _floorDeviceTypeLabels.containsKey(
                                          selectedFloorDeviceType,
                                        )
                                    ? selectedFloorDeviceType
                                    : null,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText:
                                      'Tipo de Dispositivo en Planta (ej. Impresora, Cámara, Wi-Fi...)',
                                  filled: true,
                                  fillColor: Colors.white,
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: [
                                  const DropdownMenuItem<String?>(
                                    value: null,
                                    child: Text(
                                      '— No es dispositivo de planta (VM / Rack / Cloud) —',
                                    ),
                                  ),
                                  ..._floorDeviceTypeLabels.entries.map(
                                    (e) => DropdownMenuItem<String?>(
                                      value: e.key,
                                      child: Text(e.value),
                                    ),
                                  ),
                                ],
                                onChanged: (val) {
                                  setModalState(() {
                                    selectedFloorDeviceType = val;
                                    if (val != null) {
                                      assetClass = 'floor_endpoint';
                                      final lbl =
                                          _floorDeviceTypeLabels[val] ?? val;
                                      osCtrl.text = 'Endpoint ($lbl)';
                                      if (nameCtrl.text
                                          .trim()
                                          .startsWith('Equipo Detectado')) {
                                        final h = hostCtrl.text.trim().isNotEmpty
                                            ? hostCtrl.text.trim()
                                            : (ipDrafts.isNotEmpty
                                                  ? (ipDrafts.first['ip_address'] ??
                                                            '')
                                                        .toString()
                                                  : '');
                                        nameCtrl.text =
                                            '${lbl.split('(').first.trim()} • $h';
                                      }
                                      if (selectedFloorId == null &&
                                          _floors.isNotEmpty) {
                                        final locFloor = _floors
                                            .where(
                                              (fl) =>
                                                  fl['location_id'] ==
                                                  selectedLocationId,
                                            )
                                            .firstOrNull;
                                        selectedFloorId = (locFloor?['id'] ??
                                            _floors.first['id']) as int?;
                                      }
                                    }
                                  });
                                },
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: DropdownButtonFormField<int?>(
                                initialValue: _floors.any(
                                          (fl) => fl['id'] == selectedFloorId,
                                        )
                                    ? selectedFloorId
                                    : null,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText:
                                      'Planta del Datacenter donde ubicarlo (Plano 2D)',
                                  filled: true,
                                  fillColor: Colors.white,
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: [
                                  const DropdownMenuItem<int?>(
                                    value: null,
                                    child: Text('— Sin planta asignada —'),
                                  ),
                                  ..._floors.map(
                                    (fl) => DropdownMenuItem<int?>(
                                      value: fl['id'] as int,
                                      child: Text(
                                        (fl['label'] ?? fl['name'] ?? '')
                                            .toString(),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ],
                                onChanged: (val) {
                                  setModalState(() {
                                    selectedFloorId = val;
                                    if (val != null) {
                                      assetClass = 'floor_endpoint';
                                      selectedFloorDeviceType ??= 'printer';
                                      final flObj = _floors
                                          .where((f) => f['id'] == val)
                                          .firstOrNull;
                                      if (flObj != null &&
                                          flObj['location_id'] != null) {
                                        selectedLocationId =
                                            flObj['location_id'] as int;
                                      }
                                    }
                                  });
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
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
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: monitoringEnabled
                          ? AppPalette.green50
                          : AppPalette.slate50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: monitoringEnabled
                            ? AppPalette.green300
                            : AppPalette.slate300,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: SwitchListTile(
                            value: monitoringEnabled,
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              'Activar Heartbeat de la Conexión (Monitorización continua sobre la IP marcada como ★ Heartbeat)',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
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
                          width: 90,
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
                  ),
                  const Divider(height: 22),
                  Row(
                    children: [
                      const Icon(
                        Icons.lan_rounded,
                        size: 18,
                        color: AppPalette.blue900,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Direcciones IP y Máscaras de Red (Diferenciar IP de Gestión/Heartbeat vs IPs de Servicio/VIP/iDRAC)',
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
                              'subnet_mask': '255.255.255.0',
                              'ip_role': 'secondary_service',
                              'interface_name': 'eth${ipDrafts.length}',
                              'vlan_id': 20,
                              'gateway': '192.168.2.1',
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
                            ? AppPalette.sky50
                            : AppPalette.slate50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isHb
                              ? AppPalette.sky400
                              : AppPalette.slate300,
                        ),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: TextFormField(
                                  initialValue:
                                      (item['ip_address'] ?? '').toString(),
                                  decoration: const InputDecoration(
                                    labelText: 'Dirección IP',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (v) => item['ip_address'] = v,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                flex: 2,
                                child: TextFormField(
                                  initialValue:
                                      (item['subnet_mask'] ?? '255.255.255.0')
                                          .toString(),
                                  decoration: const InputDecoration(
                                    labelText: 'Máscara de Red',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (v) => item['subnet_mask'] = v,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                flex: 3,
                                child: DropdownButtonFormField<String>(
                                  initialValue:
                                      _ipRoleLabels.containsKey(item['ip_role'])
                                          ? item['ip_role'] as String
                                          : 'primary_service',
                                  decoration: const InputDecoration(
                                    labelText: 'Rol / Diferenciación de IP',
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
                              const SizedBox(width: 6),
                              Tooltip(
                                message:
                                    'Marcar esta IP como la IP principal de Gestión / Heartbeat de la conexión',
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
                                        ? AppPalette.sky600
                                        : AppPalette.slate200,
                                    label: Text(
                                      isHb ? '★ Heartbeat ON' : 'Marcar Heartbeat',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w800,
                                        color: isHb
                                            ? Colors.white
                                            : AppPalette.slate600,
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
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  initialValue:
                                      (item['interface_name'] ?? '').toString(),
                                  decoration: const InputDecoration(
                                    labelText: 'Interfaz (eth0...)',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (v) => item['interface_name'] = v,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: TextFormField(
                                  initialValue:
                                      (item['gateway'] ?? '').toString(),
                                  decoration: const InputDecoration(
                                    labelText: 'Gateway',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (v) => item['gateway'] = v,
                                ),
                              ),
                              const SizedBox(width: 6),
                              SizedBox(
                                width: 85,
                                child: TextFormField(
                                  initialValue:
                                      '${item['vlan_id'] ?? ''}',
                                  decoration: const InputDecoration(
                                    labelText: 'VLAN',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (v) =>
                                      item['vlan_id'] = int.tryParse(v.trim()),
                                ),
                              ),
                              const SizedBox(width: 6),
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
                              Expanded(
                                flex: 2,
                                child: TextFormField(
                                  initialValue:
                                      (item['mac_address'] ?? '').toString(),
                                  decoration: const InputDecoration(
                                    labelText: 'MAC Address',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (v) => item['mac_address'] = v,
                                ),
                              ),
                            ],
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
                final existingCf = Map<String, dynamic>.from(
                  (existing?['custom_fields'] as Map?) ?? {},
                );
                if (selectedLocationId != null) {
                  existingCf['location_id'] = selectedLocationId;
                } else {
                  existingCf.remove('location_id');
                }

                final validIps = ipDrafts
                    .where(
                      (d) =>
                          (d['ip_address'] ?? '').toString().trim().isNotEmpty,
                    )
                    .toList();

                // Comprobar si alguna de las IPs colisiona con otro equipo (ej. montado en Rack Editor)
                for (final d in validIps) {
                  final candidateIp =
                      (d['ip_address'] ?? '').toString().trim();
                  final checkRes = await widget.api.checkCmdbIpOwner(
                    ip: candidateIp,
                    excludeAssetId: isEdit ? existing['id'] as int : null,
                  );
                  if (checkRes['has_collision'] == true) {
                    final owners = (checkRes['owners'] as List?) ?? [];
                    if (owners.isNotEmpty && ctx.mounted) {
                      final owner = Map<String, dynamic>.from(
                        owners.first as Map,
                      );
                      final String? choice = await showDialog<String>(
                        context: ctx,
                        builder: (dCtx) => AlertDialog(
                          title: Row(
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                color: AppPalette.red700,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Colisión de IP Detectada ($candidateIp)',
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          content: Text(
                            'La dirección IP $candidateIp ya está asignada a:\n'
                            '• [${owner['code']}] ${owner['name']} (${owner['physical_location_label']})\n\n'
                            '¿Cómo deseas proceder?',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dCtx, 'cancel'),
                              child: const Text('Cancelar y cambiar IP'),
                            ),
                            OutlinedButton(
                              onPressed: () => Navigator.pop(dCtx, 'save_anyway'),
                              child: const Text('Guardar igualmente'),
                            ),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: AppPalette.green700,
                              ),
                              onPressed: () => Navigator.pop(dCtx, 'merge'),
                              icon: const Icon(
                                Icons.merge_type_rounded,
                                size: 16,
                              ),
                              label: const Text(
                                'Es el mismo equipo: Unificar con existente',
                              ),
                            ),
                          ],
                        ),
                      );
                      if (choice == 'cancel' || choice == null) {
                        return;
                      }
                      if (choice == 'merge') {
                        if (isEdit) {
                          final updated =
                              await widget.api.resolveCmdbIpCollision({
                            'ip_address': candidateIp,
                            'action': 'merge',
                            'keep_asset_id': owner['id'],
                            'other_asset_id': existing['id'],
                            'preferred_name': nameCtrl.text.trim(),
                            'preferred_hostname': hostCtrl.text.trim(),
                            'preferred_fqdn': fqdnCtrl.text.trim(),
                          });
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          setState(() => _overview = updated);
                          return;
                        } else {
                          await widget.api.updateCmdbAsset(
                            owner['id'] as int,
                            {
                              if (nameCtrl.text.trim().isNotEmpty)
                                'name': nameCtrl.text.trim(),
                              if (hostCtrl.text.trim().isNotEmpty)
                                'hostname': hostCtrl.text.trim(),
                              if (fqdnCtrl.text.trim().isNotEmpty)
                                'fqdn': fqdnCtrl.text.trim(),
                              'monitoring_enabled': monitoringEnabled,
                              'monitor_method': monitorMethod,
                              'monitor_port':
                                  int.tryParse(monitorPortCtrl.text.trim()) ??
                                      22,
                            },
                          );
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          await _loadOverview(silent: true);
                          return;
                        }
                      }
                    }
                  }
                }

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
                  'floor_id': selectedFloorId,
                  'floor_device_type': selectedFloorDeviceType,
                  'monitoring_enabled': monitoringEnabled,
                  'monitor_method': monitorMethod,
                  'monitor_port': int.tryParse(monitorPortCtrl.text.trim()) ?? 22,
                  'custom_fields': existingCf,
                  'notes': notesCtrl.text.trim(),
                  'ip_addresses': validIps,
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
                  ScaffoldMessenger.of(ctx).aviso('Error guardando en CMDB: $e');
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

  Future<void> _openCreateSubnetDialog({
    Map<String, dynamic>? existing,
  }) async {
    final bool isEdit = existing != null;
    final cidrCtrl = TextEditingController(
      text: (existing?['cidr'] ?? '10.20.40.0/24').toString(),
    );
    final nameCtrl = TextEditingController(
      text: (existing?['name'] ?? 'VLAN 40 — Nueva Red de Servicios').toString(),
    );
    final vlanCtrl = TextEditingController(
      text: (existing?['vlan_id'] ?? '40').toString(),
    );
    final gwCtrl = TextEditingController(
      text: (existing?['gateway'] ?? '10.20.40.1').toString(),
    );
    final dnsCtrl = TextEditingController(
      text: (existing?['dns_servers'] ?? '10.20.1.5').toString(),
    );
    final notesCtrl = TextEditingController(
      text: (existing?['notes'] ?? '').toString(),
    );
    String env = (existing?['environment'] ?? 'production').toString();
    int? selectedLocationId = existing?['location_id'] as int?;
    bool userEditedGateway = isEdit;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final parsed = _ParsedCidrBlock.tryParse(cidrCtrl.text.trim());
          return AlertDialog(
            title: Text(
              isEdit
                  ? 'Editar Subred / VLAN (${existing['cidr']})'
                  : 'Registrar Nueva Subred / VLAN en IPAM',
            ),
            content: SizedBox(
              width: 540,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: cidrCtrl,
                      onChanged: (val) {
                        final p = _ParsedCidrBlock.tryParse(val.trim());
                        setModalState(() {
                          if (p != null && !userEditedGateway) {
                            gwCtrl.text = p.firstUsableIp;
                          }
                        });
                      },
                      decoration: const InputDecoration(
                        labelText:
                            'Bloque CIDR con su máscara (ej. 10.20.40.0/23, 10.20.40.0/24, 192.168.1.128/25)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (parsed != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppPalette.sky50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF7DD3FC)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Cálculo automático por máscara /${parsed.prefixLen} (${parsed.subnetMask}):',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w900,
                                color: AppPalette.sky900,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '• Red normalizada: ${parsed.canonicalCidr}\n'
                              '• Dirección de Red (No asignable): ${parsed.networkAddress}\n'
                              '• Dirección de Broadcast (No asignable): ${parsed.broadcastAddress}\n'
                              '• Rango de IPs útiles: ${parsed.firstUsableIp} a ${parsed.lastUsableIp} (${parsed.totalUsable} hosts útiles / ${parsed.totalAddresses} totales)',
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w700,
                                color: AppPalette.sky700,
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      const Text(
                        'Introduce un bloque CIDR válido (por ejemplo 10.20.40.0/23 o 192.168.10.0/24).',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.redAccent,
                          fontWeight: FontWeight.w700,
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
                    DropdownButtonFormField<int?>(
                      initialValue: _locations.any(
                                (l) => l['id'] == selectedLocationId,
                              )
                          ? selectedLocationId
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText:
                            'Sede / Location asociada al rango de IPs (Opcional)',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text(
                            'Sin Sede específica (Global / Multi-sede)',
                          ),
                        ),
                        ..._locations.map((loc) {
                          return DropdownMenuItem<int?>(
                            value: loc['id'] as int,
                            child: Text(
                              '${loc['code']} — ${loc['name']}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }),
                      ],
                      onChanged: (v) =>
                          setModalState(() => selectedLocationId = v),
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
                            onChanged: (_) => userEditedGateway = true,
                            decoration: const InputDecoration(
                              labelText: 'Gateway de la Subred',
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
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar'),
              ),
              FilledButton.icon(
                onPressed: parsed == null
                    ? null
                    : () async {
                        final payload = {
                          'cidr': parsed.canonicalCidr,
                          'subnet_mask': parsed.subnetMask,
                          'name': nameCtrl.text.trim(),
                          'vlan_id': int.tryParse(vlanCtrl.text.trim()),
                          'location_id': selectedLocationId,
                          'gateway': gwCtrl.text.trim().isNotEmpty
                              ? gwCtrl.text.trim()
                              : parsed.firstUsableIp,
                          'dns_servers': dnsCtrl.text.trim(),
                          'environment': env,
                          'notes': notesCtrl.text.trim(),
                        };
                        try {
                          if (isEdit) {
                            await widget.api.updateCmdbSubnet(
                              existing['id'] as int,
                              payload,
                            );
                          } else {
                            await widget.api.createCmdbSubnet(payload);
                          }
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          setState(() => _selectedIpamSubBlock24 = 'all');
                          await _loadOverview(silent: true);
                        } catch (e) {
                          if (!ctx.mounted) return;
                          ScaffoldMessenger.of(ctx).aviso('Error guardando subred: $e');
                        }
                      },
                icon: const Icon(Icons.save, size: 16),
                label: Text(isEdit ? 'Guardar Cambios' : 'Guardar Subred'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmDeleteSubnet(Map<String, dynamic> subnet) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Eliminar subred ${subnet['cidr']}?'),
        content: Text(
          'Se eliminará la subred "${subnet['name']}" del IPAM. Las máquinas e IPs seguirán existiendo en el inventario CMDB.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar Subred'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.api.deleteCmdbSubnet(subnet['id'] as int);
      if (_selectedIpamSubnetId == subnet['id']) {
        _selectedIpamSubnetId = null;
      }
      await _loadOverview(silent: true);
    }
  }
}

class _ParsedCidrBlock {
  final String canonicalCidr;
  final int prefixLen;
  final String subnetMask;
  final String networkAddress;
  final String broadcastAddress;
  final String firstUsableIp;
  final String lastUsableIp;
  final int totalAddresses;
  final int totalUsable;
  final int networkInt;

  const _ParsedCidrBlock({
    required this.canonicalCidr,
    required this.prefixLen,
    required this.subnetMask,
    required this.networkAddress,
    required this.broadcastAddress,
    required this.firstUsableIp,
    required this.lastUsableIp,
    required this.totalAddresses,
    required this.totalUsable,
    required this.networkInt,
  });

  static _ParsedCidrBlock? tryParse(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final slashParts = s.split('/');
    if (slashParts.length > 2) return null;
    final ipPart = slashParts[0].trim();
    final prefix = slashParts.length == 2
        ? int.tryParse(slashParts[1].trim())
        : 24;
    if (prefix == null || prefix < 8 || prefix > 32) return null;

    final octets = ipPart.split('.');
    if (octets.length != 4) return null;
    int ipInt = 0;
    for (final o in octets) {
      final v = int.tryParse(o);
      if (v == null || v < 0 || v > 255) return null;
      ipInt = (ipInt << 8) | v;
    }
    ipInt = ipInt & 0xFFFFFFFF;

    final int hostBits = 32 - prefix;
    final int maskInt =
        prefix == 0 ? 0 : ((0xFFFFFFFF << hostBits) & 0xFFFFFFFF);
    final int netInt = (ipInt & maskInt) & 0xFFFFFFFF;
    final int totalAddr = 1 << hostBits;
    final int bcastInt = (netInt + totalAddr - 1) & 0xFFFFFFFF;
    final int firstInt = totalAddr > 2 ? netInt + 1 : netInt;
    final int lastInt = totalAddr > 2 ? bcastInt - 1 : bcastInt;
    final int usable = totalAddr > 2 ? totalAddr - 2 : totalAddr;

    final netStr = _intToIpv4(netInt);
    return _ParsedCidrBlock(
      canonicalCidr: '$netStr/$prefix',
      prefixLen: prefix,
      subnetMask: _intToIpv4(maskInt),
      networkAddress: netStr,
      broadcastAddress: _intToIpv4(bcastInt),
      firstUsableIp: _intToIpv4(firstInt),
      lastUsableIp: _intToIpv4(lastInt),
      totalAddresses: totalAddr,
      totalUsable: usable,
      networkInt: netInt,
    );
  }

  List<String> buildAddressList({int maxLimit = 4096}) {
    final count = totalAddresses < maxLimit ? totalAddresses : maxLimit;
    return List<String>.generate(
      count,
      (offset) => _intToIpv4((networkInt + offset) & 0xFFFFFFFF),
    );
  }

  static String _intToIpv4(int val) {
    final a = (val >> 24) & 0xFF;
    final b = (val >> 16) & 0xFF;
    final c = (val >> 8) & 0xFF;
    final d = val & 0xFF;
    return '$a.$b.$c.$d';
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
          color: AppPalette.slate700,
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
          color: AppPalette.slate800,
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
