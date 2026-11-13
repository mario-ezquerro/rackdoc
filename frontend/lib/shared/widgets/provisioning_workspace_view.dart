import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/theme.dart';
import '../../core/widgets/avisos.dart';

/// Espacio de trabajo unificado de **Aprovisionamiento Ansible, Exporters Nativos y OpenTelemetry**.
///
/// Puede montarse como pestaña completa dentro de **`4. Red y monitorización`** o abrirse
/// como ventana modal precargada desde cualquier máquina o escaneo CIDR en **`6. CMDB`**
/// mediante [ProvisioningWorkspaceView.showQuickProvisionDialog].
class ProvisioningWorkspaceView extends StatefulWidget {
  final RackDocApiClient api;
  final bool canEdit;
  final List<String> initialTargets;
  final VoidCallback? onHostProvisioned;

  const ProvisioningWorkspaceView({
    super.key,
    required this.api,
    this.canEdit = true,
    this.initialTargets = const [],
    this.onHostProvisioned,
  });

  /// Abre un diálogo modal precargado con una o varias IPs/hosts desde CMDB o Red y Host.
  static Future<void> showQuickProvisionDialog(
    BuildContext context, {
    required RackDocApiClient api,
    required List<String> initialTargets,
    bool canEdit = true,
    VoidCallback? onCompleted,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 1180,
          height: 780,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                decoration: const BoxDecoration(
                  color: AppPalette.slate900,
                  border: Border(bottom: BorderSide(color: AppPalette.slate700)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.rocket_launch_rounded,
                      color: AppPalette.sky400,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Verificar Agentes de Serie / Desplegar con Ansible u OpenTelemetry (${initialTargets.length} destino${initialTargets.length == 1 ? '' : 's'})',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Cerrar',
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppPalette.slate300,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ProvisioningWorkspaceView(
                  api: api,
                  canEdit: canEdit,
                  initialTargets: initialTargets,
                  onHostProvisioned: onCompleted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  State<ProvisioningWorkspaceView> createState() =>
      _ProvisioningWorkspaceViewState();
}

class _ProvisioningWorkspaceViewState extends State<ProvisioningWorkspaceView> {
  bool _loading = true;
  String? _error;

  Map<String, dynamic> _overview = {};
  List<Map<String, dynamic>> _precheckResults = [];
  bool _runningPrecheck = false;
  bool _launchingJob = false;

  // Formulario del Lanzador Ansible
  late final TextEditingController _targetsCtrl;
  final TextEditingController _hostGroupsCtrl = TextEditingController();
  final TextEditingController _otelUrlCtrl = TextEditingController();

  String _osFamily = 'linux'; // 'linux' | 'windows'
  String _actionProfile = 'verify_and_propose';
  String _credentialSource = 'vault'; // 'vault' | 'ephemeral'
  int? _selectedCredentialId;
  int? _selectedLocationId;
  bool _useLocalCache = true;

  // Campos de credencial efímera (solo en memoria)
  String _ephType = 'ssh_password'; // 'ssh_key' | 'ssh_password' | 'winrm'
  final TextEditingController _ephUserCtrl = TextEditingController(
    text: 'root',
  );
  final TextEditingController _ephPortCtrl = TextEditingController(text: '22');
  final TextEditingController _ephSecretCtrl = TextEditingController();
  final TextEditingController _ephBecomeCtrl = TextEditingController();
  bool _ephWinrmSsl = false;

  // Seguimiento en vivo del Job seleccionado
  int? _selectedJobId;
  Map<String, dynamic>? _selectedJobDetail;
  Timer? _jobPollTimer;

  // Último one-liner generado con token
  Map<String, dynamic>? _generatedTokenBundle;

  static const Map<String, String> _profileLabels = {
    'verify_and_propose':
        '1. Verificar de Serie + Inventariar CMDB (No instala nada; propone si falta)',
    'ensure_native_exporter':
        '2. Asegurar Exporter Nativo (node_exporter :9100 / windows_exporter :9182 si falta)',
    'ensure_otel_collector':
        '3. Asegurar OpenTelemetry Collector (hostmetrics -> OTLP hacia RackDoc)',
    'ensure_both':
        '4. Completo: Exporter Nativo + OpenTelemetry Collector (respeta lo ya instalado)',
  };

  @override
  void initState() {
    super.initState();
    _targetsCtrl = TextEditingController(
      text: widget.initialTargets.join(', '),
    );
    _loadOverview().then((_) {
      if (widget.initialTargets.isNotEmpty && mounted) {
        _runPrecheck();
      }
    });
  }

  @override
  void dispose() {
    _jobPollTimer?.cancel();
    _targetsCtrl.dispose();
    _hostGroupsCtrl.dispose();
    _otelUrlCtrl.dispose();
    _ephUserCtrl.dispose();
    _ephPortCtrl.dispose();
    _ephSecretCtrl.dispose();
    _ephBecomeCtrl.dispose();
    super.dispose();
  }

  List<String> _parseTargets() {
    return _targetsCtrl.text
        .split(RegExp(r'[\s,;]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
  }

  List<Map<String, dynamic>> get _credentials =>
      ((_overview['credentials'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  List<Map<String, dynamic>> get _jobs =>
      ((_overview['jobs'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  List<Map<String, dynamic>> get _tokens =>
      ((_overview['tokens'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  List<Map<String, dynamic>> get _locations =>
      ((_overview['locations'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  Future<void> _loadOverview() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.api.getProvisioningOverview();
      if (!mounted) return;
      final creds = ((data['credentials'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final jobs = ((data['jobs'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      setState(() {
        _overview = data;
        if (creds.isEmpty) {
          _credentialSource = 'ephemeral';
        } else if (_selectedCredentialId == null ||
            !creds.any((c) => c['id'] == _selectedCredentialId)) {
          _selectedCredentialId = creds.first['id'] as int;
        }
        if (_selectedJobId == null && jobs.isNotEmpty) {
          _selectedJobId = jobs.first['id'] as int;
        }
        _loading = false;
      });

      if (_selectedJobId != null) {
        await _selectAndLoadJob(_selectedJobId!);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _selectAndLoadJob(int jobId) async {
    _jobPollTimer?.cancel();
    setState(() => _selectedJobId = jobId);
    try {
      final detail = await widget.api.getProvisioningJobDetail(jobId);
      if (!mounted) return;
      setState(() => _selectedJobDetail = detail);
      final st = '${detail['status'] ?? ''}';
      if (st == 'queued' || st == 'running') {
        _jobPollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
          try {
            final updated = await widget.api.getProvisioningJobDetail(jobId);
            if (!mounted) return;
            final newSt = '${updated['status'] ?? ''}';
            setState(() => _selectedJobDetail = updated);
            if (newSt != 'queued' && newSt != 'running') {
              _jobPollTimer?.cancel();
              final ov = await widget.api.getProvisioningOverview();
              if (mounted) {
                setState(() => _overview = ov);
              }
              widget.onHostProvisioned?.call();
            }
          } catch (_) {
            _jobPollTimer?.cancel();
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _runPrecheck() async {
    final targets = _parseTargets();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).avisoError(
        'Indica al menos una IP o FQDN antes de lanzar la verificación previa.',
      );
      return;
    }
    setState(() => _runningPrecheck = true);
    try {
      final res = await widget.api.runProvisioningPrecheck(targets);
      if (!mounted) return;
      final list = ((res['results'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      setState(() {
        _precheckResults = list;
        _runningPrecheck = false;
        if (list.isNotEmpty) {
          final detectedOs = '${list.first['detected_os_family'] ?? 'linux'}';
          _syncOsDefaults(detectedOs);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _runningPrecheck = false);
      ScaffoldMessenger.of(
        context,
      ).avisoError('Error en verificación previa: $e');
    }
  }

  void _syncOsDefaults(String newOs) {
    _osFamily = newOs;
    if (newOs == 'windows') {
      _ephType = 'winrm';
      if (_ephUserCtrl.text == 'root') _ephUserCtrl.text = 'Administrator';
      if (_ephPortCtrl.text == '22') _ephPortCtrl.text = '5985';
    } else {
      if (_ephType == 'winrm') _ephType = 'ssh_password';
      if (_ephUserCtrl.text == 'Administrator') _ephUserCtrl.text = 'root';
      if (_ephPortCtrl.text == '5985' || _ephPortCtrl.text == '5986') {
        _ephPortCtrl.text = '22';
      }
    }
    final matchingCred = _credentials
        .where((c) => c['os_family'] == newOs)
        .firstOrNull;
    if (matchingCred != null) {
      _selectedCredentialId = matchingCred['id'] as int;
    }
  }

  Future<void> _launchAnsibleJob({
    List<String>? overrideTargets,
    String? overrideProfile,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final targets = overrideTargets ?? _parseTargets();
    if (targets.isEmpty) {
      messenger.avisoError('Indica al menos una IP o servidor destino.');
      return;
    }

    final payload = <String, dynamic>{
      'os_family': _osFamily,
      'action_profile': overrideProfile ?? _actionProfile,
      'targets': targets,
      'target_location_id': _selectedLocationId,
      'host_groups': _hostGroupsCtrl.text
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      'otel_endpoint_url': _otelUrlCtrl.text.trim(),
      'use_local_cache': _useLocalCache,
    };

    if (_credentialSource == 'vault') {
      if (_selectedCredentialId == null) {
        messenger.avisoError(
          'Selecciona una credencial del baúl o cambia a "Credencial puntual".',
        );
        return;
      }
      payload['credential_id'] = _selectedCredentialId;
    } else {
      if (_ephSecretCtrl.text.trim().isEmpty) {
        messenger.avisoError(
          'Introduce la contraseña o clave privada SSH para la conexión puntual.',
        );
        return;
      }
      payload['ephemeral_credential'] = {
        'credential_type': _osFamily == 'windows' ? 'winrm' : _ephType,
        'username': _ephUserCtrl.text.trim(),
        'port':
            int.tryParse(_ephPortCtrl.text.trim()) ??
            (_osFamily == 'windows' ? 5985 : 22),
        'secret': _ephSecretCtrl.text,
        'become_password': _ephBecomeCtrl.text,
        'winrm_transport': 'ntlm',
        'winrm_use_ssl': _ephWinrmSsl,
        'winrm_validate_certs': false,
      };
    }

    setState(() => _launchingJob = true);
    try {
      final resp = await widget.api.launchProvisioningJob(payload);
      if (!mounted) return;
      final createdJob = Map<String, dynamic>.from(resp['job'] as Map);
      final updatedOv = Map<String, dynamic>.from(resp['overview'] as Map);
      setState(() {
        _overview = updatedOv;
        _launchingJob = false;
      });
      await _selectAndLoadJob(createdJob['id'] as int);
      messenger.aviso('Trabajo ${createdJob['job_code']} lanzado en Ansible.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _launchingJob = false);
      messenger.avisoError('No se pudo lanzar el trabajo Ansible: $e');
    }
  }

  Future<void> _showCreateVaultCredentialDialog() async {
    final nameCtrl = TextEditingController();
    final userCtrl = TextEditingController(text: 'root');
    final portCtrl = TextEditingController(text: '22');
    final secretCtrl = TextEditingController();
    final becomeCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    String credType = 'ssh_key';
    bool winrmSsl = false;
    bool saving = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final isWin = credType == 'winrm';
          return AlertDialog(
            title: const Text(
              'Nueva Credencial en Baúl Cifrado (Fernet)',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
            content: SizedBox(
              width: 540,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText:
                            'Nombre descriptivo (ej. Linux Root CPD / WinRM Dominio)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      key: ValueKey('vault_type_$credType'),
                      initialValue: credType,
                      decoration: const InputDecoration(
                        labelText: 'Tipo de autenticación',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'ssh_key',
                          child: Text('Linux — Clave Privada SSH (ed25519 / RSA)'),
                        ),
                        DropdownMenuItem(
                          value: 'ssh_password',
                          child: Text('Linux — Usuario y Contraseña SSH'),
                        ),
                        DropdownMenuItem(
                          value: 'winrm',
                          child: Text('Windows Server — WinRM (NTLM / HTTPS)'),
                        ),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setModalState(() {
                          credType = v;
                          if (v == 'winrm') {
                            userCtrl.text = 'Administrator';
                            portCtrl.text = winrmSsl ? '5986' : '5985';
                          } else {
                            userCtrl.text = 'root';
                            portCtrl.text = '22';
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: TextField(
                            controller: userCtrl,
                            decoration: InputDecoration(
                              labelText: isWin
                                  ? 'Usuario Windows (ej. CORP\\admin)'
                                  : 'Usuario SSH',
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: portCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Puerto',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: secretCtrl,
                      maxLines: credType == 'ssh_key' ? 5 : 1,
                      obscureText: credType != 'ssh_key',
                      decoration: InputDecoration(
                        labelText: credType == 'ssh_key'
                            ? 'Clave Privada PEM / OpenSSH (se cifra en reposo)'
                            : 'Contraseña (se cifra en reposo, write-only)',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    if (!isWin) ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: becomeCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText:
                              'Contraseña sudo (opcional si el usuario no es root)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ] else ...[
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Usar WinRM sobre HTTPS (:5986)',
                          style: TextStyle(fontSize: 12.5),
                        ),
                        value: winrmSsl,
                        onChanged: (val) => setModalState(() {
                          winrmSsl = val;
                          portCtrl.text = val ? '5986' : '5985';
                        }),
                      ),
                    ],
                    const SizedBox(height: 8),
                    TextField(
                      controller: notesCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Notas opcionales',
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
                onPressed: saving
                    ? null
                    : () async {
                        final messenger = ScaffoldMessenger.of(context);
                        final nav = Navigator.of(ctx);
                        setModalState(() => saving = true);
                        try {
                          final resp = await widget.api
                              .createProvisioningCredential({
                                'name': nameCtrl.text.trim(),
                                'credential_type': credType,
                                'os_family': isWin ? 'windows' : 'linux',
                                'username': userCtrl.text.trim(),
                                'port':
                                    int.tryParse(portCtrl.text.trim()) ??
                                    (isWin ? 5985 : 22),
                                'secret': secretCtrl.text,
                                'become_password': becomeCtrl.text,
                                'winrm_transport': 'ntlm',
                                'winrm_use_ssl': winrmSsl,
                                'notes': notesCtrl.text.trim(),
                              });
                          if (!mounted) return;
                          final newCred = Map<String, dynamic>.from(
                            resp['credential'] as Map,
                          );
                          setState(() {
                            _overview = Map<String, dynamic>.from(
                              resp['overview'] as Map,
                            );
                            _credentialSource = 'vault';
                            _selectedCredentialId = newCred['id'] as int;
                          });
                          nav.pop();
                          messenger.aviso(
                            'Credencial "${newCred['name']}" cifrada y guardada.',
                          );
                        } catch (e) {
                          setModalState(() => saving = false);
                          messenger.avisoError('Error al guardar credencial: $e');
                        }
                      },
                icon: const Icon(Icons.lock_outline_rounded, size: 16),
                label: const Text('Cifrar y Guardar'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showGenerateBootstrapTokenDialog() async {
    final nameCtrl = TextEditingController(
      text: 'Bootstrap Plantilla VM / DMZ',
    );
    String profile = 'ensure_native_exporter';
    int ttlHours = 24;
    bool reusable = true;
    bool creating = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: const Text(
            'Generar Comando Auto-Alta (.sh Linux / .ps1 Windows)',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Ideal para servidores en DMZ sin SSH/WinRM entrante o plantillas Proxmox / VMware / cloud-init. El script comprueba primero si node_exporter o windows_exporter ya viene instalado de serie antes de instalar nada.',
                  style: TextStyle(fontSize: 12, color: AppPalette.slate600),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Etiqueta del Token',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  key: ValueKey('tok_prof_$profile'),
                  initialValue: profile,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Acción del script en la máquina',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: _profileLabels.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(
                            e.value,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setModalState(() => profile = v);
                  },
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  key: ValueKey('tok_ttl_$ttlHours'),
                  initialValue: ttlHours,
                  decoration: const InputDecoration(
                    labelText: 'Validez temporal del token',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('1 hora')),
                    DropdownMenuItem(value: 24, child: Text('24 horas')),
                    DropdownMenuItem(value: 168, child: Text('7 días')),
                    DropdownMenuItem(
                      value: 0,
                      child: Text('Sin caducidad (plantilla permanente)'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setModalState(() => ttlHours = v);
                  },
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Token reutilizable para múltiples máquinas',
                    style: TextStyle(fontSize: 12.5),
                  ),
                  value: reusable,
                  onChanged: (v) => setModalState(() => reusable = v),
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
              onPressed: creating
                  ? null
                  : () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final nav = Navigator.of(ctx);
                      setModalState(() => creating = true);
                      try {
                        final res = await widget.api.createProvisioningToken({
                          'name': nameCtrl.text.trim(),
                          'action_profile': profile,
                          'target_location_id': _selectedLocationId,
                          'reusable': reusable,
                          'ttl_hours': ttlHours,
                        });
                        if (!mounted) return;
                        setState(() {
                          _overview = Map<String, dynamic>.from(
                            res['overview'] as Map,
                          );
                          _generatedTokenBundle = res;
                        });
                        nav.pop();
                        messenger.aviso(
                          'Token generado. Copia abajo el comando Linux (.sh) o Windows (.ps1).',
                        );
                      } catch (e) {
                        setModalState(() => creating = false);
                        messenger.avisoError('Error al generar token: $e');
                      }
                    },
              icon: const Icon(Icons.key_rounded, size: 16),
              label: const Text('Generar One-Liners'),
            ),
          ],
        ),
      ),
    );
  }

  void _copyText(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).aviso('$label copiado al portapapeles.');
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
            Text(
              'Error cargando motor de aprovisionamiento: $_error',
              style: const TextStyle(color: AppPalette.red600),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _loadOverview,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    return Container(
      color: AppPalette.slate50,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildInfoBanner(),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth >= 1040) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 5, child: _buildLauncherCard()),
                      const SizedBox(width: 14),
                      Expanded(flex: 6, child: _buildJobsAndConsoleCard()),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildLauncherCard(),
                    const SizedBox(height: 14),
                    _buildJobsAndConsoleCard(),
                  ],
                );
              },
            ),
            const SizedBox(height: 14),
            _buildVaultAndBootstrapRow(),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoBanner() {
    final engine = (_overview['engine'] as Map?) ?? const {};
    final ansibleOk = engine['ansible_available'] == true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.slate200),
      ),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                ansibleOk
                    ? Icons.verified_rounded
                    : Icons.warning_amber_rounded,
                color: ansibleOk ? AppPalette.green600 : AppPalette.amber600,
                size: 20,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  ansibleOk
                      ? 'Motor Ansible activo en rackdoc-backend • Verifica primero si node_exporter / windows_exporter ya viene de serie antes de instalar y soporta OpenTelemetry (OTLP).'
                      : 'ansible-playbook no detectado en este entorno local (estará activo dentro del contenedor rackdoc-backend).',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppPalette.slate800,
                  ),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _showCreateVaultCredentialDialog,
                icon: const Icon(Icons.enhanced_encryption_rounded, size: 15),
                label: Text(
                  'Baúl SSH/WinRM (${_credentials.length})',
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _showGenerateBootstrapTokenDialog,
                icon: const Icon(Icons.terminal_rounded, size: 15),
                label: const Text(
                  'Generar Script (.sh / .ps1)',
                  style: TextStyle(fontSize: 11.5),
                ),
              ),
              IconButton(
                tooltip: 'Refrescar estado',
                onPressed: _loadOverview,
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLauncherCard() {
    final matchingCreds = _credentials
        .where((c) => c['os_family'] == _osFamily)
        .toList();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.slate200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(
                Icons.fact_check_outlined,
                color: AppPalette.blue600,
                size: 19,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '1. Verificar Agentes de Serie y Desplegar con Ansible',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: AppPalette.slate900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _targetsCtrl,
            maxLines: 2,
            decoration: InputDecoration(
              labelText:
                  'IPs o FQDNs objetivo (separados por coma o salto de línea)',
              hintText: 'Ej: 10.200.0.11, 10.200.0.12, srv-erp-01.corp.local',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilledButton.tonalIcon(
                  onPressed: _runningPrecheck ? null : _runPrecheck,
                  icon: _runningPrecheck
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.radar_rounded, size: 16),
                  label: const Text(
                    'Pre-Check Serie',
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ),
          ),
          if (_precheckResults.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppPalette.slate50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppPalette.slate200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Resultado de Detección Previa (sin tocar las máquinas):',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: AppPalette.slate800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final r in _precheckResults)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            r['native_exporter_active'] == true
                                ? Icons.check_circle_rounded
                                : Icons.info_outline_rounded,
                            size: 16,
                            color: r['native_exporter_active'] == true
                                ? AppPalette.green600
                                : AppPalette.amber600,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${r['target']} [${(r['detected_os_family'] ?? 'linux').toString().toUpperCase()}] — ${r['summary']}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: AppPalette.slate700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey('os_fam_$_osFamily'),
                  initialValue: _osFamily,
                  decoration: const InputDecoration(
                    labelText: 'Sistema Operativo',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'linux',
                      child: Text('Linux (SSH :22)'),
                    ),
                    DropdownMenuItem(
                      value: 'windows',
                      child: Text('Windows Server (WinRM :5985/:5986)'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _syncOsDefaults(v));
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<int?>(
                  key: ValueKey('loc_sel_$_selectedLocationId'),
                  initialValue: _selectedLocationId,
                  decoration: const InputDecoration(
                    labelText: 'Sede CMDB (opcional)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('Sin sede fija'),
                    ),
                    for (final loc in _locations)
                      DropdownMenuItem<int?>(
                        value: loc['id'] as int,
                        child: Text('${loc['code']} — ${loc['name']}'),
                      ),
                  ],
                  onChanged: (v) => setState(() => _selectedLocationId = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            key: ValueKey('act_prof_$_actionProfile'),
            initialValue: _actionProfile,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Acción / Perfil de Agentes',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: _profileLabels.entries
                .map(
                  (e) => DropdownMenuItem<String>(
                    value: e.key,
                    child: Text(
                      e.value,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) {
              if (v != null) setState(() => _actionProfile = v);
            },
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(
                value: 'vault',
                icon: const Icon(Icons.lock_rounded, size: 15),
                label: Text('Baúl Cifrado (${matchingCreds.length})'),
              ),
              const ButtonSegment(
                value: 'ephemeral',
                icon: Icon(Icons.bolt_rounded, size: 15),
                label: Text('Credencial Puntual (No guardar)'),
              ),
            ],
            selected: {_credentialSource},
            onSelectionChanged: (s) =>
                setState(() => _credentialSource = s.first),
          ),
          const SizedBox(height: 10),
          if (_credentialSource == 'vault')
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int?>(
                    key: ValueKey(
                      'cred_sel_${_osFamily}_$_selectedCredentialId',
                    ),
                    initialValue: matchingCreds.any(
                      (c) => c['id'] == _selectedCredentialId,
                    )
                        ? _selectedCredentialId
                        : (matchingCreds.isNotEmpty
                              ? matchingCreds.first['id'] as int
                              : null),
                    decoration: const InputDecoration(
                      labelText: 'Credencial almacenada',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final c in matchingCreds)
                        DropdownMenuItem<int?>(
                          value: c['id'] as int,
                          child: Text(
                            '${c['name']} (${c['username']}@:${c['port']})',
                          ),
                        ),
                    ],
                    onChanged: (v) =>
                        setState(() => _selectedCredentialId = v),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Añadir credencial al baúl',
                  onPressed: _showCreateVaultCredentialDialog,
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            )
          else ...[
            if (_osFamily == 'linux') ...[
              DropdownButtonFormField<String>(
                key: ValueKey('eph_type_$_ephType'),
                initialValue: _ephType == 'winrm' ? 'ssh_password' : _ephType,
                decoration: const InputDecoration(
                  labelText: 'Método SSH puntual',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'ssh_password',
                    child: Text('Contraseña SSH'),
                  ),
                  DropdownMenuItem(
                    value: 'ssh_key',
                    child: Text('Clave Privada SSH (PEM / OpenSSH)'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _ephType = v);
                },
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _ephUserCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Usuario',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _ephPortCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Puerto',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ephSecretCtrl,
              maxLines: (_osFamily == 'linux' && _ephType == 'ssh_key') ? 3 : 1,
              obscureText: !(_osFamily == 'linux' && _ephType == 'ssh_key'),
              decoration: InputDecoration(
                labelText: (_osFamily == 'linux' && _ephType == 'ssh_key')
                    ? 'Clave privada SSH (solo en memoria RAM durante el job)'
                    : 'Contraseña (solo en memoria RAM durante el job)',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_osFamily == 'linux') ...[
              const SizedBox(height: 8),
              TextField(
                controller: _ephBecomeCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Contraseña sudo (opcional)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ] else
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'WinRM HTTPS (:5986)',
                  style: TextStyle(fontSize: 12),
                ),
                value: _ephWinrmSsl,
                onChanged: (v) => setState(() {
                  _ephWinrmSsl = v;
                  _ephPortCtrl.text = v ? '5986' : '5985';
                }),
              ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _hostGroupsCtrl,
                  decoration: const InputDecoration(
                    labelText: 'HostGroups (opcional, ej. LINUX-PROD, ERP)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                selected: _useLocalCache,
                label: const Text(
                  'Usar caché ./data/agent_cache',
                  style: TextStyle(fontSize: 11.5),
                ),
                onSelected: (v) => setState(() => _useLocalCache = v),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _launchingJob ? null : () => _launchAnsibleJob(),
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.blue600,
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),
            icon: _launchingJob
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.play_arrow_rounded, size: 19),
            label: Text(
              _actionProfile == 'verify_and_propose'
                  ? 'Analizar Máquina, Verificar Agentes de Serie y Registrar en CMDB'
                  : 'Ejecutar Playbook Ansible (Respeta Agentes ya Instalados)',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJobsAndConsoleCard() {
    final job = _selectedJobDetail;
    final hostResults = (job?['host_results'] is Map)
        ? Map<String, dynamic>.from(job!['host_results'] as Map)
        : <String, dynamic>{};

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.slate200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.terminal_rounded,
                color: AppPalette.slate900,
                size: 19,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '2. Consola Ansible en Vivo y Propuestas por Servidor',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: AppPalette.slate900,
                  ),
                ),
              ),
              if (_jobs.isNotEmpty)
                SizedBox(
                  width: 260,
                  child: DropdownButtonFormField<int>(
                    key: ValueKey('job_sel_$_selectedJobId'),
                    initialValue: _jobs.any((j) => j['id'] == _selectedJobId)
                        ? _selectedJobId
                        : (_jobs.first['id'] as int),
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Historial de Jobs',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final j in _jobs)
                        DropdownMenuItem<int>(
                          value: j['id'] as int,
                          child: Text(
                            '[${(j['status'] ?? '').toString().toUpperCase()}] ${j['job_code']} — ${j['title']}',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11.5),
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) _selectAndLoadJob(v);
                    },
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (hostResults.isNotEmpty) ...[
            for (final entry in hostResults.entries)
              _buildHostResultProposalTile(
                entry.key,
                Map<String, dynamic>.from(entry.value as Map),
              ),
            const SizedBox(height: 10),
          ],
          Container(
            height: 310,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppPalette.slate900,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              child: Text(
                (job?['console_log'] ??
                        'Aún no se ha ejecutado ningún trabajo Ansible. Lanza primero "Analizar Máquina y Verificar de Serie" para inspeccionar tus servidores Linux o Windows.')
                    .toString(),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11.5,
                  height: 1.4,
                  color: AppPalette.sky100,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHostResultProposalTile(
    String target,
    Map<String, dynamic> info,
  ) {
    final ok = info['state'] == 'ok';
    final proposal = '${info['proposal'] ?? ''}';
    final needsInstall =
        proposal == 'propose_install_exporter' ||
        proposal == 'propose_start_exporter';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: !ok
            ? AppPalette.red50
            : (needsInstall ? AppPalette.amber50 : AppPalette.green50),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: !ok
              ? AppPalette.red300
              : (needsInstall ? AppPalette.amber300 : AppPalette.green300),
        ),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                ok
                    ? '$target → [${info['asset_code']}] ${info['os_or_firmware']} (${info['cpu_cores']} vCPU / ${info['ram_gb']} GB RAM)'
                    : '$target → ${info['error'] ?? 'Fallo de conexión'}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppPalette.slate900,
                ),
              ),
              if (ok)
                Text(
                  '${info['proposal_label']}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppPalette.slate700,
                  ),
                ),
            ],
          ),
          if (ok && needsInstall)
            Wrap(
              spacing: 6,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _launchingJob
                      ? null
                      : () => _launchAnsibleJob(
                          overrideTargets: [target],
                          overrideProfile: 'ensure_native_exporter',
                        ),
                  icon: const Icon(Icons.download_for_offline_rounded, size: 15),
                  label: Text(
                    proposal == 'propose_start_exporter'
                        ? 'Arrancar Exporter'
                        : 'Instalar Exporter Nativo',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _launchingJob
                      ? null
                      : () => _launchAnsibleJob(
                          overrideTargets: [target],
                          overrideProfile: 'ensure_both',
                        ),
                  icon: const Icon(Icons.hub_rounded, size: 14),
                  label: const Text(
                    '+ OpenTelemetry',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildVaultAndBootstrapRow() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.slate200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '3. Auto-Alta sin SSH/WinRM (One-Liners .sh / .ps1 con Token) y Baúl de Credenciales',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: AppPalette.slate900,
            ),
          ),
          if (_generatedTokenBundle != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppPalette.sky50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppPalette.sky200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Comandos listos para pegar (el token completo solo se muestra ahora):',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.sky900,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _copyText(
                          '${_generatedTokenBundle!['linux_oneliner']}',
                          'Comando Linux (.sh)',
                        ),
                        icon: const Icon(Icons.copy_rounded, size: 15),
                        label: const Text('Copiar Linux (.sh)'),
                      ),
                      TextButton.icon(
                        onPressed: () => _copyText(
                          '${_generatedTokenBundle!['windows_oneliner']}',
                          'Comando Windows (.ps1)',
                        ),
                        icon: const Icon(Icons.copy_rounded, size: 15),
                        label: const Text('Copiar Windows (.ps1)'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Linux:   ${_generatedTokenBundle!['linux_oneliner']}\nWindows: ${_generatedTokenBundle!['windows_oneliner']}',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      color: AppPalette.slate900,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              for (final c in _credentials)
                Chip(
                  avatar: const Icon(Icons.vpn_key_rounded, size: 15),
                  label: Text(
                    '${c['name']} • ${c['username']}@:${c['port']} (${c['key_fingerprint']})',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  onDeleted: widget.canEdit
                      ? () async {
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            final resp = await widget.api
                                .deleteProvisioningCredential(c['id'] as int);
                            if (mounted) {
                              setState(
                                () => _overview = Map<String, dynamic>.from(
                                  resp['overview'] as Map,
                                ),
                              );
                            }
                          } catch (e) {
                            messenger.avisoError('No se pudo eliminar: $e');
                          }
                        }
                      : null,
                ),
              for (final t in _tokens.where((x) => x['revoked'] != true))
                Chip(
                  backgroundColor: AppPalette.slate100,
                  avatar: const Icon(Icons.qr_code_2_rounded, size: 15),
                  label: Text(
                    'Token ${t['name']} (${t['token_prefix']}… • usos: ${t['uses_count']})',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  onDeleted: widget.canEdit
                      ? () async {
                          final resp = await widget.api.revokeProvisioningToken(
                            t['id'] as int,
                          );
                          if (mounted) {
                            setState(
                              () => _overview = Map<String, dynamic>.from(
                                resp['overview'] as Map,
                              ),
                            );
                          }
                        }
                      : null,
                ),
            ],
          ),
        ],
      ),
    );
  }
}
