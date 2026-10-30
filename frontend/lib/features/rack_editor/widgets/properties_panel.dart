import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/api_client.dart';
import '../../../models/datacenter_models.dart';

class PropertiesPanel extends StatefulWidget {
  final RackDocApiClient api;
  final RackDetailModel rack;
  final RackDeviceModel? selectedDevice;
  final ConnectionModel? selectedConnection;
  final VoidCallback onRefreshRack;
  final VoidCallback onClearSelection;
  final ValueChanged<String> onSwitchFace;
  final ValueChanged<int> onNavigateToRack;
  final VoidCallback? onDeleteRack;
  final ValueChanged<RackDeviceModel>? onConfigureDevicePhoto;
  final UserModel? currentUser;

  const PropertiesPanel({
    super.key,
    required this.api,
    required this.rack,
    required this.selectedDevice,
    required this.selectedConnection,
    required this.onRefreshRack,
    required this.onClearSelection,
    required this.onSwitchFace,
    required this.onNavigateToRack,
    this.onDeleteRack,
    this.onConfigureDevicePhoto,
    this.currentUser,
  });

  @override
  State<PropertiesPanel> createState() => _PropertiesPanelState();
}

class _PropertiesPanelState extends State<PropertiesPanel> {
  bool _isSaving = false;
  bool _isPinging = false;
  String? _pingResultMessage;

  // Controladores para el Rack
  late TextEditingController _rackCodeCtrl;
  late TextEditingController _rackNameCtrl;
  late TextEditingController _rackRespCtrl;
  late TextEditingController _rackUnitsCtrl;
  late TextEditingController _rackManufCtrl;
  late TextEditingController _rackModelCtrl;
  late TextEditingController _rackSerialCtrl;
  late TextEditingController _rackPurchaseCtrl;
  late TextEditingController _rackOpStartCtrl;
  late TextEditingController _rackNotesCtrl;
  int? _rackAisleId;

  // Controladores para el Dispositivo seleccionado
  late TextEditingController _devCodeCtrl;
  late TextEditingController _devNameCtrl;
  late TextEditingController _devHostnameCtrl;
  late TextEditingController _devFqdnCtrl;
  late TextEditingController _devIpCtrl;
  late TextEditingController _devMaskCtrl;
  late TextEditingController _devGwCtrl;
  late TextEditingController _devMacCtrl;
  late TextEditingController _devVlanCtrl;
  late TextEditingController _devSerialCtrl;
  late TextEditingController _devNotesCtrl;
  late TextEditingController _devStartUCtrl;
  int _devUHeight = 1;
  String _devMountedFace = 'front';
  bool _devMonitorEnabled = false;
  String _devMonitorMethod = 'icmp';
  int _devMonitorPort = 22;
  late TextEditingController _devMonitorPortCtrl;

  // Configuración modular por protocolo de Heartbeat y Gestión Remota
  Set<String> _hbEnabledChecks = {'icmp'};
  bool _hbRemoteAccessEnabled = true;
  String _hbIcmpTarget = 'ip';
  String _hbSshTarget = 'ip';
  late TextEditingController _hbSshPortCtrl;
  late TextEditingController _hbSshUserCtrl;
  late TextEditingController _hbSshArgsCtrl;
  String _hbHttpTarget = 'ip';
  String _hbHttpScheme = 'https';
  late TextEditingController _hbHttpPortCtrl;
  late TextEditingController _hbUrlCtrl;
  late TextEditingController _hbExpectedStatusCtrl;
  String _hbTcpTarget = 'ip';
  late TextEditingController _hbTcpPortCtrl;
  String _hbUdpTarget = 'ip';
  late TextEditingController _hbUdpPortCtrl;
  String _hbSnmpTarget = 'ip';
  String _hbSnmpVersion = 'v2c';
  late TextEditingController _hbSnmpPortCtrl;
  late TextEditingController _hbSnmpCommunityCtrl;
  late TextEditingController _hbSnmpOidCtrl;
  List<Map<String, dynamic>> _lastHeartbeatChecks = [];
  bool _hbSimulateOffline = false;
  List<Map<String, dynamic>> _devLinks = [];
  Map<String, dynamic> _devCustomFields = {};

  // Controladores para el Cable seleccionado
  String _connCableType = 'utp_cat6a';
  String _connColorHex = '#2563EB';
  String _connChannel = 'auto';
  late TextEditingController _connLabelCtrl;
  late TextEditingController _connVlanCtrl;
  late TextEditingController _connLengthCtrl;
  late TextEditingController _connNotesCtrl;

  @override
  void initState() {
    super.initState();
    _initRackControllers();
    _initDeviceControllers();
    _initConnectionControllers();
  }

  @override
  void didUpdateWidget(covariant PropertiesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rack.id != widget.rack.id) {
      _initRackControllers();
    }
    if (oldWidget.selectedDevice?.id != widget.selectedDevice?.id) {
      _initDeviceControllers(preservePingResult: false);
    } else if (oldWidget.selectedDevice?.uHeight != widget.selectedDevice?.uHeight ||
        oldWidget.selectedDevice?.photoUrl != widget.selectedDevice?.photoUrl ||
        oldWidget.selectedDevice?.status != widget.selectedDevice?.status ||
        oldWidget.selectedDevice?.lastPingMs != widget.selectedDevice?.lastPingMs) {
      _initDeviceControllers(preservePingResult: true);
    }
    if (oldWidget.selectedConnection?.id != widget.selectedConnection?.id) {
      _initConnectionControllers();
    }
  }

  void _initRackControllers() {
    final r = widget.rack;
    _rackCodeCtrl = TextEditingController(text: r.code);
    _rackNameCtrl = TextEditingController(text: r.name);
    _rackRespCtrl = TextEditingController(text: r.responsiblePerson);
    _rackUnitsCtrl = TextEditingController(text: '${r.totalUnits}');
    _rackManufCtrl = TextEditingController(text: r.manufacturer);
    _rackModelCtrl = TextEditingController(text: r.modelName);
    _rackSerialCtrl = TextEditingController(text: r.serialNumber);
    _rackPurchaseCtrl = TextEditingController(text: r.purchaseDate);
    _rackOpStartCtrl = TextEditingController(text: r.operationStart);
    _rackNotesCtrl = TextEditingController(text: r.notes);
    _rackAisleId = r.aisleId;
  }

  void _initDeviceControllers({bool preservePingResult = false}) {
    final d = widget.selectedDevice;
    if (!preservePingResult) {
      _pingResultMessage = null;
    }
    _devCodeCtrl = TextEditingController(text: d?.code ?? '');
    _devNameCtrl = TextEditingController(text: d?.name ?? '');
    _devHostnameCtrl = TextEditingController(text: d?.hostname ?? '');
    _devFqdnCtrl = TextEditingController(text: d?.fqdn ?? '');
    _devIpCtrl = TextEditingController(text: d?.ipAddress ?? '');
    _devMaskCtrl = TextEditingController(text: d?.subnetMask ?? '255.255.255.0');
    _devGwCtrl = TextEditingController(text: d?.gateway ?? '');
    _devMacCtrl = TextEditingController(text: d?.macAddress ?? '');
    _devVlanCtrl = TextEditingController(text: d?.vlanMgmt?.toString() ?? '');
    _devSerialCtrl = TextEditingController(text: d?.serialNumber ?? '');
    _devNotesCtrl = TextEditingController(text: d?.notes ?? '');
    _devStartUCtrl = TextEditingController(text: '${d?.startU ?? 1}');
    _devUHeight = d?.uHeight ?? 1;
    _devMountedFace = d?.mountedFace ?? 'front';
    _devMonitorEnabled = d?.monitoringEnabled ?? false;
    const validMethods = {'icmp', 'ssh', 'https', 'http', 'tcp', 'udp', 'snmp'};
    final rawMethod = (d?.monitorMethod ?? 'icmp').toLowerCase();
    _devMonitorMethod = validMethods.contains(rawMethod) ? rawMethod : 'icmp';
    _devMonitorPort = d?.monitorPort ?? 22;
    _devMonitorPortCtrl = TextEditingController(text: '$_devMonitorPort');
    _devLinks = d != null
        ? d.managementLinks.map((e) => Map<String, dynamic>.from(e)).toList()
        : [];
    _devCustomFields =
        d != null ? Map<String, dynamic>.from(d.customFields) : {};

    final rawChecks = _devCustomFields['last_heartbeat_checks'];
    if (rawChecks is List) {
      _lastHeartbeatChecks = rawChecks
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } else if (!preservePingResult) {
      _lastHeartbeatChecks = [];
    }

    final rawHb = _devCustomFields['heartbeat_config'];
    final hb = rawHb is Map
        ? Map<String, dynamic>.from(rawHb)
        : <String, dynamic>{};

    _hbRemoteAccessEnabled = hb['remote_access_enabled'] != false;
    _hbSimulateOffline = hb['simulate_offline'] == true;

    final rawEnabled = hb['enabled_checks'];
    final enabledSet = <String>{};
    if (rawEnabled is List && rawEnabled.isNotEmpty) {
      for (final item in rawEnabled) {
        final s = item.toString().toLowerCase().trim();
        if (s == 'https') {
          enabledSet.add('http');
        } else if (validMethods.contains(s)) {
          enabledSet.add(s);
        }
      }
    } else {
      enabledSet.add(_devMonitorMethod == 'https' ? 'http' : _devMonitorMethod);
      final sec = hb['secondary_methods'];
      if (sec is List) {
        for (final item in sec) {
          final s = item.toString().toLowerCase().trim();
          if (s == 'https') {
            enabledSet.add('http');
          } else if (validMethods.contains(s)) {
            enabledSet.add(s);
          }
        }
      }
    }
    if (enabledSet.isEmpty) {
      enabledSet.add('icmp');
    }
    _hbEnabledChecks = enabledSet;

    final checksMap = hb['checks'] is Map
        ? Map<String, dynamic>.from(hb['checks'] as Map)
        : <String, dynamic>{};
    Map<String, dynamic> checkOf(String k) {
      final v = checksMap[k];
      return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
    }

    final icmpCfg = checkOf('icmp');
    _hbIcmpTarget =
        (icmpCfg['use_target'] ?? icmpCfg['target_type'] ?? 'ip').toString();
    if (_hbIcmpTarget != 'fqdn') _hbIcmpTarget = 'ip';

    final sshCfg = checkOf('ssh');
    _hbSshTarget =
        (sshCfg['use_target'] ?? sshCfg['target_type'] ?? 'ip').toString();
    if (_hbSshTarget != 'fqdn') _hbSshTarget = 'ip';
    _hbSshPortCtrl = TextEditingController(
      text: (sshCfg['port'] ?? (_devMonitorMethod == 'ssh' ? _devMonitorPort : 22))
          .toString(),
    );
    _hbSshUserCtrl = TextEditingController(
      text: (sshCfg['username'] ?? sshCfg['ssh_user'] ?? hb['ssh_user'] ?? 'admin')
          .toString(),
    );
    _hbSshArgsCtrl = TextEditingController(
      text: (hb['ssh_extra_args'] ?? '-o StrictHostKeyChecking=no').toString(),
    );

    final httpCfg = checkOf('http').isNotEmpty ? checkOf('http') : checkOf('https');
    _hbHttpTarget =
        (httpCfg['use_target'] ?? httpCfg['target_type'] ?? 'ip').toString();
    if (_hbHttpTarget != 'fqdn') _hbHttpTarget = 'ip';
    final rawScheme = (httpCfg['scheme'] ??
            (rawEnabled is List && rawEnabled.contains('http') && !rawEnabled.contains('https')
                ? 'http'
                : 'https'))
        .toString()
        .toLowerCase();
    _hbHttpScheme = rawScheme == 'http' ? 'http' : 'https';
    _hbHttpPortCtrl = TextEditingController(
      text: (httpCfg['port'] ?? (_hbHttpScheme == 'https' ? 443 : 80)).toString(),
    );
    final defaultHost = (d?.ipAddress.isNotEmpty ?? false)
        ? d!.ipAddress
        : ((d?.fqdn.isNotEmpty ?? false) ? d!.fqdn : '10.28.10.1');
    _hbUrlCtrl = TextEditingController(
      text: (httpCfg['url'] ??
              hb['url'] ??
              hb['path'] ??
              '$_hbHttpScheme://$defaultHost/')
          .toString(),
    );
    _hbExpectedStatusCtrl = TextEditingController(
      text: (httpCfg['expected_status'] ?? hb['expected_status'] ?? '200')
          .toString(),
    );

    final tcpCfg = checkOf('tcp');
    _hbTcpTarget =
        (tcpCfg['use_target'] ?? tcpCfg['target_type'] ?? 'ip').toString();
    if (_hbTcpTarget != 'fqdn') _hbTcpTarget = 'ip';
    _hbTcpPortCtrl = TextEditingController(
      text: (tcpCfg['port'] ?? (_devMonitorMethod == 'tcp' ? _devMonitorPort : 8080))
          .toString(),
    );

    final udpCfg = checkOf('udp');
    _hbUdpTarget =
        (udpCfg['use_target'] ?? udpCfg['target_type'] ?? 'ip').toString();
    if (_hbUdpTarget != 'fqdn') _hbUdpTarget = 'ip';
    _hbUdpPortCtrl = TextEditingController(
      text: (udpCfg['port'] ?? 53).toString(),
    );

    final snmpCfg = checkOf('snmp');
    _hbSnmpTarget =
        (snmpCfg['use_target'] ?? snmpCfg['target_type'] ?? 'ip').toString();
    if (_hbSnmpTarget != 'fqdn') _hbSnmpTarget = 'ip';
    final rawSnmpVer = (snmpCfg['version'] ??
            snmpCfg['snmp_version'] ??
            hb['snmp_version'] ??
            'v2c')
        .toString()
        .toLowerCase();
    _hbSnmpVersion = const {'v1', 'v2c', 'v3'}.contains(rawSnmpVer)
        ? rawSnmpVer
        : (rawSnmpVer == '2c' ? 'v2c' : 'v2c');
    _hbSnmpPortCtrl = TextEditingController(
      text: (snmpCfg['port'] ?? 161).toString(),
    );
    _hbSnmpCommunityCtrl = TextEditingController(
      text: (snmpCfg['community'] ??
              snmpCfg['snmp_community'] ??
              hb['snmp_community'] ??
              'public')
          .toString(),
    );
    _hbSnmpOidCtrl = TextEditingController(
      text: (snmpCfg['oid'] ??
              snmpCfg['snmp_oid'] ??
              hb['snmp_oid'] ??
              '1.3.6.1.2.1.1.1.0')
          .toString(),
    );
  }

  void _initConnectionControllers() {
    final c = widget.selectedConnection;
    _connCableType = c?.cableType ?? 'utp_cat6a';
    _connColorHex = c?.colorHex ?? '#2563EB';
    _connChannel = c?.routingChannel ?? 'auto';
    _connLabelCtrl = TextEditingController(text: c?.label ?? '');
    _connVlanCtrl = TextEditingController(text: c?.vlan?.toString() ?? '');
    _connLengthCtrl = TextEditingController(text: '${c?.lengthM ?? 1.5}');
    _connNotesCtrl = TextEditingController(text: c?.notes ?? '');
  }

  Future<void> _saveRackSettings() async {
    setState(() => _isSaving = true);
    try {
      await widget.api.updateRack(widget.rack.id, {
        'code': _rackCodeCtrl.text.trim(),
        'name': _rackNameCtrl.text.trim(),
        'responsible_person': _rackRespCtrl.text.trim(),
        'total_units': int.tryParse(_rackUnitsCtrl.text.trim()) ?? 42,
        'manufacturer': _rackManufCtrl.text.trim(),
        'model_name': _rackModelCtrl.text.trim(),
        'serial_number': _rackSerialCtrl.text.trim(),
        'purchase_date': _rackPurchaseCtrl.text.trim(),
        'operation_start': _rackOpStartCtrl.text.trim(),
        'aisle_id': _rackAisleId,
        'notes': _rackNotesCtrl.text.trim(),
      });
      widget.onRefreshRack();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ajustes del Rack guardados correctamente.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Map<String, dynamic> _buildHeartbeatConfigMap() {
    final enabledList = _hbEnabledChecks.isEmpty
        ? <String>['icmp']
        : _hbEnabledChecks.toList();
    final sshPort = int.tryParse(_hbSshPortCtrl.text.trim()) ?? 22;
    final httpPort = int.tryParse(_hbHttpPortCtrl.text.trim()) ??
        (_hbHttpScheme == 'https' ? 443 : 80);
    final tcpPort = int.tryParse(_hbTcpPortCtrl.text.trim()) ?? 8080;
    final udpPort = int.tryParse(_hbUdpPortCtrl.text.trim()) ?? 53;
    final snmpPort = int.tryParse(_hbSnmpPortCtrl.text.trim()) ?? 161;
    final expStatus = int.tryParse(_hbExpectedStatusCtrl.text.trim()) ?? 200;

    return {
      'remote_access_enabled': _hbRemoteAccessEnabled,
      'enabled_checks': enabledList,
      'simulate_offline': _hbSimulateOffline,
      'url': _hbUrlCtrl.text.trim(),
      'path': _hbUrlCtrl.text.trim(),
      'expected_status': expStatus,
      'ssh_user': _hbSshUserCtrl.text.trim(),
      'ssh_extra_args': _hbSshArgsCtrl.text.trim(),
      'snmp_version': _hbSnmpVersion,
      'snmp_community': _hbSnmpCommunityCtrl.text.trim(),
      'snmp_oid': _hbSnmpOidCtrl.text.trim(),
      'checks': {
        'icmp': {
          'use_target': _hbIcmpTarget,
          'target_type': _hbIcmpTarget,
        },
        'ssh': {
          'use_target': _hbSshTarget,
          'target_type': _hbSshTarget,
          'port': sshPort,
          'username': _hbSshUserCtrl.text.trim(),
          'ssh_user': _hbSshUserCtrl.text.trim(),
        },
        'http': {
          'use_target': _hbHttpTarget,
          'target_type': _hbHttpTarget,
          'scheme': _hbHttpScheme,
          'port': httpPort,
          'url': _hbUrlCtrl.text.trim(),
          'expected_status': expStatus,
        },
        'tcp': {
          'use_target': _hbTcpTarget,
          'target_type': _hbTcpTarget,
          'port': tcpPort,
        },
        'udp': {
          'use_target': _hbUdpTarget,
          'target_type': _hbUdpTarget,
          'port': udpPort,
        },
        'snmp': {
          'use_target': _hbSnmpTarget,
          'target_type': _hbSnmpTarget,
          'port': snmpPort,
          'version': _hbSnmpVersion,
          'snmp_version': _hbSnmpVersion,
          'community': _hbSnmpCommunityCtrl.text.trim(),
          'snmp_community': _hbSnmpCommunityCtrl.text.trim(),
          'oid': _hbSnmpOidCtrl.text.trim(),
          'snmp_oid': _hbSnmpOidCtrl.text.trim(),
        },
      },
    };
  }

  void _syncPrimaryMethodAndPortFromChecks() {
    final firstProto =
        _hbEnabledChecks.isEmpty ? 'icmp' : _hbEnabledChecks.first;
    _devMonitorMethod = firstProto == 'http' ? _hbHttpScheme : firstProto;
    if (firstProto == 'ssh') {
      _devMonitorPort = int.tryParse(_hbSshPortCtrl.text.trim()) ?? 22;
    } else if (firstProto == 'http') {
      _devMonitorPort = int.tryParse(_hbHttpPortCtrl.text.trim()) ??
          (_hbHttpScheme == 'https' ? 443 : 80);
    } else if (firstProto == 'tcp') {
      _devMonitorPort = int.tryParse(_hbTcpPortCtrl.text.trim()) ?? 8080;
    } else if (firstProto == 'udp') {
      _devMonitorPort = int.tryParse(_hbUdpPortCtrl.text.trim()) ?? 53;
    } else if (firstProto == 'snmp') {
      _devMonitorPort = int.tryParse(_hbSnmpPortCtrl.text.trim()) ?? 161;
    } else {
      _devMonitorPort = 0;
    }
    _devMonitorPortCtrl.text = '$_devMonitorPort';
  }

  Future<void> _saveDeviceSettings() async {
    final d = widget.selectedDevice;
    if (d == null) return;
    setState(() => _isSaving = true);
    try {
      _syncPrimaryMethodAndPortFromChecks();
      _devCustomFields['heartbeat_config'] = _buildHeartbeatConfigMap();
      _devCustomFields['u_height_override'] = _devUHeight;
      await widget.api.updateDevice(d.id, {
        'code': _devCodeCtrl.text.trim(),
        'name': _devNameCtrl.text.trim(),
        'hostname': _devHostnameCtrl.text.trim(),
        'fqdn': _devFqdnCtrl.text.trim(),
        'start_u': int.tryParse(_devStartUCtrl.text.trim()) ?? d.startU,
        'mounted_face': _devMountedFace,
        'ip_address': _devIpCtrl.text.trim(),
        'subnet_mask': _devMaskCtrl.text.trim(),
        'gateway': _devGwCtrl.text.trim(),
        'mac_address': _devMacCtrl.text.trim(),
        'vlan_mgmt': int.tryParse(_devVlanCtrl.text.trim()),
        'management_links': _devLinks,
        'monitoring_enabled': _devMonitorEnabled,
        'monitor_method': _devMonitorMethod,
        'monitor_port': _devMonitorPort,
        'serial_number': _devSerialCtrl.text.trim(),
        'custom_fields': _devCustomFields,
        'notes': _devNotesCtrl.text.trim(),
      });
      widget.onRefreshRack();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Configuración del equipo actualizada.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  bool get _canEdit => widget.currentUser?.canEdit ?? true;
  bool get _canConnectRemote => widget.currentUser?.canConnectRemote ?? true;

  String _resolveHostByPreference(String pref) {
    final ip = _devIpCtrl.text.trim();
    final fqdn = _devFqdnCtrl.text.trim();
    if (pref == 'fqdn') {
      return fqdn.isNotEmpty ? fqdn : ip;
    }
    return ip.isNotEmpty ? ip : fqdn;
  }

  String _buildEffectiveHttpUrl() {
    final host = _resolveHostByPreference(_hbHttpTarget);
    final port = int.tryParse(_hbHttpPortCtrl.text.trim()) ??
        (_hbHttpScheme == 'https' ? 443 : 80);
    var raw = _hbUrlCtrl.text.trim();
    if (raw.isEmpty || raw == '/') {
      final portPart = ((_hbHttpScheme == 'http' && port == 80) ||
              (_hbHttpScheme == 'https' && port == 443))
          ? ''
          : ':$port';
      return '$_hbHttpScheme://$host$portPart/';
    }
    raw = raw
        .replaceAll('{ip}', _devIpCtrl.text.trim())
        .replaceAll('{fqdn}', _devFqdnCtrl.text.trim())
        .replaceAll('{host}', host);
    if (raw.startsWith('/')) {
      final portPart = ((_hbHttpScheme == 'http' && port == 80) ||
              (_hbHttpScheme == 'https' && port == 443))
          ? ''
          : ':$port';
      return '$_hbHttpScheme://$host$portPart$raw';
    }
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      return '$_hbHttpScheme://$raw';
    }
    return raw;
  }

  Future<void> _triggerDevicePing() async {
    if (!_canConnectRemote) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Tu rol actual (Solo Ver) no permite lanzar pruebas interactivas sobre los hosts.',
          ),
        ),
      );
      return;
    }
    final d = widget.selectedDevice;
    if (d == null) return;
    setState(() {
      _isPinging = true;
      _pingResultMessage = 'Ejecutando sondas reales de red (${_hbEnabledChecks.map((e) => e.toUpperCase()).join(', ')})...';
    });
    try {
      _syncPrimaryMethodAndPortFromChecks();
      _devCustomFields['heartbeat_config'] = _buildHeartbeatConfigMap();
      if (_canEdit) {
        await widget.api.updateDevice(d.id, {
          'ip_address': _devIpCtrl.text.trim(),
          'fqdn': _devFqdnCtrl.text.trim(),
          'monitoring_enabled': _devMonitorEnabled,
          'monitor_method': _devMonitorMethod,
          'monitor_port': _devMonitorPort,
          'custom_fields': _devCustomFields,
        });
      }
      final res = await widget.api.pingDevice(d.id);
      if (mounted) {
        setState(() {
          _pingResultMessage = res['detail']?.toString() ?? 'Check completado';
          final rawChecks = res['checks'];
          if (rawChecks is List) {
            _lastHeartbeatChecks = rawChecks
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
          }
        });
      }
      widget.onRefreshRack();
    } catch (e) {
      if (mounted) {
        setState(() => _pingResultMessage = 'Error ejecutando Heartbeat: $e');
      }
    } finally {
      if (mounted) setState(() => _isPinging = false);
    }
  }

  Future<void> _openConfiguredWebUrl() async {
    if (!_canConnectRemote || !_hbRemoteAccessEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('La conexión remota está deshabilitada para este equipo o rol.'),
          backgroundColor: Color(0xFFDC2626),
        ),
      );
      return;
    }
    final url = _buildEffectiveHttpUrl();
    await Clipboard.setData(ClipboardData(text: url));
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Abriendo panel Web en nueva pestaña: $url'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _launchNativeSshOrCopy() async {
    if (!_canConnectRemote || !_hbRemoteAccessEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('La gestión SSH remota está deshabilitada para este equipo o rol.'),
          backgroundColor: Color(0xFFDC2626),
        ),
      );
      return;
    }
    final host = _resolveHostByPreference(_hbSshTarget);
    final port = int.tryParse(_hbSshPortCtrl.text.trim()) ?? 22;
    final user = _hbSshUserCtrl.text.trim().isEmpty
        ? 'admin'
        : _hbSshUserCtrl.text.trim();
    final sshCmd = port == 22 ? 'ssh $user@$host' : 'ssh -p $port $user@$host';
    final sshUri = 'ssh://$user@$host:$port';
    await Clipboard.setData(ClipboardData(text: sshCmd));
    try {
      await launchUrl(Uri.parse(sshUri), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Lanzando $sshUri (Comando copiado al portapapeles: $sshCmd)'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _openIntegratedRemoteConsoleModal({
    String initialProtocol = 'ssh',
  }) async {
    final d = widget.selectedDevice;
    if (d == null) return;
    if (!_canConnectRemote || !_hbRemoteAccessEnabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('La Consola Remota está deshabilitada en este equipo o para tu rol.'),
          backgroundColor: Color(0xFFDC2626),
        ),
      );
      return;
    }

    // Guardar primero los parámetros actuales de Heartbeat/Red si el usuario tiene permiso
    if (_canEdit) {
      _syncPrimaryMethodAndPortFromChecks();
      _devCustomFields['heartbeat_config'] = _buildHeartbeatConfigMap();
      try {
        await widget.api.updateDevice(d.id, {
          'ip_address': _devIpCtrl.text.trim(),
          'fqdn': _devFqdnCtrl.text.trim(),
          'monitoring_enabled': _devMonitorEnabled,
          'monitor_method': _devMonitorMethod,
          'monitor_port': _devMonitorPort,
          'custom_fields': _devCustomFields,
        });
      } catch (_) {}
    }

    if (!mounted) return;

    String activeProto = initialProtocol;
    bool isRunning = false;
    final cmdCtrl = TextEditingController(
      text: initialProtocol == 'ssh' ? 'show version' : '',
    );
    final List<String> consoleLog = [
      '=== CONSOLA REMOTA & DIAGNÓSTICO RACKDOC :: ${d.code} (${d.name}) ===',
      'IP: ${_devIpCtrl.text.trim().isEmpty ? "No definida" : _devIpCtrl.text.trim()} | FQDN: ${_devFqdnCtrl.text.trim().isEmpty ? "No definido" : _devFqdnCtrl.text.trim()}',
      'Selecciona una acción o protocolo arriba para conectar o diagnosticar en tiempo real.',
      '--------------------------------------------------------------------',
    ];

    Future<void> executeAction(
      String proto,
      StateSetter setModal,
    ) async {
      setModal(() {
        activeProto = proto;
        isRunning = true;
        consoleLog.add('\n> Ejecutando [${proto.toUpperCase()}]...');
      });
      try {
        Map<String, dynamic> reqPayload = {'action': proto};
        if (proto == 'icmp') {
          reqPayload['use_target'] = _hbIcmpTarget;
        } else if (proto == 'ssh') {
          reqPayload['use_target'] = _hbSshTarget;
          reqPayload['port'] = int.tryParse(_hbSshPortCtrl.text.trim()) ?? 22;
          reqPayload['username'] = _hbSshUserCtrl.text.trim();
          reqPayload['command'] = cmdCtrl.text.trim();
        } else if (proto == 'http' || proto == 'https') {
          reqPayload['action'] = _hbHttpScheme;
          reqPayload['use_target'] = _hbHttpTarget;
          reqPayload['scheme'] = _hbHttpScheme;
          reqPayload['port'] = int.tryParse(_hbHttpPortCtrl.text.trim()) ??
              (_hbHttpScheme == 'https' ? 443 : 80);
          reqPayload['url'] = _hbUrlCtrl.text.trim();
          reqPayload['expected_status'] =
              int.tryParse(_hbExpectedStatusCtrl.text.trim()) ?? 200;
        } else if (proto == 'tcp') {
          reqPayload['use_target'] = _hbTcpTarget;
          reqPayload['port'] = int.tryParse(_hbTcpPortCtrl.text.trim()) ?? 8080;
        } else if (proto == 'udp') {
          reqPayload['use_target'] = _hbUdpTarget;
          reqPayload['port'] = int.tryParse(_hbUdpPortCtrl.text.trim()) ?? 53;
        } else if (proto == 'snmp') {
          reqPayload['use_target'] = _hbSnmpTarget;
          reqPayload['port'] = int.tryParse(_hbSnmpPortCtrl.text.trim()) ?? 161;
          reqPayload['version'] = _hbSnmpVersion;
          reqPayload['community'] = _hbSnmpCommunityCtrl.text.trim();
          reqPayload['oid'] = _hbSnmpOidCtrl.text.trim();
        }
        final res = await widget.api.runDeviceRemoteConsole(d.id, reqPayload);
        setModal(() {
          consoleLog.add(res['output']?.toString() ?? 'Sin salida.');
          if (res['checks'] is List) {
            _lastHeartbeatChecks = (res['checks'] as List)
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
          }
        });
        widget.onRefreshRack();
      } catch (e) {
        setModal(() {
          consoleLog.add('ERROR: $e');
        });
      } finally {
        setModal(() => isRunning = false);
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        bool autoStarted = false;
        return StatefulBuilder(
          builder: (ctx, setModal) {
            if (!autoStarted) {
              autoStarted = true;
              Future.microtask(() => executeAction(initialProtocol, setModal));
            }
            final sshHost = _resolveHostByPreference(_hbSshTarget);
            final sshPort = int.tryParse(_hbSshPortCtrl.text.trim()) ?? 22;
            final sshUser = _hbSshUserCtrl.text.trim().isEmpty
                ? 'admin'
                : _hbSshUserCtrl.text.trim();
            final sshCli = sshPort == 22
                ? 'ssh $sshUser@$sshHost'
                : 'ssh -p $sshPort $sshUser@$sshHost';
            final webUrl = _buildEffectiveHttpUrl();

            return AlertDialog(
              backgroundColor: const Color(0xFF0F172A),
              titlePadding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
              contentPadding: const EdgeInsets.fromLTRB(18, 6, 18, 14),
              title: Row(
                children: [
                  const Icon(Icons.terminal, color: Color(0xFF38BDF8), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Consola de Conexión y Gestión Remota — ${d.code} (${d.name})',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close, color: Colors.white70, size: 18),
                  ),
                ],
              ),
              content: SizedBox(
                width: 680,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Botonera de protocolos en vivo
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _ConsoleActionChip(
                          label: 'Heartbeat Completo',
                          icon: Icons.monitor_heart_outlined,
                          selected: activeProto == 'heartbeat',
                          onTap: isRunning
                              ? null
                              : () => executeAction('heartbeat', setModal),
                        ),
                        _ConsoleActionChip(
                          label: 'ICMP Ping (${_hbIcmpTarget.toUpperCase()})',
                          icon: Icons.network_ping,
                          selected: activeProto == 'icmp',
                          onTap: isRunning
                              ? null
                              : () => executeAction('icmp', setModal),
                        ),
                        _ConsoleActionChip(
                          label: 'SSH :${_hbSshPortCtrl.text}',
                          icon: Icons.terminal,
                          selected: activeProto == 'ssh',
                          onTap: isRunning
                              ? null
                              : () => executeAction('ssh', setModal),
                        ),
                        _ConsoleActionChip(
                          label: '${_hbHttpScheme.toUpperCase()} :${_hbHttpPortCtrl.text}',
                          icon: Icons.language,
                          selected: activeProto == 'http' || activeProto == 'https',
                          onTap: isRunning
                              ? null
                              : () => executeAction(_hbHttpScheme, setModal),
                        ),
                        _ConsoleActionChip(
                          label: 'TCP :${_hbTcpPortCtrl.text}',
                          icon: Icons.settings_ethernet,
                          selected: activeProto == 'tcp',
                          onTap: isRunning
                              ? null
                              : () => executeAction('tcp', setModal),
                        ),
                        _ConsoleActionChip(
                          label: 'UDP :${_hbUdpPortCtrl.text}',
                          icon: Icons.wifi_tethering,
                          selected: activeProto == 'udp',
                          onTap: isRunning
                              ? null
                              : () => executeAction('udp', setModal),
                        ),
                        _ConsoleActionChip(
                          label: 'SNMP ${_hbSnmpVersion.toUpperCase()}',
                          icon: Icons.sensors,
                          selected: activeProto == 'snmp',
                          onTap: isRunning
                              ? null
                              : () => executeAction('snmp', setModal),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // Barra de comando SSH o lanzadores directos
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: cmdCtrl,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white,
                              fontFamily: 'monospace',
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              filled: true,
                              fillColor: const Color(0xFF1E293B),
                              labelText:
                                  'Comando remoto SSH (ej. show version, uptime, ip a)',
                              labelStyle: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF94A3B8),
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                            onSubmitted: (_) => executeAction('ssh', setModal),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: isRunning
                              ? null
                              : () => executeAction('ssh', setModal),
                          icon: const Icon(Icons.play_arrow, size: 15),
                          label: const Text('Ejecutar SSH', style: TextStyle(fontSize: 11.5)),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF0284C7),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // Salida de Terminal
                    Container(
                      height: 270,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF020617),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF334155)),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          consoleLog.join('\n'),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            height: 1.45,
                            color: Color(0xFF38BDF8),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    // Accesos nativos directos (Terminal SSH SO / Navegador Web)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.spaceBetween,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: sshCli));
                            launchUrl(
                              Uri.parse('ssh://$sshUser@$sshHost:$sshPort'),
                              mode: LaunchMode.externalApplication,
                            );
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF38BDF8),
                            side: const BorderSide(color: Color(0xFF0284C7)),
                          ),
                          icon: const Icon(Icons.open_in_new, size: 14),
                          label: Text(
                            'Abrir Cliente SSH ($sshCli)',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: () {
                            launchUrl(
                              Uri.parse(webUrl),
                              mode: LaunchMode.externalApplication,
                            );
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF34D399),
                            side: const BorderSide(color: Color(0xFF059669)),
                          ),
                          icon: const Icon(Icons.language, size: 14),
                          label: Text(
                            'Abrir Web UI ($webUrl)',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _launchRemoteProtocol(Map<String, dynamic> link) async {
    if (!_canConnectRemote) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Acceso denegado: el rol "Solo Ver" no tiene permiso para interactuar por SSH/Telnet/Web con el host.',
          ),
          backgroundColor: Color(0xFFDC2626),
        ),
      );
      return;
    }
    final host = _devIpCtrl.text.trim().isNotEmpty
        ? _devIpCtrl.text.trim()
        : _devFqdnCtrl.text.trim();
    if (host.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Configura primero una Dirección IP o FQDN en el equipo.'),
        ),
      );
      return;
    }

    final proto = (link['protocol'] ?? 'ssh').toString().toLowerCase();
    final port = link['port'] ?? 22;
    final user = (link['username'] ?? 'admin').toString();

    String uriStr;
    String cliCmd;
    if (proto == 'ssh') {
      uriStr = 'ssh://$user@$host:$port';
      cliCmd = 'ssh $user@$host -p $port';
    } else if (proto == 'telnet') {
      uriStr = 'telnet://$host:$port';
      cliCmd = 'telnet $host $port';
    } else if (proto == 'http') {
      uriStr = 'http://$host:$port';
      cliCmd = uriStr;
    } else {
      uriStr = 'https://$host:$port';
      cliCmd = uriStr;
    }

    await Clipboard.setData(ClipboardData(text: cliCmd));
    try {
      await launchUrl(Uri.parse(uriStr), mode: LaunchMode.externalApplication);
    } catch (_) {}

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Abriendo $uriStr (Comando copiado: $cliCmd)'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _showAddProtocolDialog() async {
    String proto = 'ssh';
    final portCtrl = TextEditingController(text: '22');
    final userCtrl = TextEditingController(text: 'admin');
    final labelCtrl = TextEditingController(text: 'SSH Terminal');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text('Añadir Acceso Remoto al Hardware'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: proto,
                  decoration: const InputDecoration(labelText: 'Protocolo'),
                  items: const [
                    DropdownMenuItem(value: 'ssh', child: Text('SSH (Terminal)')),
                    DropdownMenuItem(value: 'telnet', child: Text('Telnet (Consola)')),
                    DropdownMenuItem(value: 'https', child: Text('HTTPS (Web UI / iDRAC / iLO)')),
                    DropdownMenuItem(value: 'http', child: Text('HTTP (Web Panel)')),
                  ],
                  onChanged: (v) {
                    setModal(() {
                      proto = v ?? 'ssh';
                      if (proto == 'ssh') portCtrl.text = '22';
                      if (proto == 'telnet') portCtrl.text = '23';
                      if (proto == 'https') portCtrl.text = '443';
                      if (proto == 'http') portCtrl.text = '80';
                    });
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: labelCtrl,
                  decoration: const InputDecoration(labelText: 'Etiqueta (ej. Web UI, iDRAC, SSH)'),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: userCtrl,
                        decoration: const InputDecoration(labelText: 'Usuario'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: portCtrl,
                        decoration: const InputDecoration(labelText: 'Puerto TCP'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Añadir'),
            ),
          ],
        ),
      ),
    );

    if (ok == true) {
      setState(() {
        _devLinks.add({
          'protocol': proto,
          'port': int.tryParse(portCtrl.text.trim()) ?? 22,
          'username': userCtrl.text.trim(),
          'label': labelCtrl.text.trim(),
        });
      });
      await _saveDeviceSettings();
    }
  }

  Future<void> _showAddCustomFieldDialog() async {
    final keyCtrl = TextEditingController();
    final valCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Añadir Variable Personalizada'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: keyCtrl,
                decoration: const InputDecoration(
                  labelText: 'Nombre de Variable (ej. Firmware, Consumo W, Contrato)',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: valCtrl,
                decoration: const InputDecoration(
                  labelText: 'Valor',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Guardar Variable'),
          ),
        ],
      ),
    );

    if (ok == true && keyCtrl.text.trim().isNotEmpty) {
      setState(() {
        _devCustomFields[keyCtrl.text.trim()] = valCtrl.text.trim();
      });
      await _saveDeviceSettings();
    }
  }

  Future<void> _saveConnectionSettings() async {
    final c = widget.selectedConnection;
    if (c == null) return;
    setState(() => _isSaving = true);
    try {
      await widget.api.updateConnection(c.id, {
        'cable_type': _connCableType,
        'color_hex': _connColorHex,
        'routing_channel': _connChannel,
        'label': _connLabelCtrl.text.trim(),
        'vlan': int.tryParse(_connVlanCtrl.text.trim()),
        'length_m': double.tryParse(_connLengthCtrl.text.trim()) ?? 1.5,
        'notes': _connNotesCtrl.text.trim(),
      });
      widget.onRefreshRack();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Propiedades del cable actualizadas.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 340,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(left: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.selectedConnection != null)
            Expanded(child: _buildConnectionPanel(widget.selectedConnection!))
          else if (widget.selectedDevice != null)
            Expanded(child: _buildDevicePanel(widget.selectedDevice!))
          else
            Expanded(child: _buildRackSettingsPanel()),
        ],
      ),
    );
  }

  // ===========================================================================
  // 1. PANEL DE AJUSTES DEL RACK (Idéntico a la captura 1 derecha)
  // ===========================================================================
  Widget _buildRackSettingsPanel() {
    final bc = widget.rack.breadcrumb;
    final pathHeader =
        '${bc['location_code'] ?? 'HQ'}/${bc['room_name']?.toString().split(' ').first ?? '28'}/${bc['aisle_code'] ?? 'SL'}/${widget.rack.code}';

    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                pathHeader,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.download_outlined, size: 18),
              tooltip: 'Exportar este Rack a Excel (.xlsx)',
              onPressed: () {
                final url = Uri.parse(
                  widget.api.getExcelExportUrl(rackId: widget.rack.id),
                );
                launchUrl(url, mode: LaunchMode.externalApplication);
              },
            ),
          ],
        ),
        const Divider(height: 18),
        const Text(
          'Settings (RACK SETTINGS)',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Color(0xFF334155),
          ),
        ),
        const SizedBox(height: 12),
        _CompactInput(label: 'ID *', controller: _rackCodeCtrl),
        _CompactInput(label: 'Name', controller: _rackNameCtrl),
        if (widget.rack.availableAisles.isNotEmpty) ...[
          const Text(
            'Pasillo de Racks (Aisle)',
            style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 4),
          DropdownButtonFormField<int?>(
            initialValue: _rackAisleId,
            isDense: true,
            decoration: _compactDecoration(),
            items: widget.rack.availableAisles
                .map(
                  (a) => DropdownMenuItem<int?>(
                    value: a.id,
                    child: Text(
                      '${a.name} (${a.aisleType.toUpperCase()})',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => _rackAisleId = v),
          ),
          const SizedBox(height: 10),
        ],
        _CompactInput(label: 'Responsible person', controller: _rackRespCtrl),
        _CompactInput(label: 'Rack units', controller: _rackUnitsCtrl),
        _CompactInput(label: 'Manufacturer', controller: _rackManufCtrl),
        _CompactInput(label: 'Model name', controller: _rackModelCtrl),
        _CompactInput(label: 'Serial number', controller: _rackSerialCtrl),
        _CompactInput(label: 'Purchase date', controller: _rackPurchaseCtrl),
        _CompactInput(label: 'Operation start', controller: _rackOpStartCtrl),
        _CompactInput(
          label: 'Notes',
          controller: _rackNotesCtrl,
          maxLines: 3,
        ),
        const SizedBox(height: 8),
        if (_canEdit)
          FilledButton.icon(
            onPressed: _isSaving ? null : _saveRackSettings,
            icon: const Icon(Icons.save_outlined, size: 16),
            label: Text(_isSaving ? 'Guardando...' : 'Guardar Ajustes del Rack'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF0F172A),
            ),
          ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () {
            final url = Uri.parse(
              widget.api.getExcelExportUrl(rackId: widget.rack.id),
            );
            launchUrl(url, mode: LaunchMode.externalApplication);
          },
          icon: const Icon(Icons.table_view_outlined, size: 16),
          label: const Text('Exportar Informe Excel (.xlsx)'),
        ),
        if (_canEdit && widget.onDeleteRack != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: widget.onDeleteRack,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFDC2626),
              side: const BorderSide(color: Color(0xFFFCA5A5)),
            ),
            icon: const Icon(Icons.delete_outline, size: 16),
            label: Text('Eliminar este Rack (${widget.rack.code})'),
          ),
        ],
      ],
    );
  }

  // ===========================================================================
  // 2. PANEL DE DISPOSITIVO: RED (IP/FQDN/MASK/GW), SSH/TELNET/WEB, PING Y VARIABLES
  // ===========================================================================
  Widget _buildDevicePanel(RackDeviceModel d) {
    final isOnline = d.status == 'online';
    final isOffline = d.status == 'offline';
    final statusColor = isOnline
        ? const Color(0xFF16A34A)
        : (isOffline ? const Color(0xFFDC2626) : const Color(0xFFD97706));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'U${d.startU}${d.template.uHeight > 1 ? '-U${d.endU}' : ''} • ${d.mountedFace.toUpperCase()}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1D4ED8),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                d.code,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              onPressed: widget.onClearSelection,
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Volver a ajustes del Rack',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        Text(
          '${d.template.manufacturer} ${d.template.modelName}${d.template.isFullDepth ? ' (Full-Depth Front+Back)' : ''}',
          style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
        ),
        const Divider(height: 20),

        // SECCIÓN A: MONITORIZACIÓN Y HEARTBEAT MULTI-PROTOCOLO (ICMP, SSH, HTTP/HTTPS, TCP, UDP, SNMP)
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _devMonitorEnabled
                  ? statusColor.withValues(alpha: 0.45)
                  : const Color(0xFFE2E8F0),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _devMonitorEnabled
                          ? statusColor
                          : const Color(0xFF94A3B8),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _devMonitorEnabled
                          ? 'Heartbeat: ${isOnline ? "ONLINE (OK)" : (isOffline ? "CAÍDO (OFFLINE)" : "DEGRADADO (${d.status.toUpperCase()})")}'
                          : 'Heartbeat: DESACTIVADO',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        color: _devMonitorEnabled
                            ? statusColor
                            : const Color(0xFF64748B),
                      ),
                    ),
                  ),
                  if (d.lastPingMs != null && _devMonitorEnabled)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Text(
                        '${d.lastPingMs} ms',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF334155),
                        ),
                      ),
                    ),
                  Switch(
                    value: _devMonitorEnabled,
                    onChanged: _canEdit
                        ? (v) => setState(() => _devMonitorEnabled = v)
                        : null,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'Marca las opciones de Heartbeat a comprobar (cada protocolo tiene su propia configuración):',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF475569),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  ('icmp', 'ICMP Ping'),
                  ('ssh', 'SSH'),
                  ('http', 'HTTP / HTTPS'),
                  ('tcp', 'TCP'),
                  ('udp', 'UDP'),
                  ('snmp', 'SNMP'),
                ].map((pair) {
                  final key = pair.$1;
                  final label = pair.$2;
                  final isChecked = _hbEnabledChecks.contains(key);
                  final checkRes = _lastHeartbeatChecks.cast<Map<String, dynamic>?>().firstWhere(
                        (c) {
                          final m = (c?['method'] ?? c?['protocol'] ?? '')
                              .toString()
                              .toLowerCase();
                          if (key == 'http') return m == 'http' || m == 'https';
                          return m == key;
                        },
                        orElse: () => null,
                      );
                  final chkOnline = checkRes != null && checkRes['status'] == 'online';
                  final chkOffline = checkRes != null && checkRes['status'] == 'offline';
                  return FilterChip(
                    selected: isChecked,
                    showCheckmark: true,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    selectedColor: const Color(0xFFDBEAFE),
                    checkmarkColor: const Color(0xFF1D4ED8),
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            color: isChecked
                                ? const Color(0xFF1E3A8A)
                                : const Color(0xFF475569),
                          ),
                        ),
                        if (isChecked && checkRes != null) ...[
                          const SizedBox(width: 4),
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: chkOnline
                                  ? const Color(0xFF16A34A)
                                  : (chkOffline
                                      ? const Color(0xFFDC2626)
                                      : const Color(0xFFD97706)),
                            ),
                          ),
                        ],
                      ],
                    ),
                    onSelected: !_canEdit
                        ? null
                        : (sel) {
                            setState(() {
                              if (sel) {
                                _hbEnabledChecks.add(key);
                              } else if (_hbEnabledChecks.length > 1) {
                                _hbEnabledChecks.remove(key);
                              }
                            });
                          },
                  );
                }).toList(),
              ),

              const SizedBox(height: 8),

              // 1. Configuración ICMP (Solo Ping: IP o FQDN)
              if (_hbEnabledChecks.contains('icmp'))
                _buildProtocolConfigCard(
                  protocolKey: 'icmp',
                  title: 'ICMP (Solo Ping)',
                  icon: Icons.network_ping,
                  targetValue: _hbIcmpTarget,
                  onTargetChanged: (v) => setState(() => _hbIcmpTarget = v),
                  child: Text(
                    'Envía eco ICMP directo a ${_hbIcmpTarget == "fqdn" ? (_devFqdnCtrl.text.isEmpty ? "FQDN (sin definir)" : _devFqdnCtrl.text) : (_devIpCtrl.text.isEmpty ? "IP (sin definir)" : _devIpCtrl.text)} (sin puerto).',
                    style: const TextStyle(fontSize: 10, color: Color(0xFF64748B)),
                  ),
                ),

              // 2. Configuración SSH (Puerto por defecto 22 o personalizado + Usuario)
              if (_hbEnabledChecks.contains('ssh'))
                _buildProtocolConfigCard(
                  protocolKey: 'ssh',
                  title: 'SSH (Puerto 22 o a medida)',
                  icon: Icons.terminal,
                  targetValue: _hbSshTarget,
                  onTargetChanged: (v) => setState(() => _hbSshTarget = v),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 1,
                        child: _CompactInput(
                          label: 'Puerto SSH',
                          controller: _hbSshPortCtrl,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        flex: 2,
                        child: _CompactInput(
                          label: 'Usuario SSH',
                          controller: _hbSshUserCtrl,
                        ),
                      ),
                    ],
                  ),
                ),

              // 3. Configuración HTTP / HTTPS (URL con IP o FQDN, Puerto y Código esperado)
              if (_hbEnabledChecks.contains('http'))
                _buildProtocolConfigCard(
                  protocolKey: 'http',
                  title: 'HTTP / HTTPS (URL Web / API)',
                  icon: Icons.language,
                  targetValue: _hbHttpTarget,
                  onTargetChanged: (v) => setState(() {
                    _hbHttpTarget = v;
                    final h = _resolveHostByPreference(v);
                    if (h.isNotEmpty) {
                      final p = int.tryParse(_hbHttpPortCtrl.text.trim()) ??
                          (_hbHttpScheme == 'https' ? 443 : 80);
                      final pPart = ((_hbHttpScheme == 'http' && p == 80) ||
                              (_hbHttpScheme == 'https' && p == 443))
                          ? ''
                          : ':$p';
                      _hbUrlCtrl.text = '$_hbHttpScheme://$h$pPart/';
                    }
                  }),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: _hbHttpScheme,
                              isDense: true,
                              decoration: _compactDecoration(label: 'Protocolo'),
                              items: const [
                                DropdownMenuItem(
                                  value: 'https',
                                  child: Text('HTTPS', style: TextStyle(fontSize: 11)),
                                ),
                                DropdownMenuItem(
                                  value: 'http',
                                  child: Text('HTTP', style: TextStyle(fontSize: 11)),
                                ),
                              ],
                              onChanged: _canEdit
                                  ? (v) {
                                      setState(() {
                                        _hbHttpScheme = v ?? 'https';
                                        _hbHttpPortCtrl.text =
                                            _hbHttpScheme == 'https' ? '443' : '80';
                                        final h = _resolveHostByPreference(_hbHttpTarget);
                                        if (h.isNotEmpty) {
                                          _hbUrlCtrl.text = '$_hbHttpScheme://$h/';
                                        }
                                      });
                                    }
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _CompactInput(
                              label: 'Puerto',
                              controller: _hbHttpPortCtrl,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _CompactInput(
                              label: 'HTTP OK',
                              controller: _hbExpectedStatusCtrl,
                            ),
                          ),
                        ],
                      ),
                      _CompactInput(
                        label: 'URL completa o Path (usa IP/FQDN o {ip} / {fqdn})',
                        controller: _hbUrlCtrl,
                      ),
                    ],
                  ),
                ),

              // 4. Configuración TCP (Puerto en concreto)
              if (_hbEnabledChecks.contains('tcp'))
                _buildProtocolConfigCard(
                  protocolKey: 'tcp',
                  title: 'TCP (Puerto específico)',
                  icon: Icons.settings_ethernet,
                  targetValue: _hbTcpTarget,
                  onTargetChanged: (v) => setState(() => _hbTcpTarget = v),
                  child: _CompactInput(
                    label: 'Puerto TCP a comprobar (ej. 8006, 3389, 9100, 5432)',
                    controller: _hbTcpPortCtrl,
                  ),
                ),

              // 5. Configuración UDP (Puerto en concreto)
              if (_hbEnabledChecks.contains('udp'))
                _buildProtocolConfigCard(
                  protocolKey: 'udp',
                  title: 'UDP (Puerto específico)',
                  icon: Icons.wifi_tethering,
                  targetValue: _hbUdpTarget,
                  onTargetChanged: (v) => setState(() => _hbUdpTarget = v),
                  child: _CompactInput(
                    label: 'Puerto UDP a comprobar (ej. 53 DNS, 123 NTP, 514 Syslog)',
                    controller: _hbUdpPortCtrl,
                  ),
                ),

              // 6. Configuración SNMP (Versión, Comunidad, Puerto UDP y OID)
              if (_hbEnabledChecks.contains('snmp'))
                _buildProtocolConfigCard(
                  protocolKey: 'snmp',
                  title: 'SNMP (OID + Versión + Comunidad)',
                  icon: Icons.sensors,
                  targetValue: _hbSnmpTarget,
                  onTargetChanged: (v) => setState(() => _hbSnmpTarget = v),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: _hbSnmpVersion,
                              isDense: true,
                              decoration: _compactDecoration(label: 'Versión'),
                              items: const [
                                DropdownMenuItem(
                                  value: 'v1',
                                  child: Text('SNMP v1', style: TextStyle(fontSize: 11)),
                                ),
                                DropdownMenuItem(
                                  value: 'v2c',
                                  child: Text('SNMP v2c', style: TextStyle(fontSize: 11)),
                                ),
                                DropdownMenuItem(
                                  value: 'v3',
                                  child: Text('SNMP v3', style: TextStyle(fontSize: 11)),
                                ),
                              ],
                              onChanged: _canEdit
                                  ? (v) => setState(() => _hbSnmpVersion = v ?? 'v2c')
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _CompactInput(
                              label: 'Comunidad',
                              controller: _hbSnmpCommunityCtrl,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _CompactInput(
                              label: 'Puerto UDP',
                              controller: _hbSnmpPortCtrl,
                            ),
                          ),
                        ],
                      ),
                      _CompactInput(
                        label: 'OID SNMP (ej. 1.3.6.1.2.1.1.1.0 sysDescr)',
                        controller: _hbSnmpOidCtrl,
                      ),
                    ],
                  ),
                ),

              // Desglose de resultados por protocolo del último Heartbeat
              if (_lastHeartbeatChecks.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Estado real por cada protocolo marcado:',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF475569),
                        ),
                      ),
                      const SizedBox(height: 4),
                      ..._lastHeartbeatChecks.map((chk) {
                        final st = (chk['status'] ?? 'offline').toString();
                        final ok = st == 'online';
                        final det = (chk['detail'] ?? '').toString();
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                ok ? Icons.check_circle : Icons.cancel,
                                size: 13,
                                color: ok
                                    ? const Color(0xFF16A34A)
                                    : const Color(0xFFDC2626),
                              ),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  det,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: ok
                                        ? const Color(0xFF15803D)
                                        : const Color(0xFFB91C1C),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ] else if (_pingResultMessage != null) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Text(
                    _pingResultMessage!,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: Color(0xFF334155),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: (_isPinging || !_canConnectRemote)
                      ? null
                      : _triggerDevicePing,
                  icon: _isPinging
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.monitor_heart_outlined, size: 15),
                  label: Text(
                    _isPinging
                        ? 'Comprobando protocolos en red...'
                        : 'Probar Heartbeat Ahora (${_hbEnabledChecks.length})',
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // SECCIÓN B: CONECTAR Y GESTIONAR EQUIPO (USANDO LOS DATOS DE SSH / WEB / SNMP CONFIGURADOS)
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFF0F9FF),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFBAE6FD)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.important_devices,
                    size: 16,
                    color: Color(0xFF0369A1),
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'Conectar / Gestión Remota del Equipo',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0C4A6E),
                      ),
                    ),
                  ),
                  if (_canEdit)
                    Tooltip(
                      message:
                          'Habilitar o bloquear la conexión remota a este equipo',
                      child: Switch(
                        value: _hbRemoteAccessEnabled,
                        onChanged: (v) =>
                            setState(() => _hbRemoteAccessEnabled = v),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                ],
              ),
              Text(
                _hbRemoteAccessEnabled
                    ? 'Usa directamente los parámetros configurados (SSH, Web HTTP/HTTPS y SNMP) para conectarte o administrar el equipo:'
                    : '⛔ Conexión remota bloqueada por configuración en este equipo.',
                style: TextStyle(
                  fontSize: 10.5,
                  color: _hbRemoteAccessEnabled
                      ? const Color(0xFF0369A1)
                      : const Color(0xFFB91C1C),
                ),
              ),
              if (!_canConnectRemote) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFFECACA)),
                  ),
                  child: const Text(
                    '🔒 Rol "Solo Ver": la conexión interactiva SSH / Web está deshabilitada.',
                    style: TextStyle(fontSize: 10.5, color: Color(0xFFB91C1C)),
                  ),
                ),
              ],
              if (_hbRemoteAccessEnabled && _canConnectRemote) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    // 1. Conectar por SSH (Consola Integrada)
                    FilledButton.icon(
                      onPressed: () => _openIntegratedRemoteConsoleModal(
                        initialProtocol: 'ssh',
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF0F172A),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                      ),
                      icon: const Icon(Icons.terminal, size: 14),
                      label: Text(
                        'Consola SSH (:${_hbSshPortCtrl.text})',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    // 2. Lanzar Cliente SSH Nativo
                    OutlinedButton.icon(
                      onPressed: _launchNativeSshOrCopy,
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 6,
                        ),
                      ),
                      icon: const Icon(Icons.open_in_new, size: 13),
                      label: Text(
                        'SSH App (${_hbSshUserCtrl.text}@${_hbSshTarget.toUpperCase()})',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    // 3. Conectar vía Web HTTP/HTTPS
                    FilledButton.tonalIcon(
                      onPressed: _openConfiguredWebUrl,
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                      ),
                      icon: const Icon(Icons.language, size: 14),
                      label: Text(
                        'Abrir Web (${_hbHttpScheme.toUpperCase()}:${_hbHttpPortCtrl.text})',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    // 4. Consultar SNMP / Diagnóstico en vivo
                    OutlinedButton.icon(
                      onPressed: () => _openIntegratedRemoteConsoleModal(
                        initialProtocol:
                            _hbEnabledChecks.contains('snmp') ? 'snmp' : 'heartbeat',
                      ),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 6,
                        ),
                      ),
                      icon: const Icon(Icons.sensors, size: 14),
                      label: const Text(
                        'Diagnóstico / SNMP',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Accesos adicionales (Telnet / iDRAC / iLO / VNC):',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF334155),
                      ),
                    ),
                  ),
                  if (_canEdit)
                    TextButton.icon(
                      onPressed: _showAddProtocolDialog,
                      icon: const Icon(Icons.add, size: 13),
                      label: const Text(
                        'Añadir Acceso',
                        style: TextStyle(fontSize: 10.5),
                      ),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                ],
              ),
              if (_devLinks.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _devLinks.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final lnk = entry.value;
                    final proto =
                        (lnk['protocol'] ?? 'ssh').toString().toUpperCase();
                    final port = lnk['port'] ?? 22;
                    final label = (lnk['label'] ?? proto).toString();
                    return InputChip(
                      avatar: Icon(
                        proto == 'SSH' || proto == 'TELNET'
                            ? Icons.terminal
                            : Icons.language,
                        size: 13,
                        color: (_canConnectRemote && _hbRemoteAccessEnabled)
                            ? const Color(0xFF1D4ED8)
                            : const Color(0xFF94A3B8),
                      ),
                      label: Text(
                        '$label ($proto:$port)',
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      backgroundColor: Colors.white,
                      onPressed: (_canConnectRemote && _hbRemoteAccessEnabled)
                          ? () => _launchRemoteProtocol(lnk)
                          : null,
                      onDeleted: _canEdit
                          ? () {
                              setState(() => _devLinks.removeAt(idx));
                            }
                          : null,
                    );
                  }).toList(),
                ),
            ],
          ),
        ),

        const Divider(height: 22),

        // SECCIÓN C: CONFIGURACIÓN DE RED Y OCUPACIÓN U (HOSTNAME, FQDN, IP, ALTURA U, FOTO)
        if (widget.onConfigureDevicePhoto != null) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.photo_camera_outlined,
                  size: 18,
                  color: Color(0xFF1D4ED8),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Foto de Referencia del Equipo',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      Text(
                        d.photoUrl.isNotEmpty
                            ? 'Imagen configurada (visible con modo Foto ON)'
                            : 'Bisel realista automático o busca foto en Internet',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => widget.onConfigureDevicePhoto!(d),
                  icon: const Icon(Icons.image_search_outlined, size: 14),
                  label: const Text(
                    'Buscar Foto',
                    style: TextStyle(fontSize: 11),
                  ),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ],
            ),
          ),
        ],
        const Text(
          'Red, Posición y Altura en U',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Color(0xFF0F172A),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: _CompactInput(label: 'Código Rack *', controller: _devCodeCtrl),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 1,
              child: _CompactInput(label: 'U Inicial', controller: _devStartUCtrl),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: DropdownButtonFormField<int>(
                  initialValue: _devUHeight.clamp(1, 16),
                  isDense: true,
                  decoration: _compactDecoration(label: 'Ocupa (U)'),
                  items: List.generate(16, (idx) => idx + 1)
                      .map(
                        (uVal) => DropdownMenuItem<int>(
                          value: uVal,
                          child: Text(
                            '${uVal}U',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _canEdit
                      ? (v) {
                          if (v != null) {
                            setState(() => _devUHeight = v);
                          }
                        }
                      : null,
                ),
              ),
            ),
          ],
        ),
        _CompactInput(label: 'Nombre descriptivo', controller: _devNameCtrl),
        Row(
          children: [
            Expanded(
              child: _CompactInput(label: 'Hostname', controller: _devHostnameCtrl),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _CompactInput(label: 'VLAN Gestión', controller: _devVlanCtrl),
            ),
          ],
        ),
        _CompactInput(
          label: 'FQDN (ej. sw01.hq.rackdoc.local)',
          controller: _devFqdnCtrl,
        ),
        Row(
          children: [
            Expanded(
              child: _CompactInput(
                label: 'Dirección IP',
                controller: _devIpCtrl,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _CompactInput(
                label: 'Máscara Subred',
                controller: _devMaskCtrl,
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _CompactInput(
                label: 'Gateway (Puerta Enlace)',
                controller: _devGwCtrl,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _CompactInput(
                label: 'MAC Address',
                controller: _devMacCtrl,
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _CompactInput(
                label: 'Número de Serie',
                controller: _devSerialCtrl,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Cara Montaje',
                    style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                  ),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<String>(
                    initialValue: _devMountedFace,
                    isDense: true,
                    decoration: _compactDecoration(),
                    items: const [
                      DropdownMenuItem(value: 'front', child: Text('FRONT')),
                      DropdownMenuItem(value: 'back', child: Text('BACK')),
                    ],
                    onChanged: (v) =>
                        setState(() => _devMountedFace = v ?? 'front'),
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ],
        ),

        // SECCIÓN D: VARIABLES PERSONALIZADAS DINÁMICAS (CUSTOM FIELDS)
        const Divider(height: 18),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Variables Personalizadas (Custom Fields)',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _showAddCustomFieldDialog,
              icon: const Icon(Icons.add, size: 14),
              label: const Text('+ Variable', style: TextStyle(fontSize: 11)),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
          ],
        ),
        if (_devCustomFields.entries
            .where((e) => !const {
                  'heartbeat_config',
                  'last_heartbeat_checks',
                  'last_heartbeat_detail',
                  'real_heartbeat_v2_initialized',
                  'real_heartbeat_v3_initialized',
                  'is_external_feed',
                  'feed_type',
                  'feed_color',
                  'socket_count',
                  'u_height_override',
                  'photo_url',
                  'show_photo',
                }.contains(e.key))
            .isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Añade variables extra como CPU, RAM, OS, Contrato, Consumo W...',
              style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
          )
        else
          ..._devCustomFields.entries
              .where((e) => !const {
                    'heartbeat_config',
                    'last_heartbeat_checks',
                    'last_heartbeat_detail',
                    'real_heartbeat_v2_initialized',
                    'is_external_feed',
                    'feed_type',
                    'feed_color',
                    'socket_count',
                    'u_height_override',
                    'photo_url',
                    'show_photo',
                  }.contains(e.key))
              .map((entry) {
            return Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${entry.key}: ',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF334155),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${entry.value}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () {
                      setState(() => _devCustomFields.remove(entry.key));
                    },
                    child: const Icon(
                      Icons.delete_outline,
                      size: 15,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
            );
          }),

        const SizedBox(height: 6),
        _CompactInput(label: 'Notas técnicas', controller: _devNotesCtrl, maxLines: 2),
        if (_canEdit) ...[
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _isSaving ? null : _saveDeviceSettings,
            icon: const Icon(Icons.save_outlined, size: 16),
            label: Text(_isSaving ? 'Guardando...' : 'Guardar Cambios del Equipo'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1E3A8A),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              await widget.api.deleteDevice(d.id);
              widget.onClearSelection();
              widget.onRefreshRack();
            },
            icon: const Icon(
              Icons.delete_outline,
              size: 16,
              color: Color(0xFFDC2626),
            ),
            label: const Text(
              'Desmontar Equipo del Rack',
              style: TextStyle(color: Color(0xFFDC2626)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildProtocolConfigCard({
    required String protocolKey,
    required String title,
    required IconData icon,
    required String targetValue,
    required ValueChanged<String> onTargetChanged,
    required Widget child,
  }) {
    final checkRes = _lastHeartbeatChecks.cast<Map<String, dynamic>?>().firstWhere(
          (c) {
            final m = (c?['method'] ?? c?['protocol'] ?? '')
                .toString()
                .toLowerCase();
            if (protocolKey == 'http') return m == 'http' || m == 'https';
            return m == protocolKey;
          },
          orElse: () => null,
        );
    final isOk = checkRes != null && checkRes['status'] == 'online';
    final isFail = checkRes != null && checkRes['status'] == 'offline';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isOk
              ? const Color(0xFF86EFAC)
              : (isFail ? const Color(0xFFFCA5A5) : const Color(0xFFCBD5E1)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: const Color(0xFF1D4ED8)),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ),
              if (checkRes != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    color: isOk
                        ? const Color(0xFFDCFCE7)
                        : const Color(0xFFFEE2E2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    isOk
                        ? 'OK${checkRes["latency_ms"] != null ? " ${checkRes["latency_ms"]}ms" : ""}'
                        : 'CAÍDO',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      color: isOk
                          ? const Color(0xFF15803D)
                          : const Color(0xFFB91C1C),
                    ),
                  ),
                ),
              // Selector IP vs FQDN para cada protocolo
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: const Color(0xFFCBD5E1)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final opt in [('ip', 'IP'), ('fqdn', 'FQDN')])
                      InkWell(
                        onTap: _canEdit ? () => onTargetChanged(opt.$1) : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2.5,
                          ),
                          decoration: BoxDecoration(
                            color: targetValue == opt.$1
                                ? const Color(0xFF1D4ED8)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            opt.$2,
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              color: targetValue == opt.$1
                                  ? Colors.white
                                  : const Color(0xFF475569),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }

  // ===========================================================================
  // 3. PANEL DE PROPIEDADES DEL CABLE / CONEXIÓN (RED, FIBRA, ELECTRICIDAD)
  // ===========================================================================
  Widget _buildConnectionPanel(ConnectionModel c) {
    const colorPalette = [
      '#2563EB', // Azul Red UTP
      '#0284C7', // Cyan Fibra OM4
      '#F59E0B', // Ámbar Fibra OS2
      '#DC2626', // Rojo Electricidad Línea A
      '#EA580C', // Naranja Electricidad Línea B
      '#10B981', // Verde Trunk / Outbound
      '#7C3AED', // Violeta Gestión / VLAN
      '#334155', // Gris / Negro
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Icon(Icons.cable, size: 18, color: Color(0xFF2563EB)),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Conexión de Cable',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
              ),
            ),
            IconButton(
              onPressed: widget.onClearSelection,
              icon: const Icon(Icons.close, size: 18),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        const Divider(height: 18),

        // Tarjeta Origen -> Destino
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _EndpointRow(
                title: 'ORIGEN',
                info: c.sourceInfo,
                onSwitchFace: () => widget.onSwitchFace(c.sourceInfo.face),
                onJumpRack: c.sourceInfo.rackId != widget.rack.id
                    ? () => widget.onNavigateToRack(c.sourceInfo.rackId)
                    : null,
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Icon(Icons.arrow_downward_rounded, size: 16, color: Color(0xFF64748B)),
              ),
              _EndpointRow(
                title: 'DESTINO',
                info: c.targetInfo,
                onSwitchFace: () => widget.onSwitchFace(c.targetInfo.face),
                onJumpRack: c.targetInfo.rackId != widget.rack.id
                    ? () => widget.onNavigateToRack(c.targetInfo.rackId)
                    : null,
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),
        const Text(
          'Tipo de Cable (Red / Fibra / Electricidad)',
          style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 4),
        DropdownButtonFormField<String>(
          initialValue: _connCableType,
          isDense: true,
          decoration: _compactDecoration(),
          items: const [
            DropdownMenuItem(value: 'utp_cat6a', child: Text('Red Cobre UTP Cat.6a')),
            DropdownMenuItem(value: 'utp_cat6', child: Text('Red Cobre UTP Cat.6')),
            DropdownMenuItem(value: 'fiber_om4', child: Text('Fibra Óptica Multimodo OM4')),
            DropdownMenuItem(value: 'fiber_os2', child: Text('Fibra Óptica Monomodo OS2')),
            DropdownMenuItem(value: 'power_ac', child: Text('Electricidad AC (C13/C14/PDU)')),
          ],
          onChanged: (v) => setState(() => _connCableType = v ?? 'utp_cat6a'),
        ),

        const SizedBox(height: 12),
        const Text(
          'Color del Cable',
          style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: colorPalette.map((hex) {
            final isSel = _connColorHex.toUpperCase() == hex.toUpperCase();
            final col = Color(int.parse('FF${hex.replaceAll('#', '')}', radix: 16));
            return GestureDetector(
              onTap: () => setState(() => _connColorHex = hex),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: col,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isSel ? Colors.black : Colors.white,
                    width: isSel ? 2.5 : 1.5,
                  ),
                ),
                child: isSel
                    ? const Icon(Icons.check, size: 15, color: Colors.white)
                    : null,
              ),
            );
          }).toList(),
        ),

        const SizedBox(height: 14),
        const Text(
          'Canaleta del Rack (Routing Channel)',
          style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 4),
        DropdownButtonFormField<String>(
          initialValue: _connChannel,
          isDense: true,
          decoration: _compactDecoration(),
          items: const [
            DropdownMenuItem(value: 'auto', child: Text('Automático (Más cercano)')),
            DropdownMenuItem(value: 'left', child: Text('Canaleta Izquierda')),
            DropdownMenuItem(value: 'right', child: Text('Canaleta Derecha')),
          ],
          onChanged: (v) => setState(() => _connChannel = v ?? 'auto'),
        ),

        const SizedBox(height: 12),
        _CompactInput(
          label: 'Etiqueta / Indicaciones (ej. Trunk VLAN 10 / Línea A)',
          controller: _connLabelCtrl,
        ),
        Row(
          children: [
            Expanded(
              child: _CompactInput(label: 'VLAN ID', controller: _connVlanCtrl),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _CompactInput(label: 'Longitud (m)', controller: _connLengthCtrl),
            ),
          ],
        ),
        _CompactInput(
          label: 'Notas del cableado',
          controller: _connNotesCtrl,
          maxLines: 2,
        ),

        if (_canEdit) ...[
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _isSaving ? null : _saveConnectionSettings,
            icon: const Icon(Icons.save_outlined, size: 16),
            label: const Text('Guardar Propiedades del Cable'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1E3A8A),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              await widget.api.deleteConnection(c.id);
              widget.onClearSelection();
              widget.onRefreshRack();
            },
            icon: const Icon(
              Icons.link_off,
              size: 16,
              color: Color(0xFFDC2626),
            ),
            label: const Text(
              'Desconectar / Eliminar Cable',
              style: TextStyle(color: Color(0xFFDC2626)),
            ),
          ),
        ],
      ],
    );
  }

  InputDecoration _compactDecoration({String? label}) {
    return InputDecoration(
      labelText: label,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      filled: true,
      fillColor: const Color(0xFFF8FAFC),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
      ),
    );
  }
}

class _EndpointRow extends StatelessWidget {
  final String title;
  final ConnectionEndpointInfoModel info;
  final VoidCallback onSwitchFace;
  final VoidCallback? onJumpRack;

  const _EndpointRow({
    required this.title,
    required this.info,
    required this.onSwitchFace,
    this.onJumpRack,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$title (${info.rackCode} • U${info.startU} • ${info.face.toUpperCase()})',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF64748B),
                ),
              ),
              Text(
                '${info.deviceCode} — Boca ${info.portNumber} (${info.portType.toUpperCase()})',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
              ),
            ],
          ),
        ),
        if (onJumpRack != null)
          TextButton(
            onPressed: onJumpRack,
            child: const Text('Ir al Rack', style: TextStyle(fontSize: 11)),
          )
        else
          TextButton(
            onPressed: onSwitchFace,
            child: Text(
              'Ver ${info.face.toUpperCase()}',
              style: const TextStyle(fontSize: 11),
            ),
          ),
      ],
    );
  }
}

class _CompactInput extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final int maxLines;

  const _CompactInput({
    required this.label,
    required this.controller,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            maxLines: maxLines,
            style: const TextStyle(fontSize: 12, color: Color(0xFF0F172A)),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 9,
              ),
              filled: true,
              fillColor: const Color(0xFFF8FAFC),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConsoleActionChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;

  const _ConsoleActionChip({
    required this.label,
    required this.icon,
    required this.selected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF0284C7) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? const Color(0xFF38BDF8) : const Color(0xFF334155),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: Colors.white),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
