import 'package:flutter/material.dart';
import '../../core/api_client.dart';
import '../../core/theme.dart';
import '../../core/widgets/avisos.dart';
import '../cmdb/api_onboarding_dialog.dart';

class CertScopeView extends StatefulWidget {
  final RackDocApiClient api;
  final bool canEdit;
  final bool canOperate;
  final void Function(int rackId, int? deviceId)? onNavigateToRack;
  final void Function(int floorId, int? floorDeviceId)? onNavigateToFloor;
  final void Function(int stackId, int? nodeId)? onNavigateToStack;
  final VoidCallback? onNavigateToCmdb;

  const CertScopeView({
    super.key,
    required this.api,
    required this.canEdit,
    required this.canOperate,
    this.onNavigateToRack,
    this.onNavigateToFloor,
    this.onNavigateToStack,
    this.onNavigateToCmdb,
  });

  @override
  State<CertScopeView> createState() => _CertScopeViewState();
}

class _CertScopeViewState extends State<CertScopeView> {
  bool _loading = true;
  bool _verifyingAll = false;
  String? _error;
  Map<String, dynamic> _overview = {};

  final TextEditingController _searchCtrl = TextEditingController();
  String _statusFilter = 'all'; // all | valid | expiring_soon | critical | expired | unreachable
  String _modeFilter = 'all'; // all | https_live | manual
  String _renewalFilter = 'all'; // all | manual | auto_acme
  String _sortColumn = 'days_remaining'; // status | days_remaining | code | name | target_host | common_name | issuer_cn | renewal_type
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    _loadOverview();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
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
      final data = await widget.api.getCertScopeOverview();
      if (!mounted) return;
      setState(() {
        _overview = data;
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

  Future<void> _verifyAllNow() async {
    setState(() => _verifyingAll = true);
    try {
      final data = await widget.api.verifyAllCertificates();
      if (!mounted) return;
      setState(() {
        _overview = data;
        _verifyingAll = false;
      });
      final batch = data['last_batch_result'] as Map?;
      final probed = batch?['probed_count'] ?? 0;
      final alerts = batch?['alerts_triggered'] ?? 0;
      mostrarAviso(
        context,
        'Verificación TLS completada ($probed endpoints HTTPS sondeados, $alerts avisos automáticos emitidos).',
        tono: TonoAviso.exito,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _verifyingAll = false);
      mostrarAviso(
        context,
        'Error al verificar certificados: $e',
        tono: TonoAviso.error,
      );
    }
  }

  Future<void> _verifySingleCert(Map<String, dynamic> cert) async {
    final id = cert['id'] as int?;
    if (id == null) return;
    mostrarAviso(
      context,
      'Verificando certificado ${cert['code']} (${cert['target_host']}:${cert['port']})...',
      tono: TonoAviso.info,
    );
    try {
      final data = await widget.api.verifyCertificate(id);
      if (!mounted) return;
      setState(() => _overview = data);
      mostrarAviso(
        context,
        'Certificado ${cert['code']} actualizado.',
        tono: TonoAviso.exito,
      );
    } catch (e) {
      if (!mounted) return;
      mostrarAviso(
        context,
        'Error verificando certificado: $e',
        tono: TonoAviso.error,
      );
    }
  }

  Future<void> _notifyCertContacts(Map<String, dynamic> cert) async {
    final id = cert['id'] as int?;
    if (id == null) return;
    final noteCtrl = TextEditingController();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.notifications_active_rounded, color: AppPalette.amber600),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Enviar Aviso de Caducidad — ${cert['code']}',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Se enviará una notificación detallada sobre el certificado "${cert['name']}" (${cert['common_name'] ?? cert['target_host']}) a las personas y grupos asignados.',
                style: const TextStyle(fontSize: 12.5, color: AppPalette.slate700),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Mensaje adicional del operador (opcional)',
                  hintText: 'Ej: Por favor renovar el certificado antes del viernes en ventana de mantenimiento.',
                  border: OutlineInputBorder(),
                  isDense: true,
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
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.send_rounded, size: 16),
            label: const Text('Enviar Aviso Ahora'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final res = await widget.api.notifyCertificateContacts(id, {
        'custom_message': noteCtrl.text.trim(),
        'force_send': true,
      });
      if (!mounted) return;
      await _loadOverview(silent: true);
      mostrarAviso(
        context,
        'Aviso enviado y registrado para: ${res['recipients_summary'] ?? 'Destinatarios asignados'}.',
        tono: TonoAviso.exito,
      );
    } catch (e) {
      if (!mounted) return;
      mostrarAviso(
        context,
        'No se pudo enviar el aviso: $e',
        tono: TonoAviso.error,
      );
    }
  }

  Future<void> _deleteCert(Map<String, dynamic> cert) async {
    final id = cert['id'] as int?;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar Certificado de CertScope'),
        content: Text(
          '¿Seguro que deseas eliminar el certificado "${cert['code']} — ${cert['name']}" de CertScope?\n(El dispositivo en CMDB / Rack / Planta no se borrará).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppPalette.red600),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final data = await widget.api.deleteCertificate(id);
      if (!mounted) return;
      setState(() => _overview = data);
      mostrarAviso(context, 'Certificado eliminado.', tono: TonoAviso.exito);
    } catch (e) {
      if (!mounted) return;
      mostrarAviso(context, 'Error al eliminar: $e', tono: TonoAviso.error);
    }
  }

  void _toggleSort(String column) {
    setState(() {
      if (_sortColumn == column) {
        _sortAsc = !_sortAsc;
      } else {
        _sortColumn = column;
        _sortAsc = true;
      }
    });
  }

  List<Map<String, dynamic>> _filteredAndSortedCertificates() {
    final raw = (_overview['certificates'] as List?) ?? [];
    final q = _searchCtrl.text.trim().toLowerCase();

    final filtered = raw.map((e) => Map<String, dynamic>.from(e as Map)).where((c) {
      final st = (c['status'] ?? '').toString();
      final mode = (c['check_mode'] ?? 'https_live').toString();
      final ren = (c['renewal_type'] ?? 'manual').toString();

      if (_statusFilter != 'all') {
        if (_statusFilter == 'critical_or_expired') {
          if (st != 'critical' && st != 'expired') return false;
        } else if (st != _statusFilter) {
          return false;
        }
      }
      if (_modeFilter != 'all' && mode != _modeFilter) return false;
      if (_renewalFilter != 'all' && ren != _renewalFilter) return false;

      if (q.isNotEmpty) {
        final rackInfo = c['rack_info'] as Map?;
        final floorInfo = c['floor_info'] as Map?;
        final assetInfo = c['asset_info'] as Map?;
        final locInfo = c['location_info'] as Map?;
        final groups = (c['assigned_groups'] as List?) ?? [];
        final contacts = (c['assigned_contacts'] as List?) ?? [];
        final sans = (c['san_domains'] as List?) ?? [];

        final haystack = [
          c['code'],
          c['name'],
          c['target_host'],
          c['port'],
          c['common_name'],
          c['issuer_cn'],
          c['issuer_org'],
          c['owner_team'],
          c['responsible_person'],
          c['notify_emails'],
          c['renewal_notes'],
          c['notes'],
          rackInfo?['rack_code'],
          rackInfo?['rack_device_code'],
          floorInfo?['floor_name'],
          floorInfo?['floor_device_code'],
          assetInfo?['code'],
          assetInfo?['name'],
          locInfo?['label'],
          c['primary_stack_label'],
          ...sans,
          ...groups.map((g) => (g as Map)['name']),
          ...contacts.map((p) => (p as Map)['full_name']),
        ].where((x) => x != null).join(' ').toLowerCase();

        if (!haystack.contains(q)) return false;
      }
      return true;
    }).toList();

    filtered.sort((a, b) {
      int cmp = 0;
      switch (_sortColumn) {
        case 'days_remaining':
          final da = (a['days_remaining'] as num?)?.toInt() ?? 999999;
          final db = (b['days_remaining'] as num?)?.toInt() ?? 999999;
          cmp = da.compareTo(db);
          break;
        case 'status':
          cmp = (a['status'] ?? '').toString().compareTo((b['status'] ?? '').toString());
          break;
        case 'code':
          cmp = (a['code'] ?? '').toString().compareTo((b['code'] ?? '').toString());
          break;
        case 'name':
          cmp = (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString());
          break;
        case 'target_host':
          cmp = (a['target_host'] ?? '').toString().compareTo((b['target_host'] ?? '').toString());
          break;
        case 'common_name':
          cmp = (a['common_name'] ?? '').toString().compareTo((b['common_name'] ?? '').toString());
          break;
        case 'issuer_cn':
          cmp = (a['issuer_cn'] ?? '').toString().compareTo((b['issuer_cn'] ?? '').toString());
          break;
        case 'renewal_type':
          cmp = (a['renewal_type'] ?? '').toString().compareTo((b['renewal_type'] ?? '').toString());
          break;
        default:
          cmp = 0;
      }
      return _sortAsc ? cmp : -cmp;
    });

    return filtered;
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
            const Icon(Icons.error_outline, size: 42, color: AppPalette.red600),
            const SizedBox(height: 8),
            Text('Error cargando CertScope: $_error'),
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

    final kpi = Map<String, dynamic>.from((_overview['kpi'] as Map?) ?? {});
    final certs = _filteredAndSortedCertificates();

    return Container(
      color: AppPalette.slate50,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTopHeader(),
          const SizedBox(height: 12),
          _buildKpiRow(kpi),
          const SizedBox(height: 12),
          _buildFilterToolbar(certs.length),
          const SizedBox(height: 10),
          Expanded(
            child: _buildExcelTable(certs),
          ),
        ],
      ),
    );
  }

  Widget _buildTopHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppPalette.slate200),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppPalette.blue900,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.verified_user_rounded,
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
                  '7. CertScope — Auditoría, Caducidad y Alertas de Certificados SSL/TLS',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: AppPalette.slate900,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Análisis automático HTTPS/TLS en vivo y registro manual de certificados X.509 con avisos a personas/grupos y enlaces directos a Rack, Planta, CMDB y Stack.',
                  style: TextStyle(fontSize: 11.5, color: AppPalette.slate600),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppPalette.blue900,
              side: const BorderSide(color: AppPalette.blue300),
            ),
            onPressed: () => showApiOnboardingGuideDialog(context, api: widget.api),
            icon: const Icon(Icons.terminal_rounded, size: 16),
            label: const Text(
              'Alta vía API (cURL / Ansible / Puppet)',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          if (widget.canOperate)
            OutlinedButton.icon(
              onPressed: _verifyingAll ? null : _verifyAllNow,
              icon: _verifyingAll
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync_rounded, size: 16),
              label: Text(
                _verifyingAll
                    ? 'Auto-Analizando Equipos HTTPS...'
                    : 'Auto-Analizar Equipos HTTPS (CMDB / Rack / Planta)',
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
              ),
            ),
          const SizedBox(width: 8),
          if (widget.canEdit)
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppPalette.blue900,
                foregroundColor: Colors.white,
              ),
              onPressed: () => _showUpsertCertificateDialog(),
              icon: const Icon(Icons.add_moderator_rounded, size: 16),
              label: const Text(
                '+ Vincular Equipo / Añadir Certificado',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildKpiRow(Map<String, dynamic> kpi) {
    final total = (kpi['total'] ?? 0) as int;
    final valid = (kpi['valid'] ?? 0) as int;
    final expiring = (kpi['expiring_soon'] ?? 0) as int;
    final critical = ((kpi['critical'] ?? 0) as int) + ((kpi['expired'] ?? 0) as int);
    final manualRenewal = (kpi['manual_renewal'] ?? 0) as int;
    final unreachable = (kpi['unreachable'] ?? 0) as int;

    return Row(
      children: [
        Expanded(
          child: _buildKpiCard(
            title: 'Total Certificados',
            value: '$total',
            subtitle: '${kpi['auto_mode'] ?? 0} Auto HTTPS · ${kpi['manual_mode'] ?? 0} Manuales',
            icon: Icons.shield_outlined,
            color: AppPalette.blue900,
            bgColor: AppPalette.blue50,
            selected: _statusFilter == 'all',
            onTap: () => setState(() => _statusFilter = 'all'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildKpiCard(
            title: 'Válidos (>30 días)',
            value: '$valid',
            subtitle: 'Certificados en vigor',
            icon: Icons.check_circle_outline_rounded,
            color: AppPalette.green700,
            bgColor: AppPalette.green50,
            selected: _statusFilter == 'valid',
            onTap: () => setState(() => _statusFilter = _statusFilter == 'valid' ? 'all' : 'valid'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildKpiCard(
            title: 'Próximos (<=30 días)',
            value: '$expiring',
            subtitle: 'Programar renovación',
            icon: Icons.warning_amber_rounded,
            color: AppPalette.amber700,
            bgColor: AppPalette.amber50,
            selected: _statusFilter == 'expiring_soon',
            onTap: () => setState(
              () => _statusFilter = _statusFilter == 'expiring_soon' ? 'all' : 'expiring_soon',
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildKpiCard(
            title: 'Críticos (<=7d) / Caducados',
            value: '$critical',
            subtitle: '${kpi['expired'] ?? 0} vencidos · ${kpi['critical'] ?? 0} <=7d',
            icon: Icons.gpp_bad_rounded,
            color: AppPalette.red700,
            bgColor: AppPalette.red50,
            selected: _statusFilter == 'critical_or_expired',
            onTap: () => setState(
              () => _statusFilter =
                  _statusFilter == 'critical_or_expired' ? 'all' : 'critical_or_expired',
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildKpiCard(
            title: 'Renovación Manual / Avisos',
            value: '$manualRenewal',
            subtitle: '$unreachable sin respuesta TLS',
            icon: Icons.notifications_active_outlined,
            color: AppPalette.violet600,
            bgColor: AppPalette.indigo100,
            selected: _renewalFilter == 'manual',
            onTap: () => setState(
              () => _renewalFilter = _renewalFilter == 'manual' ? 'all' : 'manual',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildKpiCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    required Color bgColor,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? bgColor : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? color : AppPalette.slate200,
            width: selected ? 1.8 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppPalette.slate600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: color,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 10.5, color: AppPalette.slate500),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterToolbar(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.slate200),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: _searchCtrl,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
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
                  hintText:
                      'Buscar por Código, CN, Emisor CA, IP/Dominio, SAN, Rack, Planta, Máquina CMDB o Grupo de aviso...',
                  hintStyle: const TextStyle(fontSize: 12),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppPalette.slate300),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _buildDropdownFilter(
            label: 'Estado',
            value: _statusFilter,
            items: const {
              'all': 'Estado: Todos',
              'valid': '🟢 Válidos (>30d)',
              'expiring_soon': '🟠 Próximos (<=30d)',
              'critical_or_expired': '🔴 Críticos (<=7d) / Vencidos',
              'expired': '🔴 Solo Caducados',
              'unreachable': '⚪ Sin acceso TLS / Manual',
            },
            onChanged: (v) => setState(() => _statusFilter = v),
          ),
          const SizedBox(width: 8),
          _buildDropdownFilter(
            label: 'Modo',
            value: _modeFilter,
            items: const {
              'all': 'Modo: Todos',
              'https_live': '🌐 Auto HTTPS/TLS',
              'manual': '✍️ Manual / Offline',
            },
            onChanged: (v) => setState(() => _modeFilter = v),
          ),
          const SizedBox(width: 8),
          _buildDropdownFilter(
            label: 'Renovación',
            value: _renewalFilter,
            items: const {
              'all': 'Renovación: Todas',
              'manual': '🔔 Renovación Manual',
              'auto_acme': '🤖 Automática ACME',
            },
            onChanged: (v) => setState(() => _renewalFilter = v),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppPalette.slate100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count certificados',
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: AppPalette.slate700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdownFilter({
    required String label,
    required String value,
    required Map<String, String> items,
    required ValueChanged<String> onChanged,
  }) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppPalette.slate50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppPalette.slate300),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: items.containsKey(value) ? value : 'all',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppPalette.slate800,
          ),
          items: items.entries
              .map(
                (e) => DropdownMenuItem<String>(
                  value: e.key,
                  child: Text(e.value),
                ),
              )
              .toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }

  Widget _buildExcelTable(List<Map<String, dynamic>> certs) {
    if (certs.isEmpty) {
      return Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppPalette.slate200),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.verified_user_outlined,
                  size: 48,
                  color: AppPalette.slate400,
                ),
                const SizedBox(height: 12),
                const Text(
                  'No hay certificados SSL/TLS registrados con los filtros actuales',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: AppPalette.slate800,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Puedes añadir un certificado conectando en vivo por HTTPS a cualquier servidor/router/impresora o registrarlo manualmente con su fecha de caducidad.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: AppPalette.slate600),
                ),
                const SizedBox(height: 16),
                if (widget.canEdit)
                  FilledButton.icon(
                    onPressed: () => _showUpsertCertificateDialog(),
                    icon: const Icon(Icons.add_moderator_rounded, size: 16),
                    label: const Text('+ Añadir Primer Certificado SSL/TLS'),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppPalette.slate200),
      ),
      child: Column(
        children: [
          // Cabecera estilo hoja Excel
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: const BoxDecoration(
              color: AppPalette.slate100,
              borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
              border: Border(bottom: BorderSide(color: AppPalette.slate300)),
            ),
            child: Row(
              children: [
                _buildSortHeader('Estado', 'status', flex: 2),
                _buildSortHeader('Caducidad / Días', 'days_remaining', flex: 2),
                _buildSortHeader('Código / Certificado', 'name', flex: 3),
                _buildSortHeader('Host : Puerto (Modo)', 'target_host', flex: 2),
                _buildSortHeader('Common Name (CN) & CA', 'common_name', flex: 3),
                const Expanded(
                  flex: 4,
                  child: Text(
                    'Ubicación & Enlaces (Rack / Planta / CMDB / Stack)',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: AppPalette.slate700,
                    ),
                  ),
                ),
                _buildSortHeader('Renovación & Avisos', 'renewal_type', flex: 3),
                const SizedBox(
                  width: 136,
                  child: Text(
                    'Acciones',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: AppPalette.slate700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: certs.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: AppPalette.slate200),
              itemBuilder: (ctx, idx) => _buildCertRow(certs[idx]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSortHeader(String label, String colKey, {int flex = 2}) {
    final active = _sortColumn == colKey;
    return Expanded(
      flex: flex,
      child: InkWell(
        onTap: () => _toggleSort(colKey),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: active ? AppPalette.blue900 : AppPalette.slate700,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 3),
            Icon(
              active
                  ? (_sortAsc ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded)
                  : Icons.unfold_more_rounded,
              size: 13,
              color: active ? AppPalette.blue900 : AppPalette.slate400,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCertRow(Map<String, dynamic> cert) {
    final status = (cert['status'] ?? 'unknown').toString();
    final days = cert['days_remaining'] as int?;
    final validUntilRaw = (cert['valid_until'] ?? '').toString();
    final validUntilDate = validUntilRaw.isNotEmpty ? validUntilRaw.split('T').first : 'Sin fecha';
    final checkMode = (cert['check_mode'] ?? 'https_live').toString();
    final renewalType = (cert['renewal_type'] ?? 'manual').toString();
    final isSelfSigned = cert['is_self_signed'] == true;
    final lastError = (cert['last_probe_error'] ?? '').toString();

    final rackInfo = cert['rack_info'] as Map?;
    final floorInfo = cert['floor_info'] as Map?;
    final assetInfo = cert['asset_info'] as Map?;
    final locInfo = cert['location_info'] as Map?;
    final stackId = cert['primary_stack_diagram_id'] as int?;
    final stackLabel = (cert['primary_stack_label'] ?? '').toString();

    final groups = (cert['assigned_groups'] as List?) ?? [];
    final contacts = (cert['assigned_contacts'] as List?) ?? [];
    final notifyEmails = (cert['notify_emails'] ?? '').toString();

    Color badgeBg = AppPalette.slate100;
    Color badgeFg = AppPalette.slate700;
    String badgeText = 'SIN DATOS';
    IconData badgeIcon = Icons.help_outline_rounded;

    if (status == 'valid') {
      badgeBg = AppPalette.green100;
      badgeFg = AppPalette.green700;
      badgeText = 'VÁLIDO';
      badgeIcon = Icons.verified_rounded;
    } else if (status == 'expiring_soon') {
      badgeBg = AppPalette.amber100;
      badgeFg = AppPalette.amber800;
      badgeText = 'PRÓXIMO <=30D';
      badgeIcon = Icons.warning_amber_rounded;
    } else if (status == 'critical') {
      badgeBg = AppPalette.red200;
      badgeFg = AppPalette.red800;
      badgeText = 'CRÍTICO <=7D';
      badgeIcon = Icons.error_rounded;
    } else if (status == 'expired') {
      badgeBg = AppPalette.red600;
      badgeFg = Colors.white;
      badgeText = 'CADUCADO';
      badgeIcon = Icons.gpp_bad_rounded;
    } else if (status == 'unreachable') {
      badgeBg = AppPalette.amber50;
      badgeFg = AppPalette.amber800;
      badgeText = 'SIN ACCESO TLS';
      badgeIcon = Icons.link_off_rounded;
    } else if (checkMode == 'manual') {
      badgeBg = AppPalette.indigo100;
      badgeFg = AppPalette.indigo600;
      badgeText = 'MANUAL';
      badgeIcon = Icons.edit_calendar_rounded;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 1. Estado
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: badgeBg,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(badgeIcon, size: 13, color: badgeFg),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          badgeText,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            color: badgeFg,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                if (lastError.isNotEmpty && checkMode == 'https_live') ...[
                  const SizedBox(height: 3),
                  Tooltip(
                    message: lastError,
                    child: Text(
                      lastError,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 9.5, color: AppPalette.red600),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // 2. Caducidad / Días
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  days != null
                      ? (days < 0 ? 'Vencido hace ${days.abs()} d' : '$days días restantes')
                      : 'Pendiente de fecha',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: days == null
                        ? AppPalette.slate500
                        : (days <= 7
                            ? AppPalette.red700
                            : (days <= 30 ? AppPalette.amber700 : AppPalette.green700)),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Vence: $validUntilDate',
                  style: const TextStyle(fontSize: 10.5, color: AppPalette.slate600),
                ),
              ],
            ),
          ),

          // 3. Código / Nombre
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: AppPalette.slate100,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: AppPalette.slate300),
                      ),
                      child: Text(
                        (cert['code'] ?? '').toString(),
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: AppPalette.slate800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        (cert['name'] ?? '').toString(),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppPalette.slate900,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if ((cert['renewal_notes'] ?? '').toString().isNotEmpty)
                  Text(
                    (cert['renewal_notes'] ?? '').toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: AppPalette.slate500),
                  ),
              ],
            ),
          ),

          // 4. Host : Puerto (Modo)
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (cert['target_host'] ?? '').toString().isNotEmpty
                      ? '${cert['target_host']}:${cert['port'] ?? 443}'
                      : 'Sin endpoint red',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppPalette.slate800,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(
                      checkMode == 'https_live' ? Icons.wifi_tethering_rounded : Icons.edit_note_rounded,
                      size: 12,
                      color: checkMode == 'https_live' ? AppPalette.sky600 : AppPalette.violet600,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        checkMode == 'https_live' ? 'Auto HTTPS/TLS' : 'Manual / Offline',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: checkMode == 'https_live' ? AppPalette.sky700 : AppPalette.violet600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 5. Common Name (CN) & Emisor (CA)
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (cert['common_name'] ?? '').toString().isNotEmpty
                      ? 'CN: ${cert['common_name']}'
                      : 'CN no extraído',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppPalette.slate900,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (isSelfSigned)
                      Container(
                        margin: const EdgeInsets.only(right: 5),
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppPalette.amber100,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'Autofirmado',
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.amber800,
                          ),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        (cert['issuer_cn'] ?? '').toString().isNotEmpty
                            ? 'CA: ${cert['issuer_cn']}'
                            : 'CA: —',
                        style: const TextStyle(fontSize: 10.5, color: AppPalette.slate600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 6. Ubicación & Enlaces Directos (Rack / Planta / CMDB / Stack)
          Expanded(
            flex: 4,
            child: Wrap(
              spacing: 5,
              runSpacing: 4,
              children: [
                if (locInfo != null)
                  _buildLinkChip(
                    icon: Icons.location_on_outlined,
                    label: (locInfo['code'] ?? '').toString(),
                    tooltip: 'Sede: ${locInfo['label']}',
                    bgColor: AppPalette.slate100,
                    fgColor: AppPalette.slate700,
                    onTap: null,
                  ),
                if (rackInfo != null)
                  _buildLinkChip(
                    icon: Icons.dns_rounded,
                    label: 'Rack ${rackInfo['rack_code']} • ${rackInfo['u_label']}',
                    tooltip: 'Ir al Rack Editor (${rackInfo['rack_name']} — ${rackInfo['rack_device_name']})',
                    bgColor: AppPalette.blue50,
                    fgColor: AppPalette.blue900,
                    onTap: widget.onNavigateToRack != null
                        ? () => widget.onNavigateToRack!(
                              rackInfo['rack_id'] as int,
                              rackInfo['rack_device_id'] as int?,
                            )
                        : null,
                  ),
                if (floorInfo != null)
                  _buildLinkChip(
                    icon: Icons.domain_rounded,
                    label: '${floorInfo['floor_name']} • ${floorInfo['floor_device_code']}',
                    tooltip: 'Ir a Planta Datacenter (${floorInfo['floor_device_name']})',
                    bgColor: AppPalette.sky50,
                    fgColor: AppPalette.sky700,
                    onTap: widget.onNavigateToFloor != null
                        ? () => widget.onNavigateToFloor!(
                              floorInfo['floor_id'] as int,
                              floorInfo['floor_device_id'] as int?,
                            )
                        : null,
                  ),
                if (assetInfo != null)
                  _buildLinkChip(
                    icon: Icons.inventory_2_outlined,
                    label: 'CMDB: ${assetInfo['code']}',
                    tooltip: 'Ver máquina en 6. CMDB (${assetInfo['name']})',
                    bgColor: AppPalette.green50,
                    fgColor: AppPalette.green700,
                    onTap: widget.onNavigateToCmdb,
                  ),
                if (stackId != null && stackLabel.isNotEmpty)
                  _buildLinkChip(
                    icon: Icons.account_tree_outlined,
                    label: 'Stack: $stackLabel',
                    tooltip: 'Abrir en 4. Red & Host -> Stack Tecnológico',
                    bgColor: AppPalette.indigo100,
                    fgColor: AppPalette.indigo600,
                    onTap: widget.onNavigateToStack != null
                        ? () => widget.onNavigateToStack!(stackId, null)
                        : null,
                  ),
                if (rackInfo == null && floorInfo == null && assetInfo == null && locInfo == null)
                  const Text(
                    'Sin dispositivo vinculado',
                    style: TextStyle(fontSize: 10.5, color: AppPalette.slate400),
                  ),
              ],
            ),
          ),

          // 7. Renovación & Personas/Grupos de aviso
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: renewalType == 'manual' ? AppPalette.amber50 : AppPalette.green50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: renewalType == 'manual' ? AppPalette.amber300 : AppPalette.green300,
                        ),
                      ),
                      child: Text(
                        renewalType == 'manual' ? '🔔 Manual' : '🤖 Auto ACME',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: renewalType == 'manual' ? AppPalette.amber800 : AppPalette.green700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        (cert['responsible_person'] ?? '').toString(),
                        style: const TextStyle(fontSize: 10.5, color: AppPalette.slate700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  _formatRecipientsLabel(groups, contacts, notifyEmails, (cert['owner_team'] ?? '').toString()),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: AppPalette.slate500),
                ),
              ],
            ),
          ),

          // 8. Acciones
          SizedBox(
            width: 136,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.canOperate && checkMode == 'https_live')
                  IconButton(
                    tooltip: 'Sondear HTTPS/TLS en vivo ahora',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.sync_rounded, size: 17, color: AppPalette.sky600),
                    onPressed: () => _verifySingleCert(cert),
                  ),
                if (widget.canOperate)
                  IconButton(
                    tooltip: 'Enviar aviso a Personas / Grupos responsables',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(
                      Icons.notifications_active_outlined,
                      size: 17,
                      color: AppPalette.amber600,
                    ),
                    onPressed: () => _notifyCertContacts(cert),
                  ),
                if (widget.canEdit)
                  IconButton(
                    tooltip: 'Editar certificado / vínculos / avisos',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.edit_outlined, size: 17, color: AppPalette.slate700),
                    onPressed: () => _showUpsertCertificateDialog(existing: cert),
                  ),
                if (widget.canEdit)
                  IconButton(
                    tooltip: 'Eliminar certificado',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.delete_outline, size: 17, color: AppPalette.red600),
                    onPressed: () => _deleteCert(cert),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatRecipientsLabel(
    List<dynamic> groups,
    List<dynamic> contacts,
    String notifyEmails,
    String ownerTeam,
  ) {
    final parts = <String>[];
    for (final g in groups) {
      if (g is Map && g['name'] != null) parts.add('👥 ${g['name']}');
    }
    for (final c in contacts) {
      if (c is Map && c['full_name'] != null) parts.add('👤 ${c['full_name']}');
    }
    if (notifyEmails.isNotEmpty) {
      parts.add('✉️ $notifyEmails');
    }
    if (parts.isEmpty) {
      return 'Equipo: $ownerTeam';
    }
    return parts.join(' · ');
  }

  Widget _buildLinkChip({
    required IconData icon,
    required String label,
    required String tooltip,
    required Color bgColor,
    required Color fgColor,
    required VoidCallback? onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: fgColor.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: fgColor),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: fgColor,
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 3),
                Icon(Icons.open_in_new_rounded, size: 10, color: fgColor),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showUpsertCertificateDialog({Map<String, dynamic>? existing}) async {
    final isEdit = existing != null;
    final catalogs = Map<String, dynamic>.from((_overview['catalogs'] as Map?) ?? {});
    final assetsList = ((catalogs['assets'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final rackDevsList = ((catalogs['rack_devices'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final floorDevsList = ((catalogs['floor_devices'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final locationsList = ((catalogs['locations'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final contactsList = ((catalogs['contacts'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final groupsList = ((catalogs['contact_groups'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final codeCtrl = TextEditingController(text: (existing?['code'] ?? '').toString());
    final nameCtrl = TextEditingController(text: (existing?['name'] ?? '').toString());
    String checkMode = (existing?['check_mode'] ?? 'https_live').toString();
    final hostCtrl = TextEditingController(text: (existing?['target_host'] ?? '').toString());
    final portCtrl = TextEditingController(text: (existing?['port'] ?? 443).toString());
    final sniCtrl = TextEditingController(text: (existing?['sni_hostname'] ?? '').toString());
    String environment = (existing?['environment'] ?? 'production').toString();

    final cnCtrl = TextEditingController(text: (existing?['common_name'] ?? '').toString());
    final issuerCnCtrl = TextEditingController(text: (existing?['issuer_cn'] ?? '').toString());
    final issuerOrgCtrl = TextEditingController(text: (existing?['issuer_org'] ?? '').toString());
    final sanCtrl = TextEditingController(
      text: ((existing?['san_domains'] as List?) ?? []).join(', '),
    );
    final validFromCtrl = TextEditingController(
      text: (existing?['valid_from'] ?? '').toString().split('T').first,
    );
    final validUntilCtrl = TextEditingController(
      text: (existing?['valid_until'] ?? '').toString().split('T').first,
    );
    final pemCtrl = TextEditingController();

    String renewalType = (existing?['renewal_type'] ?? 'manual').toString();
    final warnDaysCtrl = TextEditingController(
      text: (existing?['warn_days_before'] ?? 30).toString(),
    );
    final critDaysCtrl = TextEditingController(
      text: (existing?['critical_days_before'] ?? 7).toString(),
    );
    bool notifyEnabled = existing?['notify_enabled'] != false;
    final selectedGroupIds = <int>{
      ...((existing?['contact_group_ids'] as List?) ?? []).map((e) => (e as num).toInt()),
    };
    final selectedContactIds = <int>{
      ...((existing?['contact_ids'] as List?) ?? []).map((e) => (e as num).toInt()),
    };
    final notifyEmailsCtrl = TextEditingController(
      text: (existing?['notify_emails'] ?? '').toString(),
    );
    final ownerTeamCtrl = TextEditingController(
      text: (existing?['owner_team'] ?? 'Seguridad & Sistemas').toString(),
    );
    final responsibleCtrl = TextEditingController(
      text: (existing?['responsible_person'] ?? 'Alex Geng').toString(),
    );
    final renewalNotesCtrl = TextEditingController(
      text: (existing?['renewal_notes'] ?? '').toString(),
    );
    final notesCtrl = TextEditingController(text: (existing?['notes'] ?? '').toString());

    int? selectedAssetId = existing?['asset_id'] as int?;
    int? selectedRackDeviceId = existing?['rack_device_id'] as int?;
    int? selectedFloorDeviceId = existing?['floor_device_id'] as int?;
    int? selectedLocationId = existing?['location_id'] as int?;

    bool probing = false;
    String? probeFeedback;
    bool probeOk = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          Future<void> runLiveProbe() async {
            setModalState(() {
              probing = true;
              probeFeedback = null;
            });
            try {
              final res = await widget.api.probeCertificate({
                'target_host': hostCtrl.text.trim(),
                'port': int.tryParse(portCtrl.text.trim()) ?? 443,
                'sni_hostname': sniCtrl.text.trim(),
                'pem_text': pemCtrl.text.trim(),
              });
              setModalState(() {
                probing = false;
                if (res['ok'] == true) {
                  probeOk = true;
                  cnCtrl.text = (res['common_name'] ?? '').toString();
                  issuerCnCtrl.text = (res['issuer_cn'] ?? '').toString();
                  issuerOrgCtrl.text = (res['issuer_org'] ?? '').toString();
                  sanCtrl.text = ((res['san_domains'] as List?) ?? []).join(', ');
                  validFromCtrl.text = (res['valid_from'] ?? '').toString().split('T').first;
                  validUntilCtrl.text = (res['valid_until'] ?? '').toString().split('T').first;
                  if (nameCtrl.text.trim().isEmpty) {
                    nameCtrl.text = 'Certificado TLS ${cnCtrl.text.isNotEmpty ? cnCtrl.text : hostCtrl.text}';
                  }
                  probeFeedback =
                      'Certificado X.509 extraído correctamente: CN=${cnCtrl.text} · Emisor=${issuerCnCtrl.text} · Vence=${validUntilCtrl.text} (${res['days_remaining']} días restantes).';
                } else {
                  probeOk = false;
                  probeFeedback = (res['error'] ?? 'No se pudo obtener el certificado.').toString();
                }
              });
            } catch (e) {
              setModalState(() {
                probing = false;
                probeOk = false;
                probeFeedback = 'Error sondeando certificado: $e';
              });
            }
          }

          return AlertDialog(
            title: Row(
              children: [
                Icon(
                  isEdit ? Icons.edit_rounded : Icons.add_moderator_rounded,
                  color: AppPalette.blue900,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isEdit
                        ? 'Editar Certificado SSL/TLS — ${existing['code']}'
                        : 'Nuevo Certificado SSL/TLS en CertScope (Auto HTTPS o Manual)',
                    style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 820,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Selector de modo: Auto HTTPS vs Manual
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () => setModalState(() => checkMode = 'https_live'),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: checkMode == 'https_live' ? AppPalette.blue50 : AppPalette.slate50,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: checkMode == 'https_live'
                                      ? AppPalette.blue900
                                      : AppPalette.slate300,
                                  width: checkMode == 'https_live' ? 1.8 : 1.0,
                                ),
                              ),
                              child: const Row(
                                children: [
                                  Icon(Icons.wifi_tethering_rounded, color: AppPalette.blue900),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '1. Verificación Automática HTTPS / TLS en Vivo',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w800,
                                            color: AppPalette.blue900,
                                          ),
                                        ),
                                        Text(
                                          'Conecta al puerto TLS (443, 8443, 8006...) y extrae fecha de caducidad, CN y CA automáticamente.',
                                          style: TextStyle(fontSize: 10.5, color: AppPalette.slate600),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: InkWell(
                            onTap: () => setModalState(() => checkMode = 'manual'),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: checkMode == 'manual' ? AppPalette.indigo100 : AppPalette.slate50,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: checkMode == 'manual'
                                      ? AppPalette.violet600
                                      : AppPalette.slate300,
                                  width: checkMode == 'manual' ? 1.8 : 1.0,
                                ),
                              ),
                              child: const Row(
                                children: [
                                  Icon(Icons.edit_calendar_rounded, color: AppPalette.violet600),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '2. Certificado Manual / Offline / Sin Web',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w800,
                                            color: AppPalette.violet600,
                                          ),
                                        ),
                                        Text(
                                          'Para certificados que no pueden sondearse por red: introduce su fecha a mano o pega el PEM.',
                                          style: TextStyle(fontSize: 10.5, color: AppPalette.slate600),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Vinculación con Dispositivos Existentes (CMDB / Rack / Planta / Sede)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppPalette.slate50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppPalette.slate200),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Vincular con Dispositivo de CMDB, Rack Editor, Planta Datacenter o Sede (autocompleta IP/Host y crea enlaces clicables):',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: AppPalette.slate800,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<int?>(
                                  value: assetsList.any((a) => a['id'] == selectedAssetId)
                                      ? selectedAssetId
                                      : null,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Máquina / Activo CMDB',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  items: [
                                    const DropdownMenuItem<int?>(
                                      value: null,
                                      child: Text('— Sin activo CMDB fijo —'),
                                    ),
                                    ...assetsList.map(
                                      (a) => DropdownMenuItem<int?>(
                                        value: a['id'] as int,
                                        child: Text(
                                          '${a['code']} — ${a['name']} (${a['primary_ip'] ?? ''})',
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ],
                                  onChanged: (val) {
                                    setModalState(() {
                                      selectedAssetId = val;
                                      if (val != null) {
                                        final ast = assetsList.firstWhere((a) => a['id'] == val);
                                        final ipOrFqdn = (ast['primary_ip'] ?? ast['fqdn'] ?? '').toString().trim();
                                        if (ipOrFqdn.isNotEmpty) {
                                          hostCtrl.text = ipOrFqdn;
                                        }
                                        nameCtrl.text = 'Certificado TLS ${ast['name']}';
                                        codeCtrl.text = 'CERT-${ast['code']}';
                                        if ((ast['fqdn'] ?? '').toString().isNotEmpty) {
                                          sniCtrl.text = ast['fqdn'].toString();
                                        }
                                        if (ast['rack_device_id'] != null) {
                                          selectedRackDeviceId = ast['rack_device_id'] as int?;
                                        }
                                        if (ast['floor_device_id'] != null) {
                                          selectedFloorDeviceId = ast['floor_device_id'] as int?;
                                        }
                                      }
                                    });
                                    if (val != null && checkMode == 'https_live' && hostCtrl.text.trim().isNotEmpty) {
                                      runLiveProbe();
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: DropdownButtonFormField<int?>(
                                  value: rackDevsList.any((r) => r['id'] == selectedRackDeviceId)
                                      ? selectedRackDeviceId
                                      : null,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Equipo en Rack Editor',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  items: [
                                    const DropdownMenuItem<int?>(
                                      value: null,
                                      child: Text('— Sin equipo de Rack —'),
                                    ),
                                    ...rackDevsList.map(
                                      (r) => DropdownMenuItem<int?>(
                                        value: r['id'] as int,
                                        child: Text(
                                          '${r['rack_code']} U${r['start_u']} · ${r['code']} (${r['ip_address'] ?? ''})',
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ],
                                  onChanged: (val) {
                                    setModalState(() {
                                      selectedRackDeviceId = val;
                                      if (val != null) {
                                        final r = rackDevsList.firstWhere((x) => x['id'] == val);
                                        final ipOrFqdn = (r['ip_address'] ?? r['fqdn'] ?? '').toString().trim();
                                        if (ipOrFqdn.isNotEmpty) {
                                          hostCtrl.text = ipOrFqdn;
                                        }
                                        nameCtrl.text = 'Certificado TLS ${r['name']}';
                                        codeCtrl.text = 'CERT-${r['code']}';
                                      }
                                    });
                                    if (val != null && checkMode == 'https_live' && hostCtrl.text.trim().isNotEmpty) {
                                      runLiveProbe();
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<int?>(
                                  value: floorDevsList.any((f) => f['id'] == selectedFloorDeviceId)
                                      ? selectedFloorDeviceId
                                      : null,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Dispositivo en Planta Datacenter',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  items: [
                                    const DropdownMenuItem<int?>(
                                      value: null,
                                      child: Text('— Sin equipo de Planta —'),
                                    ),
                                    ...floorDevsList.map(
                                      (f) => DropdownMenuItem<int?>(
                                        value: f['id'] as int,
                                        child: Text(
                                          '${f['floor_name']} · ${f['code']} — ${f['name']} (${f['ip_address'] ?? ''})',
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ],
                                  onChanged: (val) {
                                    setModalState(() {
                                      selectedFloorDeviceId = val;
                                      if (val != null) {
                                        final f = floorDevsList.firstWhere((x) => x['id'] == val);
                                        final ipOrFqdn = (f['ip_address'] ?? f['fqdn'] ?? '').toString().trim();
                                        if (ipOrFqdn.isNotEmpty) {
                                          hostCtrl.text = ipOrFqdn;
                                        }
                                        nameCtrl.text = 'Certificado TLS ${f['name']}';
                                        codeCtrl.text = 'CERT-${f['code']}';
                                      }
                                    });
                                    if (val != null && checkMode == 'https_live' && hostCtrl.text.trim().isNotEmpty) {
                                      runLiveProbe();
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: DropdownButtonFormField<int?>(
                                  value: locationsList.any((l) => l['id'] == selectedLocationId)
                                      ? selectedLocationId
                                      : null,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Sede / Location (1. Locations)',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  items: [
                                    const DropdownMenuItem<int?>(
                                      value: null,
                                      child: Text('— Auto / Global —'),
                                    ),
                                    ...locationsList.map(
                                      (l) => DropdownMenuItem<int?>(
                                        value: l['id'] as int,
                                        child: Text(
                                          (l['label'] ?? l['name']).toString(),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ],
                                  onChanged: (val) => setModalState(() => selectedLocationId = val),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Identidad y Endpoint
                    Row(
                      children: [
                        SizedBox(
                          width: 140,
                          child: TextField(
                            controller: codeCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Código (opcional)',
                              hintText: 'CERT-001',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: nameCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Nombre descriptivo del Certificado *',
                              hintText: 'Ej: Portal HTTPS Router Principal / Proxmox VE / ERP',
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
                          flex: 3,
                          child: TextField(
                            controller: hostCtrl,
                            decoration: InputDecoration(
                              labelText: checkMode == 'https_live'
                                  ? 'IP o Dominio a verificar por HTTPS *'
                                  : 'IP o Dominio de referencia (opcional)',
                              hintText: 'Ej: 192.168.2.1 o erp.empresa.local',
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 110,
                          child: TextField(
                            controller: portCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Puerto TLS',
                              hintText: '443',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: sniCtrl,
                            decoration: const InputDecoration(
                              labelText: 'SNI Hostname (opcional)',
                              hintText: 'erp.empresa.local',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        if (checkMode == 'https_live') ...[
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: AppPalette.sky600,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: probing ? null : runLiveProbe,
                            icon: probing
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.radar_rounded, size: 16),
                            label: const Text(
                              'Probar HTTPS Ahora',
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (probeFeedback != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: probeOk ? AppPalette.green50 : AppPalette.red50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: probeOk ? AppPalette.green300 : AppPalette.red300,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              probeOk ? Icons.check_circle_rounded : Icons.warning_rounded,
                              size: 16,
                              color: probeOk ? AppPalette.green700 : AppPalette.red700,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                probeFeedback!,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: probeOk ? AppPalette.green700 : AppPalette.red700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),

                    // Datos X.509 (autocompletados por HTTPS o editables manualmente)
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: cnCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Common Name (CN)',
                              hintText: '*.empresa.local / 192.168.2.1',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: issuerCnCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Emisor / Autoridad Certificadora (CA)',
                              hintText: 'Let\'s Encrypt / DigiCert / PKI Interna',
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
                            controller: validFromCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Válido Desde (YYYY-MM-DD)',
                              hintText: '2026-01-01',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: validUntilCtrl,
                            decoration: InputDecoration(
                              labelText: 'Fecha de Caducidad (YYYY-MM-DD) *',
                              hintText: '2027-01-01',
                              border: const OutlineInputBorder(),
                              isDense: true,
                              suffixIcon: IconButton(
                                tooltip: 'Seleccionar fecha en calendario',
                                icon: const Icon(Icons.calendar_month_rounded, size: 18),
                                onPressed: () async {
                                  final now = DateTime.now();
                                  final picked = await showDatePicker(
                                    context: ctx,
                                    initialDate: now.add(const Duration(days: 90)),
                                    firstDate: DateTime(2020),
                                    lastDate: DateTime(2040),
                                  );
                                  if (picked != null) {
                                    setModalState(() {
                                      validUntilCtrl.text =
                                          '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                                    });
                                  }
                                },
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: sanCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Dominios SAN (separados por coma)',
                              hintText: 'erp.empresa.local, api.empresa.local',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (checkMode == 'manual') ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: pemCtrl,
                              maxLines: 2,
                              decoration: const InputDecoration(
                                labelText:
                                    'Opcional: Pegar bloque -----BEGIN CERTIFICATE----- (PEM) para extraer datos automáticamente',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: probing ? null : runLiveProbe,
                            icon: const Icon(Icons.auto_fix_high_rounded, size: 16),
                            label: const Text('Extraer del PEM'),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 14),

                    // Renovación y Avisos a Personas / Grupos
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppPalette.amber50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppPalette.amber300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.notifications_active_rounded,
                                size: 18,
                                color: AppPalette.amber800,
                              ),
                              const SizedBox(width: 6),
                              const Expanded(
                                child: Text(
                                  'Política de Renovación y Avisos a Personas / Grupos (para certificados manuales o críticos)',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: AppPalette.amber800,
                                  ),
                                ),
                              ),
                              Switch(
                                value: notifyEnabled,
                                onChanged: (v) => setModalState(() => notifyEnabled = v),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: DropdownButtonFormField<String>(
                                  value: renewalType,
                                  decoration: const InputDecoration(
                                    labelText: 'Tipo de Renovación',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                    filled: true,
                                    fillColor: Colors.white,
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'manual',
                                      child: Text('🔔 Renovación Manual (Avisar al equipo)'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'auto_acme',
                                      child: Text('🤖 Renovación Automática (ACME / Let\'s Encrypt)'),
                                    ),
                                  ],
                                  onChanged: (v) {
                                    if (v != null) setModalState(() => renewalType = v);
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 130,
                                child: TextField(
                                  controller: warnDaysCtrl,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Aviso previo (días)',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                    filled: true,
                                    fillColor: Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 130,
                                child: TextField(
                                  controller: critDaysCtrl,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Alerta crítica (días)',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                    filled: true,
                                    fillColor: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (groupsList.isNotEmpty) ...[
                            const Text(
                              'Grupos de Personas a notificar:',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppPalette.slate800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: groupsList.map((g) {
                                final gid = g['id'] as int;
                                final sel = selectedGroupIds.contains(gid);
                                return FilterChip(
                                  selected: sel,
                                  label: Text(
                                    '👥 ${g['name']}',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  onSelected: (v) {
                                    setModalState(() {
                                      if (v) {
                                        selectedGroupIds.add(gid);
                                      } else {
                                        selectedGroupIds.remove(gid);
                                      }
                                    });
                                  },
                                );
                              }).toList(),
                            ),
                            const SizedBox(height: 6),
                          ],
                          if (contactsList.isNotEmpty) ...[
                            const Text(
                              'Personas concretas a notificar:',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppPalette.slate800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: contactsList.map((c) {
                                final cid = c['id'] as int;
                                final sel = selectedContactIds.contains(cid);
                                return FilterChip(
                                  selected: sel,
                                  label: Text(
                                    '👤 ${c['full_name']} (${c['email']})',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  onSelected: (v) {
                                    setModalState(() {
                                      if (v) {
                                        selectedContactIds.add(cid);
                                      } else {
                                        selectedContactIds.remove(cid);
                                      }
                                    });
                                  },
                                );
                              }).toList(),
                            ),
                            const SizedBox(height: 8),
                          ],
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: notifyEmailsCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Correos adicionales de aviso (separados por comas)',
                                    hintText: 'seguridad@empresa.local, guardia@empresa.local',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                    filled: true,
                                    fillColor: Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: responsibleCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Responsable directo',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                    filled: true,
                                    fillColor: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: renewalNotesCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Instrucciones paso a paso para la renovación manual',
                              hintText:
                                  'Ej: Acceder a iDRAC / FortiGate -> Generar CSR -> Firmar en CA Interna y subir .crt',
                              border: OutlineInputBorder(),
                              isDense: true,
                              filled: true,
                              fillColor: Colors.white,
                            ),
                          ),
                        ],
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
                style: FilledButton.styleFrom(
                  backgroundColor: AppPalette.blue900,
                  foregroundColor: Colors.white,
                ),
                onPressed: () async {
                  if (nameCtrl.text.trim().isEmpty && hostCtrl.text.trim().isEmpty) {
                    mostrarAviso(
                      context,
                      'Indica al menos el nombre del certificado o el host/IP.',
                      tono: TonoAviso.advertencia,
                    );
                    return;
                  }
                  final payload = <String, dynamic>{
                    'code': codeCtrl.text.trim().isEmpty ? null : codeCtrl.text.trim(),
                    'name': nameCtrl.text.trim().isNotEmpty
                        ? nameCtrl.text.trim()
                        : 'Certificado ${hostCtrl.text.trim()}',
                    'check_mode': checkMode,
                    'target_host': hostCtrl.text.trim(),
                    'port': int.tryParse(portCtrl.text.trim()) ?? 443,
                    'sni_hostname': sniCtrl.text.trim(),
                    'environment': environment,
                    'common_name': cnCtrl.text.trim(),
                    'issuer_cn': issuerCnCtrl.text.trim(),
                    'issuer_org': issuerOrgCtrl.text.trim(),
                    'san_domains': sanCtrl.text
                        .split(',')
                        .map((s) => s.trim())
                        .where((s) => s.isNotEmpty)
                        .toList(),
                    'valid_from': validFromCtrl.text.trim().isEmpty
                        ? null
                        : validFromCtrl.text.trim(),
                    'valid_until': validUntilCtrl.text.trim().isEmpty
                        ? null
                        : validUntilCtrl.text.trim(),
                    'pem_text': pemCtrl.text.trim(),
                    'renewal_type': renewalType,
                    'warn_days_before': int.tryParse(warnDaysCtrl.text.trim()) ?? 30,
                    'critical_days_before': int.tryParse(critDaysCtrl.text.trim()) ?? 7,
                    'auto_probe_enabled': checkMode == 'https_live',
                    'notify_enabled': notifyEnabled,
                    'contact_group_ids': selectedGroupIds.toList(),
                    'contact_ids': selectedContactIds.toList(),
                    'notify_emails': notifyEmailsCtrl.text.trim(),
                    'owner_team': ownerTeamCtrl.text.trim(),
                    'responsible_person': responsibleCtrl.text.trim(),
                    'asset_id': selectedAssetId,
                    'rack_device_id': selectedRackDeviceId,
                    'floor_device_id': selectedFloorDeviceId,
                    'location_id': selectedLocationId,
                    'renewal_notes': renewalNotesCtrl.text.trim(),
                    'notes': notesCtrl.text.trim(),
                  };
                  try {
                    final Map<String, dynamic> updated;
                    if (isEdit) {
                      updated = await widget.api.updateCertificate(
                        existing['id'] as int,
                        payload,
                      );
                    } else {
                      updated = await widget.api.createCertificate(payload);
                    }
                    if (!ctx.mounted) return;
                    Navigator.pop(ctx);
                    setState(() => _overview = updated);
                    mostrarAviso(
                      context,
                      isEdit
                          ? 'Certificado actualizado en CertScope.'
                          : 'Certificado registrado en CertScope.',
                      tono: TonoAviso.exito,
                    );
                  } catch (e) {
                    if (!ctx.mounted) return;
                    mostrarAviso(
                      context,
                      'Error guardando certificado: $e',
                      tono: TonoAviso.error,
                    );
                  }
                },
                icon: const Icon(Icons.save_rounded, size: 16),
                label: Text(isEdit ? 'Guardar Cambios' : 'Registrar Certificado'),
              ),
            ],
          );
        },
      ),
    );
  }
}
