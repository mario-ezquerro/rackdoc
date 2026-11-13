import 'package:flutter/material.dart';
import '../../core/widgets/avisos.dart';
import '../../core/theme.dart';
import 'package:flutter/services.dart';
import '../../core/api_client.dart';
import '../../shared/widgets/diagram_exporter.dart';
import '../../shared/widgets/provisioning_workspace_view.dart';
import 'api_onboarding_dialog.dart';

part 'tabs/cmdb_inventory_tab.dart';
part 'tabs/cmdb_ip_verifier_tab.dart';
part 'tabs/cmdb_subnets_ipam_tab.dart';
part 'tabs/cmdb_hypervisor_and_dialogs.dart';

/// Vista principal de **`6. CMDB & Control IPs`** (Inventario Multi-IP, Escáner CIDR, IPAM y Árbol VMs).
class CmdbView extends StatefulWidget {
  final RackDocApiClient api;
  final bool canEdit;
  final void Function(int rackId, int? deviceId)? onNavigateToRackDevice;
  final void Function(int? locationId, int floorId, int floorDeviceId)?
      onNavigateToFloorDevice;
  final void Function(int stackId, int? nodeId)? onNavigateToStackNode;
  final VoidCallback? onExportExcel;
  final VoidCallback? onNavigateToSreDocs;

  const CmdbView({
    super.key,
    required this.api,
    required this.canEdit,
    this.onNavigateToRackDevice,
    this.onNavigateToFloorDevice,
    this.onNavigateToStackNode,
    this.onExportExcel,
    this.onNavigateToSreDocs,
  });

  @override
  State<CmdbView> createState() => _CmdbViewState();
}

class _CmdbViewState extends State<CmdbView> {
  /// Puente interno para reconstruir el estado desde extensiones `part`.
  void _rebuildState(VoidCallback fn) => setState(fn);

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
          final firstSub = Map<String, dynamic>.from(subnets.first as Map);
          final firstSubId = firstSub['id'] as int?;
          if (_verifySelectedSubnetId == null && firstSubId != null) {
            _verifySelectedSubnetId = firstSubId;
            final firstCidr = (firstSub['cidr'] ?? '').toString().trim();
            if (firstCidr.isNotEmpty &&
                _verifyIpCtrl.text.trim() == '192.168.2.0/24') {
              _verifyIpCtrl.text = firstCidr;
            }
          }
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
        final modelName = (a['model_name'] ?? '').toString().toLowerCase();
        final serialNum = (a['serial_or_uuid'] ?? '').toString().toLowerCase();
        final resources =
            '${a['cpu_cores'] ?? ''}vcpu ${a['ram_gb'] ?? ''}gb ${a['storage_gb'] ?? ''}gb'
                .toLowerCase();
        final ips = ((a['ip_addresses'] as List?) ?? [])
            .map((ip) =>
                '${(ip as Map)['ip_address']} ${ip['subnet_mask'] ?? ''} ${ip['gateway'] ?? ''} ${ip['fqdn']} ${ip['interface_name']} ${ip['mac_address']} ${ip['ip_role_label']} vlan ${ip['vlan_id'] ?? ''}'
                    .toLowerCase())
            .join(' ');
        final haystack =
            '$code $name $host $fqdn $os $plat $modelName $serialNum $loc $siteLoc $stackLbl $primaryMask $env $cls $status $owner $resp $notes $resources $ips';
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
          final firstSub = Map<String, dynamic>.from(subnets.first as Map);
          final firstSubId = firstSub['id'] as int?;
          if (_verifySelectedSubnetId == null && firstSubId != null) {
            _verifySelectedSubnetId = firstSubId;
            final firstCidr = (firstSub['cidr'] ?? '').toString().trim();
            if (firstCidr.isNotEmpty &&
                _verifyIpCtrl.text.trim() == '192.168.2.0/24') {
              _verifyIpCtrl.text = firstCidr;
            }
          }
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

  DiagramExportDocument _buildCmdbExportDocument() {
    final assets = _assets;
    final subnets = _subnets;
    final zones = <DiagramExportZone>[];
    for (int i = 0; i < subnets.length; i++) {
      final sub = subnets[i];
      zones.add(
        DiagramExportZone(
          id: 'sub_${sub['id'] ?? i}',
          title: '${sub['name'] ?? 'Subred'} (${sub['cidr'] ?? ''})',
          subtitle: 'VLAN ${sub['vlan_id'] ?? '-'} • GW ${sub['gateway'] ?? '-'}',
          x: 24.0 + (i % 2) * 680.0,
          y: 24.0 + (i ~/ 2) * 280.0,
          width: 650.0,
          height: 255.0,
          colorHex: '#0284C7',
        ),
      );
    }

    final nodes = <DiagramExportNode>[];
    final edges = <DiagramExportEdge>[];
    for (int i = 0; i < assets.length; i++) {
      final a = assets[i];
      final id = 'asset_${a['id'] ?? i}';
      final col = i % 5;
      final row = i ~/ 5;
      final st = (a['status'] ?? 'online').toString();
      nodes.add(
        DiagramExportNode(
          id: id,
          code: '${a['code'] ?? ''}',
          name: '${a['name'] ?? a['hostname'] ?? ''}',
          subtitle: '${a['asset_class_label'] ?? a['asset_class'] ?? 'CI'}',
          ip: '${a['primary_ip'] ?? a['heartbeat_ip'] ?? ''}',
          modelName: '${a['os_or_firmware'] ?? a['environment'] ?? ''}',
          serialNumber: '${a['fqdn'] ?? ''}',
          status: st,
          x: 40.0 + col * 265.0,
          y: 55.0 + row * 110.0,
          width: 240.0,
          height: 86.0,
          colorHex: st == 'offline' ? '#DC2626' : '#1E3A8A',
        ),
      );
      if (a['parent_asset_id'] != null) {
        edges.add(
          DiagramExportEdge(
            id: 'edge_parent_${a['id']}',
            sourceId: 'asset_${a['parent_asset_id']}',
            targetId: id,
            label: 'HOST/HIPERVISOR',
            detail: '${a['hosting_mode'] ?? 'VM'}',
            colorHex: '#2563EB',
          ),
        );
      }
    }

    return DiagramExportDocument(
      moduleName: '6. CMDB & Control Multi-IP',
      title: 'Inventario CMDB & Direccionamiento IPAM (${assets.length} activos)',
      subtitle: '${subnets.length} Subredes/VLANs • ${assets.length} CIs / Servidores / VMs',
      fileBaseName: 'inventario_cmdb_rackdoc',
      canvasWidth: 1420,
      canvasHeight: (120.0 + ((assets.length ~/ 5) + 1) * 115.0).clamp(900.0, 2600.0),
      zones: zones,
      nodes: nodes,
      edges: edges,
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
                      'CMDB e IPAM',
                      style: TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w900,
                        color: AppPalette.slate900,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Inventario de activos, direcciones IP, subredes y relaciones de alojamiento.',
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
                  if (widget.onNavigateToSreDocs != null) {
                    widget.onNavigateToSreDocs!();
                  } else {
                    showApiOnboardingGuideDialog(
                      context,
                      api: widget.api,
                    );
                  }
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppPalette.blue900,
                  side: const BorderSide(color: AppPalette.blue300, width: 1.4),
                  backgroundColor: AppPalette.blue50,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                icon: const Icon(Icons.menu_book_rounded, size: 17),
                label: const Text(
                  'Guía y API',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 8),
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
                  'Comprobar IP',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 8),
              DiagramExportMenuButton(
                buttonLabel:
                    'Exportar',
                onExportExcel: widget.onExportExcel,
                documentBuilder: _buildCmdbExportDocument,
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
                    'Añadir activo',
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
        'Inventario',
      ),
      (
        'verifier',
        Icons.radar_rounded,
        'Comprobar IPs',
      ),
      (
        'subnets_ipam',
        Icons.grid_on_rounded,
        'Subredes y mapa IP',
      ),
      (
        'hypervisor_tree',
        Icons.account_tree_outlined,
        'Hosts y máquinas virtuales',
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
}
