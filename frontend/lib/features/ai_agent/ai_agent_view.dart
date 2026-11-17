import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/api_client.dart';
import '../../core/file_downloader.dart';
import '../../core/theme.dart';
import '../../core/widgets/avisos.dart';
import 'widgets/ai_network_schema_tab.dart';
import 'widgets/mermaid_visual_viewer.dart';
import 'widgets/passive_discovery_tab.dart';

/// Vista principal del Módulo **`10. Agente IA (Solo-Lectura)`**:
/// - Autodocumentación técnica de Sedes, Racks 42U, Stacks Lógicos 2D y Hosts (Markdown + Mermaid).
/// - Auditoría determinista de Puntos Únicos de Fallo (SPOF), Guardias SRE, CertScope y Deriva CMDB.
/// - Copiloto conversacional 100% Solo-Lectura contextualizado con el inventario vivo.
/// - Bandeja `Human-in-the-Loop` de borradores CMDB (aplicables con 1 clic por `editor`/`admin`).
class AiAgentView extends StatefulWidget {
  final RackDocApiClient api;
  final bool canEdit;
  final bool canGenerateDocs;
  final bool isAdmin;
  final VoidCallback onOpenAdminAiSettings;
  final void Function(int rackId, int? deviceId)? onNavigateToRack;
  final void Function(int stackId)? onNavigateToTechStack;

  const AiAgentView({
    super.key,
    required this.api,
    required this.canEdit,
    required this.canGenerateDocs,
    required this.isAdmin,
    required this.onOpenAdminAiSettings,
    this.onNavigateToRack,
    this.onNavigateToTechStack,
  });

  @override
  State<AiAgentView> createState() => _AiAgentViewState();
}

class _AiAgentViewState extends State<AiAgentView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  bool _loading = true;
  String? _error;
  Map<String, dynamic> _overview = const {};

  // Pestaña 1: Generación y lectura de Dossiers
  String _selectedScopeType = 'global_cpd';
  int? _selectedScopeTargetId;
  final TextEditingController _customFocusCtrl = TextEditingController();
  bool _autoProposeSuggestions = true;
  bool _generatingDoc = false;
  Map<String, dynamic>? _activeDocument;
  bool _loadingDocDetail = false;
  String _docDisplayMode = 'split'; // 'split' | 'mermaid' | 'markdown'

  // Pestaña 2: Filtro de hallazgos en vivo
  String _findingSeverityFilter = 'all';

  // Pestaña 3: Copiloto Solo-Lectura
  final TextEditingController _chatInputCtrl = TextEditingController();
  final List<Map<String, String>> _chatMessages = [];
  bool _sendingChat = false;

  // Pestaña 4: Borradores CMDB
  String _suggestionStatusFilter = 'pending';
  bool _scanningSuggestions = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _loadOverview();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _customFocusCtrl.dispose();
    _chatInputCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadOverview({int? selectDocId}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ov = await widget.api.getAiAgentOverview();
      if (!mounted) return;
      final docs = ((ov['documents'] ?? const []) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      setState(() {
        _overview = ov;
        _loading = false;
      });
      final targetDocId =
          selectDocId ?? (docs.isNotEmpty ? docs.first['id'] as int? : null);
      if (targetDocId != null) {
        await _openDocumentDetail(targetDocId);
      } else {
        if (mounted) {
          setState(() => _activeDocument = null);
        }
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

  Future<void> _openDocumentDetail(int docId) async {
    setState(() => _loadingDocDetail = true);
    try {
      final detail = await widget.api.getAiDocumentDetail(docId);
      if (mounted) {
        setState(() => _activeDocument = detail);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).avisoError(e);
      }
    } finally {
      if (mounted) {
        setState(() => _loadingDocDetail = false);
      }
    }
  }

  List<Map<String, dynamic>> _targetsForCurrentScope() {
    final targetsMap = Map<String, dynamic>.from(
      (_overview['scope_targets'] ?? const {}) as Map,
    );
    String? key;
    if (_selectedScopeType == 'location') key = 'locations';
    if (_selectedScopeType == 'rack') key = 'racks';
    if (_selectedScopeType == 'logical_stack') key = 'logical_stacks';
    if (_selectedScopeType == 'host') key = 'hosts';
    if (key == null) return const [];
    return ((targetsMap[key] ?? const []) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<void> _triggerGenerateDocument() async {
    final messenger = ScaffoldMessenger.of(context);
    final targets = _targetsForCurrentScope();
    if (targets.isNotEmpty && _selectedScopeTargetId == null) {
      messenger.avisoError('Selecciona el elemento objetivo del desplegable.');
      return;
    }
    setState(() => _generatingDoc = true);
    try {
      final res = await widget.api.generateAiDocument({
        'scope_type': _selectedScopeType,
        'scope_target_id': _selectedScopeTargetId,
        'custom_focus': _customFocusCtrl.text.trim(),
        'auto_propose_cmdb_suggestions': _autoProposeSuggestions,
      });
      if (!mounted) return;
      final doc = Map<String, dynamic>.from((res['document'] ?? const {}) as Map);
      final ov = Map<String, dynamic>.from((res['overview'] ?? const {}) as Map);
      final sugCount = (res['created_suggestions_count'] ?? 0) as int;
      setState(() {
        _overview = ov;
        _activeDocument = doc;
      });
      messenger.avisoExito(
        sugCount > 0
            ? 'Dossier generado + $sugCount borrador(es) nuevos propuestos para CMDB.'
            : 'Dossier técnico generado en modo Solo-Lectura.',
      );
    } catch (e) {
      messenger.avisoError(e);
    } finally {
      if (mounted) {
        setState(() => _generatingDoc = false);
      }
    }
  }

  Future<void> _deleteDocument(int docId) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await widget.api.deleteAiDocument(docId);
      if (!mounted) return;
      final ov = Map<String, dynamic>.from((res['overview'] ?? const {}) as Map);
      setState(() {
        _overview = ov;
        if (_activeDocument != null && _activeDocument!['id'] == docId) {
          _activeDocument = null;
        }
      });
      messenger.aviso('Documento eliminado de la biblioteca IA.');
    } catch (e) {
      messenger.avisoError(e);
    }
  }

  Future<void> _sendChatQuestion([String? presetQuestion]) async {
    final messenger = ScaffoldMessenger.of(context);
    final q = (presetQuestion ?? _chatInputCtrl.text).trim();
    if (q.isEmpty || _sendingChat) return;
    if (presetQuestion == null) {
      _chatInputCtrl.clear();
    }
    final priorHistory = List<Map<String, String>>.from(_chatMessages);
    setState(() {
      _chatMessages.add({'role': 'user', 'content': q});
      _sendingChat = true;
    });
    try {
      final res = await widget.api.sendAiReadonlyChat({
        'question': q,
        'scope_type': _selectedScopeType,
        'scope_target_id': _selectedScopeTargetId,
        'history': priorHistory,
      });
      if (!mounted) return;
      setState(() {
        _chatMessages.add({
          'role': 'assistant',
          'content': (res['answer'] ?? '').toString(),
          'meta': '${res['provider_used']} · ${res['model_used']} (${res['mode']})',
        });
      });
    } catch (e) {
      messenger.avisoError(e);
    } finally {
      if (mounted) {
        setState(() => _sendingChat = false);
      }
    }
  }

  Future<void> _scanSuggestionsNow() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _scanningSuggestions = true);
    try {
      final res = await widget.api.scanCmdbSuggestions();
      if (!mounted) return;
      final created = (res['created_count'] ?? 0) as int;
      setState(() {
        _overview =
            Map<String, dynamic>.from((res['overview'] ?? const {}) as Map);
      });
      messenger.avisoExito(
        created > 0
            ? 'Escaneo completado: $created nueva(s) sugerencia(s) en borrador.'
            : 'Escaneo completado: no hay nuevos huecos documentales pendientes.',
      );
    } catch (e) {
      messenger.avisoError(e);
    } finally {
      if (mounted) {
        setState(() => _scanningSuggestions = false);
      }
    }
  }

  Future<void> _reviewSuggestion(int id, bool apply) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = apply
          ? await widget.api.applyCmdbSuggestion(id)
          : await widget.api.dismissCmdbSuggestion(id);
      if (!mounted) return;
      setState(() {
        _overview =
            Map<String, dynamic>.from((res['overview'] ?? const {}) as Map);
      });
      messenger.avisoExito(
        apply
            ? 'Sugerencia aplicada a la ficha CMDB.'
            : 'Sugerencia descartada (la CMDB no fue modificada).',
      );
    } catch (e) {
      messenger.avisoError(e);
    }
  }

  Color _severityColor(String sev) {
    switch (sev.toLowerCase()) {
      case 'critical':
        return AppPalette.red600;
      case 'high':
        return AppPalette.orange600;
      case 'warning':
        return AppPalette.amber600;
      default:
        return AppPalette.sky600;
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
            const Icon(Icons.error_outline, color: AppPalette.red600, size: 40),
            const SizedBox(height: 8),
            Text('Error cargando Agente IA: $_error'),
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

    final engine = Map<String, dynamic>.from(
      (_overview['engine_summary'] ?? const {}) as Map,
    );
    final kpis = Map<String, dynamic>.from(
      (_overview['kpis'] ?? const {}) as Map,
    );
    final pendingSugCount = (_overview['pending_suggestions_count'] ?? 0) as int;
    final providerLabel = (engine['provider_type'] == 'ollama_local')
        ? 'Ollama Local (${engine['model_name']})'
        : '${engine['provider_type']} · ${engine['model_name']}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // CABECERA SUPERIOR CON CANDADO SOLO-LECTURA Y KPIS
        Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
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
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppPalette.indigo100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.auto_awesome_rounded,
                      color: AppPalette.indigo600,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Agente IA Analista y Documentador (100% Modo Solo-Lectura)',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.slate900,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Analiza Racks 42U, Cableado, Topología 5 Capas, CMDB, CertScope y Prometheus sin alterar producción.',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppPalette.slate500,
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
                      color: AppPalette.green50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppPalette.green300),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 14,
                          color: AppPalette.green700,
                        ),
                        SizedBox(width: 5),
                        Text(
                          'ZERO-TOUCH SOLO LECTURA',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.green700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: AppPalette.slate100,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppPalette.slate300),
                    ),
                    child: Text(
                      providerLabel,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppPalette.slate800,
                      ),
                    ),
                  ),
                  if (widget.isAdmin) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: widget.onOpenAdminAiSettings,
                      icon: const Icon(Icons.tune_rounded, size: 15),
                      label: const Text('Motor IA / MCP'),
                    ),
                  ],
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Refrescar radiografía del CPD',
                    onPressed: _loadOverview,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  _KpiPill(
                    label: 'Racks Auditados',
                    value: '${kpis['racks_count'] ?? 0}',
                    color: AppPalette.blue600,
                  ),
                  _KpiPill(
                    label: 'Activos CMDB',
                    value: '${kpis['active_cmdb_assets_count'] ?? 0}',
                    color: AppPalette.teal600,
                  ),
                  _KpiPill(
                    label: 'Certificados TLS',
                    value: '${kpis['tls_certificates_count'] ?? 0}',
                    color: AppPalette.indigo600,
                  ),
                  _KpiPill(
                    label: 'SPOFs / Riesgos Altos',
                    value: '${kpis['findings_critical_or_high'] ?? 0}',
                    color: ((kpis['findings_critical_or_high'] ?? 0) as int) > 0
                        ? AppPalette.red600
                        : AppPalette.green600,
                  ),
                  _KpiPill(
                    label: 'Borradores CMDB',
                    value: '$pendingSugCount',
                    color: AppPalette.amber600,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TabBar(
                controller: _tabController,
                isScrollable: true,
                labelColor: AppPalette.blue700,
                unselectedLabelColor: AppPalette.slate600,
                indicatorColor: AppPalette.blue600,
                tabs: [
                  const Tab(
                    icon: Icon(Icons.menu_book_rounded, size: 17),
                    text: '1. Autodocumentación & Runbooks',
                  ),
                  const Tab(
                    icon: Icon(Icons.hub_outlined, size: 17),
                    text: '2. Esquemas de Red 2D (IA)',
                  ),
                  Tab(
                    icon: const Icon(Icons.shield_outlined, size: 17),
                    text:
                        '3. SPOFs, SRE & FinOps (${kpis['findings_total'] ?? 0})',
                  ),
                  const Tab(
                    icon: Icon(Icons.forum_outlined, size: 17),
                    text: '4. Copiloto Solo-Lectura',
                  ),
                  Tab(
                    icon: const Icon(Icons.fact_check_outlined, size: 17),
                    text: '5. Borradores CMDB ($pendingSugCount)',
                  ),
                  Tab(
                    icon: const Icon(Icons.radar_rounded, size: 17),
                    text:
                        '6. Descubrimiento Pasivo RO (${((((_overview['passive_discovery'] ?? const {}) as Map)['snapshots'] ?? const []) as List).length})',
                  ),
                ],
              ),
            ],
          ),
        ),

        // CONTENIDO DE LAS 6 PESTAÑAS
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildDocumenterTab(),
              AiNetworkSchemaTab(
                api: widget.api,
                scopeTargets: Map<String, dynamic>.from(
                  (_overview['scope_targets'] ?? const {}) as Map,
                ),
                canEdit: widget.canEdit,
                onNavigateToRack: widget.onNavigateToRack,
                onNavigateToTechStack: widget.onNavigateToTechStack,
              ),
              _buildLiveFindingsTab(),
              _buildCopilotChatTab(),
              _buildSuggestionsTab(),
              PassiveDiscoveryTab(
                api: widget.api,
                passiveData: Map<String, dynamic>.from(
                  (_overview['passive_discovery'] ?? const {}) as Map,
                ),
                canLaunchAudit: widget.canGenerateDocs,
                canEdit: widget.canEdit,
                onOverviewUpdated: (ov) => setState(() => _overview = ov),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // PESTAÑA 1: AUTODOCUMENTACIÓN Y BIBLIOTECA DE DOSSIERS (MARKDOWN + MERMAID)
  // ---------------------------------------------------------------------------
  Widget _buildDocumenterTab() {
    final docs = ((_overview['documents'] ?? const []) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final scopeTargets = _targetsForCurrentScope();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Columna izquierda: Generador + Biblioteca
        Container(
          width: 370,
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(right: BorderSide(color: AppPalette.slate200)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Generar Nuevo Dossier Técnico',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  color: AppPalette.slate900,
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _selectedScopeType,
                isDense: true,
                decoration: const InputDecoration(
                  labelText: 'Alcance del Análisis',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'global_cpd',
                    child: Text('CPD Completo (Arquitectura Global)'),
                  ),
                  DropdownMenuItem(
                    value: 'spof_risk_audit',
                    child: Text('Auditoría Integral de SPOFs y Riesgos SRE'),
                  ),
                  DropdownMenuItem(
                    value: 'location',
                    child: Text('Sede / Ubicación Concreta'),
                  ),
                  DropdownMenuItem(
                    value: 'rack',
                    child: Text('Bastidor Rack 42U y Cableado'),
                  ),
                  DropdownMenuItem(
                    value: 'logical_stack',
                    child: Text('Stack Tecnológico / Servicio 2D'),
                  ),
                  DropdownMenuItem(
                    value: 'host',
                    child: Text('Host / Máquina Virtual CMDB'),
                  ),
                ],
                onChanged: (val) {
                  if (val == null) return;
                  setState(() {
                    _selectedScopeType = val;
                    final nextTargets = _targetsForCurrentScope();
                    _selectedScopeTargetId = nextTargets.isNotEmpty
                        ? nextTargets.first['id'] as int
                        : null;
                  });
                },
              ),
              if (scopeTargets.isNotEmpty) ...[
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  initialValue: scopeTargets
                          .any((t) => t['id'] == _selectedScopeTargetId)
                      ? _selectedScopeTargetId
                      : (scopeTargets.first['id'] as int),
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Elemento Objetivo',
                    border: OutlineInputBorder(),
                  ),
                  items: scopeTargets
                      .map(
                        (t) => DropdownMenuItem<int>(
                          value: t['id'] as int,
                          child: Text(
                            (t['label'] ?? '').toString(),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (id) =>
                      setState(() => _selectedScopeTargetId = id),
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                controller: _customFocusCtrl,
                decoration: const InputDecoration(
                  labelText: 'Foco específico opcional',
                  hintText: 'Ej: Plan DRP ante corte eléctrico en Sala 1',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _autoProposeSuggestions,
                onChanged: (v) =>
                    setState(() => _autoProposeSuggestions = v ?? true),
                title: const Text(
                  'Proponer borradores para fichas CMDB incompletas',
                  style: TextStyle(fontSize: 11.5),
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: (!widget.canGenerateDocs || _generatingDoc)
                      ? null
                      : _triggerGenerateDocument,
                  icon: _generatingDoc
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.auto_stories_rounded, size: 17),
                  label: Text(
                    _generatingDoc
                        ? 'Analizando CPD...'
                        : 'Analizar y Documentar',
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Divider(height: 1),
              const SizedBox(height: 10),
              Text(
                'Biblioteca de Dossiers Generados (${docs.length})',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppPalette.slate600,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: docs.isEmpty
                    ? const Center(
                        child: Text(
                          'Aún no hay documentos generados.\nPulsa "Analizar y Documentar" arriba.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppPalette.slate500,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: docs.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 6),
                        itemBuilder: (ctx, i) {
                          final d = docs[i];
                          final selected = _activeDocument != null &&
                              _activeDocument!['id'] == d['id'];
                          return InkWell(
                            onTap: () => _openDocumentDetail(d['id'] as int),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: selected
                                    ? AppPalette.blue50
                                    : AppPalette.slate50,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: selected
                                      ? AppPalette.blue500
                                      : AppPalette.slate200,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          (d['title'] ?? '').toString(),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      if (widget.canEdit)
                                        IconButton(
                                          visualDensity: VisualDensity.compact,
                                          icon: const Icon(
                                            Icons.delete_outline,
                                            size: 16,
                                            color: AppPalette.red600,
                                          ),
                                          onPressed: () =>
                                              _deleteDocument(d['id'] as int),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${d['doc_code']} · ${d['provider_used']} (${d['model_used']})',
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      color: AppPalette.slate500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),

        // Columna derecha: Visor del Dossier Markdown + Visor Gráfico Mermaid
        Expanded(
          child: _loadingDocDetail
              ? const Center(child: CircularProgressIndicator())
              : _activeDocument == null
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: ((_overview['global_mermaid'] ?? '')
                              .toString()
                              .trim()
                              .isNotEmpty)
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Vista Previa Mermaid en Vivo del CPD (Genera un Dossier a la izquierda para archivar el informe completo)',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w800,
                                    color: AppPalette.slate700,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Expanded(
                                  child: MermaidVisualViewer(
                                    mermaidCode:
                                        (_overview['global_mermaid'] ?? '')
                                            .toString(),
                                    title: 'Vista Global CPD',
                                  ),
                                ),
                              ],
                            )
                          : const Center(
                              child: Text(
                                'Selecciona o genera un Dossier Técnico para leer su contenido Markdown y visualizar su diagrama Mermaid.',
                                style: TextStyle(color: AppPalette.slate500),
                              ),
                            ),
                    )
                  : Padding(
                      padding: const EdgeInsets.all(20),
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppPalette.slate200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SizedBox(
                                  width: 320,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        (_activeDocument!['title'] ?? '')
                                            .toString(),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 15.5,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${_activeDocument!['doc_code']} · ${_activeDocument!['provider_used']} (${_activeDocument!['model_used']})',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: AppPalette.slate500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                SegmentedButton<String>(
                                  style: const ButtonStyle(
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  segments: const [
                                    ButtonSegment(
                                      value: 'split',
                                      icon: Icon(
                                        Icons.vertical_split_rounded,
                                        size: 15,
                                      ),
                                      label: Text('Dossier + Visor'),
                                    ),
                                    ButtonSegment(
                                      value: 'mermaid',
                                      icon: Icon(
                                        Icons.account_tree_rounded,
                                        size: 15,
                                      ),
                                      label: Text('Visor Mermaid'),
                                    ),
                                    ButtonSegment(
                                      value: 'markdown',
                                      icon: Icon(
                                        Icons.article_outlined,
                                        size: 15,
                                      ),
                                      label: Text('Markdown'),
                                    ),
                                  ],
                                  selected: {_docDisplayMode},
                                  onSelectionChanged: (sel) => setState(
                                    () => _docDisplayMode = sel.first,
                                  ),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () async {
                                    final messenger =
                                        ScaffoldMessenger.of(context);
                                    final md = (_activeDocument![
                                                'markdown_content'] ??
                                            '')
                                        .toString();
                                    final code =
                                        (_activeDocument!['doc_code'] ??
                                                'dossier_ia')
                                            .toString()
                                            .toLowerCase();
                                    await downloadBytesAsFile(
                                      bytes: Uint8List.fromList(
                                        utf8.encode(md),
                                      ),
                                      filename: '$code.md',
                                      mimeType: 'text/markdown;charset=utf-8',
                                    );
                                    messenger.avisoExito(
                                      'Archivo $code.md descargado.',
                                    );
                                  },
                                  icon: const Icon(
                                    Icons.download_rounded,
                                    size: 15,
                                  ),
                                  label: const Text('Descargar .MD'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () {
                                    final md = (_activeDocument![
                                                'markdown_content'] ??
                                            '')
                                        .toString();
                                    Clipboard.setData(ClipboardData(text: md));
                                    ScaffoldMessenger.of(context).avisoExito(
                                      'Markdown completo copiado al portapapeles.',
                                    );
                                  },
                                  icon:
                                      const Icon(Icons.copy_rounded, size: 15),
                                  label: const Text('Copiar MD'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: () {
                                    final mmd =
                                        (_activeDocument!['mermaid_diagram'] ??
                                                '')
                                            .toString();
                                    Clipboard.setData(ClipboardData(text: mmd));
                                    ScaffoldMessenger.of(context).avisoExito(
                                      'Diagrama Mermaid copiado.',
                                    );
                                  },
                                  icon: const Icon(
                                    Icons.code_rounded,
                                    size: 15,
                                  ),
                                  label: const Text('Código Mermaid'),
                                ),
                              ],
                            ),
                            const Divider(height: 20),
                            Expanded(
                              child: _buildActiveDocumentBody(),
                            ),
                          ],
                        ),
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _buildActiveDocumentBody() {
    final doc = _activeDocument!;
    final md = (doc['markdown_content'] ?? '').toString();
    final rawMermaid = (doc['mermaid_diagram'] ?? '').toString().trim();
    final effectiveMermaid = rawMermaid.isNotEmpty ? rawMermaid : md;
    final docTitle = (doc['title'] ?? 'Dossier IA').toString();

    if (_docDisplayMode == 'mermaid') {
      return MermaidVisualViewer(
        mermaidCode: effectiveMermaid,
        title: docTitle,
      );
    }

    if (_docDisplayMode == 'markdown') {
      return SingleChildScrollView(
        child: Text(
          md,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12.5,
            height: 1.5,
            color: AppPalette.slate800,
          ),
        ),
      );
    }

    // Modo 'split': Visor Mermaid interactivo arriba + Dossier Markdown debajo
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 310,
          child: MermaidVisualViewer(
            mermaidCode: effectiveMermaid,
            title: docTitle,
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: SingleChildScrollView(
            child: Text(
              md,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.5,
                color: AppPalette.slate800,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // PESTAÑA 2: AUDITORÍA EN VIVO DE SPOFS, GUARDIAS SRE Y RIESGOS
  // ---------------------------------------------------------------------------
  Widget _buildLiveFindingsTab() {
    final allFindings = ((_overview['live_findings'] ?? const []) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final filtered = _findingSeverityFilter == 'all'
        ? allFindings
        : allFindings
            .where((f) => f['severity'] == _findingSeverityFilter)
            .toList();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in const [
                ('all', 'Todos los Hallazgos'),
                ('critical', 'Críticos (SPOF)'),
                ('high', 'Altos (SRE / Monitorización)'),
                ('warning', 'Advertencias'),
                ('info', 'Huecos Documentales'),
              ])
                ChoiceChip(
                  label: Text(entry.$2),
                  selected: _findingSeverityFilter == entry.$1,
                  onSelected: (_) =>
                      setState(() => _findingSeverityFilter = entry.$1),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: filtered.isEmpty
                ? const Center(
                    child: Text(
                      'No hay hallazgos registrados para el filtro seleccionado.',
                      style: TextStyle(color: AppPalette.slate500),
                    ),
                  )
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (ctx, idx) {
                      final f = filtered[idx];
                      final sev = (f['severity'] ?? 'info').toString();
                      final col = _severityColor(sev);
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border(
                            left: BorderSide(color: col, width: 4),
                            top: const BorderSide(color: AppPalette.slate200),
                            right: const BorderSide(color: AppPalette.slate200),
                            bottom:
                                const BorderSide(color: AppPalette.slate200),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: col.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                sev.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  color: col,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '[${f['category']}] ${f['target_code']} — ${f['title']}',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                      color: AppPalette.slate900,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    (f['detail'] ?? '').toString(),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppPalette.slate600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // PESTAÑA 3: COPILOTO CONVERSACIONAL SOLO-LECTURA
  // ---------------------------------------------------------------------------
  Widget _buildCopilotChatTab() {
    const quickPrompts = [
      '¿Qué puntos únicos de fallo (SPOF) físicos o de virtualización tiene hoy el CPD?',
      '¿Qué máquinas críticas de producción no tienen regla de guardia SRE activa?',
      'Resume el estado de los certificados TLS y cuáles caducan pronto.',
      'Redacta un plan rápido de verificación antes de apagar un Rack por mantenimiento.',
    ];

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppPalette.slate200),
        ),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: AppPalette.slate50,
                border: Border(bottom: BorderSide(color: AppPalette.slate200)),
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: quickPrompts
                    .map(
                      (p) => ActionChip(
                        avatar: const Icon(Icons.bolt_rounded, size: 15),
                        label: Text(p, style: const TextStyle(fontSize: 11.5)),
                        onPressed:
                            _sendingChat ? null : () => _sendChatQuestion(p),
                      ),
                    )
                    .toList(),
              ),
            ),
            Expanded(
              child: _chatMessages.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Pregunta en lenguaje natural sobre tus Racks, cableado, IPs, dependencias o riesgos SRE.\nEl Copiloto opera en modo 100% Solo-Lectura sobre el grafo real de RackDoc.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppPalette.slate500),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _chatMessages.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (ctx, i) {
                        final m = _chatMessages[i];
                        final isUser = m['role'] == 'user';
                        return Align(
                          alignment: isUser
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 780),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: isUser
                                  ? AppPalette.blue600
                                  : AppPalette.slate100,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (!isUser && (m['meta'] ?? '').isNotEmpty) ...[
                                  Text(
                                    m['meta']!,
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700,
                                      color: AppPalette.indigo600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                ],
                                Text(
                                  m['content'] ?? '',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    height: 1.45,
                                    color: isUser
                                        ? Colors.white
                                        : AppPalette.slate900,
                                  ),
                                ),
                                if (!isUser &&
                                    (m['content'] ?? '')
                                        .toLowerCase()
                                        .contains('```mermaid')) ...[
                                  const SizedBox(height: 10),
                                  SizedBox(
                                    height: 270,
                                    child: MermaidVisualViewer(
                                      mermaidCode: m['content'] ?? '',
                                      title: 'Diagrama Copiloto IA',
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppPalette.slate200)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _chatInputCtrl,
                      onSubmitted: (_) => _sendChatQuestion(),
                      decoration: const InputDecoration(
                        hintText:
                            'Pregunta al Agente IA sobre tu infraestructura (modo solo-lectura)...',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: _sendingChat ? null : () => _sendChatQuestion(),
                    icon: _sendingChat
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.send_rounded, size: 16),
                    label: Text(_sendingChat ? 'Consultando...' : 'Consultar'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // PESTAÑA 4: BANDEJA HUMAN-IN-THE-LOOP DE BORRADORES CMDB
  // ---------------------------------------------------------------------------
  Widget _buildSuggestionsTab() {
    final allSuggestions = ((_overview['suggestions'] ?? const []) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final filtered = _suggestionStatusFilter == 'all'
        ? allSuggestions
        : allSuggestions
            .where((s) => s['status'] == _suggestionStatusFilter)
            .toList();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final st in const [
                    ('pending', 'Pendientes de Revisión'),
                    ('applied', 'Aplicadas a CMDB'),
                    ('dismissed', 'Descartadas'),
                    ('all', 'Todas'),
                  ])
                    ChoiceChip(
                      label: Text(st.$2),
                      selected: _suggestionStatusFilter == st.$1,
                      onSelected: (_) =>
                          setState(() => _suggestionStatusFilter = st.$1),
                    ),
                ],
              ),
              const Spacer(),
              FilledButton.tonalIcon(
                onPressed: (!widget.canGenerateDocs || _scanningSuggestions)
                    ? null
                    : _scanSuggestionsNow,
                icon: _scanningSuggestions
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.radar_rounded, size: 17),
                label: Text(
                  _scanningSuggestions
                      ? 'Escaneando...'
                      : 'Escanear Huecos en CMDB',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: filtered.isEmpty
                ? const Center(
                    child: Text(
                      'No hay borradores CMDB en este estado. Pulsa "Escanear Huecos en CMDB" para analizar fichas vacías.',
                      style: TextStyle(color: AppPalette.slate500),
                    ),
                  )
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (ctx, idx) {
                      final s = filtered[idx];
                      final isPending = s['status'] == 'pending';
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppPalette.slate200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${s['asset_code']} — ${s['asset_name']}  ·  Campo: ${s['field_name']}',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                Text(
                                  'Confianza ${(s['confidence'] as num) * 100 ~/ 1}% · Estado: ${s['status']}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppPalette.slate500,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Motivo: ${s['rationale']}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: AppPalette.slate600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: AppPalette.green50,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: AppPalette.green300),
                              ),
                              child: Text(
                                'Propuesta IA: ${s['proposed_value']}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppPalette.slate900,
                                ),
                              ),
                            ),
                            if (isPending && widget.canEdit) ...[
                              const SizedBox(height: 10),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  OutlinedButton(
                                    onPressed: () =>
                                        _reviewSuggestion(s['id'] as int, false),
                                    child: const Text('Descartar'),
                                  ),
                                  const SizedBox(width: 8),
                                  FilledButton.icon(
                                    onPressed: () =>
                                        _reviewSuggestion(s['id'] as int, true),
                                    icon: const Icon(Icons.check, size: 16),
                                    label: const Text('Aplicar a Ficha CMDB'),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _KpiPill extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _KpiPill({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: AppPalette.slate700,
            ),
          ),
        ],
      ),
    );
  }
}
