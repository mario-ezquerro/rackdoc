part of '../network_hosts_view.dart';

/// Diálogos modales CRUD de `4. Red & Host` y `8. Alarmas SRE`: alta/edición
/// de máquinas y servicios, enlaces lógicos, conectores, contactos, grupos y reglas.
extension _NetworkHostsCrudDialogsExt on _NetworkHostsViewState {
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
            api: widget.api,
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
                      _rebuildState(() {
                        _overview = stackUpdated;
                        _selectedHostId = newAssetId;
                        _syncStackCanvasState();
                      });
                    }
                  } else if (mounted) {
                    _rebuildState(() {
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
              _rebuildState(() {
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
                      color: AppPalette.slate900,
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
        title: const Text('Comprobar Switch por SNMP'),
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
                _rebuildState(() {
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
            label: const Text('Comprobar por SNMP'),
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
                _rebuildState(() => _overview = res);
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
                _rebuildState(() => _overview = res);
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
                      child: Text('Switch SNMPv2c/v3 (comprobación de respuesta)'),
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
                _rebuildState(() => _overview = res);
                _showSnack('Conector registrado. No se ha comprobado la conexión con él.');
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
                  _rebuildState(() => _overview = testRes.isNotEmpty ? testRes : res);
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
                _rebuildState(() => _overview = res);
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
                  _rebuildState(() => _overview = res);
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
                int? createdContactId;
                if (savedUser != null) {
                  final cid = savedUser['id'] as int;
                  createdContactId = cid;
                  final currentGroups =
                      ((res['alert_contact_groups'] as List?) ?? _alertContactGroups)
                          .map((e) => Map<String, dynamic>.from(e as Map))
                          .toList();
                  for (final cg in currentGroups) {
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
                if (mounted) {
                  _rebuildState(() {
                    _overview = res;
                    if (createdContactId != null) {
                      _selectedAlertContactId = createdContactId;
                    }
                  });
                }
              },
              child: const Text('Guardar Usuario'),
            ),
          ],
        ),
      ),
    );
  }

  /// Normaliza un nombre de usuario para usarlo como código de AlertContact.
  static String _codigoDeContactoDeUsuario(UserModel u) {
    final limpio = u.username
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final prefijo = u.authSource == 'ad' ? 'USR-AD' : 'USR-LOCAL';
    return '$prefijo-${limpio.isEmpty ? 'SIN-NOMBRE' : limpio}';
  }

  /// Selector de personas para los Grupos de Avisos. Resuelve dos cosas que
  /// antes obligaban a teclear a mano:
  ///   1. Lista con buscador a las personas YA dadas de alta como contactos de
  ///      alarma, en vez de una parrilla plana de chips.
  ///   2. Ofrece además los usuarios que ya existen en RackDoc (locales y de
  ///      dominio) y todavía no son contactos de alarma; al marcarlos se les da
  ///      de alta como contacto con su nombre y su correo, sin reescribir nada.
  /// Devuelve los ids de contacto seleccionados, o null si se cancela.
  Future<Set<int>?> _showPersonPickerDialog({
    required Set<int> seleccionados,
    String tituloContexto = '',
  }) async {
    final elegidos = <int>{...seleccionados};
    // Usuarios de RackDoc marcados para darles de alta como contacto al aceptar.
    final usuariosAAltaIds = <int>{};
    final buscadorCtrl = TextEditingController();
    String consulta = '';
    bool guardando = false;

    // Un usuario de RackDoc ya es contacto de alarma si coincide el correo: es
    // el mismo criterio que usa el backend para pintar el origen (AD / Local).
    Set<String> correosYaContacto() => _alertContacts
        .map((c) => '${c['email'] ?? ''}'.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toSet();

    final resultado = await showDialog<Set<int>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) {
          final yaContacto = correosYaContacto();
          final q = consulta.trim().toLowerCase();

          bool coincide(String texto) => q.isEmpty || texto.toLowerCase().contains(q);

          final contactosFiltrados = _alertContacts.where((c) {
            return coincide(
              '${c['full_name'] ?? ''} ${c['email'] ?? ''} ${c['code'] ?? ''} '
              '${c['role_title'] ?? ''} ${c['source_badge'] ?? ''}',
            );
          }).toList();

          final usuariosPendientes = _directoryUsers.where((u) {
            if (!u.isActive) return false;
            final correo = u.email.trim().toLowerCase();
            if (correo.isEmpty || yaContacto.contains(correo)) return false;
            return coincide('${u.fullName} ${u.username} ${u.email} ${u.role}');
          }).toList();

          return AlertDialog(
            title: Text(
              tituloContexto.isEmpty
                  ? 'Seleccionar Personas para Avisos'
                  : 'Personas de $tituloContexto',
              style: const TextStyle(fontSize: 15.5),
            ),
            content: SizedBox(
              width: 560,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: buscadorCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search_rounded, size: 18),
                      hintText: 'Buscar por nombre, correo, usuario o rol…',
                    ),
                    onChanged: (v) => setModal(() => consulta = v),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text(
                        '${elegidos.length} seleccionada(s)',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Spacer(),
                      if (contactosFiltrados.isNotEmpty)
                        TextButton.icon(
                          onPressed: () => setModal(() {
                            for (final c in contactosFiltrados) {
                              elegidos.add(c['id'] as int);
                            }
                          }),
                          icon: const Icon(Icons.done_all_rounded, size: 15),
                          label: Text(
                            'Marcar los ${contactosFiltrados.length} filtrados',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      if (elegidos.isNotEmpty)
                        TextButton.icon(
                          onPressed: () => setModal(() => elegidos.clear()),
                          icon: const Icon(Icons.remove_done_rounded, size: 15),
                          label: const Text(
                            'Limpiar',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                    ],
                  ),
                  const Divider(height: 14),
                  SizedBox(
                    height: 330,
                    child: ListView(
                      children: [
                        _rotuloSeccionSelector(
                          'YA DADAS DE ALTA COMO CONTACTO DE ALARMA (${contactosFiltrados.length})',
                        ),
                        if (contactosFiltrados.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 8,
                            ),
                            child: Text(
                              'Ninguna coincide con la búsqueda.',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.textMuted,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                        ...contactosFiltrados.map((c) {
                          final cid = c['id'] as int;
                          final grupos =
                              ((c['member_of_groups'] as List?) ?? [])
                                  .map((g) => '${(g as Map)['code']}')
                                  .join(', ');
                          return CheckboxListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: elegidos.contains(cid),
                            onChanged: (v) => setModal(() {
                              if (v == true) {
                                elegidos.add(cid);
                              } else {
                                elegidos.remove(cid);
                              }
                            }),
                            title: Text(
                              '${c['full_name']}  ·  ${c['email']}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              '${c['code']} · ${c['source_badge'] ?? ''}'
                              '${grupos.isNotEmpty ? ' · Ya en: $grupos' : ''}',
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: AppTheme.textMuted,
                              ),
                            ),
                          );
                        }),
                        const SizedBox(height: 10),
                        _rotuloSeccionSelector(
                          'USUARIOS DE RACKDOC SIN CONTACTO DE ALARMA (${usuariosPendientes.length})',
                        ),
                        if (_directoryUsersDenegado)
                          const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 8,
                            ),
                            child: Text(
                              'Tu rol no permite consultar la lista de usuarios de RackDoc '
                              '(es información reservada a admin), así que aquí solo salen los '
                              'contactos de alarma ya creados.',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.textMuted,
                              ),
                            ),
                          )
                        else if (usuariosPendientes.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 8,
                            ),
                            child: Text(
                              'Todos los usuarios con correo ya tienen su contacto de alarma.',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.textMuted,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                        ...usuariosPendientes.map((u) {
                          return CheckboxListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: usuariosAAltaIds.contains(u.id),
                            onChanged: (v) => setModal(() {
                              if (v == true) {
                                usuariosAAltaIds.add(u.id);
                              } else {
                                usuariosAAltaIds.remove(u.id);
                              }
                            }),
                            title: Text(
                              '${u.fullName.isEmpty ? u.username : u.fullName}  ·  ${u.email}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              '${u.username} · rol ${u.role} · '
                              '${u.authSource == 'ad' ? 'Active Directory' : 'Usuario Local'}'
                              ' · se dará de alta como ${_codigoDeContactoDeUsuario(u)}',
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: AppTheme.textMuted,
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                  if (usuariosAAltaIds.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Al aceptar se darán de alta ${usuariosAAltaIds.length} contacto(s) de alarma '
                      'con el nombre y el correo que ya tienen en RackDoc.',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.warning,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: guardando ? null : () => Navigator.pop(ctx, null),
                child: const Text('Cancelar'),
              ),
              ElevatedButton.icon(
                onPressed: guardando
                    ? null
                    : () async {
                        setModal(() => guardando = true);
                        // Dar de alta como contacto a los usuarios marcados y
                        // recoger su id del overview que devuelve el backend.
                        for (final uid in usuariosAAltaIds) {
                          UserModel? u;
                          for (final e in _directoryUsers) {
                            if (e.id == uid) {
                              u = e;
                              break;
                            }
                          }
                          if (u == null) continue;
                          final codigo = _codigoDeContactoDeUsuario(u);
                          try {
                            final res = await widget.api.upsertAlertContact({
                              'code': codigo,
                              'full_name':
                                  u.fullName.isEmpty ? u.username : u.fullName,
                              'email': u.email,
                              'role_title': u.authSource == 'ad'
                                  ? '[Active Directory] ${u.role}'
                                  : '[Usuario Local] ${u.role}',
                              'schedule_period': '24x7',
                            });
                            if (mounted) _rebuildState(() => _overview = res);
                            final creado =
                                ((res['alert_contacts'] as List?) ?? [])
                                    .map((e) => Map<String, dynamic>.from(e as Map))
                                    .firstWhere(
                                      (c) =>
                                          '${c['code']}'.toUpperCase() ==
                                          codigo.toUpperCase(),
                                      orElse: () => <String, dynamic>{},
                                    );
                            if (creado.isNotEmpty) {
                              elegidos.add(creado['id'] as int);
                            }
                          } catch (e) {
                            _showSnack(
                              'No se pudo dar de alta a ${u.username}: $e',
                              isError: true,
                            );
                          }
                        }
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx, {...elegidos});
                      },
                icon: guardando
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.how_to_reg_rounded, size: 16),
                label: const Text('Usar estas personas'),
              ),
            ],
          );
        },
      ),
    );
    buscadorCtrl.dispose();
    return resultado;
  }

  static Widget _rotuloSeccionSelector(String texto) => Padding(
    padding: const EdgeInsets.only(top: 2, bottom: 4),
    child: Text(
      texto,
      style: const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w900,
        letterSpacing: 0.5,
        color: AppTheme.textMuted,
      ),
    ),
  );

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
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Usuarios Miembros de este Grupo:',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Text(
                        '${selectedMemberIds.length} seleccionada(s)',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // El selector trae con buscador las personas ya dadas de alta
                  // y, además, los usuarios de RackDoc que todavía no son
                  // contacto de alarma, para no reescribir a mano a gente que ya
                  // está en el sistema.
                  OutlinedButton.icon(
                    onPressed: () async {
                      final elegidas = await _showPersonPickerDialog(
                        seleccionados: selectedMemberIds,
                        tituloContexto: nameCtrl.text.trim().isEmpty
                            ? 'este Grupo'
                            : nameCtrl.text.trim(),
                      );
                      if (elegidas == null) return;
                      setModal(() {
                        selectedMemberIds
                          ..clear()
                          ..addAll(elegidas);
                      });
                    },
                    icon: const Icon(Icons.person_search_rounded, size: 16),
                    label: const Text(
                      'Seleccionar personas (contactos y usuarios de RackDoc)…',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (selectedMemberIds.isEmpty)
                    const Text(
                      'Ninguna persona todavía. Un grupo sin miembros solo avisa a su correo de grupo.',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.textMuted,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 170),
                      child: SingleChildScrollView(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: selectedMemberIds.map((cid) {
                            final c = _alertContacts.firstWhere(
                              (e) => e['id'] == cid,
                              orElse: () => <String, dynamic>{},
                            );
                            return InputChip(
                              visualDensity: VisualDensity.compact,
                              label: Text(
                                c.isEmpty
                                    ? 'Contacto #$cid'
                                    : '${c['full_name']} · ${c['email']}',
                                style: const TextStyle(fontSize: 10.5),
                              ),
                              onDeleted: () => setModal(
                                () => selectedMemberIds.remove(cid),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
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
                  _rebuildState(() => _overview = res);
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
                _rebuildState(() => _overview = res);
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
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Hosts / Sistemas incluidos en este Grupo:',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Text(
                        '${selectedHostIds.length} de ${_hosts.length}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Antes esto era un Wrap con un chip por cada equipo de la
                  // CMDB: con cientos de equipos es inmanejable. Ahora se
                  // eligen en el Explorador CMDB (virtualizado, agrupado por
                  // subred y con filtros) y aquí solo se listan los elegidos.
                  OutlinedButton.icon(
                    onPressed: () async {
                      final elegidos =
                          await CmdbAssetExplorerDialog.showMulti(
                        context,
                        api: widget.api,
                        initialSelectedAssetIds: selectedHostIds,
                        title:
                            'Elegir los Hosts del Grupo ${codeCtrl.text.trim()}',
                        subtitle:
                            'Marca los equipos que este HostGroup debe vigilar. Vienen de la CMDB, '
                            'incluidos los que ya están montados en racks, agrupados por Subred (CIDR / Máscara).',
                        confirmLabel: 'Usar los equipos marcados',
                      );
                      if (elegidos == null) return;
                      setModal(() {
                        selectedHostIds
                          ..clear()
                          ..addAll(elegidos);
                      });
                    },
                    icon: const Icon(Icons.dns_rounded, size: 16),
                    label: const Text(
                      'Seleccionar equipos en el Explorador CMDB / Racks…',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (selectedHostIds.isEmpty)
                    const Text(
                      'Ningún equipo todavía. Un HostGroup sin equipos no dispara ningún aviso.',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.textMuted,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 190),
                      child: SingleChildScrollView(
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: selectedHostIds.map((hid) {
                            final h = _hosts.firstWhere(
                              (e) => e['id'] == hid,
                              orElse: () => <String, dynamic>{},
                            );
                            final rotulo = h.isEmpty
                                ? 'Activo #$hid'
                                : '${h['code']}'
                                      '${(h['heartbeat_ip'] ?? '').toString().isNotEmpty ? ' · ${h['heartbeat_ip']}' : ''}'
                                      '${(h['rack_code'] ?? '').toString().isNotEmpty ? ' · ${h['rack_code']}' : ''}';
                            return InputChip(
                              visualDensity: VisualDensity.compact,
                              label: Text(
                                rotulo,
                                style: const TextStyle(fontSize: 10.2),
                              ),
                              onDeleted: () => setModal(
                                () => selectedHostIds.remove(hid),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
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
                  _rebuildState(() => _overview = res);
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
                _rebuildState(() => _overview = res);
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

    // Ámbito de la ventana. Antes estaba fijado a 'single_host' con el host que
    // hubiera seleccionado en la vista: no se podía silenciar un grupo entero ni
    // un puñado de equipos, aunque el backend acepta los tres ámbitos.
    String ambito = 'single_host'; // single_host | host_group | ip_or_hostname_list
    int? equipoId = _selectedHostId;
    int? grupoId = _hostGroups.isNotEmpty ? _hostGroups.first['id'] as int : null;
    final variosIds = <int>{};

    Map<String, dynamic> hostPorId(int? id) => _hosts.firstWhere(
      (h) => h['id'] == id,
      orElse: () => <String, dynamic>{},
    );

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) {
          // Cuántos equipos quedarían silenciados, para no activar a ciegas.
          int afectados;
          switch (ambito) {
            case 'host_group':
              final g = _hostGroups.firstWhere(
                (e) => e['id'] == grupoId,
                orElse: () => <String, dynamic>{},
              );
              afectados = ((g['member_asset_ids'] as List?) ?? []).length;
              break;
            case 'ip_or_hostname_list':
              afectados = variosIds.length;
              break;
            default:
              afectados = equipoId == null ? 0 : 1;
          }

          return AlertDialog(
            title: const Text(
              'Activar Ventana de Mantenimiento (Silenciar Avisos)',
              style: TextStyle(fontSize: 15.5),
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
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
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setModal(() {}),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      children: const [30, 60, 240, 480, 1440].map((m) {
                        final rotulo = m < 60
                            ? '$m min'
                            : (m == 1440 ? '24 h' : '${m ~/ 60} h');
                        return ActionChip(
                          visualDensity: VisualDensity.compact,
                          label: Text(
                            rotulo,
                            style: const TextStyle(fontSize: 10.5),
                          ),
                          onPressed: () =>
                              setModal(() => minsCtrl.text = '$m'),
                        );
                      }).toList(),
                    ),
                    const Divider(height: 22),
                    const Text(
                      '¿A qué se aplica esta ventana?',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      initialValue: ambito,
                      decoration: const InputDecoration(isDense: true),
                      items: const [
                        DropdownMenuItem(
                          value: 'single_host',
                          child: Text('Un solo equipo'),
                        ),
                        DropdownMenuItem(
                          value: 'host_group',
                          child: Text('Un Grupo de Hosts completo'),
                        ),
                        DropdownMenuItem(
                          value: 'ip_or_hostname_list',
                          child: Text('Varios equipos sueltos'),
                        ),
                      ],
                      onChanged: (v) =>
                          v == null ? null : setModal(() => ambito = v),
                    ),
                    const SizedBox(height: 10),
                    if (ambito == 'single_host') ...[
                      Text(
                        equipoId == null
                            ? 'Ningún equipo elegido.'
                            : '[${hostPorId(equipoId)['code']}] ${hostPorId(equipoId)['name']}'
                                  ' · ${hostPorId(equipoId)['heartbeat_ip'] ?? 'Sin IP'}',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: equipoId == null
                              ? AppTheme.textMuted
                              : AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final elegido = await CmdbAssetExplorerDialog.show(
                            context,
                            api: widget.api,
                            preselectedAssetId: equipoId,
                            defaultOnlyUnplaced: false,
                            title: 'Elegir el equipo a silenciar',
                            subtitle:
                                'Busca entre todos los equipos de la CMDB, estén o no montados en un rack.',
                          );
                          if (elegido == null) return;
                          setModal(
                            () => equipoId = (elegido['id'] as num).toInt(),
                          );
                        },
                        icon: const Icon(Icons.dns_rounded, size: 16),
                        label: const Text(
                          'Elegir equipo…',
                          style: TextStyle(fontSize: 11.5),
                        ),
                      ),
                    ] else if (ambito == 'host_group') ...[
                      if (_hostGroups.isEmpty)
                        const Text(
                          'No hay ningún Grupo de Hosts creado todavía.',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.textMuted,
                            fontStyle: FontStyle.italic,
                          ),
                        )
                      else
                        DropdownButtonFormField<int>(
                          initialValue: grupoId,
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: 'Grupo de Hosts',
                          ),
                          items: _hostGroups.map((g) {
                            final n =
                                ((g['member_asset_ids'] as List?) ?? []).length;
                            return DropdownMenuItem(
                              value: g['id'] as int,
                              child: Text(
                                '${g['code']} · ${g['name']} ($n equipos)',
                                style: const TextStyle(fontSize: 12),
                              ),
                            );
                          }).toList(),
                          onChanged: (v) => setModal(() => grupoId = v),
                        ),
                    ] else ...[
                      OutlinedButton.icon(
                        onPressed: () async {
                          final elegidos =
                              await CmdbAssetExplorerDialog.showMulti(
                            context,
                            api: widget.api,
                            initialSelectedAssetIds: variosIds,
                            title: 'Elegir los equipos a silenciar',
                            subtitle:
                                'Marca todos los equipos que entran en esta ventana de mantenimiento.',
                            confirmLabel: 'Silenciar los marcados',
                          );
                          if (elegidos == null) return;
                          setModal(() {
                            variosIds
                              ..clear()
                              ..addAll(elegidos);
                          });
                        },
                        icon: const Icon(Icons.playlist_add_check_rounded,
                            size: 16),
                        label: Text(
                          variosIds.isEmpty
                              ? 'Elegir equipos…'
                              : 'Cambiar los ${variosIds.length} equipos elegidos…',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                      if (variosIds.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 130),
                          child: SingleChildScrollView(
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: variosIds.map((id) {
                                final h = hostPorId(id);
                                return InputChip(
                                  visualDensity: VisualDensity.compact,
                                  label: Text(
                                    h.isEmpty
                                        ? 'Activo #$id'
                                        : '${h['code']}',
                                    style: const TextStyle(fontSize: 10.2),
                                  ),
                                  onDeleted: () =>
                                      setModal(() => variosIds.remove(id)),
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      ],
                    ],
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: (afectados == 0 ? AppTheme.error : AppTheme.warning)
                            .withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        afectados == 0
                            ? 'Sin equipos en el ámbito: esta ventana no silenciaría nada.'
                            : 'Se dejarán de enviar avisos de $afectados equipo(s) durante '
                                  '${minsCtrl.text.trim().isEmpty ? '60' : minsCtrl.text.trim()} minutos.',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: afectados == 0
                              ? AppTheme.error
                              : AppTheme.warning,
                        ),
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
              ElevatedButton(
                onPressed: afectados == 0
                    ? null
                    : () async {
                        Navigator.pop(ctx);
                        // En el ámbito de varios equipos el backend casa por
                        // código, hostname, FQDN o IP (target_matches), así que
                        // se mandan los códigos de los elegidos.
                        final codigos = ambito == 'ip_or_hostname_list'
                            ? variosIds
                                  .map((id) => '${hostPorId(id)['code'] ?? ''}')
                                  .where((c) => c.isNotEmpty)
                                  .toList()
                            : <String>[];
                        final res = await widget.api.createMaintenanceWindow({
                          'title': titleCtrl.text.trim(),
                          'reason': reasonCtrl.text.trim(),
                          'scope_type': ambito,
                          'asset_id': ambito == 'single_host' ? equipoId : null,
                          'host_group_id':
                              ambito == 'host_group' ? grupoId : null,
                          'target_matches': codigos,
                          'duration_minutes':
                              int.tryParse(minsCtrl.text.trim()) ?? 60,
                        });
                        _rebuildState(() => _overview = res);
                        _showSnack(
                          'Ventana de mantenimiento activada sobre $afectados equipo(s).',
                        );
                      },
                child: const Text('Activar Mantenimiento'),
              ),
            ],
          );
        },
      ),
    );
  }
}
