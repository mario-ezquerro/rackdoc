import 'package:flutter/material.dart';
import '../../../core/api_client.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/avisos.dart';

/// Pestaña **`5. Descubrimiento Pasivo (RO)`** de Fase 2 en `AiAgentView`:
/// - Lanza **Walk SNMP Solo-Lectura (`IF-MIB` + `LLDP-MIB`)** sobre Switches/Routers.
/// - Lanza **Auditoría en Memoria SSH (Linux) / WinRM (Windows)** con cero escritura remota
///   reutilizando credenciales cifradas del Baúl Fernet o credenciales puntuales en memoria.
/// - Muestra puertos escuchando, conexiones TCP entre máquinas, contenedores, bocas y vecinos LLDP,
///   permitiendo volcarlos a `SwitchSnmpPort` y `LogicalTopologyLink` bajo aprobación humana (`editor+`).
class PassiveDiscoveryTab extends StatefulWidget {
  final RackDocApiClient api;
  final Map<String, dynamic> passiveData;
  final bool canLaunchAudit;
  final bool canEdit;
  final ValueChanged<Map<String, dynamic>> onOverviewUpdated;

  const PassiveDiscoveryTab({
    super.key,
    required this.api,
    required this.passiveData,
    required this.canLaunchAudit,
    required this.canEdit,
    required this.onOverviewUpdated,
  });

  @override
  State<PassiveDiscoveryTab> createState() => _PassiveDiscoveryTabState();
}

class _PassiveDiscoveryTabState extends State<PassiveDiscoveryTab> {
  String _collectorMode = 'net_scan'; // 'net_scan' | 'snmp' | 'host_audit'

  // Controles Barrido Pasivo Red / Huella OS + TCP/IP + MAC
  final TextEditingController _netRangeCtrl =
      TextEditingController(text: '192.168.2.0/24');
  bool _runningNetScan = false;

  // Controles Walk SNMP RO
  final TextEditingController _snmpHostCtrl = TextEditingController();
  final TextEditingController _snmpPortCtrl =
      TextEditingController(text: '161');
  final TextEditingController _snmpCommunityCtrl =
      TextEditingController(text: 'public');
  bool _runningSnmp = false;

  // Controles Auditoría SSH / WinRM RO
  String _osFamily = 'linux';
  final TextEditingController _auditTargetsCtrl = TextEditingController();
  int? _selectedVaultCredentialId;
  bool _useEphemeralCred = false;
  final TextEditingController _ephUserCtrl =
      TextEditingController(text: 'root');
  final TextEditingController _ephPortCtrl = TextEditingController(text: '22');
  final TextEditingController _ephSecretCtrl = TextEditingController();
  bool _runningHostAudit = false;

  @override
  void dispose() {
    _netRangeCtrl.dispose();
    _snmpHostCtrl.dispose();
    _snmpPortCtrl.dispose();
    _snmpCommunityCtrl.dispose();
    _auditTargetsCtrl.dispose();
    _ephUserCtrl.dispose();
    _ephPortCtrl.dispose();
    _ephSecretCtrl.dispose();
    super.dispose();
  }

  Future<void> _launchNetworkFingerprintScan() async {
    final messenger = ScaffoldMessenger.of(context);
    final range = _netRangeCtrl.text.trim();
    if (range.isEmpty) {
      messenger.avisoError(
        'Indica una IP, rango (10.20.20.1-50) o red CIDR (10.20.20.0/24).',
      );
      return;
    }
    setState(() => _runningNetScan = true);
    try {
      final res = await widget.api.runPassiveNetworkScan({
        'target_range': range,
        'timeout_sec': 0.6,
        'count_limit': 254,
      });
      if (!mounted) return;
      final ov = Map<String, dynamic>.from((res['overview'] ?? const {}) as Map);
      widget.onOverviewUpdated(ov);
      final count = (res['detected_count'] as num?)?.toInt() ?? 0;
      messenger.avisoExito(
        'Barrido RO completado en $range: $count máquina(s) activas perfiladas (OS, Pila TCP/IP y MAC OUI).',
      );
    } catch (e) {
      messenger.avisoError(e);
    } finally {
      if (mounted) {
        setState(() => _runningNetScan = false);
      }
    }
  }

  Future<void> _launchSnmpWalk() async {
    final messenger = ScaffoldMessenger.of(context);
    final host = _snmpHostCtrl.text.trim();
    if (host.isEmpty) {
      messenger.avisoError('Indica la IP o FQDN del Switch/Router a consultar.');
      return;
    }
    setState(() => _runningSnmp = true);
    try {
      final res = await widget.api.runPassiveSnmpWalk({
        'target_host': host,
        'port': int.tryParse(_snmpPortCtrl.text.trim()) ?? 161,
        'community': _snmpCommunityCtrl.text.trim().isEmpty
            ? 'public'
            : _snmpCommunityCtrl.text.trim(),
        'version': 'v2c',
        'timeout_sec': 2.0,
      });
      if (!mounted) return;
      final ov = Map<String, dynamic>.from((res['overview'] ?? const {}) as Map);
      widget.onOverviewUpdated(ov);
      final snap =
          Map<String, dynamic>.from((res['snapshot'] ?? const {}) as Map);
      final ifsCount = ((snap['snmp_interfaces'] ?? const []) as List).length;
      messenger.avisoExito(
        'Walk SNMP RO completado en $host: $ifsCount boca(s) descubiertas.',
      );
    } catch (e) {
      messenger.avisoError(e);
    } finally {
      if (mounted) {
        setState(() => _runningSnmp = false);
      }
    }
  }

  Future<void> _launchHostAudit() async {
    final messenger = ScaffoldMessenger.of(context);
    final targets = _auditTargetsCtrl.text
        .split(RegExp(r'[,;\s]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (targets.isEmpty) {
      messenger.avisoError('Indica al menos una IP o hostname a auditar.');
      return;
    }
    if (!_useEphemeralCred && _selectedVaultCredentialId == null) {
      messenger.avisoError(
        'Selecciona una credencial del Baúl Fernet o activa "Credencial puntual en memoria".',
      );
      return;
    }
    if (_useEphemeralCred && _ephSecretCtrl.text.trim().isEmpty) {
      messenger.avisoError('Introduce la contraseña o clave SSH de lectura.');
      return;
    }

    setState(() => _runningHostAudit = true);
    try {
      final payload = <String, dynamic>{
        'os_family': _osFamily,
        'targets': targets,
      };
      if (_useEphemeralCred) {
        payload['ephemeral_credential'] = {
          'credential_type':
              _osFamily == 'windows' ? 'winrm' : 'ssh_password',
          'username': _ephUserCtrl.text.trim().isEmpty
              ? (_osFamily == 'windows' ? 'Administrator' : 'root')
              : _ephUserCtrl.text.trim(),
          'port': int.tryParse(_ephPortCtrl.text.trim()) ??
              (_osFamily == 'windows' ? 5985 : 22),
          'secret': _ephSecretCtrl.text,
        };
      } else {
        payload['credential_id'] = _selectedVaultCredentialId;
      }

      final res = await widget.api.runPassiveHostAudit(payload);
      if (!mounted) return;
      final ov = Map<String, dynamic>.from((res['overview'] ?? const {}) as Map);
      widget.onOverviewUpdated(ov);
      final snaps = (res['snapshots'] ?? const []) as List;
      messenger.avisoExito(
        'Auditoría RO completada sobre ${snaps.length} máquina(s) sin escritura remota.',
      );
    } catch (e) {
      messenger.avisoError(e);
    } finally {
      if (mounted) {
        setState(() => _runningHostAudit = false);
      }
    }
  }

  Future<void> _applySnapshotTopology(int snapId) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await widget.api.applyPassiveSnapshotTopology(snapId);
      if (!mounted) return;
      final ov = Map<String, dynamic>.from((res['overview'] ?? const {}) as Map);
      widget.onOverviewUpdated(ov);
      messenger.avisoExito(
        'Sincronizado: ${res['snmp_ports_upserted']} boca(s) SNMP y ${res['logical_links_created']} enlace(s) lógico(s).',
      );
    } catch (e) {
      messenger.avisoError(e);
    }
  }

  Future<void> _deleteSnapshot(int snapId) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await widget.api.deletePassiveSnapshot(snapId);
      if (!mounted) return;
      final ov = Map<String, dynamic>.from((res['overview'] ?? const {}) as Map);
      widget.onOverviewUpdated(ov);
      messenger.aviso('Instantánea pasiva eliminada.');
    } catch (e) {
      messenger.avisoError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshots = ((widget.passiveData['snapshots'] ?? const []) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final vaultCreds =
        ((widget.passiveData['vault_credentials'] ?? const []) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();

    if (_selectedVaultCredentialId == null && vaultCreds.isNotEmpty) {
      _selectedVaultCredentialId = vaultCreds.first['id'] as int?;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // PANEL IZQUIERDO: LANZADOR DE COLECTORES SOLO-LECTURA
        Container(
          width: 390,
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(right: BorderSide(color: AppPalette.slate200)),
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Fase 2: Descubrimiento Pasivo 100% RO',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: AppPalette.slate900,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Inspecciona bocas/vecinos LLDP en switches o sockets y contenedores en servidores con cero escritura remota.',
                  style: TextStyle(fontSize: 11.5, color: AppPalette.slate500),
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'net_scan',
                      icon: Icon(Icons.memory_rounded, size: 15),
                      label: Text('Huella Red / OS'),
                    ),
                    ButtonSegment(
                      value: 'snmp',
                      icon: Icon(Icons.router_outlined, size: 15),
                      label: Text('SNMP'),
                    ),
                    ButtonSegment(
                      value: 'host_audit',
                      icon: Icon(Icons.terminal_rounded, size: 15),
                      label: Text('SSH/WinRM'),
                    ),
                  ],
                  selected: {_collectorMode},
                  onSelectionChanged: (sel) =>
                      setState(() => _collectorMode = sel.first),
                ),
                const SizedBox(height: 14),
                if (_collectorMode == 'net_scan') ...[
                  TextField(
                    controller: _netRangeCtrl,
                    onSubmitted: (_) => _launchNetworkFingerprintScan(),
                    decoration: const InputDecoration(
                      labelText: 'IP, Rango o Red CIDR a escanear (100% RO)',
                      hintText: 'Ej: 10.20.20.0/24 o 10.20.20.1-50',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Deduce Sistema Operativo, respuestas de pila TCP/IP (TTL, saltos, MSS, Window Scale, TS/SACK), '
                    'fabricante MAC OUI / hipervisor y banners SSH, HTTP/TLS, SMB/NTLMSSP, NetBIOS, SNMP y mDNS sin credenciales ni escritura.',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppPalette.slate600,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: (!widget.canLaunchAudit || _runningNetScan)
                          ? null
                          : _launchNetworkFingerprintScan,
                      icon: _runningNetScan
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.radar_rounded, size: 17),
                      label: Text(
                        _runningNetScan
                            ? 'Perfilando máquinas en red...'
                            : 'Escanear Red y Averiguar OS / TCP-IP / MAC',
                      ),
                    ),
                  ),
                ] else if (_collectorMode == 'snmp') ...[
                  TextField(
                    controller: _snmpHostCtrl,
                    decoration: const InputDecoration(
                      labelText: 'IP o Hostname del Switch / Router',
                      hintText: 'Ej: 10.20.1.2',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: _snmpPortCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Puerto UDP',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _snmpCommunityCtrl,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Comunidad SNMP RO',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: (!widget.canLaunchAudit || _runningSnmp)
                          ? null
                          : _launchSnmpWalk,
                      icon: _runningSnmp
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.radar_rounded, size: 17),
                      label: Text(
                        _runningSnmp
                            ? 'Recorriendo MIBs...'
                            : 'Ejecutar Walk IF-MIB + LLDP-MIB (RO)',
                      ),
                    ),
                  ),
                ] else ...[
                  DropdownButtonFormField<String>(
                    initialValue: _osFamily,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Familia de Sistema Operativo',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'linux',
                        child: Text('Linux (SSH en memoria · sin sudo)'),
                      ),
                      DropdownMenuItem(
                        value: 'windows',
                        child: Text('Windows Server (WinRM PowerShell RO)'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() {
                        _osFamily = v;
                        _ephUserCtrl.text =
                            v == 'windows' ? 'Administrator' : 'root';
                        _ephPortCtrl.text = v == 'windows' ? '5985' : '22';
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _auditTargetsCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'IPs o Hostnames Objetivo (separados por coma)',
                      hintText: '10.20.20.145, 10.20.20.150',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _useEphemeralCred || vaultCreds.isEmpty,
                    onChanged: vaultCreds.isEmpty
                        ? null
                        : (v) => setState(() => _useEphemeralCred = v),
                    title: const Text(
                      'Usar credencial puntual en memoria (no guardada)',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                  if (!_useEphemeralCred && vaultCreds.isNotEmpty)
                    DropdownButtonFormField<int>(
                      initialValue: _selectedVaultCredentialId,
                      isDense: true,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Credencial Cifrada del Baúl Fernet',
                        border: OutlineInputBorder(),
                      ),
                      items: vaultCreds
                          .map(
                            (c) => DropdownMenuItem<int>(
                              value: c['id'] as int,
                              child: Text(
                                '${c['name']} (${c['username']}:${c['port']})',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (id) =>
                          setState(() => _selectedVaultCredentialId = id),
                    )
                  else ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _ephUserCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Usuario RO',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 95,
                          child: TextField(
                            controller: _ephPortCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Puerto',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _ephSecretCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Contraseña (solo en RAM durante la sonda)',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: (!widget.canLaunchAudit || _runningHostAudit)
                          ? null
                          : _launchHostAudit,
                      icon: _runningHostAudit
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.search_rounded, size: 17),
                      label: Text(
                        _runningHostAudit
                            ? 'Auditando en memoria...'
                            : 'Auditar Puertos, Conexiones y Docker (RO)',
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // PANEL DERECHO: HISTORIAL E INSPECTOR DE INSTANTÁNEAS CAPTURADAS
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: snapshots.isEmpty
                ? const Center(
                    child: Text(
                      'Aún no hay instantáneas de Descubrimiento Pasivo.\nLanza un Walk SNMP o una Auditoría SSH/WinRM RO en el panel izquierdo.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppPalette.slate500),
                    ),
                  )
                : ListView.separated(
                    itemCount: snapshots.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (ctx, idx) {
                      final s = snapshots[idx];
                      final ok = s['status'] == 'completed';
                      final applied = s['topology_applied'] == true;
                      final snmpIfs =
                          ((s['snmp_interfaces'] ?? const []) as List)
                              .map((e) => Map<String, dynamic>.from(e as Map))
                              .toList();
                      final listenPorts =
                          ((s['listening_ports'] ?? const []) as List)
                              .map((e) => Map<String, dynamic>.from(e as Map))
                              .toList();
                      final peers =
                          ((s['peer_connections'] ?? const []) as List)
                              .map((e) => Map<String, dynamic>.from(e as Map))
                              .toList();
                      final containers =
                          ((s['containers'] ?? const []) as List)
                              .map((e) => Map<String, dynamic>.from(e as Map))
                              .toList();
                      final deps =
                          ((s['inferred_dependencies'] ?? const []) as List)
                              .map((e) => Map<String, dynamic>.from(e as Map))
                              .toList();
                      final runningEv =
                          ((s['running_services'] ?? const []) as List)
                              .map((e) => e.toString())
                              .where((x) => x.isNotEmpty)
                              .toList();
                      final fpMetaList =
                          ((s['web_vhosts_or_dbs'] ?? const []) as List)
                              .whereType<Map>()
                              .map((e) => Map<String, dynamic>.from(e))
                              .toList();
                      final Map<String, dynamic> netMeta =
                          (s['collector_type'] == 'network_fingerprint_ro' &&
                                  fpMetaList.isNotEmpty)
                              ? fpMetaList.first
                              : const <String, dynamic>{};
                      final Map<String, dynamic> netStack =
                          (netMeta['tcpip_stack'] is Map)
                              ? Map<String, dynamic>.from(
                                  netMeta['tcpip_stack'] as Map,
                                )
                              : const <String, dynamic>{};

                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: ok ? AppPalette.slate200 : AppPalette.red300,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: ok
                                        ? AppPalette.green100
                                        : AppPalette.red50,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '${s['collector_type']} · ${s['status']}'
                                        .toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                      color: ok
                                          ? AppPalette.green700
                                          : AppPalette.red700,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    '${s['target_host']} (${(s['asset_code'] ?? '').toString().isNotEmpty ? s['asset_code'] : (s['hostname_detected'] ?? 'No vinculado a CMDB')})',
                                    style: const TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                if (ok &&
                                    widget.canEdit &&
                                    (snmpIfs.isNotEmpty || deps.isNotEmpty))
                                  applied
                                      ? const Chip(
                                          label: Text(
                                            'Sincronizado en Topología',
                                            style: TextStyle(fontSize: 11),
                                          ),
                                          backgroundColor: AppPalette.sky50,
                                        )
                                      : FilledButton.tonalIcon(
                                          onPressed: () =>
                                              _applySnapshotTopology(
                                            s['id'] as int,
                                          ),
                                          icon: const Icon(
                                            Icons.sync_alt_rounded,
                                            size: 16,
                                          ),
                                          label: const Text(
                                            'Aplicar Bocas / Enlaces a CMDB',
                                          ),
                                        ),
                                if (widget.canEdit)
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 18,
                                      color: AppPalette.red600,
                                    ),
                                    onPressed: () =>
                                        _deleteSnapshot(s['id'] as int),
                                  ),
                              ],
                            ),
                            if ((s['os_or_sysdescr'] ?? '')
                                .toString()
                                .isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                'Sistema / Firmware: ${s['os_or_sysdescr']}',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: AppPalette.slate600,
                                ),
                              ),
                            ],
                            if (!ok &&
                                (s['error_detail'] ?? '')
                                    .toString()
                                    .isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                (s['error_detail'] ?? '').toString(),
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: AppPalette.red700,
                                ),
                              ),
                            ],
                            if (snmpIfs.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Text(
                                'Bocas SNMP IF-MIB / LLDP descubiertas (${snmpIfs.length}):',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: snmpIfs.take(18).map((iface) {
                                  final isUp = iface['oper_status'] == 'up';
                                  final nb = (iface['lldp_neighbor_sysname'] ??
                                          '')
                                      .toString();
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isUp
                                          ? AppPalette.green50
                                          : AppPalette.slate100,
                                      borderRadius: BorderRadius.circular(5),
                                      border: Border.all(
                                        color: isUp
                                            ? AppPalette.green300
                                            : AppPalette.slate300,
                                      ),
                                    ),
                                    child: Text(
                                      '${iface['if_name']} (${iface['speed_mbps']}M · ${iface['oper_status']})${nb.isNotEmpty ? " ⇄ LLDP: $nb" : ""}',
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ],
                            if (listenPorts.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Text(
                                'Puertos / Servicios detectados (${listenPorts.length}): ${listenPorts.take(14).map((p) {
                                  final b = (p['banner'] ?? '').toString().trim();
                                  return ":${p['port']}/${p['proto']} (${p['process'] ?? ''}${b.isNotEmpty ? ' · $b' : ''})";
                                }).join(', ')}',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: AppPalette.slate800,
                                ),
                              ),
                            ],
                            if (netMeta.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                'Pila TCP/IP & MAC: ${(netStack['stack_signature'] ?? 'N/D')}  •  MAC: ${(netMeta['mac_address'] ?? '').toString().isNotEmpty ? netMeta['mac_address'] : 'Sin ARP L2'}${(netMeta['mac_vendor'] ?? '').toString().isNotEmpty ? " [${netMeta['mac_vendor']}]" : ""}${(netMeta['suggested_asset_class_label'] ?? '').toString().isNotEmpty ? "  •  Rol sugerido: ${netMeta['suggested_asset_class_label']}" : ""}',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppPalette.indigo600,
                                ),
                              ),
                            ],
                            if (s['collector_type'] == 'network_fingerprint_ro' &&
                                runningEv.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                'Evidencias: ${runningEv.join("  •  ")}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppPalette.slate600,
                                ),
                              ),
                            ],
                            if (peers.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                'Conexiones establecidas (${peers.length}): ${peers.take(10).map((p) => "${p['remote_ip']}:${p['remote_port']}${(p['resolved_asset_code'] ?? '').toString().isNotEmpty ? ' [${p['resolved_asset_code']}]' : ''}").join(', ')}',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: AppPalette.blue700,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                            if (containers.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                'Contenedores activos (${containers.length}): ${containers.map((c) => "${c['name']} (${c['image']})").join(', ')}',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: AppPalette.indigo600,
                                ),
                              ),
                            ],
                            if (deps.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Dependencias deducidas listas para topología: ${deps.map((d) => "${d['source_code']} ➔ ${d['target_code']} (${d['protocol_label']})").join('  |  ')}',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppPalette.teal700,
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
