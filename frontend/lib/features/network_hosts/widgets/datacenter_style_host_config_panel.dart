part of '../network_hosts_view.dart';

/// Panel lateral y modal reutilizable estilo Datacenter para configurar
/// hardware, red, chequeos de servicio, SSH y enlaces de un activo.
// =============================================================================
// PANEL DE CONFIGURACIÓN DE ELEMENTO / HOST ESTILO DATACENTER FLOOR
// (USADO TANTO EN EL PANEL DERECHO DEL STACK COMO EN EL MODAL "+ AÑADIR ELEMENTO")
// =============================================================================

class _DatacenterStyleHostConfigPanel extends StatefulWidget {
  final RackDocApiClient? api;
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
    this.api,
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
  late final TextEditingController _modelCtrl;
  late final TextEditingController _serialCtrl;
  int? _selectedExistingCmdbAssetId;
  Map<String, dynamic>? _selectedExistingCmdbAsset;

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

  // Sección C (3ª Gestión): CertScope — Verificación Certificado HTTPS/TLS
  late bool _csEnabled;
  late final TextEditingController _csUrlCtrl;
  late final TextEditingController _csPortCtrl;
  late String _csRenewalType;
  Map<String, dynamic> _csSummary = {};

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
    _modelCtrl = TextEditingController(
      text: (h['model_name'] as String?) ?? '',
    );
    _serialCtrl = TextEditingController(
      text: (h['serial_or_uuid'] as String?) ?? '',
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

    final rawCs = h['certscope_config'];
    final csCfg = rawCs is Map
        ? Map<String, dynamic>.from(rawCs)
        : <String, dynamic>{};
    if (csCfg.containsKey('enabled')) {
      _csEnabled = csCfg['enabled'] == true;
    } else {
      _csEnabled = (_connEnabled && _connHttps) ||
          (_hbEnabled && _hbHttp && _hbHttpScheme == 'https');
    }
    _csUrlCtrl = TextEditingController(
      text: (csCfg['url'] ?? csCfg['target_url'] ?? _connHttpsUrlCtrl.text)
          .toString(),
    );
    _csPortCtrl = TextEditingController(
      text: '${csCfg['port'] ?? 443}',
    );
    _csRenewalType =
        (csCfg['renewal_type'] ?? 'manual').toString() == 'auto_acme'
            ? 'auto_acme'
            : 'manual';
    _csSummary = csCfg;
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
      if (_selectedExistingCmdbAssetId != null)
        'asset_id': _selectedExistingCmdbAssetId
      else if (!widget.isNewElement && widget.host['id'] != null)
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
      'model_name': _modelCtrl.text.trim(),
      'serial_or_uuid': _serialCtrl.text.trim(),
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
      'certscope_enabled': _csEnabled,
      'certscope_url': _csUrlCtrl.text.trim().isNotEmpty
          ? _csUrlCtrl.text.trim()
          : _connHttpsUrlCtrl.text.trim(),
      'certscope_port': int.tryParse(_csPortCtrl.text.trim()) ?? 443,
      'certscope_renewal_type': _csRenewalType,
      'certscope_sni': _fqdnCtrl.text.trim(),
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
    // 'hypervisors' son los posibles padres del desplegable de alojamiento y
    // 'otherNodes' los posibles destinos de un enlace. Se calculan aquí porque
    // cada lista la consume una sección distinta, que la recibe por parámetro.
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
        _buildCabeceraDelPanel(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(11),
            children: [
              ..._buildIdentidadDelElemento(),
              ..._buildAlojamiento(hypervisors),
              ..._buildEnlacesDelLienzo(otherNodes),
              ..._buildGestionHeartbeat(),
              ..._buildGestionConectar(),
              ..._buildGestionCertScope(),
            ],
          ),
        ),
        if (widget.canEdit) _buildBarraDeGuardado(),
      ],
    );
  }

  // 1. Tipo de elemento, identificadores, IP, FQDN y sistema operativo.
  List<Widget> _buildIdentidadDelElemento() {
    return [
      if (widget.isNewElement && widget.api != null) ...[
        Container(
          padding: const EdgeInsets.all(9),
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: _selectedExistingCmdbAsset != null
                ? const Color(0xFFF0FDF4)
                : const Color(0xFFEFF6FF),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _selectedExistingCmdbAsset != null
                  ? const Color(0xFF22C55E)
                  : AppPalette.blue300,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.account_tree_rounded,
                    size: 15,
                    color: _selectedExistingCmdbAsset != null
                        ? const Color(0xFF15803D)
                        : AppPalette.blue900,
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      '0. ¿Seleccionar activo ya registrado en la CMDB?',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        color: AppPalette.slate900,
                      ),
                    ),
                  ),
                  if (_selectedExistingCmdbAsset != null)
                    InkWell(
                      onTap: () {
                        setState(() {
                          _selectedExistingCmdbAssetId = null;
                          _selectedExistingCmdbAsset = null;
                        });
                      },
                      child: const Text(
                        'Desvincular',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: AppPalette.red600,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              if (_selectedExistingCmdbAsset != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Vinculado: [${_selectedExistingCmdbAsset!['code']}] ${_selectedExistingCmdbAsset!['name']} (${_ipCtrl.text})',
                    style: const TextStyle(
                      fontSize: 10.8,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF166534),
                    ),
                  ),
                ),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: Colors.white,
                    side: const BorderSide(color: AppPalette.blue600),
                  ),
                  onPressed: () async {
                    final inStackIds = widget.allStackNodes
                        .map((n) => (n['host'] as Map?)?['id'])
                        .whereType<int>()
                        .toSet();
                    final picked = await CmdbAssetExplorerDialog.show(
                      context,
                      api: widget.api!,
                      contextMode: 'stack',
                      alreadyInStackAssetIds: inStackIds,
                      preselectedAssetId: _selectedExistingCmdbAssetId,
                      title:
                          'Seleccionar Activo de la CMDB por Redes / Máscara',
                      subtitle:
                          'Elige una Subred / Máscara CIDR en la columna izquierda y selecciona el equipo para autocompletar todos sus campos.',
                    );
                    if (picked != null) {
                      setState(() {
                        _selectedExistingCmdbAsset = picked;
                        _selectedExistingCmdbAssetId =
                            (picked['id'] as num?)?.toInt();
                        final rawCode =
                            (picked['code'] ?? '').toString().trim();
                        if (rawCode.isNotEmpty) _codeCtrl.text = rawCode;
                        final rawName =
                            (picked['name'] ?? '').toString().trim();
                        if (rawName.isNotEmpty) _nameCtrl.text = rawName;
                        final resIp = (picked['_resolved_ip'] ??
                                picked['heartbeat_ip'] ??
                                '')
                            .toString()
                            .trim();
                        if (resIp.isNotEmpty) {
                          _ipCtrl.text = resIp;
                          _connSshHostCtrl.text = resIp;
                          _hbHttpUrlCtrl.text = '$_hbHttpScheme://$resIp/health';
                          _connHttpUrlCtrl.text = 'http://$resIp/';
                          _connHttpsUrlCtrl.text = 'https://$resIp/';
                          _csUrlCtrl.text = 'https://$resIp/';
                        }
                        final resFqdn = (picked['_resolved_fqdn'] ??
                                picked['fqdn'] ??
                                '')
                            .toString()
                            .trim();
                        if (resFqdn.isNotEmpty) _fqdnCtrl.text = resFqdn;
                        final resOs = (picked['os_or_firmware'] ?? '')
                            .toString()
                            .trim();
                        if (resOs.isNotEmpty) _osCtrl.text = resOs;
                        final resModel =
                            (picked['model_name'] ?? '').toString().trim();
                        if (resModel.isNotEmpty) _modelCtrl.text = resModel;
                        final resSerial =
                            (picked['serial_or_uuid'] ?? '').toString().trim();
                        if (resSerial.isNotEmpty) _serialCtrl.text = resSerial;
                      });
                    }
                  },
                  icon: const Icon(
                    Icons.manage_search_rounded,
                    size: 15,
                    color: AppPalette.blue700,
                  ),
                  label: Text(
                    _selectedExistingCmdbAsset != null
                        ? 'Cambiar Activo CMDB (Por Redes / Máscara)'
                        : 'Explorar CMDB por Redes / Máscara de Red...',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: AppPalette.blue900,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
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
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _modelCtrl,
              style: const TextStyle(fontSize: 11.5),
              decoration: _compactDeco(
                'Marca / Modelo del Equipo',
                hint: 'Ej: Dell PowerEdge R750',
              ),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: TextField(
              controller: _serialCtrl,
              style: const TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
              ),
              decoration: _compactDeco(
                'Número de Serie / S/N',
                hint: 'Service Tag / UUID',
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
    ];
  }

  // 2. Alojamiento: clúster, bastidor físico o independiente.
  List<Widget> _buildAlojamiento(List<Map<String, dynamic>> hypervisors) {
    return [
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
    ];
  }

  // 3. Enlaces en el lienzo del stack, hacia cualquier otro elemento.
  List<Widget> _buildEnlacesDelLienzo(List<Map<String, dynamic>> otherNodes) {
    return [
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
    ];
  }

  // Sección A: Heartbeat, la monitorización que corre en el servidor.
  List<Widget> _buildGestionHeartbeat() {
    return [
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
    ];
  }

  // Sección B: Conectar, los accesos que se lanzan desde el navegador.
  List<Widget> _buildGestionConectar() {
    return [
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
      const SizedBox(height: 10),
    ];
  }

  // Sección C: CertScope, verificación de certificados HTTPS/TLS.
  List<Widget> _buildGestionCertScope() {
    return [
      // ===============================================================
      // SECCIÓN C (3ª GESTIÓN): CERTSCOPE — VERIFICACIÓN HTTPS/TLS
      // ===============================================================
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: _csEnabled
              ? AppTheme.accentPurple.withValues(alpha: 0.08)
              : AppTheme.bgSecondary,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _csEnabled ? AppTheme.accentPurple : AppTheme.border,
            width: _csEnabled ? 1.4 : 1.0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.verified_user_rounded,
                  size: 16,
                  color: _csEnabled
                      ? AppTheme.accentPurple
                      : AppTheme.textSecondary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '3. CERTSCOPE — VERIFICACIÓN HTTPS / TLS',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w900,
                          color: _csEnabled
                              ? AppTheme.textPrimary
                              : AppTheme.textSecondary,
                        ),
                      ),
                      const Text(
                        'Comprueba caducidad de certificado SSL/TLS y sincroniza con 7. CertScope',
                        style: TextStyle(
                          fontSize: 9.5,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: _csEnabled,
                  activeThumbColor: AppTheme.accentPurple,
                  onChanged: (v) => setState(() => _csEnabled = v),
                ),
              ],
            ),
            if (_csEnabled) ...[
              const SizedBox(height: 7),
              TextField(
                controller: _csUrlCtrl,
                style: const TextStyle(fontSize: 10.8),
                decoration: _compactDeco(
                  'URL / Host HTTPS a verificar en CertScope',
                  hint: 'https://10.20.20.160:8443/',
                ),
              ),
              const SizedBox(height: 5),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final pItem in const [
                    {'p': '443', 'l': 'Web :443'},
                    {'p': '8443', 'l': 'Tomcat/WildFly :8443'},
                    {'p': '9993', 'l': 'WildFly Admin :9993'},
                    {'p': '9443', 'l': 'WebSphere :9443'},
                    {'p': '7002', 'l': 'WebLogic :7002'},
                    {'p': '8006', 'l': 'Proxmox :8006'},
                    {'p': '636', 'l': 'LDAPS :636'},
                    {'p': '587', 'l': 'STARTTLS :587'},
                  ])
                    InkWell(
                      onTap: () => setState(() => _csPortCtrl.text = pItem['p']!),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _csPortCtrl.text.trim() == pItem['p']
                              ? AppTheme.accentPurple
                              : AppTheme.bgPrimary,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: AppTheme.border),
                        ),
                        child: Text(
                          pItem['l']!,
                          style: TextStyle(
                            fontSize: 9.2,
                            fontWeight: FontWeight.w700,
                            color: _csPortCtrl.text.trim() == pItem['p']
                                ? Colors.white
                                : AppTheme.textSecondary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: _csPortCtrl,
                      style: const TextStyle(fontSize: 10.8),
                      decoration: _compactDeco('Puerto TLS'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _csRenewalType,
                      isExpanded: true,
                      decoration: _compactDeco('Renovación'),
                      items: const [
                        DropdownMenuItem(
                          value: 'manual',
                          child: Text(
                            '🔔 Manual (Avisar)',
                            style: TextStyle(fontSize: 10.8),
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'auto_acme',
                          child: Text(
                            '🤖 Automática ACME',
                            style: TextStyle(fontSize: 10.8),
                          ),
                        ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => _csRenewalType = v);
                        }
                      },
                    ),
                  ),
                ],
              ),
              if ((_csSummary['common_name'] ?? '')
                      .toString()
                      .isNotEmpty ||
                  (_csSummary['last_error'] ?? '')
                      .toString()
                      .isNotEmpty) ...[
                const SizedBox(height: 7),
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: AppTheme.bgPrimary,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (_csSummary['common_name'] ?? '')
                                .toString()
                                .isNotEmpty
                            ? 'CN: ${_csSummary['common_name']} (${_csSummary['days_remaining'] ?? '?'} días)'
                            : 'Estado TLS: ${_csSummary['status'] ?? 'Pendiente'}',
                        style: const TextStyle(
                          fontSize: 10.2,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if ((_csSummary['issuer_cn'] ?? '')
                          .toString()
                          .isNotEmpty)
                        Text(
                          'CA: ${_csSummary['issuer_cn']} · Vence: ${(_csSummary['valid_until'] ?? '').toString().split('T').first}',
                          style: const TextStyle(
                            fontSize: 9.5,
                            color: AppTheme.textSecondary,
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
    ];
  }

  // Cabecera del panel: título del elemento y accesos directos.
  Widget _buildCabeceraDelPanel() {
    return Container(
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
    );
  }

  // Barra inferior de guardado. Quien llama decide si se muestra,
  // igual que antes hacía el 'if (widget.canEdit)' del árbol.
  Widget _buildBarraDeGuardado() {
    return Container(
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
    );
  }
}
