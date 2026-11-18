part of '../network_hosts_view.dart';

/// Diálogos y tarjetas compartidas para:
/// 1. Gestión de Targets Prometheus / OpenTelemetry multipuerto, rutas a medida,
///    HTTP/HTTPS, modo Push OTLP y autodetección en vivo de firma (ej. ORA-TUI).
/// 2. Sistema dual de Plantillas Reutilizables (`TelemetryProfile`) + Gráficas
///    exclusivas por servidor (`AssetCustomChart`), con autocompletado de métricas
///    reales y previsualización PromQL en vivo.
extension _NetworkHostsTelemetryManagementExtension on _NetworkHostsViewState {
  static const List<Map<String, String>> _chartColorChoices = [
    {'hex': '#3B82F6', 'label': 'Azul'},
    {'hex': '#A855F7', 'label': 'Púrpura'},
    {'hex': '#14B8A6', 'label': 'Teal'},
    {'hex': '#F59E0B', 'label': 'Ámbar'},
    {'hex': '#EF4444', 'label': 'Rojo'},
    {'hex': '#06B6D4', 'label': 'Cyan'},
    {'hex': '#10B981', 'label': 'Verde'},
    {'hex': '#EC4899', 'label': 'Rosa'},
  ];

  IconData _profileIcon(String? key) {
    switch ((key ?? '').toLowerCase()) {
      case 'storage':
        return Icons.storage_rounded;
      case 'memory':
        return Icons.memory_rounded;
      case 'hub':
        return Icons.hub_rounded;
      case 'dns':
        return Icons.dns_rounded;
      default:
        return Icons.ssid_chart_rounded;
    }
  }

  Color _kpiSeverityColor(String? severity) {
    switch ((severity ?? '').toLowerCase()) {
      case 'ok':
        return AppTheme.success;
      case 'warning':
        return AppTheme.warning;
      case 'critical':
        return AppTheme.error;
      default:
        return AppTheme.textMuted;
    }
  }

  Widget _buildEvaluatedKpiStrip(List<Map<String, dynamic>> kpis) {
    if (kpis.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final kpi in kpis)
            Builder(
              builder: (context) {
                final col = _kpiSeverityColor(kpi['severity']?.toString());
                return Tooltip(
                  message: 'PromQL: ${kpi['promql'] ?? ''}',
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: col.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: col.withValues(alpha: 0.45)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: col,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${kpi['label'] ?? 'KPI'}: ',
                          style: const TextStyle(
                            fontSize: 10.2,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                        Text(
                          '${kpi['display_value'] ?? '-'}',
                          style: TextStyle(
                            fontSize: 10.8,
                            fontWeight: FontWeight.w900,
                            fontFamily: 'monospace',
                            color: col,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildEvaluatedPanelCard({
    required Map<String, dynamic> panel,
    Map<String, dynamic>? host,
    bool isCustomServerChart = false,
    double height = 252,
  }) {
    final series = ((panel['series'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final timeLabels = ((panel['time_labels'] as List?) ?? const [])
        .map((e) => '$e')
        .toList();
    final unit = (panel['unit'] ?? '').toString();
    final warnTh = (panel['warn_threshold'] as num?)?.toDouble();
    final critTh = (panel['crit_threshold'] as num?)?.toDouble();
    final promQl = (panel['promql_display'] ?? '').toString();
    final hasData = panel['has_data'] == true;

    double overallMax = 0.0;
    double overallAvg = 0.0;
    if (series.isNotEmpty) {
      overallMax = (series.first['max'] as num?)?.toDouble() ?? 0.0;
      overallAvg = (series.first['avg'] as num?)?.toDouble() ?? 0.0;
    }

    final rawCfg = panel['raw_config'] is Map
        ? Map<String, dynamic>.from(panel['raw_config'] as Map)
        : null;

    return Container(
      height: height,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${panel['title'] ?? 'Gráfica Prometheus'}',
                  style: const TextStyle(
                    fontSize: 11.4,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!hasData)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.textMuted.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'Sin muestras TSDB aún',
                    style: TextStyle(
                      fontSize: 9.0,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
              if (isCustomServerChart &&
                  widget.canEdit &&
                  host != null &&
                  rawCfg != null) ...[
                IconButton(
                  tooltip: 'Promover a Plantilla Reutilizable (múltiples servidores)',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  icon: const Icon(
                    Icons.ios_share_rounded,
                    size: 14.5,
                    color: AppTheme.accentCyan,
                  ),
                  onPressed: () =>
                      _showPromoteChartToProfileDialog(host, rawCfg),
                ),
                IconButton(
                  tooltip: 'Editar gráfica de este servidor',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  icon: const Icon(
                    Icons.edit_outlined,
                    size: 14.5,
                    color: AppTheme.accentBlue,
                  ),
                  onPressed: () => _showCreateOrEditChartDialog(
                    host,
                    existingCustomChart: rawCfg,
                  ),
                ),
                IconButton(
                  tooltip: 'Eliminar gráfica de este servidor',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    size: 14.5,
                    color: AppTheme.error,
                  ),
                  onPressed: () async {
                    final cid = rawCfg['id'] as int?;
                    if (cid == null) return;
                    try {
                      final res = await widget.api.deleteAssetCustomChart(cid);
                      if (!mounted) return;
                      if (res['telemetry'] is Map) {
                        _rebuildState(() {
                          _telemetryData = Map<String, dynamic>.from(
                            res['telemetry'] as Map,
                          );
                        });
                      }
                      _showSnack('Gráfica eliminada del servidor.');
                    } catch (e) {
                      _showSnack('Error al borrar gráfica: $e', isError: true);
                    }
                  },
                ),
              ],
            ],
          ),
          const SizedBox(height: 5),
          // Leyenda multi-serie compacta con valores actuales
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final s in series)
                  Builder(
                    builder: (context) {
                      final col = _parseTelemetryHexColor(
                        s['color_hex']?.toString(),
                        AppTheme.accentBlue,
                      );
                      final lastV =
                          ((s['last'] as num?)?.toDouble() ?? 0.0)
                              .toStringAsFixed(1);
                      return Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: col.withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          '${s['label']}: $lastV${unit.isEmpty ? '' : ' $unit'}',
                          style: TextStyle(
                            fontSize: 9.8,
                            fontWeight: FontWeight.w800,
                            color: col,
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: promQl,
                  child: Text(
                    'PromQL: $promQl',
                    style: const TextStyle(
                      fontSize: 9.2,
                      fontFamily: 'monospace',
                      color: AppTheme.textMuted,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Máx ${overallMax.toStringAsFixed(1)}$unit • Media ${overallAvg.toStringAsFixed(1)}$unit',
                style: const TextStyle(
                  fontSize: 9.0,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SizedBox(
              width: double.infinity,
              child: ClipRect(
                child: CustomPaint(
                  painter: _PrometheusMultiSeriesChartPainter(
                    timeLabels: timeLabels,
                    series: series,
                    unit: unit,
                    warnThreshold: warnTh,
                    critThreshold: critTh,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEvaluatedPanelsGrid({
    required List<Map<String, dynamic>> panels,
    required Map<String, dynamic> host,
    bool isCustomServerChart = false,
  }) {
    final rows = <Widget>[];
    for (int i = 0; i < panels.length; i += 2) {
      final first = panels[i];
      final second = (i + 1 < panels.length) ? panels[i + 1] : null;
      rows.add(
        Padding(
          padding: EdgeInsets.only(bottom: i + 2 < panels.length ? 12 : 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _buildEvaluatedPanelCard(
                  panel: first,
                  host: host,
                  isCustomServerChart: isCustomServerChart,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: second != null
                    ? _buildEvaluatedPanelCard(
                        panel: second,
                        host: host,
                        isCustomServerChart: isCustomServerChart,
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      );
    }
    return Column(children: rows);
  }

  // ===========================================================================
  // DIÁLOGO 1: GESTIÓN DE TARGETS PROMETHEUS / OPENTELEMETRY MULTIPUERTO & PROBE
  // ===========================================================================

  Future<void> _showManageTelemetryTargetsDialog(
    Map<String, dynamic> host,
  ) async {
    final assetId = host['id'] as int?;
    if (assetId == null) return;

    List<Map<String, dynamic>> targets = [];
    List<Map<String, dynamic>> presets = [];
    try {
      final res = await widget.api.getAssetTelemetryTargets(assetId);
      targets = ((res['targets'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      presets = ((res['presets'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      _showSnack('No se pudieron cargar los targets: $e', isError: true);
      return;
    }
    if (!mounted) return;

    int? editingTargetId;
    String selectedType = 'oratui_oracle';
    String mode = 'pull';
    String scheme = 'http';
    final nameCtrl = TextEditingController(
      text: 'ORA-TUI Oracle DB & Linux SAN',
    );
    final hostOverrideCtrl = TextEditingController(text: '');
    final portCtrl = TextEditingController(text: '9161');
    final pathCtrl = TextEditingController(text: '/metrics');
    final intervalCtrl = TextEditingController(text: '15s');
    final bearerCtrl = TextEditingController(text: '');
    bool enabled = true;
    bool busy = false;
    Map<String, dynamic>? probeBanner;

    void applyPreset(String expType, StateSetter setModal) {
      final pr = presets.firstWhere(
        (p) => p['exporter_type'] == expType,
        orElse: () => <String, dynamic>{},
      );
      setModal(() {
        selectedType = expType;
        if (editingTargetId == null && pr.isNotEmpty) {
          nameCtrl.text = '${pr['label'] ?? expType}';
          portCtrl.text = '${pr['default_port'] ?? 9100}';
          pathCtrl.text = '${pr['default_path'] ?? '/metrics'}';
          scheme = '${pr['default_scheme'] ?? 'http'}';
          mode = '${pr['default_mode'] ?? 'pull'}';
        }
      });
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) {
          final otlpPushUrl =
              '${widget.api.baseUrl}/automation/otlp/v1/metrics?asset_code=${host['code']}';

          return AlertDialog(
            backgroundColor: AppTheme.bgCard,
            title: Row(
              children: [
                const Icon(
                  Icons.settings_input_antenna_rounded,
                  color: AppTheme.accentCyan,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Targets Prometheus & OpenTelemetry — ${host['code']} (${host['heartbeat_ip'] ?? 'sin IP'})',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
            content: SizedBox(
              width: 840,
              height: 580,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Configura en qué puertos, rutas o esquemas (HTTP/HTTPS) expone métricas esta máquina (por ejemplo ORA-TUI en :9161 o en otro puerto custom, OpenTelemetry Collector en :8889, o Push OTLP). Prometheus recarga targets_dynamic.json cada 15 s sin reiniciarse.',
                      style: TextStyle(
                        fontSize: 11.2,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Lista de endpoints ya configurados en el servidor
                    Text(
                      'ENDPOINTS CONFIGURADOS EN ESTE SERVIDOR (${targets.length})',
                      style: const TextStyle(
                        fontSize: 10.8,
                        fontWeight: FontWeight.w900,
                        color: AppTheme.accentCyan,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (targets.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.bgPrimary,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.border),
                        ),
                        child: const Text(
                          'No hay endpoints personalizados dados de alta todavía. Usa el formulario inferior para añadir ORA-TUI (:9161 o puerto a medida), OTel Collector o cualquier exporter.',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      )
                    else
                      for (final t in targets)
                        Container(
                          margin: const EdgeInsets.only(bottom: 7),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.bgPrimary,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: editingTargetId == t['id']
                                  ? AppTheme.accentBlue
                                  : AppTheme.border,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.circle,
                                size: 9,
                                color: t['last_probe_status'] == 'ok'
                                    ? AppTheme.success
                                    : (t['last_probe_status'] == 'error'
                                          ? AppTheme.error
                                          : AppTheme.textMuted),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${t['name']}  [${t['exporter_type']}]',
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    Text(
                                      '${t['endpoint_preview']} • Intervalo ${t['scrape_interval']}',
                                      style: const TextStyle(
                                        fontSize: 10.2,
                                        fontFamily: 'monospace',
                                        color: AppTheme.accentTeal,
                                      ),
                                    ),
                                    if ((t['last_probe_summary'] ?? '')
                                        .toString()
                                        .isNotEmpty)
                                      Text(
                                        '${t['last_probe_summary']}',
                                        style: const TextStyle(
                                          fontSize: 9.8,
                                          color: AppTheme.textSecondary,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (t['mode'] == 'pull')
                                OutlinedButton.icon(
                                  onPressed: busy
                                      ? null
                                      : () async {
                                          setModal(() => busy = true);
                                          try {
                                            final pr = await widget.api
                                                .probeTelemetryTarget({
                                                  'target_id': t['id'],
                                                  'asset_id': assetId,
                                                });
                                            final refreshed = await widget.api
                                                .getAssetTelemetryTargets(
                                                  assetId,
                                                );
                                            setModal(() {
                                              targets =
                                                  ((refreshed['targets']
                                                              as List?) ??
                                                          const [])
                                                      .map(
                                                        (e) =>
                                                            Map<
                                                              String,
                                                              dynamic
                                                            >.from(e as Map),
                                                      )
                                                      .toList();
                                              probeBanner = pr;
                                              busy = false;
                                            });
                                          } catch (e) {
                                            setModal(() => busy = false);
                                            _showSnack(
                                              'Error al probar target: $e',
                                              isError: true,
                                            );
                                          }
                                        },
                                  icon: const Icon(Icons.radar, size: 13),
                                  label: const Text(
                                    'Probar',
                                    style: TextStyle(fontSize: 10.5),
                                  ),
                                ),
                              if (widget.canEdit) ...[
                                const SizedBox(width: 6),
                                IconButton(
                                  tooltip: 'Editar puerto / ruta',
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 16,
                                    color: AppTheme.accentBlue,
                                  ),
                                  onPressed: () {
                                    setModal(() {
                                      editingTargetId = t['id'] as int?;
                                      nameCtrl.text = '${t['name'] ?? ''}';
                                      selectedType =
                                          '${t['exporter_type'] ?? 'custom_prometheus'}';
                                      mode = '${t['mode'] ?? 'pull'}';
                                      scheme = '${t['scheme'] ?? 'http'}';
                                      hostOverrideCtrl.text =
                                          '${t['target_host'] ?? ''}';
                                      portCtrl.text = '${t['port'] ?? 9100}';
                                      pathCtrl.text =
                                          '${t['metrics_path'] ?? '/metrics'}';
                                      intervalCtrl.text =
                                          '${t['scrape_interval'] ?? '15s'}';
                                      enabled = t['enabled'] != false;
                                    });
                                  },
                                ),
                                IconButton(
                                  tooltip: 'Eliminar target',
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 16,
                                    color: AppTheme.error,
                                  ),
                                  onPressed: busy
                                      ? null
                                      : () async {
                                          setModal(() => busy = true);
                                          try {
                                            final delRes = await widget.api
                                                .deleteAssetTelemetryTarget(
                                                  t['id'] as int,
                                                );
                                            final refreshed = await widget.api
                                                .getAssetTelemetryTargets(
                                                  assetId,
                                                );
                                            if (delRes['telemetry'] is Map &&
                                                mounted) {
                                              _rebuildState(() {
                                                _telemetryData =
                                                    Map<String, dynamic>.from(
                                                      delRes['telemetry']
                                                          as Map,
                                                    );
                                              });
                                            }
                                            setModal(() {
                                              targets =
                                                  ((refreshed['targets']
                                                              as List?) ??
                                                          const [])
                                                      .map(
                                                        (e) =>
                                                            Map<
                                                              String,
                                                              dynamic
                                                            >.from(e as Map),
                                                      )
                                                      .toList();
                                              busy = false;
                                            });
                                            _loadOverview(silent: true);
                                          } catch (e) {
                                            setModal(() => busy = false);
                                            _showSnack(
                                              'Error al eliminar: $e',
                                              isError: true,
                                            );
                                          }
                                        },
                                ),
                              ],
                            ],
                          ),
                        ),

                    if (widget.canEdit) ...[
                      const Divider(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            editingTargetId == null
                                ? 'AÑADIR NUEVO ENDPOINT PROMETHEUS / OPENTELEMETRY'
                                : 'EDITANDO ENDPOINT #$editingTargetId',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              color: AppTheme.accentBlue,
                            ),
                          ),
                          if (editingTargetId != null)
                            TextButton(
                              onPressed: () => setModal(() {
                                editingTargetId = null;
                                applyPreset('oratui_oracle', setModal);
                              }),
                              child: const Text('Cancelar edición'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: DropdownButtonFormField<String>(
                              key: ValueKey('preset_$selectedType'),
                              initialValue: presets.any(
                                    (p) => p['exporter_type'] == selectedType,
                                  )
                                  ? selectedType
                                  : 'custom_prometheus',
                              decoration: const InputDecoration(
                                labelText: 'Agente / Plantilla Rápida',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                              items: [
                                for (final p in presets)
                                  DropdownMenuItem<String>(
                                    value: '${p['exporter_type']}',
                                    child: Text(
                                      '${p['label']}',
                                      style: const TextStyle(fontSize: 11.5),
                                    ),
                                  ),
                              ],
                              onChanged: (v) {
                                if (v != null) applyPreset(v, setModal);
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: DropdownButtonFormField<String>(
                              key: ValueKey('mode_$mode'),
                              initialValue: mode,
                              decoration: const InputDecoration(
                                labelText: 'Modo de Ingesta',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'pull',
                                  child: Text(
                                    'Pull (Prometheus raspa :puerto)',
                                    style: TextStyle(fontSize: 11.5),
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'push_otlp',
                                  child: Text(
                                    'Push OTLP (Agente envía HTTP)',
                                    style: TextStyle(fontSize: 11.5),
                                  ),
                                ),
                              ],
                              onChanged: (v) =>
                                  setModal(() => mode = v ?? 'pull'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: nameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Nombre descriptivo del Endpoint',
                          hintText:
                              'Ej: ORA-TUI Oracle Instancia PROD (:9261)',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (mode == 'push_otlp')
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.bgPrimary,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.accentTeal),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Configura tu OpenTelemetry Collector remoto (otlphttp exporter) apuntando a:',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              SelectableText(
                                'POST $otlpPushUrl\nHeader: X-API-Key: <AUTOMATION_API_KEY>',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                  color: AppTheme.accentCyan,
                                ),
                              ),
                            ],
                          ),
                        )
                      else ...[
                        Row(
                          children: [
                            SizedBox(
                              width: 105,
                              child: DropdownButtonFormField<String>(
                                key: ValueKey('sch_$scheme'),
                                initialValue: scheme,
                                decoration: const InputDecoration(
                                  labelText: 'Esquema',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'http',
                                    child: Text('HTTP'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'https',
                                    child: Text('HTTPS'),
                                  ),
                                ],
                                onChanged: (v) =>
                                    setModal(() => scheme = v ?? 'http'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: hostOverrideCtrl,
                                decoration: InputDecoration(
                                  labelText:
                                      'IP / Host (vacío = ${host['heartbeat_ip'] ?? 'IP primaria'})',
                                  isDense: true,
                                  border: const OutlineInputBorder(),
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
                                  labelText: 'Puerto',
                                  hintText: '9161',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: pathCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Ruta Métricas',
                                  hintText: '/metrics',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 88,
                              child: TextField(
                                controller: intervalCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Scrape',
                                  hintText: '15s',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: bearerCtrl,
                                obscureText: true,
                                decoration: const InputDecoration(
                                  labelText:
                                      'Token Bearer de autenticación (opcional, cifrado en baúl)',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            OutlinedButton.icon(
                              onPressed: busy
                                  ? null
                                  : () async {
                                      setModal(() => busy = true);
                                      try {
                                        final pr = await widget.api
                                            .probeTelemetryTarget({
                                              'asset_id': assetId,
                                              'target_host': hostOverrideCtrl
                                                  .text
                                                  .trim(),
                                              'port':
                                                  int.tryParse(
                                                    portCtrl.text.trim(),
                                                  ) ??
                                                  9161,
                                              'metrics_path': pathCtrl.text
                                                  .trim(),
                                              'scheme': scheme,
                                              if (bearerCtrl.text
                                                  .trim()
                                                  .isNotEmpty)
                                                'bearer_token': bearerCtrl.text
                                                    .trim(),
                                            });
                                        setModal(() {
                                          probeBanner = pr;
                                          if (pr['ok'] == true &&
                                              pr['detected_exporter_type'] !=
                                                  null) {
                                            selectedType =
                                                '${pr['detected_exporter_type']}';
                                          }
                                          busy = false;
                                        });
                                      } catch (e) {
                                        setModal(() => busy = false);
                                        _showSnack(
                                          'Fallo al sondear: $e',
                                          isError: true,
                                        );
                                      }
                                    },
                              icon: const Icon(Icons.radar_rounded, size: 16),
                              label: const Text(
                                'Probar & Autodetectar Firma',
                              ),
                            ),
                          ],
                        ),
                      ],

                      if (probeBanner != null) ...[
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: (probeBanner!['ok'] == true
                                    ? AppTheme.success
                                    : AppTheme.error)
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: probeBanner!['ok'] == true
                                  ? AppTheme.success
                                  : AppTheme.error,
                            ),
                          ),
                          child: Text(
                            '${probeBanner!['summary'] ?? ''}'
                            '${probeBanner!['suggested_profile_code'] != null ? ' ➔ Plantilla activa: ${probeBanner!['suggested_profile_code']}' : ''}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: probeBanner!['ok'] == true
                                  ? AppTheme.success
                                  : AppTheme.error,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cerrar'),
              ),
              if (widget.canEdit)
                ElevatedButton.icon(
                  onPressed: busy
                      ? null
                      : () async {
                          setModal(() => busy = true);
                          final payload = <String, dynamic>{
                            'name': nameCtrl.text.trim().isEmpty
                                ? 'Target $selectedType'
                                : nameCtrl.text.trim(),
                            'exporter_type': selectedType,
                            'mode': mode,
                            'target_host': hostOverrideCtrl.text.trim(),
                            'port': int.tryParse(portCtrl.text.trim()) ?? 9100,
                            'metrics_path': pathCtrl.text.trim().isEmpty
                                ? '/metrics'
                                : pathCtrl.text.trim(),
                            'scheme': scheme,
                            'scrape_interval': intervalCtrl.text.trim().isEmpty
                                ? '15s'
                                : intervalCtrl.text.trim(),
                            if (bearerCtrl.text.trim().isNotEmpty)
                              'bearer_token': bearerCtrl.text.trim(),
                            'enabled': enabled,
                            'auto_probe': mode == 'pull',
                          };
                          try {
                            final Map<String, dynamic> saveRes;
                            if (editingTargetId != null) {
                              saveRes = await widget.api
                                  .updateAssetTelemetryTarget(
                                    editingTargetId!,
                                    payload,
                                  );
                            } else {
                              saveRes = await widget.api
                                  .createAssetTelemetryTarget(assetId, payload);
                            }
                            final refreshed = await widget.api
                                .getAssetTelemetryTargets(assetId);
                            if (saveRes['telemetry'] is Map && mounted) {
                              final telMap = Map<String, dynamic>.from(
                                saveRes['telemetry'] as Map,
                              );
                              _rebuildState(() {
                                _telemetryData = telMap;
                                final savedExp =
                                    (saveRes['target'] as Map?)?['exporter_type']
                                        ?.toString();
                                if (savedExp == 'oratui_oracle') {
                                  _selectedTelemetryTabKey = 'oratui_oracle';
                                }
                              });
                            }
                            setModal(() {
                              targets = ((refreshed['targets'] as List?) ??
                                      const [])
                                  .map(
                                    (e) =>
                                        Map<String, dynamic>.from(e as Map),
                                  )
                                  .toList();
                              editingTargetId = null;
                              probeBanner = saveRes['probe'] is Map
                                  ? Map<String, dynamic>.from(
                                      saveRes['probe'] as Map,
                                    )
                                  : null;
                              busy = false;
                            });
                            _loadOverview(silent: true);
                            _showSnack(
                              'Target guardado y sincronizado en targets_dynamic.json.',
                            );
                          } catch (e) {
                            setModal(() => busy = false);
                            _showSnack(
                              'Error al guardar target: $e',
                              isError: true,
                            );
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accentBlue,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.save_rounded, size: 16),
                  label: Text(
                    editingTargetId == null
                        ? 'Guardar en Prometheus SD'
                        : 'Actualizar Target',
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  // ===========================================================================
  // DIÁLOGO 2: CREADOR / EDITOR DUAL (POR SERVIDOR O PLANTILLA REUTILIZABLE)
  // ===========================================================================

  Future<void> _showCreateOrEditChartDialog(
    Map<String, dynamic> host, {
    Map<String, dynamic>? existingCustomChart,
  }) async {
    final assetId = host['id'] as int?;
    if (assetId == null) return;

    List<Map<String, dynamic>> availableMetrics = [];
    List<Map<String, dynamic>> profilesCatalog =
        ((_telemetryData?['all_profiles_catalog'] as List?) ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();

    try {
      final availRes = await widget.api.getAssetAvailableMetrics(assetId);
      availableMetrics = ((availRes['metrics'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (profilesCatalog.isEmpty) {
        final prRes = await widget.api.getTelemetryProfiles();
        profilesCatalog = ((prRes['profiles'] as List?) ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }
    } catch (_) {}
    if (!mounted) return;

    final isEditingServerChart = existingCustomChart != null;
    // scopeMode: 'server_only' | 'existing_profile' | 'new_profile'
    String scopeMode = 'server_only';
    int? targetProfileId = profilesCatalog.isNotEmpty
        ? (profilesCatalog.first['id'] as int?)
        : null;
    final newProfileNameCtrl = TextEditingController(
      text: 'Plantilla ${host['code']}',
    );

    final titleCtrl = TextEditingController(
      text: '${existingCustomChart?['title'] ?? ''}',
    );
    final unitCtrl = TextEditingController(
      text: '${existingCustomChart?['unit'] ?? '%'}',
    );
    final legendLabelCtrl = TextEditingController(
      text: '${existingCustomChart?['legend_label'] ?? ''}',
    );
    final warnCtrl = TextEditingController(
      text: existingCustomChart?['warn_threshold'] != null
          ? '${existingCustomChart!['warn_threshold']}'
          : '',
    );
    final critCtrl = TextEditingController(
      text: existingCustomChart?['crit_threshold'] != null
          ? '${existingCustomChart!['crit_threshold']}'
          : '',
    );
    final promqlACtrl = TextEditingController(
      text: '${existingCustomChart?['promql_a'] ?? ''}',
    );
    final labelACtrl = TextEditingController(
      text: '${existingCustomChart?['label_a'] ?? 'Serie Principal'}',
    );
    String colorA = '${existingCustomChart?['color_a'] ?? '#3B82F6'}';

    final promqlBCtrl = TextEditingController(
      text: '${existingCustomChart?['promql_b'] ?? ''}',
    );
    final labelBCtrl = TextEditingController(
      text: '${existingCustomChart?['label_b'] ?? ''}',
    );
    String colorB = '${existingCustomChart?['color_b'] ?? '#A855F7'}';

    String metricFilter = '';
    bool busy = false;
    Map<String, dynamic>? previewPanel;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) {
          final filteredMetrics = availableMetrics.where((m) {
            if (metricFilter.trim().isEmpty) return true;
            return '${m['name']}'.toLowerCase().contains(
              metricFilter.trim().toLowerCase(),
            );
          }).take(40).toList();

          return AlertDialog(
            backgroundColor: AppTheme.bgCard,
            title: Row(
              children: [
                const Icon(
                  Icons.add_chart_rounded,
                  color: AppTheme.accentBlue,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isEditingServerChart
                        ? 'Editar Gráfica de ${host['code']}'
                        : 'Nueva Gráfica Prometheus — Servidor o Plantilla Reutilizable',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
            content: SizedBox(
              width: 860,
              height: 610,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. Selección de Ámbito (Solo este servidor vs Plantilla Reutilizable)
                    if (!isEditingServerChart) ...[
                      const Text(
                        '1. ¿DÓNDE QUIERES GUARDAR ESTA GRÁFICA?',
                        style: TextStyle(
                          fontSize: 10.8,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.accentCyan,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          ChoiceChip(
                            label: Text(
                              'Solo en este servidor (${host['code']})',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            selected: scopeMode == 'server_only',
                            onSelected: (_) =>
                                setModal(() => scopeMode = 'server_only'),
                          ),
                          ChoiceChip(
                            label: const Text(
                              'Añadir a Plantilla Reutilizable existente',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            selected: scopeMode == 'existing_profile',
                            onSelected: (_) =>
                                setModal(() => scopeMode = 'existing_profile'),
                          ),
                          ChoiceChip(
                            label: const Text(
                              '+ Crear Nueva Plantilla Reutilizable',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            selected: scopeMode == 'new_profile',
                            onSelected: (_) =>
                                setModal(() => scopeMode = 'new_profile'),
                          ),
                        ],
                      ),
                      if (scopeMode == 'existing_profile' &&
                          profilesCatalog.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        DropdownButtonFormField<int>(
                          key: ValueKey('prof_$targetProfileId'),
                          initialValue: targetProfileId,
                          decoration: const InputDecoration(
                            labelText: 'Plantilla Reutilizable destino',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final p in profilesCatalog)
                              DropdownMenuItem<int>(
                                value: p['id'] as int,
                                child: Text(
                                  '${p['name']} (${p['panels_count'] ?? 0} paneles)',
                                  style: const TextStyle(fontSize: 11.5),
                                ),
                              ),
                          ],
                          onChanged: (v) =>
                              setModal(() => targetProfileId = v),
                        ),
                      ],
                      if (scopeMode == 'new_profile') ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: newProfileNameCtrl,
                          decoration: const InputDecoration(
                            labelText:
                                'Nombre de la Nueva Plantilla Reutilizable (se asignará a este servidor y podrás activarla en otros)',
                            hintText: 'Ej: Cluster Oracle Financiero / JVM Apps',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                      const Divider(height: 20),
                    ],

                    // 2. Autocompletado de métricas reales expuestas por el servidor
                    Text(
                      '2. MÉTRICAS REALES DETECTADAS EN ${host['code']} (${availableMetrics.length} disponibles — pulsa para insertar)',
                      style: const TextStyle(
                        fontSize: 10.8,
                        fontWeight: FontWeight.w900,
                        color: AppTheme.accentCyan,
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      onChanged: (v) => setModal(() => metricFilter = v),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search, size: 16),
                        hintText:
                            'Filtrar métricas del servidor (ej. oratui_tablespace, sessions, node_disk, jvm...)',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (filteredMetrics.isNotEmpty)
                      Container(
                        constraints: const BoxConstraints(maxHeight: 88),
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: AppTheme.bgPrimary,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.border),
                        ),
                        child: SingleChildScrollView(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 5,
                            children: [
                              for (final m in filteredMetrics)
                                ActionChip(
                                  visualDensity: VisualDensity.compact,
                                  label: Text(
                                    '${m['name']}',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  onPressed: () {
                                    final expr =
                                        '${m['suggested_promql'] ?? '${m['name']}{asset_code="{{asset_code}}"}'}';
                                    final lbls =
                                        ((m['labels'] as List?) ?? const [])
                                            .map((e) => '$e')
                                            .toList();
                                    setModal(() {
                                      if (promqlACtrl.text.trim().isEmpty) {
                                        promqlACtrl.text = expr;
                                        if (titleCtrl.text.trim().isEmpty) {
                                          titleCtrl.text = '${m['name']}';
                                        }
                                      } else {
                                        promqlBCtrl.text = expr;
                                        if (labelBCtrl.text.trim().isEmpty) {
                                          labelBCtrl.text = 'Serie B';
                                        }
                                      }
                                      for (final cand in [
                                        'tablespace',
                                        'diskgroup',
                                        'mountpoint',
                                        'datname',
                                        'instance',
                                      ]) {
                                        if (lbls.contains(cand) &&
                                            legendLabelCtrl.text
                                                .trim()
                                                .isEmpty) {
                                          legendLabelCtrl.text = cand;
                                          break;
                                        }
                                      }
                                    });
                                  },
                                ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),

                    // 3. Definición del panel y expresiones PromQL
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: TextField(
                            controller: titleCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Título de la Gráfica',
                              hintText:
                                  'Ej: Ocupación Tablespaces Críticos (%)',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 90,
                          child: TextField(
                            controller: unitCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Unidad',
                              hintText: '%, ms, MB/s',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 95,
                          child: TextField(
                            controller: warnCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Warn >=',
                              hintText: '85',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 95,
                          child: TextField(
                            controller: critCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Crit >=',
                              hintText: '92',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          flex: 4,
                          child: TextField(
                            controller: promqlACtrl,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                            ),
                            decoration: const InputDecoration(
                              labelText:
                                  'Expresión PromQL Serie A (usa {{asset_code}} para reutilizar en varios servidores)',
                              hintText:
                                  'topk(5, oratui_tablespace_used_percent{asset_code="{{asset_code}}"})',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 130,
                          child: TextField(
                            controller: labelACtrl,
                            decoration: const InputDecoration(
                              labelText: 'Etiqueta A',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 115,
                          child: DropdownButtonFormField<String>(
                            key: ValueKey('colA_$colorA'),
                            initialValue: _chartColorChoices.any(
                                  (c) => c['hex'] == colorA,
                                )
                                ? colorA
                                : '#3B82F6',
                            decoration: const InputDecoration(
                              labelText: 'Color A',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              for (final c in _chartColorChoices)
                                DropdownMenuItem(
                                  value: c['hex'],
                                  child: Text(
                                    c['label']!,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                            ],
                            onChanged: (v) =>
                                setModal(() => colorA = v ?? '#3B82F6'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          flex: 4,
                          child: TextField(
                            controller: promqlBCtrl,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Expresión PromQL Serie B (opcional)',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 130,
                          child: TextField(
                            controller: labelBCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Etiqueta B',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 115,
                          child: DropdownButtonFormField<String>(
                            key: ValueKey('colB_$colorB'),
                            initialValue: _chartColorChoices.any(
                                  (c) => c['hex'] == colorB,
                                )
                                ? colorB
                                : '#A855F7',
                            decoration: const InputDecoration(
                              labelText: 'Color B',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              for (final c in _chartColorChoices)
                                DropdownMenuItem(
                                  value: c['hex'],
                                  child: Text(
                                    c['label']!,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                            ],
                            onChanged: (v) =>
                                setModal(() => colorB = v ?? '#A855F7'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: legendLabelCtrl,
                            decoration: const InputDecoration(
                              labelText:
                                  'Etiqueta multi-serie dinámica (opcional, ej: tablespace, diskgroup, mountpoint, instance)',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () async {
                                  if (promqlACtrl.text.trim().isEmpty) return;
                                  setModal(() => busy = true);
                                  try {
                                    final pr = await widget.api
                                        .previewAssetTelemetryQuery(assetId, {
                                          'promql_a': promqlACtrl.text.trim(),
                                          'label_a': labelACtrl.text.trim(),
                                          'color_a': colorA,
                                          'promql_b': promqlBCtrl.text.trim(),
                                          'label_b': labelBCtrl.text.trim(),
                                          'color_b': colorB,
                                          'legend_label': legendLabelCtrl.text
                                              .trim(),
                                          'unit': unitCtrl.text.trim(),
                                          'range_hours': _telemetryRangeHours,
                                        });
                                    setModal(() {
                                      previewPanel = pr['panel'] is Map
                                          ? Map<String, dynamic>.from(
                                              pr['panel'] as Map,
                                            )
                                          : null;
                                      busy = false;
                                    });
                                  } catch (e) {
                                    setModal(() => busy = false);
                                    _showSnack(
                                      'Error en previsualización: $e',
                                      isError: true,
                                    );
                                  }
                                },
                          icon: const Icon(Icons.visibility_rounded, size: 16),
                          label: const Text('Previsualizar en Vivo'),
                        ),
                      ],
                    ),

                    if (previewPanel != null) ...[
                      const SizedBox(height: 12),
                      _buildEvaluatedPanelCard(
                        panel: previewPanel!,
                        height: 200,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar'),
              ),
              ElevatedButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        if (titleCtrl.text.trim().isEmpty ||
                            promqlACtrl.text.trim().isEmpty) {
                          _showSnack(
                            'Indica título y expresión PromQL principal.',
                            isError: true,
                          );
                          return;
                        }
                        setModal(() => busy = true);
                        final warnVal = double.tryParse(warnCtrl.text.trim());
                        final critVal = double.tryParse(critCtrl.text.trim());

                        try {
                          if (isEditingServerChart) {
                            final cid = existingCustomChart['id'] as int;
                            final res = await widget.api.updateAssetCustomChart(
                              cid,
                              {
                                'title': titleCtrl.text.trim(),
                                'unit': unitCtrl.text.trim(),
                                'chart_type':
                                    legendLabelCtrl.text.trim().isNotEmpty
                                        ? 'multi_line'
                                        : 'line',
                                'promql_a': promqlACtrl.text.trim(),
                                'label_a': labelACtrl.text.trim(),
                                'color_a': colorA,
                                'promql_b': promqlBCtrl.text.trim(),
                                'label_b': labelBCtrl.text.trim(),
                                'color_b': colorB,
                                'legend_label': legendLabelCtrl.text.trim(),
                                'warn_threshold': warnVal,
                                'crit_threshold': critVal,
                                'enabled': true,
                              },
                            );
                            if (res['telemetry'] is Map && mounted) {
                              _rebuildState(() {
                                _telemetryData = Map<String, dynamic>.from(
                                  res['telemetry'] as Map,
                                );
                              });
                            }
                          } else if (scopeMode == 'server_only') {
                            final res = await widget.api.createAssetCustomChart(
                              assetId,
                              {
                                'title': titleCtrl.text.trim(),
                                'unit': unitCtrl.text.trim(),
                                'chart_type':
                                    legendLabelCtrl.text.trim().isNotEmpty
                                        ? 'multi_line'
                                        : 'line',
                                'promql_a': promqlACtrl.text.trim(),
                                'label_a': labelACtrl.text.trim(),
                                'color_a': colorA,
                                'promql_b': promqlBCtrl.text.trim(),
                                'label_b': labelBCtrl.text.trim(),
                                'color_b': colorB,
                                'legend_label': legendLabelCtrl.text.trim(),
                                'warn_threshold': warnVal,
                                'crit_threshold': critVal,
                                'enabled': true,
                              },
                            );
                            if (res['telemetry'] is Map && mounted) {
                              _rebuildState(() {
                                _telemetryData = Map<String, dynamic>.from(
                                  res['telemetry'] as Map,
                                );
                                _selectedTelemetryTabKey = '__custom_server__';
                              });
                            }
                          } else {
                            final queries = <Map<String, dynamic>>[
                              {
                                'label': labelACtrl.text.trim().isEmpty
                                    ? 'Serie A'
                                    : labelACtrl.text.trim(),
                                'promql': promqlACtrl.text.trim(),
                                'color_hex': colorA,
                              },
                            ];
                            if (promqlBCtrl.text.trim().isNotEmpty) {
                              queries.add({
                                'label': labelBCtrl.text.trim().isEmpty
                                    ? 'Serie B'
                                    : labelBCtrl.text.trim(),
                                'promql': promqlBCtrl.text.trim(),
                                'color_hex': colorB,
                              });
                            }
                            final newPanel = <String, dynamic>{
                              'id':
                                  'panel_${DateTime.now().millisecondsSinceEpoch}',
                              'title': titleCtrl.text.trim(),
                              'unit': unitCtrl.text.trim(),
                              'chart_type':
                                  legendLabelCtrl.text.trim().isNotEmpty
                                      ? 'multi_line'
                                      : 'line',
                              'warn_threshold': warnVal,
                              'crit_threshold': critVal,
                              'legend_label': legendLabelCtrl.text.trim(),
                              'queries': queries,
                            };

                            if (scopeMode == 'existing_profile' &&
                                targetProfileId != null) {
                              final existingProf = profilesCatalog.firstWhere(
                                (p) => p['id'] == targetProfileId,
                              );
                              final updatedPanels = [
                                ...((existingProf['panels'] as List?) ??
                                    const []),
                                newPanel,
                              ];
                              final assignedAssets = <int>{
                                ...((existingProf['assigned_asset_ids']
                                            as List?) ??
                                        const [])
                                    .map((e) => (e as num).toInt()),
                                assetId,
                              }.toList();
                              final upRes = await widget.api
                                  .updateTelemetryProfile(targetProfileId!, {
                                    'name': existingProf['name'],
                                    'description':
                                        existingProf['description'] ?? '',
                                    'icon_key':
                                        existingProf['icon_key'] ?? 'analytics',
                                    'auto_match_exporter_types':
                                        existingProf['auto_match_exporter_types'] ??
                                        const [],
                                    'assigned_asset_ids': assignedAssets,
                                    'assigned_host_group_ids':
                                        existingProf['assigned_host_group_ids'] ??
                                        const [],
                                    'kpi_badges':
                                        existingProf['kpi_badges'] ?? const [],
                                    'panels': updatedPanels,
                                  });
                              final savedCode =
                                  (upRes['profile'] as Map?)?['code']
                                      ?.toString();
                              await _loadHostTelemetry(assetId);
                              if (savedCode != null && mounted) {
                                _rebuildState(
                                  () => _selectedTelemetryTabKey = savedCode,
                                );
                              }
                            } else {
                              final crRes = await widget.api
                                  .createTelemetryProfile({
                                    'name':
                                        newProfileNameCtrl.text.trim().isEmpty
                                        ? 'Plantilla ${host['code']}'
                                        : newProfileNameCtrl.text.trim(),
                                    'description':
                                        'Plantilla reutilizable creada desde ${host['code']}.',
                                    'icon_key': 'analytics',
                                    'assigned_asset_ids': [assetId],
                                    'panels': [newPanel],
                                  });
                              final savedCode =
                                  (crRes['profile'] as Map?)?['code']
                                      ?.toString();
                              await _loadHostTelemetry(assetId);
                              if (savedCode != null && mounted) {
                                _rebuildState(
                                  () => _selectedTelemetryTabKey = savedCode,
                                );
                              }
                            }
                          }
                          if (ctx.mounted) Navigator.pop(ctx);
                          _showSnack('Gráfica guardada correctamente.');
                        } catch (e) {
                          setModal(() => busy = false);
                          _showSnack(
                            'Error al guardar gráfica: $e',
                            isError: true,
                          );
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentBlue,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.save_rounded, size: 16),
                label: const Text('Guardar Gráfica'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ===========================================================================
  // DIÁLOGO 3: PROMOVER GRÁFICA INDIVIDUAL A PLANTILLA REUTILIZABLE
  // ===========================================================================

  Future<void> _showPromoteChartToProfileDialog(
    Map<String, dynamic> host,
    Map<String, dynamic> rawChart,
  ) async {
    final chartId = rawChart['id'] as int?;
    if (chartId == null) return;

    final profilesCatalog =
        ((_telemetryData?['all_profiles_catalog'] as List?) ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();

    bool createNew = true;
    int? selectedProfId = profilesCatalog.isNotEmpty
        ? (profilesCatalog.first['id'] as int?)
        : null;
    final newNameCtrl = TextEditingController(
      text: 'Pack Compartido ${host['code']}',
    );
    bool busy = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          backgroundColor: AppTheme.bgCard,
          title: Text(
            'Promover «${rawChart['title']}» a Plantilla Reutilizable',
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w900),
          ),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Convierte esta gráfica individual en parte de una Plantilla Reutilizable (reemplazando automáticamente el código literal del servidor por {{asset_code}}) para aplicarla a cualquier otra máquina.',
                  style: TextStyle(fontSize: 11.2, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Crear nueva plantilla'),
                      selected: createNew,
                      onSelected: (_) => setModal(() => createNew = true),
                    ),
                    if (profilesCatalog.isNotEmpty)
                      ChoiceChip(
                        label: const Text('Añadir a plantilla existente'),
                        selected: !createNew,
                        onSelected: (_) => setModal(() => createNew = false),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (createNew)
                  TextField(
                    controller: newNameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Nombre de la nueva plantilla reutilizable',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  )
                else
                  DropdownButtonFormField<int>(
                    key: ValueKey('prom_prof_$selectedProfId'),
                    initialValue: selectedProfId,
                    decoration: const InputDecoration(
                      labelText: 'Plantilla destino',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final p in profilesCatalog)
                        DropdownMenuItem<int>(
                          value: p['id'] as int,
                          child: Text('${p['name']}'),
                        ),
                    ],
                    onChanged: (v) => setModal(() => selectedProfId = v),
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
              onPressed: busy
                  ? null
                  : () async {
                      setModal(() => busy = true);
                      try {
                        final res = await widget.api
                            .promoteCustomChartToProfile(chartId, {
                              if (!createNew && selectedProfId != null)
                                'target_profile_id': selectedProfId,
                              if (createNew)
                                'new_profile_name': newNameCtrl.text.trim(),
                              'assign_to_current_asset': true,
                            });
                        if (res['telemetry'] is Map && mounted) {
                          final savedCode = (res['profile'] as Map?)?['code']
                              ?.toString();
                          _rebuildState(() {
                            _telemetryData = Map<String, dynamic>.from(
                              res['telemetry'] as Map,
                            );
                            if (savedCode != null) {
                              _selectedTelemetryTabKey = savedCode;
                            }
                          });
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                        _showSnack(
                          'Gráfica promovida a plantilla reutilizable.',
                        );
                      } catch (e) {
                        setModal(() => busy = false);
                        _showSnack('Error al promover: $e', isError: true);
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accentBlue,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.ios_share_rounded, size: 15),
              label: const Text('Promover Plantilla'),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // DIÁLOGO 4: CATÁLOGO DE PLANTILLAS REUTILIZABLES (ASIGNAR A SERVIDOR / GRUPOS)
  // ===========================================================================

  Future<void> _showManageProfilesCatalogDialog(
    Map<String, dynamic> host,
  ) async {
    final assetId = host['id'] as int?;
    if (assetId == null) return;

    List<Map<String, dynamic>> profiles = [];
    try {
      final res = await widget.api.getTelemetryProfiles();
      profiles = ((res['profiles'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      _showSnack('Error cargando plantillas: $e', isError: true);
      return;
    }
    if (!mounted) return;

    bool busy = false;
    final hostGroups = ((_overview['host_groups'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) {
          final activeCodes =
              ((_telemetryData?['active_profiles'] as List?) ?? const [])
                  .map((p) => '${(p as Map)['code']}')
                  .toSet();

          return AlertDialog(
            backgroundColor: AppTheme.bgCard,
            title: Row(
              children: [
                const Icon(
                  Icons.dashboard_customize_rounded,
                  color: AppTheme.accentPurple,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Catálogo de Plantillas Reutilizables de Gráficas — ${host['code']}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
            content: SizedBox(
              width: 780,
              height: 500,
              child: ListView(
                children: [
                  const Text(
                    'Activa o desactiva plantillas reutilizables para este servidor o asígnalas a un HostGroup entero (ej. todos tus nodos Oracle RAC o servidores web). Las plantillas con autodetección (como ORA-TUI) se activan solas al detectar su exporter.',
                    style: TextStyle(
                      fontSize: 11.2,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final p in profiles)
                    Builder(
                      builder: (context) {
                        final pid = p['id'] as int;
                        final code = '${p['code']}';
                        final isSys = code == 'system_base';
                        final assignedIds =
                            ((p['assigned_asset_ids'] as List?) ?? const [])
                                .map((e) => (e as num).toInt())
                                .toSet();
                        final assignedGroupIds =
                            ((p['assigned_host_group_ids'] as List?) ??
                                    const [])
                                .map((e) => (e as num).toInt())
                                .toSet();
                        final isExplicit = assignedIds.contains(assetId);
                        final isCurrentlyActive = activeCodes.contains(code);

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.bgPrimary,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isCurrentlyActive
                                  ? AppTheme.accentBlue
                                  : AppTheme.border,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    _profileIcon(p['icon_key']?.toString()),
                                    size: 18,
                                    color: isCurrentlyActive
                                        ? AppTheme.accentCyan
                                        : AppTheme.textMuted,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${p['name']} (${p['panels_count'] ?? 0} gráficas)',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        if ((p['description'] ?? '')
                                            .toString()
                                            .isNotEmpty)
                                          Text(
                                            '${p['description']}',
                                            style: const TextStyle(
                                              fontSize: 10.2,
                                              color: AppTheme.textSecondary,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  if (isSys)
                                    const Chip(
                                      label: Text(
                                        'Siempre Activa',
                                        style: TextStyle(fontSize: 10),
                                      ),
                                    )
                                  else if (widget.canEdit) ...[
                                    FilterChip(
                                      label: Text(
                                        isExplicit
                                            ? 'Asignada a ${host['code']}'
                                            : (isCurrentlyActive
                                                  ? 'Activa por Exporter'
                                                  : 'Asignar a ${host['code']}'),
                                        style: const TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      selected: isExplicit || isCurrentlyActive,
                                      onSelected: busy
                                          ? null
                                          : (_) async {
                                              setModal(() => busy = true);
                                              try {
                                                final tog = await widget.api
                                                    .toggleAssetTelemetryProfile(
                                                      assetId,
                                                      pid,
                                                    );
                                                final refreshed = await widget
                                                    .api
                                                    .getTelemetryProfiles();
                                                if (tog['telemetry'] is Map &&
                                                    mounted) {
                                                  _rebuildState(() {
                                                    _telemetryData =
                                                        Map<
                                                          String,
                                                          dynamic
                                                        >.from(
                                                          tog['telemetry']
                                                              as Map,
                                                        );
                                                  });
                                                }
                                                setModal(() {
                                                  profiles =
                                                      ((refreshed['profiles']
                                                                  as List?) ??
                                                              const [])
                                                          .map(
                                                            (e) =>
                                                                Map<
                                                                  String,
                                                                  dynamic
                                                                >.from(
                                                                  e as Map,
                                                                ),
                                                          )
                                                          .toList();
                                                  busy = false;
                                                });
                                              } catch (e) {
                                                setModal(() => busy = false);
                                                _showSnack(
                                                  'Error: $e',
                                                  isError: true,
                                                );
                                              }
                                            },
                                    ),
                                    if (p['is_builtin'] != true)
                                      IconButton(
                                        tooltip:
                                            'Eliminar plantilla personalizada',
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          size: 17,
                                          color: AppTheme.error,
                                        ),
                                        onPressed: busy
                                            ? null
                                            : () async {
                                                setModal(() => busy = true);
                                                try {
                                                  await widget.api
                                                      .deleteTelemetryProfile(
                                                        pid,
                                                      );
                                                  final refreshed = await widget
                                                      .api
                                                      .getTelemetryProfiles();
                                                  await _loadHostTelemetry(
                                                    assetId,
                                                  );
                                                  setModal(() {
                                                    profiles =
                                                        ((refreshed['profiles']
                                                                    as List?) ??
                                                                const [])
                                                            .map(
                                                              (e) =>
                                                                  Map<
                                                                    String,
                                                                    dynamic
                                                                  >.from(
                                                                    e as Map,
                                                                  ),
                                                            )
                                                            .toList();
                                                    busy = false;
                                                  });
                                                } catch (e) {
                                                  setModal(() => busy = false);
                                                  _showSnack(
                                                    'No se pudo eliminar: $e',
                                                    isError: true,
                                                  );
                                                }
                                              },
                                      ),
                                  ],
                                ],
                              ),
                              if (!isSys &&
                                  hostGroups.isNotEmpty &&
                                  widget.canEdit) ...[
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    const Text(
                                      'HostGroups:',
                                      style: TextStyle(
                                        fontSize: 9.8,
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.textMuted,
                                      ),
                                    ),
                                    for (final hg in hostGroups)
                                      FilterChip(
                                        visualDensity: VisualDensity.compact,
                                        label: Text(
                                          '${hg['code']}',
                                          style: const TextStyle(fontSize: 9.8),
                                        ),
                                        selected: assignedGroupIds.contains(
                                          hg['id'] as int,
                                        ),
                                        onSelected: busy
                                            ? null
                                            : (sel) async {
                                                final nextGroups = <int>{
                                                  ...assignedGroupIds,
                                                };
                                                if (sel) {
                                                  nextGroups.add(
                                                    hg['id'] as int,
                                                  );
                                                } else {
                                                  nextGroups.remove(
                                                    hg['id'] as int,
                                                  );
                                                }
                                                setModal(() => busy = true);
                                                try {
                                                  await widget.api
                                                      .updateTelemetryProfile(
                                                        pid,
                                                        {
                                                          'name': p['name'],
                                                          'description':
                                                              p['description'] ??
                                                              '',
                                                          'icon_key':
                                                              p['icon_key'] ??
                                                              'analytics',
                                                          'auto_match_exporter_types':
                                                              p['auto_match_exporter_types'] ??
                                                              const [],
                                                          'assigned_asset_ids':
                                                              assignedIds
                                                                  .toList(),
                                                          'assigned_host_group_ids':
                                                              nextGroups
                                                                  .toList(),
                                                          'kpi_badges':
                                                              p['kpi_badges'] ??
                                                              const [],
                                                          'panels':
                                                              p['panels'] ??
                                                              const [],
                                                        },
                                                      );
                                                  final refreshed = await widget
                                                      .api
                                                      .getTelemetryProfiles();
                                                  await _loadHostTelemetry(
                                                    assetId,
                                                  );
                                                  setModal(() {
                                                    profiles =
                                                        ((refreshed['profiles']
                                                                    as List?) ??
                                                                const [])
                                                            .map(
                                                              (e) =>
                                                                  Map<
                                                                    String,
                                                                    dynamic
                                                                  >.from(
                                                                    e as Map,
                                                                  ),
                                                            )
                                                            .toList();
                                                    busy = false;
                                                  });
                                                } catch (e) {
                                                  setModal(() => busy = false);
                                                }
                                              },
                                      ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cerrar'),
              ),
            ],
          );
        },
      ),
    );
  }
}
