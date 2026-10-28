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
  String _devMountedFace = 'front';
  bool _devMonitorEnabled = false;
  String _devMonitorMethod = 'icmp';
  int _devMonitorPort = 22;
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
    if (oldWidget.selectedDevice?.id != widget.selectedDevice?.id ||
        oldWidget.selectedDevice?.status != widget.selectedDevice?.status ||
        oldWidget.selectedDevice?.lastPingMs != widget.selectedDevice?.lastPingMs) {
      _initDeviceControllers();
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

  void _initDeviceControllers() {
    final d = widget.selectedDevice;
    _pingResultMessage = null;
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
    _devMountedFace = d?.mountedFace ?? 'front';
    _devMonitorEnabled = d?.monitoringEnabled ?? false;
    _devMonitorMethod = d?.monitorMethod ?? 'icmp';
    _devMonitorPort = d?.monitorPort ?? 22;
    _devLinks = d != null
        ? d.managementLinks.map((e) => Map<String, dynamic>.from(e)).toList()
        : [];
    _devCustomFields =
        d != null ? Map<String, dynamic>.from(d.customFields) : {};
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

  Future<void> _saveDeviceSettings() async {
    final d = widget.selectedDevice;
    if (d == null) return;
    setState(() => _isSaving = true);
    try {
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
      _pingResultMessage = null;
    });
    try {
      if (_canEdit) {
        await widget.api.updateDevice(d.id, {
          'ip_address': _devIpCtrl.text.trim(),
          'fqdn': _devFqdnCtrl.text.trim(),
          'monitoring_enabled': true,
          'monitor_method': _devMonitorMethod,
          'monitor_port': _devMonitorPort,
        });
      }
      final res = await widget.api.pingDevice(d.id);
      setState(() {
        _pingResultMessage = res['detail']?.toString() ?? 'Check completado';
      });
      widget.onRefreshRack();
    } catch (e) {
      setState(() => _pingResultMessage = 'Error: $e');
    } finally {
      if (mounted) setState(() => _isPinging = false);
    }
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

        // SECCIÓN A: ESTADO PING Y CONECTIVIDAD EN VIVO
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE2E8F0)),
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
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Estado: ${d.status.toUpperCase()}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: statusColor,
                    ),
                  ),
                  const Spacer(),
                  if (d.lastPingMs != null)
                    Text(
                      '${d.lastPingMs} ms',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF334155),
                      ),
                    ),
                ],
              ),
              if (_pingResultMessage != null) ...[
                const SizedBox(height: 6),
                Text(
                  _pingResultMessage!,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF475569)),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _devMonitorMethod,
                      isDense: true,
                      decoration: _compactDecoration(label: 'Método Check'),
                      items: const [
                        DropdownMenuItem(value: 'icmp', child: Text('ICMP Ping')),
                        DropdownMenuItem(value: 'tcp', child: Text('TCP Port Probe')),
                      ],
                      onChanged: (v) =>
                          setState(() => _devMonitorMethod = v ?? 'icmp'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: (_isPinging || !_canConnectRemote)
                        ? null
                        : _triggerDevicePing,
                    icon: const Icon(Icons.network_ping, size: 15),
                    label: Text(_isPinging ? 'Ping...' : 'Test Ping'),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // SECCIÓN B: LANZADORES RÁPIDOS DE CONEXIÓN (SSH / TELNET / WEB / iDRAC)
        Row(
          children: [
            const Expanded(
              child: Text(
                'Conexión Directa (SSH / Telnet / Web)',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
              ),
            ),
            if (_canEdit)
              TextButton.icon(
                onPressed: _showAddProtocolDialog,
                icon: const Icon(Icons.add, size: 14),
                label: const Text('Añadir', style: TextStyle(fontSize: 11)),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
        if (!_canConnectRemote)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFFECACA)),
            ),
            child: const Text(
              '🔒 Rol "Solo Ver": la conexión interactiva SSH / Telnet / Web está deshabilitada.',
              style: TextStyle(fontSize: 10.5, color: Color(0xFFB91C1C)),
            ),
          ),
        const SizedBox(height: 6),
        if (_devLinks.isEmpty)
          const Text(
            'Sin accesos configurados. Pulsa + Añadir para configurar SSH, Telnet o Web.',
            style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _devLinks.asMap().entries.map((entry) {
              final idx = entry.key;
              final lnk = entry.value;
              final proto = (lnk['protocol'] ?? 'ssh').toString().toUpperCase();
              final port = lnk['port'] ?? 22;
              final label = (lnk['label'] ?? proto).toString();
              return InputChip(
                avatar: Icon(
                  proto == 'SSH' || proto == 'TELNET'
                      ? Icons.terminal
                      : Icons.language,
                  size: 14,
                  color: _canConnectRemote
                      ? const Color(0xFF1D4ED8)
                      : const Color(0xFF94A3B8),
                ),
                label: Text(
                  '$label ($proto:$port)',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                ),
                backgroundColor: _canConnectRemote
                    ? const Color(0xFFEFF6FF)
                    : const Color(0xFFF1F5F9),
                onPressed: () => _launchRemoteProtocol(lnk),
                onDeleted: _canEdit
                    ? () {
                        setState(() => _devLinks.removeAt(idx));
                      }
                    : null,
              );
            }).toList(),
          ),

        const Divider(height: 22),

        // SECCIÓN C: CONFIGURACIÓN DE RED (HOSTNAME, FQDN, IP, MÁSCARA, GATEWAY, VLAN)
        const Text(
          'Red e Identificación',
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
              child: _CompactInput(label: 'Código Rack *', controller: _devCodeCtrl),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _CompactInput(label: 'Unidad U Inicial', controller: _devStartUCtrl),
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
        if (_devCustomFields.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'Añade variables extra como CPU, RAM, OS, Contrato, Consumo W...',
              style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
          )
        else
          ..._devCustomFields.entries.map((entry) {
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
