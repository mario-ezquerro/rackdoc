import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/api_client.dart';
import '../../core/theme.dart';
import '../../core/widgets/avisos.dart';

Future<void> showApiOnboardingGuideDialog(
  BuildContext context, {
  required RackDocApiClient api,
}) async {
  Map<String, dynamic>? guideData;
  try {
    guideData = await api.getApiOnboardingGuide();
  } catch (_) {
    guideData = null;
  }
  if (!context.mounted) return;

  final baseUrl = (guideData?['base_url'] ?? 'http://localhost:8180').toString();
  final curlWebhook = (guideData?['curl_webhook_example'] ?? '').toString();
  final curlJwtCmdb = (guideData?['curl_jwt_cmdb_example'] ?? '').toString();
  final ansibleExample = (guideData?['ansible_playbook_example'] ?? '').toString();
  final puppetExample = (guideData?['puppet_manifest_example'] ?? '').toString();

  int activeTab = 0;

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setModalState) {
        String currentCode() {
          switch (activeTab) {
            case 0:
              return curlWebhook;
            case 1:
              return curlJwtCmdb;
            case 2:
              return ansibleExample;
            case 3:
              return puppetExample;
            default:
              return curlWebhook;
          }
        }

        String currentTitle() {
          switch (activeTab) {
            case 0:
              return 'cURL Todo-en-Uno (POST /api/v1/automation/webhook/host-upsert con X-API-Key)';
            case 1:
              return 'cURL con Login JWT + Alta Directa en CMDB, Planta y CertScope';
            case 2:
              return 'Playbook de Ansible (playbooks/rackdoc_register_host.yml con ansible_facts)';
            case 3:
              return 'Manifiesto de Puppet (manifests/rackdoc_node_onboarding.pp con Facter)';
            default:
              return '';
          }
        }

        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(22, 18, 22, 10),
          contentPadding: const EdgeInsets.fromLTRB(22, 0, 22, 14),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: AppPalette.blue900,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.terminal_rounded,
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
                      'Guía y Ejemplos Funcionales de Alta vía API REST (cURL / Ansible / Puppet)',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.slate900,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Registra o actualiza dispositivos con toda su información (Hardware, Multi-IP, Planta/Rack, Prometheus y Certificado SSL en CertScope) desde scripts o herramientas IaC.',
                      style: TextStyle(fontSize: 11.5, color: AppPalette.slate600),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
          content: SizedBox(
            width: 960,
            height: 620,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppPalette.sky50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppPalette.sky200),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.menu_book_rounded, size: 17, color: AppPalette.sky700),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Documentación Markdown completa incluida en el repositorio: docs/API_ONBOARDING_CURL_ANSIBLE_PUPPET.md  •  Endpoint base activo: $baseUrl',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: AppPalette.sky900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildTabPill(
                      index: 0,
                      activeTab: activeTab,
                      icon: Icons.bolt_rounded,
                      label: '1. cURL Todo-en-Uno (X-API-Key)',
                      onTap: () => setModalState(() => activeTab = 0),
                    ),
                    _buildTabPill(
                      index: 1,
                      activeTab: activeTab,
                      icon: Icons.vpn_key_rounded,
                      label: '2. cURL + Login JWT (CMDB + Planta)',
                      onTap: () => setModalState(() => activeTab = 1),
                    ),
                    _buildTabPill(
                      index: 2,
                      activeTab: activeTab,
                      icon: Icons.integration_instructions_rounded,
                      label: '3. Playbook Ansible (YAML)',
                      onTap: () => setModalState(() => activeTab = 2),
                    ),
                    _buildTabPill(
                      index: 3,
                      activeTab: activeTab,
                      icon: Icons.settings_suggest_rounded,
                      label: '4. Manifiesto Puppet (Facter)',
                      onTap: () => setModalState(() => activeTab = 3),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: const BoxDecoration(
                    color: AppPalette.slate800,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.code_rounded, size: 16, color: AppPalette.sky400),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          currentTitle(),
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppPalette.emerald500,
                          foregroundColor: Colors.white,
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: currentCode()));
                          mostrarAviso(
                            context,
                            'Ejemplo copiado al portapapeles.',
                            tono: TonoAviso.exito,
                          );
                        },
                        icon: const Icon(Icons.copy_rounded, size: 14),
                        label: const Text(
                          'Copiar Código',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: const BoxDecoration(
                      color: AppPalette.slate900,
                      borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        currentCode(),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          height: 1.45,
                          color: AppPalette.slate100,
                        ),
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
              child: const Text('Cerrar'),
            ),
          ],
        );
      },
    ),
  );
}

Widget _buildTabPill({
  required int index,
  required int activeTab,
  required IconData icon,
  required String label,
  required VoidCallback onTap,
}) {
  final isSelected = index == activeTab;
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: isSelected ? AppPalette.blue900 : AppPalette.slate100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isSelected ? AppPalette.blue900 : AppPalette.slate300,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 15,
            color: isSelected ? Colors.white : AppPalette.slate700,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: isSelected ? Colors.white : AppPalette.slate800,
            ),
          ),
        ],
      ),
    ),
  );
}
