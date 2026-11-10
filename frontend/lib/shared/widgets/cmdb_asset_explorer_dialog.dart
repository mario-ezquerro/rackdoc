import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/theme.dart';

/// Modal Explorador Maestro-Detalle (estilo Finder) para seleccionar un activo de la CMDB
/// agrupado por Redes / Subredes (CIDR + Máscara de red + VLAN), diseñado para escalar
/// con fluidez a 600–1.000+ dispositivos mediante renderizado virtualizado (`ListView.builder`).
class CmdbAssetExplorerDialog extends StatefulWidget {
  final RackDocApiClient api;
  final List<Map<String, dynamic>>? initialAssets;
  final List<Map<String, dynamic>>? initialSubnets;

  /// 'rack' | 'floor' | 'stack' | 'general'
  final String contextMode;
  final String title;
  final String subtitle;
  final int? preselectedAssetId;
  final Set<int> alreadyInStackAssetIds;
  final bool defaultOnlyUnplaced;

  /// Modo multiselección: en vez de devolver un activo, devuelve el conjunto de
  /// ids marcados. Pensado para asignar DECENAS o CIENTOS de equipos de golpe
  /// (p. ej. los miembros de un HostGroup de alarmas) sin una lista plana de
  /// chips imposible de recorrer.
  final bool multiSelect;
  final Set<int> initialSelectedAssetIds;
  final String? confirmLabel;

  const CmdbAssetExplorerDialog({
    super.key,
    required this.api,
    this.initialAssets,
    this.initialSubnets,
    this.contextMode = 'general',
    this.title = 'Explorador de Activos CMDB por Redes / Subredes',
    this.subtitle =
        'Selecciona una red en la columna izquierda y elige el equipo a vincular en el panel derecho.',
    this.preselectedAssetId,
    this.alreadyInStackAssetIds = const {},
    this.defaultOnlyUnplaced = true,
    this.multiSelect = false,
    this.initialSelectedAssetIds = const {},
    this.confirmLabel,
  });

  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    required RackDocApiClient api,
    List<Map<String, dynamic>>? initialAssets,
    List<Map<String, dynamic>>? initialSubnets,
    String contextMode = 'general',
    String? title,
    String? subtitle,
    int? preselectedAssetId,
    Set<int> alreadyInStackAssetIds = const {},
    bool defaultOnlyUnplaced = true,
  }) {
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => CmdbAssetExplorerDialog(
        api: api,
        initialAssets: initialAssets,
        initialSubnets: initialSubnets,
        contextMode: contextMode,
        title:
            title ?? 'Explorador de Activos CMDB por Redes / Máscara de Red',
        subtitle: subtitle ??
            'Filtra entre cientos de dispositivos agrupados por su Subred (CIDR / Máscara) y estado de ubicación.',
        preselectedAssetId: preselectedAssetId,
        alreadyInStackAssetIds: alreadyInStackAssetIds,
        defaultOnlyUnplaced: defaultOnlyUnplaced,
      ),
    );
  }

  /// Abre el explorador en modo multiselección y devuelve los ids marcados
  /// (null si se cancela). Muestra TODOS los equipos de la CMDB, ubicados en
  /// racks o no, porque aquí no se está ubicando nada: se está eligiendo a
  /// quién vigilar.
  static Future<Set<int>?> showMulti(
    BuildContext context, {
    required RackDocApiClient api,
    required Set<int> initialSelectedAssetIds,
    List<Map<String, dynamic>>? initialAssets,
    List<Map<String, dynamic>>? initialSubnets,
    String? title,
    String? subtitle,
    String? confirmLabel,
  }) {
    return showDialog<Set<int>>(
      context: context,
      builder: (ctx) => CmdbAssetExplorerDialog(
        api: api,
        initialAssets: initialAssets,
        initialSubnets: initialSubnets,
        contextMode: 'general',
        title: title ?? 'Seleccionar Equipos de la CMDB y de los Racks',
        subtitle: subtitle ??
            'Filtra por Subred, texto, clase o estado y marca los equipos. La lista está virtualizada: '
            'aguanta cientos de equipos sin degradarse.',
        alreadyInStackAssetIds: const {},
        defaultOnlyUnplaced: false,
        multiSelect: true,
        initialSelectedAssetIds: initialSelectedAssetIds,
        confirmLabel: confirmLabel,
      ),
    );
  }

  @override
  State<CmdbAssetExplorerDialog> createState() =>
      _CmdbAssetExplorerDialogState();
}

class _SubnetGroupNode {
  final String key;
  final String cidr;
  final String subnetMask;
  final String name;
  final int? vlanId;
  final String gateway;
  final bool isExplicitSubnet;
  final List<Map<String, dynamic>> assets = [];

  _SubnetGroupNode({
    required this.key,
    required this.cidr,
    required this.subnetMask,
    required this.name,
    this.vlanId,
    this.gateway = '',
    this.isExplicitSubnet = true,
  });
}

class _CmdbAssetExplorerDialogState extends State<CmdbAssetExplorerDialog> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _assets = [];
  List<Map<String, dynamic>> _subnets = [];

  String _selectedSubnetKey = '__ALL__';
  late bool _onlyUnplaced;
  String _statusFilter = 'all'; // 'all' | 'online' | 'offline'
  String _classFilter = 'all'; // 'all' | 'physical' | 'virtual' | 'network'

  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _subnetSearchCtrl = TextEditingController();
  String _searchQuery = '';
  String _subnetQuery = '';

  Map<String, dynamic>? _selectedAsset;

  /// Ids marcados en modo multiselección.
  late Set<int> _multiSelected;

  @override
  void initState() {
    super.initState();
    _onlyUnplaced = widget.defaultOnlyUnplaced;
    _multiSelected = {...widget.initialSelectedAssetIds};
    _loadData();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _subnetSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    if (widget.initialAssets != null &&
        widget.initialAssets!.isNotEmpty &&
        widget.initialSubnets != null) {
      _assets = widget.initialAssets!;
      _subnets = widget.initialSubnets!;
      _initPreselected();
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ov = await widget.api.fetchCmdbOverview();
      final rawAssets = (ov['assets'] as List?) ?? [];
      final rawSubnets = (ov['subnets'] as List?) ?? [];
      _assets = rawAssets
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      _subnets = rawSubnets
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      _initPreselected();
      if (mounted) {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  void _initPreselected() {
    if (widget.preselectedAssetId != null) {
      for (final a in _assets) {
        if ((a['id'] as num?)?.toInt() == widget.preselectedAssetId) {
          _selectedAsset = a;
          // Si el preseleccionado ya estaba ubicado, desactivar filtro solo pendientes para que sea visible
          if (!_isAssetUnplaced(a)) {
            _onlyUnplaced = false;
          }
          break;
        }
      }
    }
  }

  /// Determina si un activo está "pendiente de ubicar" según el contexto donde se abrió el explorador.
  bool _isAssetUnplaced(Map<String, dynamic> a) {
    final id = (a['id'] as num?)?.toInt();
    final hasRack = a['rack_device_id'] != null || a['rack_id'] != null;
    final hasFloor = a['floor_device_id'] != null || a['floor_id'] != null;
    switch (widget.contextMode) {
      case 'rack':
        return !hasRack;
      case 'floor':
        return !hasFloor && !hasRack;
      case 'stack':
        return id == null || !widget.alreadyInStackAssetIds.contains(id);
      default:
        return !hasRack && !hasFloor;
    }
  }

  bool _matchesClassFilter(Map<String, dynamic> a) {
    if (_classFilter == 'all') return true;
    final cls = (a['asset_class'] ?? '').toString().toLowerCase();
    final src = (a['sync_source'] ?? '').toString().toLowerCase();
    if (_classFilter == 'physical') {
      return cls == 'physical_server' ||
          cls == 'floor_endpoint' ||
          src == 'rack_device' ||
          src == 'floor_device';
    }
    if (_classFilter == 'virtual') {
      return cls == 'virtual_machine' ||
          cls == 'container' ||
          cls == 'container_lxc' ||
          cls == 'virtual_appliance' ||
          cls == 'cloud_instance';
    }
    if (_classFilter == 'network') {
      return cls == 'network_security' ||
          cls == 'vip_cluster' ||
          cls == 'cluster_vip' ||
          cls == 'storage_san_nas';
    }
    return true;
  }

  bool _matchesStatusFilter(Map<String, dynamic> a) {
    if (_statusFilter == 'all') return true;
    final st = (a['status'] ?? '').toString().toLowerCase();
    if (_statusFilter == 'online') return st == 'online';
    if (_statusFilter == 'offline') return st != 'online';
    return true;
  }

  bool _matchesSearch(Map<String, dynamic> a) {
    if (_searchQuery.isEmpty) return true;
    final q = _searchQuery.toLowerCase();
    final ip = (a['heartbeat_ip'] ?? '').toString().toLowerCase();
    final code = (a['code'] ?? '').toString().toLowerCase();
    final name = (a['name'] ?? '').toString().toLowerCase();
    final host = (a['hostname'] ?? '').toString().toLowerCase();
    final fqdn = (a['fqdn'] ?? '').toString().toLowerCase();
    final model = (a['model_name'] ?? '').toString().toLowerCase();
    final serial = (a['serial_or_uuid'] ?? '').toString().toLowerCase();
    final os = (a['os_or_firmware'] ?? '').toString().toLowerCase();
    if (ip.contains(q) ||
        code.contains(q) ||
        name.contains(q) ||
        host.contains(q) ||
        fqdn.contains(q) ||
        model.contains(q) ||
        serial.contains(q) ||
        os.contains(q)) {
      return true;
    }
    final ips = (a['ip_addresses'] as List?) ?? const [];
    for (final rec in ips) {
      if (rec is Map) {
        final rIp = (rec['ip_address'] ?? '').toString().toLowerCase();
        final rMac = (rec['mac_address'] ?? '').toString().toLowerCase();
        if (rIp.contains(q) || rMac.contains(q)) return true;
      }
    }
    return false;
  }

  static int? _ipToInt(String ip) {
    final parts = ip.trim().split('.');
    if (parts.length != 4) return null;
    int res = 0;
    for (final p in parts) {
      final v = int.tryParse(p);
      if (v == null || v < 0 || v > 255) return null;
      res = (res << 8) | v;
    }
    return res;
  }

  static bool _ipInCidr(String ip, String cidr) {
    final ipInt = _ipToInt(ip);
    if (ipInt == null) return false;
    final slash = cidr.split('/');
    final netInt = _ipToInt(slash.first);
    if (netInt == null) return false;
    final prefix = slash.length > 1 ? (int.tryParse(slash[1]) ?? 24) : 24;
    if (prefix <= 0) return true;
    if (prefix >= 32) return ipInt == netInt;
    final mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    return (ipInt & mask) == (netInt & mask);
  }

  /// Construye los grupos de subred para la columna izquierda respetando los filtros superiores
  /// (excepto el filtro de subred seleccionada).
  List<_SubnetGroupNode> _buildSubnetGroups(
    List<Map<String, dynamic>> baseFilteredAssets,
  ) {
    final Map<String, _SubnetGroupNode> groupsByKey = {};
    final List<_SubnetGroupNode> explicitNodes = [];

    for (final s in _subnets) {
      final cidr = (s['cidr'] ?? '').toString().trim();
      if (cidr.isEmpty) continue;
      final key = 'sub:$cidr';
      if (groupsByKey.containsKey(key)) continue;
      final node = _SubnetGroupNode(
        key: key,
        cidr: cidr,
        subnetMask: (s['subnet_mask'] ?? '255.255.255.0').toString(),
        name: (s['name'] ?? cidr).toString(),
        vlanId: (s['vlan_id'] as num?)?.toInt(),
        gateway: (s['gateway'] ?? '').toString(),
        isExplicitSubnet: true,
      );
      groupsByKey[key] = node;
      explicitNodes.add(node);
    }

    final Map<String, _SubnetGroupNode> autoNodesByKey = {};
    final _SubnetGroupNode noIpNode = _SubnetGroupNode(
      key: '__NO_IP__',
      cidr: 'Sin IP',
      subnetMask: '—',
      name: 'Equipos sin IP asignada',
      isExplicitSubnet: false,
    );

    for (final a in baseFilteredAssets) {
      final primaryIp = (a['heartbeat_ip'] ?? '').toString().trim();
      final ips = (a['ip_addresses'] as List?) ?? const [];
      String effectiveIp = primaryIp;
      if (effectiveIp.isEmpty && ips.isNotEmpty && ips.first is Map) {
        effectiveIp = ((ips.first as Map)['ip_address'] ?? '').toString().trim();
      }

      if (effectiveIp.isEmpty) {
        noIpNode.assets.add(a);
        continue;
      }

      // 1. Buscar coincidencia en subredes explícitas de CMDB (priorizando prefijo más específico)
      _SubnetGroupNode? matchedNode;
      for (final node in explicitNodes) {
        if (_ipInCidr(effectiveIp, node.cidr)) {
          matchedNode = node;
          break;
        }
      }

      if (matchedNode != null) {
        matchedNode.assets.add(a);
      } else {
        // 2. Agrupar automáticamente por bloque /24 (x.y.z.0/24 • 255.255.255.0)
        final parts = effectiveIp.split('.');
        final prefix24 = parts.length == 4
            ? '${parts[0]}.${parts[1]}.${parts[2]}.0/24'
            : effectiveIp;
        final key = 'auto:$prefix24';
        final mask = (a['primary_subnet_mask'] ?? '255.255.255.0').toString();
        final node = autoNodesByKey.putIfAbsent(
          key,
          () => _SubnetGroupNode(
            key: key,
            cidr: prefix24,
            subnetMask: mask.isNotEmpty ? mask : '255.255.255.0',
            name: 'Red detectada $prefix24',
            isExplicitSubnet: false,
          ),
        );
        node.assets.add(a);
      }
    }

    final result = <_SubnetGroupNode>[
      ...explicitNodes,
      ...autoNodesByKey.values,
      if (noIpNode.assets.isNotEmpty) noIpNode,
    ];

    // Ordenar cada lista interna por IP numérica y luego por código
    for (final g in result) {
      g.assets.sort((a, b) {
        final ipA = _ipToInt((a['heartbeat_ip'] ?? '').toString()) ?? 0x7FFFFFFF;
        final ipB = _ipToInt((b['heartbeat_ip'] ?? '').toString()) ?? 0x7FFFFFFF;
        if (ipA != ipB) return ipA.compareTo(ipB);
        return (a['code'] ?? '').toString().compareTo((b['code'] ?? '').toString());
      });
    }

    return result;
  }

  Map<String, String> _extractPrimaryIpDetails(
    Map<String, dynamic> asset,
    List<_SubnetGroupNode> groups,
  ) {
    String ip = (asset['heartbeat_ip'] ?? '').toString().trim();
    String mask = (asset['primary_subnet_mask'] ?? '255.255.255.0').toString().trim();
    String gw = '';
    String mac = '';
    String vlan = '';
    String fqdn = (asset['fqdn'] ?? '').toString().trim();

    final ips = (asset['ip_addresses'] as List?) ?? const [];
    if (ips.isNotEmpty && ips.first is Map) {
      final first = Map<String, dynamic>.from(ips.first as Map);
      if (ip.isEmpty) ip = (first['ip_address'] ?? '').toString().trim();
      final m = (first['subnet_mask'] ?? '').toString().trim();
      if (m.isNotEmpty) mask = m;
      gw = (first['gateway'] ?? '').toString().trim();
      mac = (first['mac_address'] ?? '').toString().trim();
      if (first['vlan_id'] != null) vlan = '${first['vlan_id']}';
      if (fqdn.isEmpty) fqdn = (first['fqdn'] ?? '').toString().trim();
    }

    if (ip.isNotEmpty && gw.isEmpty) {
      for (final g in groups) {
        if (g.cidr != 'Sin IP' && _ipInCidr(ip, g.cidr)) {
          if (g.gateway.isNotEmpty) gw = g.gateway;
          if (g.subnetMask.isNotEmpty && g.subnetMask != '—') {
            mask = g.subnetMask;
          }
          if (vlan.isEmpty && g.vlanId != null) vlan = '${g.vlanId}';
          break;
        }
      }
      if (gw.isEmpty) {
        final parts = ip.split('.');
        if (parts.length == 4) {
          gw = '${parts[0]}.${parts[1]}.${parts[2]}.1';
        }
      }
    }

    return {
      'ip': ip,
      'subnet_mask': mask.isEmpty ? '255.255.255.0' : mask,
      'gateway': gw,
      'mac_address': mac,
      'vlan_id': vlan,
      'fqdn': fqdn,
    };
  }

  String _unplacedFilterLabel() {
    switch (widget.contextMode) {
      case 'rack':
        return 'Solo pendientes de montar en Rack';
      case 'floor':
        return 'Solo pendientes de ubicar en Planta / Rack';
      case 'stack':
        return 'Solo pendientes de añadir a este Stack';
      default:
        return 'Solo pendientes de ubicar';
    }
  }

  Widget _buildPlacementBadge(Map<String, dynamic> a) {
    final id = (a['id'] as num?)?.toInt();
    final rackCode = (a['rack_code'] ?? '').toString().trim();
    final startU = a['start_u'];
    final floorName = (a['floor_name'] ?? '').toString().trim();
    final inStack = id != null && widget.alreadyInStackAssetIds.contains(id);

    if (rackCode.isNotEmpty) {
      return _pill(
        icon: Icons.dns_rounded,
        text: 'En Rack $rackCode${startU != null ? " (U$startU)" : ""}',
        bg: const Color(0xFFFEF3C7),
        fg: const Color(0xFF92400E),
        border: const Color(0xFFFCD34D),
      );
    }
    if (floorName.isNotEmpty) {
      return _pill(
        icon: Icons.location_on_outlined,
        text: 'En Planta: $floorName',
        bg: const Color(0xFFE0E7FF),
        fg: const Color(0xFF3730A3),
        border: const Color(0xFFA5B4FC),
      );
    }
    if (inStack) {
      return _pill(
        icon: Icons.hub_outlined,
        text: 'Ya en este Stack',
        bg: const Color(0xFFE0F2FE),
        fg: const Color(0xFF075985),
        border: const Color(0xFF7DD3FC),
      );
    }
    return _pill(
      icon: Icons.check_circle_outline_rounded,
      text: 'Disponible para vincular',
      bg: const Color(0xFFDCFCE7),
      fg: const Color(0xFF166534),
      border: const Color(0xFF86EFAC),
    );
  }

  Widget _pill({
    required IconData icon,
    required String text,
    required Color bg,
    required Color fg,
    required Color border,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: fg),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalCount = _assets.length;
    final unplacedTotalCount = _assets.where(_isAssetUnplaced).length;

    // 1. Filtrar por estado de ubicación, clase, estado online y búsqueda de texto
    final baseFiltered = _assets.where((a) {
      if (_onlyUnplaced && !_isAssetUnplaced(a)) return false;
      if (!_matchesClassFilter(a)) return false;
      if (!_matchesStatusFilter(a)) return false;
      if (!_matchesSearch(a)) return false;
      return true;
    }).toList();

    // 2. Agrupar por Subred / Máscara
    final allGroups = _buildSubnetGroups(baseFiltered);
    final visibleGroups = _subnetQuery.isEmpty
        ? allGroups
        : allGroups.where((g) {
            final q = _subnetQuery.toLowerCase();
            return g.cidr.toLowerCase().contains(q) ||
                g.subnetMask.toLowerCase().contains(q) ||
                g.name.toLowerCase().contains(q) ||
                (g.vlanId != null && 'vlan ${g.vlanId}'.contains(q));
          }).toList();

    // 3. Activos mostrados en el panel derecho según la subred seleccionada
    List<Map<String, dynamic>> displayedAssets;
    _SubnetGroupNode? activeGroup;
    if (_selectedSubnetKey == '__ALL__') {
      displayedAssets = baseFiltered;
    } else {
      activeGroup =
          allGroups.where((g) => g.key == _selectedSubnetKey).firstOrNull;
      displayedAssets = activeGroup?.assets ?? const [];
    }

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Container(
        width: 1080,
        height: 700,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // CABECERA DEL EXPLORADOR
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
              decoration: const BoxDecoration(
                color: AppPalette.slate900,
                borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppPalette.blue600,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(
                      Icons.account_tree_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppPalette.slate300,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Text(
                      'CMDB: $totalCount equipos ($unplacedTotalCount disponibles)',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Cerrar',
                    onPressed: () => Navigator.pop(context, null),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),

            // BARRA DE BÚSQUEDA Y FILTROS RÁPIDOS
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: const BoxDecoration(
                color: AppPalette.slate50,
                border: Border(bottom: BorderSide(color: AppPalette.slate200)),
              ),
              child: Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 340,
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: (v) => setState(() => _searchQuery = v.trim()),
                      style: const TextStyle(fontSize: 12),
                      decoration: InputDecoration(
                        hintText:
                            'Buscar por IP, Código, Nombre, Modelo, S/N, MAC o FQDN...',
                        prefixIcon: const Icon(Icons.search, size: 17),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 15),
                                onPressed: () {
                                  _searchCtrl.clear();
                                  setState(() => _searchQuery = '');
                                },
                              )
                            : null,
                        isDense: true,
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  FilterChip(
                    selected: _onlyUnplaced,
                    selectedColor: const Color(0xFFDCFCE7),
                    checkmarkColor: const Color(0xFF166534),
                    label: Text(
                      '${_unplacedFilterLabel()} ($unplacedTotalCount)',
                      style: TextStyle(
                        fontSize: 11.2,
                        fontWeight: FontWeight.w800,
                        color: _onlyUnplaced
                            ? const Color(0xFF166534)
                            : AppPalette.slate700,
                      ),
                    ),
                    onSelected: (v) => setState(() => _onlyUnplaced = v),
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
                        border: Border.all(color: AppPalette.slate300),
                      ),
                      child: DropdownButton<String>(
                        value: _classFilter,
                        isDense: true,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: AppPalette.slate800,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text('Todas las clases'),
                          ),
                          DropdownMenuItem(
                            value: 'physical',
                            child: Text('🗄️ Servidores / Equipos Físicos'),
                          ),
                          DropdownMenuItem(
                            value: 'virtual',
                            child: Text('🖥️ VMs / Contenedores'),
                          ),
                          DropdownMenuItem(
                            value: 'network',
                            child: Text('🛡️ Switches / Firewalls / Storage'),
                          ),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _classFilter = v);
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
                        border: Border.all(color: AppPalette.slate300),
                      ),
                      child: DropdownButton<String>(
                        value: _statusFilter,
                        isDense: true,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: AppPalette.slate800,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text('Todos los estados'),
                          ),
                          DropdownMenuItem(
                            value: 'online',
                            child: Text('🟢 Solo Online'),
                          ),
                          DropdownMenuItem(
                            value: 'offline',
                            child: Text('🔴 Offline / Sin monitorizar'),
                          ),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _statusFilter = v);
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // CUERPO MAESTRO-DETALLE (COLUMNA IZQUIERDA REDES + PANEL DERECHO ACTIVOS)
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Text(
                        'Error al cargar CMDB: $_error',
                        style: const TextStyle(color: AppPalette.red600),
                      ),
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // COLUMNA IZQUIERDA: ÁRBOL DE REDES / SUBREDES (CIDR + MÁSCARA + VLAN)
                        Container(
                          width: 315,
                          decoration: const BoxDecoration(
                            color: Color(0xFFF8FAFC),
                            border: Border(
                              right: BorderSide(color: AppPalette.slate200),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  10,
                                  10,
                                  10,
                                  6,
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.lan_outlined,
                                      size: 15,
                                      color: AppPalette.blue700,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'REDES / MÁSCARAS (${allGroups.length})',
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w900,
                                        color: AppPalette.slate700,
                                        letterSpacing: 0.3,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                child: TextField(
                                  controller: _subnetSearchCtrl,
                                  onChanged: (v) =>
                                      setState(() => _subnetQuery = v.trim()),
                                  style: const TextStyle(fontSize: 11.5),
                                  decoration: InputDecoration(
                                    hintText:
                                        'Filtrar red (ej. 10.20, /24, VLAN)...',
                                    prefixIcon: const Icon(
                                      Icons.filter_alt_outlined,
                                      size: 15,
                                    ),
                                    isDense: true,
                                    filled: true,
                                    fillColor: Colors.white,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 6,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(7),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Expanded(
                                child: ListView(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  children: [
                                    _buildSubnetTile(
                                      keyId: '__ALL__',
                                      title: '🌐 Todas las Redes / Subredes',
                                      subtitle:
                                          'Mostrar todos los equipos filtrados',
                                      maskLabel: 'Todas las máscaras',
                                      vlanId: null,
                                      count: baseFiltered.length,
                                      isExplicit: true,
                                    ),
                                    const Divider(height: 12),
                                    for (final g in visibleGroups)
                                      _buildSubnetTile(
                                        keyId: g.key,
                                        title: g.cidr,
                                        subtitle: g.name,
                                        maskLabel: 'Máscara: ${g.subnetMask}',
                                        vlanId: g.vlanId,
                                        count: g.assets.length,
                                        isExplicit: g.isExplicitSubnet,
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),

                        // PANEL DERECHO: TABLA VIRTUALIZADA DE EQUIPOS DE LA RED SELECCIONADA
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Subcabecera de la red activa
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 9,
                                ),
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  border: Border(
                                    bottom: BorderSide(
                                      color: AppPalette.slate200,
                                    ),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      activeGroup != null
                                          ? Icons.router_outlined
                                          : Icons.grid_view_rounded,
                                      size: 16,
                                      color: AppPalette.blue700,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        activeGroup != null
                                            ? '${activeGroup.cidr} (${activeGroup.subnetMask}) • ${activeGroup.name}'
                                            : 'Todas las Redes (${displayedAssets.length} equipos)',
                                        style: const TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w900,
                                          color: AppPalette.slate900,
                                        ),
                                      ),
                                    ),
                                    if (activeGroup != null &&
                                        activeGroup.vlanId != null)
                                      Container(
                                        margin: const EdgeInsets.only(right: 8),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppPalette.blue50,
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          border: Border.all(
                                            color: AppPalette.blue300,
                                          ),
                                        ),
                                        child: Text(
                                          'VLAN ${activeGroup.vlanId}',
                                          style: const TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w800,
                                            color: AppPalette.blue900,
                                          ),
                                        ),
                                      ),
                                    Text(
                                      'Mostrando ${displayedAssets.length} equipos',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: AppPalette.slate500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Lista virtualizada (soporta 1000+ elementos sin lag)
                              Expanded(
                                child: displayedAssets.isEmpty
                                    ? Center(
                                        child: Padding(
                                          padding: const EdgeInsets.all(24),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(
                                                Icons.search_off_rounded,
                                                size: 40,
                                                color: AppPalette.slate400,
                                              ),
                                              const SizedBox(height: 10),
                                              const Text(
                                                'No hay activos que coincidan con el filtro en esta red.',
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w800,
                                                  color: AppPalette.slate700,
                                                ),
                                              ),
                                              const SizedBox(height: 6),
                                              if (_onlyUnplaced)
                                                OutlinedButton.icon(
                                                  onPressed: () => setState(
                                                    () => _onlyUnplaced = false,
                                                  ),
                                                  icon: const Icon(
                                                    Icons.visibility_outlined,
                                                    size: 15,
                                                  ),
                                                  label: Text(
                                                    'Mostrar también los equipos ya ubicados ($totalCount totales)',
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      )
                                    : ListView.builder(
                                        padding: const EdgeInsets.all(10),
                                        itemCount: displayedAssets.length,
                                        itemBuilder: (ctx, idx) {
                                          final a = displayedAssets[idx];
                                          final id = (a['id'] as num?)?.toInt();
                                          final isSelected =
                                              widget.multiSelect
                                              ? (id != null &&
                                                    _multiSelected.contains(id))
                                              : (_selectedAsset != null &&
                                                    (_selectedAsset!['id']
                                                            as num?)
                                                        ?.toInt() ==
                                                    id);
                                          return _buildAssetRow(
                                            a,
                                            isSelected: isSelected,
                                            allGroups: allGroups,
                                          );
                                        },
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),

            // PIE CON RESUMEN DEL EQUIPO SELECCIONADO Y BOTÓN DE CONFIRMACIÓN
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
              decoration: const BoxDecoration(
                color: AppPalette.slate50,
                border: Border(top: BorderSide(color: AppPalette.slate200)),
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(14),
                ),
              ),
              child: widget.multiSelect
                  ? Row(
                      children: [
                        Icon(
                          _multiSelected.isEmpty
                              ? Icons.radio_button_unchecked
                              : Icons.check_circle,
                          size: 18,
                          color: _multiSelected.isEmpty
                              ? AppPalette.slate400
                              : AppPalette.green600,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${_multiSelected.length} equipo(s) seleccionado(s)',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.slate900,
                          ),
                        ),
                        const SizedBox(width: 14),
                        TextButton.icon(
                          onPressed: displayedAssets.isEmpty
                              ? null
                              : () => setState(() {
                                  for (final a in displayedAssets) {
                                    final id = (a['id'] as num?)?.toInt();
                                    if (id != null) _multiSelected.add(id);
                                  }
                                }),
                          icon: const Icon(Icons.done_all_rounded, size: 16),
                          label: Text(
                            'Marcar los ${displayedAssets.length} filtrados',
                            style: const TextStyle(fontSize: 11.5),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: displayedAssets.isEmpty
                              ? null
                              : () => setState(() {
                                  for (final a in displayedAssets) {
                                    final id = (a['id'] as num?)?.toInt();
                                    if (id != null) _multiSelected.remove(id);
                                  }
                                }),
                          icon: const Icon(Icons.remove_done_rounded, size: 16),
                          label: const Text(
                            'Desmarcar los filtrados',
                            style: TextStyle(fontSize: 11.5),
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.pop(context, null),
                          child: const Text('Cancelar'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: () =>
                              Navigator.pop(context, {..._multiSelected}),
                          icon: const Icon(Icons.playlist_add_check_rounded,
                              size: 17),
                          label: Text(
                            widget.confirmLabel ??
                                'Confirmar ${_multiSelected.length} equipo(s)',
                          ),
                        ),
                      ],
                    )
                  : Row(
                children: [
                  Expanded(
                    child: _selectedAsset == null
                        ? const Text(
                            'Haz clic sobre un equipo de la lista (o doble clic para seleccionarlo directamente).',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: AppPalette.slate500,
                            ),
                          )
                        : Row(
                            children: [
                              const Icon(
                                Icons.check_circle,
                                color: AppPalette.green600,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Seleccionado: [${_selectedAsset!['code']}] ${_selectedAsset!['name']} '
                                  '• IP: ${_selectedAsset!['heartbeat_ip'] ?? "Sin IP"} '
                                  '${(_selectedAsset!['model_name'] ?? "").toString().isNotEmpty ? "• Modelo: ${_selectedAsset!['model_name']} " : ""}'
                                  '${(_selectedAsset!['serial_or_uuid'] ?? "").toString().isNotEmpty ? "• S/N: ${_selectedAsset!['serial_or_uuid']}" : ""}',
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: AppPalette.slate900,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: () => Navigator.pop(context, null),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _selectedAsset == null
                        ? null
                        : () {
                            final enriched = Map<String, dynamic>.from(
                              _selectedAsset!,
                            );
                            final netDetails = _extractPrimaryIpDetails(
                              enriched,
                              allGroups,
                            );
                            enriched['_resolved_ip'] = netDetails['ip'];
                            enriched['_resolved_subnet_mask'] =
                                netDetails['subnet_mask'];
                            enriched['_resolved_gateway'] =
                                netDetails['gateway'];
                            enriched['_resolved_mac'] =
                                netDetails['mac_address'];
                            enriched['_resolved_vlan'] = netDetails['vlan_id'];
                            enriched['_resolved_fqdn'] = netDetails['fqdn'];
                            Navigator.pop(context, enriched);
                          },
                    icon: const Icon(Icons.link_rounded, size: 17),
                    label: const Text('Vincular y Autocompletar Equipo'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubnetTile({
    required String keyId,
    required String title,
    required String subtitle,
    required String maskLabel,
    required int? vlanId,
    required int count,
    required bool isExplicit,
  }) {
    final selected = _selectedSubnetKey == keyId;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _selectedSubnetKey = keyId),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppPalette.blue50 : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? AppPalette.blue600 : AppPalette.slate200,
              width: selected ? 1.5 : 1.0,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                              fontFamily: keyId == '__ALL__'
                                  ? null
                                  : 'monospace',
                              color: selected
                                  ? AppPalette.blue900
                                  : AppPalette.slate900,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (vlanId != null)
                          Container(
                            margin: const EdgeInsets.only(left: 4),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE0E7FF),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'VLAN $vlanId',
                              style: const TextStyle(
                                fontSize: 9.2,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF3730A3),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: AppPalette.slate600,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      maskLabel,
                      style: const TextStyle(
                        fontSize: 9.8,
                        color: AppPalette.slate500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: count > 0
                      ? (selected ? AppPalette.blue600 : AppPalette.slate200)
                      : AppPalette.slate100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    color: count > 0
                        ? (selected ? Colors.white : AppPalette.slate800)
                        : AppPalette.slate400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAssetRow(
    Map<String, dynamic> a, {
    required bool isSelected,
    required List<_SubnetGroupNode> allGroups,
  }) {
    final code = (a['code'] ?? '').toString();
    final name = (a['name'] ?? '').toString();
    final host = (a['hostname'] ?? '').toString();
    final fqdn = (a['fqdn'] ?? '').toString();
    final clsLabel = (a['asset_class_label'] ?? a['asset_class'] ?? '')
        .toString();
    final os = (a['os_or_firmware'] ?? '').toString();
    final model = (a['model_name'] ?? '').toString().trim();
    final serial = (a['serial_or_uuid'] ?? '').toString().trim();
    final status = (a['status'] ?? 'unmonitored').toString();
    final pingMs = a['last_ping_ms'];
    final netDetails = _extractPrimaryIpDetails(a, allGroups);
    final ip = netDetails['ip'] ?? '';
    final mask = netDetails['subnet_mask'] ?? '';
    final mac = netDetails['mac_address'] ?? '';
    final vlan = netDetails['vlan_id'] ?? '';

    final isOnline = status == 'online';
    final statusColor = isOnline
        ? AppPalette.green600
        : (status == 'offline' ? AppPalette.red600 : AppPalette.slate400);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: () => setState(() {
          if (!widget.multiSelect) {
            _selectedAsset = a;
            return;
          }
          final id = (a['id'] as num?)?.toInt();
          if (id == null) return;
          if (!_multiSelected.remove(id)) _multiSelected.add(id);
        }),
        onDoubleTap: widget.multiSelect ? null : () {
          final enriched = Map<String, dynamic>.from(a);
          enriched['_resolved_ip'] = netDetails['ip'];
          enriched['_resolved_subnet_mask'] = netDetails['subnet_mask'];
          enriched['_resolved_gateway'] = netDetails['gateway'];
          enriched['_resolved_mac'] = netDetails['mac_address'];
          enriched['_resolved_vlan'] = netDetails['vlan_id'];
          enriched['_resolved_fqdn'] = netDetails['fqdn'];
          Navigator.pop(context, enriched);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFFEFF6FF) : Colors.white,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: isSelected ? AppPalette.blue600 : AppPalette.slate200,
              width: isSelected ? 1.6 : 1.0,
            ),
          ),
          child: Row(
            children: [
              if (widget.multiSelect) ...[
                SizedBox(
                  width: 22,
                  height: 22,
                  child: Checkbox(
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                    value: isSelected,
                    onChanged: (_) => setState(() {
                      final id = (a['id'] as num?)?.toInt();
                      if (id == null) return;
                      if (!_multiSelected.remove(id)) _multiSelected.add(id);
                    }),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              // Indicador estado Online/Offline
              Tooltip(
                message: isOnline
                    ? 'ONLINE (${pingMs ?? "<1"} ms)'
                    : status.toUpperCase(),
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Columna IP + Máscara + VLAN
              SizedBox(
                width: 155,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ip.isNotEmpty ? ip : 'Sin IP',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w900,
                        fontFamily: 'monospace',
                        color: ip.isNotEmpty
                            ? AppPalette.blue900
                            : AppPalette.slate400,
                      ),
                    ),
                    Text(
                      'Mask: $mask${vlan.isNotEmpty ? " • VLAN $vlan" : ""}',
                      style: const TextStyle(
                        fontSize: 9.8,
                        color: AppPalette.slate500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (mac.isNotEmpty)
                      Text(
                        'MAC: $mac',
                        style: const TextStyle(
                          fontSize: 9.5,
                          fontFamily: 'monospace',
                          color: AppPalette.slate500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // Columna Código + Nombre + Hostname/FQDN + Modelo + S/N
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: AppPalette.slate100,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: AppPalette.slate300),
                          ),
                          child: Text(
                            code,
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w900,
                              fontFamily: 'monospace',
                              color: AppPalette.slate900,
                            ),
                          ),
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: AppPalette.slate900,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Wrap(
                      spacing: 8,
                      runSpacing: 3,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '$clsLabel${os.isNotEmpty ? " • $os" : ""}${fqdn.isNotEmpty ? " • $fqdn" : (host.isNotEmpty ? " • $host" : "")}',
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: AppPalette.slate600,
                          ),
                        ),
                        if (model.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF0F9FF),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: const Color(0xFFBAE6FD),
                              ),
                            ),
                            child: Text(
                              'Modelo: $model',
                              style: const TextStyle(
                                fontSize: 9.8,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF0369A1),
                              ),
                            ),
                          ),
                        if (serial.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5F3FF),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: const Color(0xFFDDD6FE),
                              ),
                            ),
                            child: Text(
                              'S/N: $serial',
                              style: const TextStyle(
                                fontSize: 9.8,
                                fontWeight: FontWeight.w700,
                                fontFamily: 'monospace',
                                color: Color(0xFF6D28D9),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _buildPlacementBadge(a),
            ],
          ),
        ),
      ),
    );
  }
}
