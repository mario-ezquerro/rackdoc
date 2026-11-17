import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/api_client.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/avisos.dart';

/// Tarjeta de administración del Motor IA Solo-Lectura (`RackDoc AI`) mostrada en
/// **`9. Administración`** (exclusiva para el rol `admin`).
///
/// Permite mantener **Ollama Local (`rackdoc-ollama:11434`)** por defecto, descargar modelos
/// con 1 clic (`ollama pull`), o conmutar a un proveedor externo (`OpenAI-compatible`,
/// `Gemini`, `Anthropic`) con API Key cifrada mediante Fernet, además de rotar el token
/// `X-AI-Readonly-Key` para el Servidor MCP (`rackdoc-mcp`).
class AiEngineAdminCard extends StatefulWidget {
  final RackDocApiClient api;

  const AiEngineAdminCard({
    super.key,
    required this.api,
  });

  @override
  State<AiEngineAdminCard> createState() => _AiEngineAdminCardState();
}

class _AiEngineAdminCardState extends State<AiEngineAdminCard> {
  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  bool _pulling = false;
  bool _rotatingToken = false;

  String _providerType = 'ollama_local';
  final TextEditingController _baseUrlCtrl =
      TextEditingController(text: 'http://rackdoc-ollama:11434');
  final TextEditingController _modelNameCtrl =
      TextEditingController(text: 'qwen2.5:7b');
  final TextEditingController _apiKeyCtrl = TextEditingController();
  final TextEditingController _customInstructionsCtrl = TextEditingController();

  double _temperature = 0.2;
  int _maxTokens = 2048;
  bool _autoAuditEnabled = false;
  int _autoAuditHours = 24;
  bool _hasSavedApiKey = false;
  bool _clearSavedApiKey = false;
  bool _hasMcpUiToken = false;
  String _mcpTokenPrefix = '';
  bool _envMcpKeyConfigured = false;

  Map<String, dynamic> _ollamaStatus = const {};
  Map<String, dynamic>? _lastTestResult;
  List<Map<String, dynamic>> _providerPresets = const [];
  List<Map<String, dynamic>> _recommendedModels = const [];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _modelNameCtrl.dispose();
    _apiKeyCtrl.dispose();
    _customInstructionsCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    setState(() => _loading = true);
    try {
      final res = await widget.api.getAiAgentSettings();
      if (!mounted) return;
      _applyResponse(res);
    } catch (_) {
      // Si el usuario actual no es admin o aún arranca el backend, ocultamos en silencio
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _applyResponse(Map<String, dynamic> res) {
    final cfg = Map<String, dynamic>.from((res['settings'] ?? const {}) as Map);
    final oll =
        Map<String, dynamic>.from((res['ollama_status'] ?? const {}) as Map);
    final presets = ((cfg['provider_presets'] ?? const []) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final recModels = ((cfg['recommended_ollama_models'] ?? const []) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    setState(() {
      _providerType = (cfg['provider_type'] ?? 'ollama_local').toString();
      _baseUrlCtrl.text =
          (cfg['base_url'] ?? 'http://rackdoc-ollama:11434').toString();
      _modelNameCtrl.text = (cfg['model_name'] ?? 'qwen2.5:7b').toString();
      _temperature = ((cfg['temperature'] ?? 0.2) as num).toDouble();
      _maxTokens = ((cfg['max_tokens'] ?? 2048) as num).toInt();
      _autoAuditEnabled = cfg['auto_audit_enabled'] == true;
      _autoAuditHours = ((cfg['auto_audit_interval_hours'] ?? 24) as num).toInt();
      _customInstructionsCtrl.text =
          (cfg['custom_system_instructions'] ?? '').toString();
      _hasSavedApiKey = cfg['has_api_key'] == true;
      _clearSavedApiKey = false;
      _apiKeyCtrl.clear();
      _hasMcpUiToken = cfg['has_mcp_ui_token'] == true;
      _mcpTokenPrefix = (cfg['mcp_token_prefix'] ?? '').toString();
      _envMcpKeyConfigured = cfg['env_mcp_key_configured'] == true;
      _ollamaStatus = oll;
      _providerPresets = presets;
      _recommendedModels = recModels;
    });
  }

  void _onChangeProvider(String? newProvider) {
    if (newProvider == null || newProvider == _providerType) return;
    final preset = _providerPresets.firstWhere(
      (p) => p['provider_type'] == newProvider,
      orElse: () => const <String, dynamic>{},
    );
    setState(() {
      _providerType = newProvider;
      if (preset.isNotEmpty) {
        _baseUrlCtrl.text = (preset['default_base_url'] ?? '').toString();
        _modelNameCtrl.text = (preset['default_model'] ?? '').toString();
      }
      _lastTestResult = null;
    });
  }

  Future<void> _saveSettings() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final res = await widget.api.updateAiAgentSettings({
        'provider_type': _providerType,
        'base_url': _baseUrlCtrl.text.trim(),
        'model_name': _modelNameCtrl.text.trim(),
        'api_key': _apiKeyCtrl.text.trim().isEmpty
            ? null
            : _apiKeyCtrl.text.trim(),
        'clear_api_key': _clearSavedApiKey,
        'temperature': _temperature,
        'max_tokens': _maxTokens,
        'auto_audit_enabled': _autoAuditEnabled,
        'auto_audit_interval_hours': _autoAuditHours,
        'custom_system_instructions': _customInstructionsCtrl.text.trim(),
      });
      if (!mounted) return;
      _applyResponse(res);
      messenger.avisoExito(
        'Configuración del Motor IA guardada (${_providerType == 'ollama_local' ? 'Ollama Local' : _providerType}).',
      );
    } catch (e) {
      messenger.avisoError(e);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _testProviderLive() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _testing = true;
      _lastTestResult = null;
    });
    try {
      final res = await widget.api.testAiAgentProvider();
      if (!mounted) return;
      setState(() => _lastTestResult = res);
      if (res['ok'] == true) {
        messenger.avisoExito(
          'Conexión IA verificada en ${res['latency_ms']} ms (${res['model_name']}).',
        );
      } else {
        messenger.avisoError(res['error'] ?? 'Fallo de prueba LLM');
      }
    } catch (e) {
      messenger.avisoError(e);
    } finally {
      if (mounted) {
        setState(() => _testing = false);
      }
    }
  }

  Future<void> _pullOllamaModel(String modelToPull) async {
    final messenger = ScaffoldMessenger.of(context);
    final clean = modelToPull.trim();
    if (clean.isEmpty) {
      messenger.avisoError('Indica el nombre del modelo Ollama a descargar.');
      return;
    }
    setState(() => _pulling = true);
    messenger.aviso(
      'Descargando modelo "$clean" en rackdoc-ollama... Puede tardar unos minutos según el ancho de banda.',
    );
    try {
      final res = await widget.api.pullOllamaModel(clean);
      if (!mounted) return;
      final probe =
          Map<String, dynamic>.from((res['probe'] ?? const {}) as Map);
      setState(() => _ollamaStatus = probe);
      messenger.avisoExito('Modelo "$clean" descargado y listo en Ollama Local.');
    } catch (e) {
      messenger.avisoError(e);
    } finally {
      if (mounted) {
        setState(() => _pulling = false);
      }
    }
  }

  Future<void> _rotateMcpTokenAndShowDialog() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _rotatingToken = true);
    try {
      final res = await widget.api.rotateMcpReadonlyToken();
      if (!mounted) return;
      final rawToken = (res['raw_token'] ?? '').toString();
      final mcpCfgJson = const JsonEncoder.withIndent('  ')
          .convert(res['mcp_client_config'] ?? const {});
      final settingsMap =
          Map<String, dynamic>.from((res['settings'] ?? const {}) as Map);
      setState(() {
        _hasMcpUiToken = settingsMap['has_mcp_ui_token'] == true;
        _mcpTokenPrefix = (settingsMap['mcp_token_prefix'] ?? '').toString();
      });

      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.vpn_key_rounded, color: AppPalette.indigo600),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Token MCP Solo-Lectura Generado (Copia Única)',
                  style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 620,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Guarda esta clave ahora: en la base de datos solo se almacena su hash SHA-256 y garantiza acceso 100% Solo-Lectura desde Antigravity, Claude Desktop o Cursor.',
                  style: TextStyle(fontSize: 12, color: AppPalette.slate600),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppPalette.slate100,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppPalette.slate300),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          rawToken,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copiar clave X-AI-Readonly-Key',
                        icon: const Icon(Icons.copy_rounded, size: 16),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: rawToken));
                          messenger.avisoExito('Clave MCP copiada al portapapeles.');
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Configuración JSON para tu cliente MCP (`mcp_config.json`):',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: mcpCfgJson));
                        messenger.avisoExito('Bloque JSON MCP copiado.');
                      },
                      icon: const Icon(Icons.copy_all_rounded, size: 15),
                      label: const Text('Copiar JSON'),
                    ),
                  ],
                ),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppPalette.slate900,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    mcpCfgJson,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: AppPalette.sky200,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Entendido'),
            ),
          ],
        ),
      );
    } catch (e) {
      messenger.avisoError(e);
    } finally {
      if (mounted) {
        setState(() => _rotatingToken = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      );
    }

    final ollamaReachable = _ollamaStatus['reachable'] == true;
    final modelInstalled = _ollamaStatus['configured_model_installed'] == true;
    final installedModels =
        ((_ollamaStatus['installed_models'] ?? const []) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.indigo600, width: 1.4),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
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
                      'Motor de IA Solo-Lectura: Ollama Local (Por Defecto) y Proveedores Externos + Servidor MCP',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.slate900,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Doble candado de seguridad: ningún modelo ni cliente MCP puede modificar Racks, Red ni CMDB sin aprobación humana.',
                      style: TextStyle(fontSize: 12, color: AppPalette.slate600),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: ollamaReachable
                      ? AppPalette.green100
                      : AppPalette.amber100,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  ollamaReachable
                      ? (modelInstalled
                          ? 'OLLAMA LOCAL ACTIVO (MODELO LISTO)'
                          : 'OLLAMA CONECTADO (FALTA PULL MODELO)')
                      : 'OLLAMA LOCAL PENDIENTE DE LEVANTAR',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: ollamaReachable
                        ? AppPalette.green700
                        : AppPalette.amber800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // FILA DE CONFIGURACIÓN DEL PROVEEDOR
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 310,
                child: DropdownButtonFormField<String>(
                  initialValue: _providerType,
                  decoration: const InputDecoration(
                    labelText: 'Proveedor de IA Activo',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'ollama_local',
                      child: Text('Ollama Local (Por defecto On-Prem)'),
                    ),
                    DropdownMenuItem(
                      value: 'openai_compatible',
                      child: Text('API Externa (OpenAI / vLLM / LM Studio)'),
                    ),
                    DropdownMenuItem(
                      value: 'gemini',
                      child: Text('Google Gemini API'),
                    ),
                    DropdownMenuItem(
                      value: 'anthropic',
                      child: Text('Anthropic Claude API'),
                    ),
                  ],
                  onChanged: _onChangeProvider,
                ),
              ),
              SizedBox(
                width: 300,
                child: TextField(
                  controller: _baseUrlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'URL Base del Motor IA',
                    hintText: 'http://rackdoc-ollama:11434',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              SizedBox(
                width: 210,
                child: TextField(
                  controller: _modelNameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Modelo (Nombre / Tag)',
                    hintText: 'qwen2.5:7b',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              if (_providerType != 'ollama_local')
                SizedBox(
                  width: 270,
                  child: TextField(
                    controller: _apiKeyCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: _hasSavedApiKey
                          ? 'API Key (Cifrada Fernet · escribir para rotar)'
                          : 'API Key del Proveedor Externo',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: _hasSavedApiKey
                          ? IconButton(
                              tooltip: 'Borrar API Key guardada al guardar',
                              icon: Icon(
                                _clearSavedApiKey
                                    ? Icons.delete_forever_rounded
                                    : Icons.key_off_rounded,
                                size: 18,
                                color: _clearSavedApiKey
                                    ? AppPalette.red600
                                    : AppPalette.slate500,
                              ),
                              onPressed: () => setState(
                                () => _clearSavedApiKey = !_clearSavedApiKey,
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 12),

          // MODELOS RÁPIDOS DE OLLAMA LOCAL Y BOTÓN PULL
          if (_providerType == 'ollama_local')
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppPalette.slate50,
                borderRadius: BorderRadius.circular(8),
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
                      const Text(
                        'Modelos Ollama recomendados:',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppPalette.slate700,
                        ),
                      ),
                      ..._recommendedModels.map((m) {
                        final mName = (m['name'] ?? '').toString();
                        final selected = _modelNameCtrl.text.trim() == mName;
                        return ActionChip(
                          avatar: Icon(
                            selected
                                ? Icons.check_circle_rounded
                                : Icons.smart_toy_outlined,
                            size: 15,
                            color: selected
                                ? AppPalette.indigo600
                                : AppPalette.slate600,
                          ),
                          label: Text(
                            '$mName (${m['size_hint'] ?? ''})',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight:
                                  selected ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                          onPressed: () =>
                              setState(() => _modelNameCtrl.text = mName),
                        );
                      }),
                      FilledButton.tonalIcon(
                        onPressed: _pulling
                            ? null
                            : () => _pullOllamaModel(_modelNameCtrl.text),
                        icon: _pulling
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.download_rounded, size: 16),
                        label: Text(
                          _pulling
                              ? 'Descargando en Ollama...'
                              : 'Descargar Modelo en Ollama (Pull)',
                        ),
                      ),
                    ],
                  ),
                  if (installedModels.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Instalados en ./data/ollama: ${installedModels.map((m) => "${m['name']} (${m['size_gb']} GB)").join(', ')}',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppPalette.green700,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ] else if ((_ollamaStatus['error'] ?? '')
                      .toString()
                      .isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      (_ollamaStatus['error'] ?? '').toString(),
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppPalette.amber800,
                      ),
                    ),
                  ],
                ],
              ),
            ),

          const SizedBox(height: 12),

          // AUDITORÍA PERIÓDICA EN BACKGROUND (SOLO-LECTURA)
          Row(
            children: [
              Switch(
                value: _autoAuditEnabled,
                onChanged: (v) => setState(() => _autoAuditEnabled = v),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Auditoría y autodocumentación periódica en background (100% Solo-Lectura: regenera Dossier SPOF/FinOps y borradores CMDB)',
                  style: TextStyle(fontSize: 12, color: AppPalette.slate700),
                ),
              ),
              SizedBox(
                width: 155,
                child: DropdownButtonFormField<int>(
                  initialValue: const [6, 12, 24, 48, 168]
                          .contains(_autoAuditHours)
                      ? _autoAuditHours
                      : 24,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: 'Frecuencia',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 6, child: Text('Cada 6 horas')),
                    DropdownMenuItem(value: 12, child: Text('Cada 12 horas')),
                    DropdownMenuItem(value: 24, child: Text('Cada 24 horas')),
                    DropdownMenuItem(value: 48, child: Text('Cada 48 horas')),
                    DropdownMenuItem(value: 168, child: Text('Semanal (7d)')),
                  ],
                  onChanged: (h) {
                    if (h != null) setState(() => _autoAuditHours = h);
                  },
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ACCIONES DE GUARDADO, PRUEBA EN VIVO Y TOKEN MCP
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _saving ? null : _saveSettings,
                icon: const Icon(Icons.save_rounded, size: 16),
                label: Text(_saving ? 'Guardando...' : 'Guardar Motor IA'),
              ),
              OutlinedButton.icon(
                onPressed: _testing ? null : _testProviderLive,
                icon: _testing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bolt_rounded, size: 16),
                label: Text(
                  _testing ? 'Probando LLM...' : 'Probar Conexión LLM',
                ),
              ),
              OutlinedButton.icon(
                onPressed:
                    _rotatingToken ? null : _rotateMcpTokenAndShowDialog,
                icon: const Icon(Icons.terminal_rounded, size: 16),
                label: Text(
                  _hasMcpUiToken
                      ? 'Rotar Token MCP ($_mcpTokenPrefix)'
                      : 'Generar Token Servidor MCP Solo-Lectura',
                ),
              ),
              if (_envMcpKeyConfigured)
                const Chip(
                  label: Text(
                    'AI_READONLY_API_KEY activa en .env',
                    style: TextStyle(fontSize: 11),
                  ),
                  backgroundColor: AppPalette.sky50,
                ),
            ],
          ),

          if (_lastTestResult != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _lastTestResult!['ok'] == true
                    ? AppPalette.green50
                    : AppPalette.red50,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: _lastTestResult!['ok'] == true
                      ? AppPalette.green300
                      : AppPalette.red300,
                ),
              ),
              child: Text(
                _lastTestResult!['ok'] == true
                    ? 'Respuesta (${_lastTestResult!['latency_ms']} ms): ${_lastTestResult!['sample_reply']}'
                    : 'Error conectando con el modelo: ${_lastTestResult!['error']}',
                style: TextStyle(
                  fontSize: 12,
                  color: _lastTestResult!['ok'] == true
                      ? AppPalette.green700
                      : AppPalette.red800,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
