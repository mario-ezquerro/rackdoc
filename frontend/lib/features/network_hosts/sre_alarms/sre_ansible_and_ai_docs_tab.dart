part of '../network_hosts_view.dart';

/// Pestaña de automatización SRE: webhooks Ansible, alta vía API REST
/// (`cURL` / `Puppet`), guías de agentes Prometheus y manifiesto JSON para IA.
extension _NetworkHostsSreAnsibleDocsExt on _NetworkHostsViewState {
  // ===========================================================================
  // TAB 3 (EN MODO 8. ALARMAS SRE): CENTRO UNIFICADO DE DOCUMENTACIÓN,
  // AUTOMATIZACIÓN ANSIBLE, API (cURL / PUPPET), AGENTES PROMETHEUS (.MD) & IA
  // ===========================================================================

  Widget _buildAnsibleWebhooksAndAiDocsTab() {
    final apiKey =
        (_summary['automation_api_key_hint'] as String?) ??
        'rackdoc-ansible-secret-key-2026';

    final examples = (_apiOnboardingGuide?['examples'] as Map?)
            ?.cast<String, dynamic>() ??
        <String, dynamic>{};

    final curlWebhook = (examples['curl_webhook_all_in_one'] as String?) ??
        '''curl -X POST "http://localhost:8180/api/v1/automation/webhook/host-upsert" \\
  -H "Content-Type: application/json" \\
  -H "X-API-Key: $apiKey" \\
  -d '{
    "code": "SRV-WEB-PROD-01",
    "hostname": "srv-web-prod-01",
    "fqdn": "srv-web-prod-01.corp.local",
    "asset_class": "virtual_machine",
    "environment": "production",
    "primary_ip": "10.20.30.45",
    "exporters": [{"type": "node_exporter", "port": 9100}],
    "heartbeats": [{"name": "HTTPS Portal", "type": "https", "port": 443, "url": "https://srv-web-prod-01.corp.local/health"}]
  }' ''';

    final curlJwt = (examples['curl_jwt_cmdb_and_certscope'] as String?) ??
        '''# 1. Obtener Token Bearer JWT:
TOKEN=\$(curl -s -X POST "http://localhost:8180/api/v1/auth/login" \\
  -H "Content-Type: application/json" \\
  -d '{"username":"admin","password":"ChangeMe123!"}' | jq -r .access_token)

# 2. Dar de alta activo en CMDB (6. CMDB) o Certificado en CertScope (7. CertScope):
curl -X POST "http://localhost:8180/api/v1/cmdb/assets" \\
  -H "Authorization: Bearer \$TOKEN" \\
  -H "Content-Type: application/json" \\
  -d '{"code":"SRV-DB-01","name":"PostgreSQL Primary","asset_class":"virtual_machine","primary_ip":"10.20.30.50"}' ''';

    final puppetManifest = (examples['puppet_manifest'] as String?) ??
        '''# Manifiesto Puppet (rackdoc_register.pp) usando hechos de Facter:
class profile::rackdoc_agent (
  String \$rackdoc_url = 'http://localhost:8180',
  String \$api_key     = '$apiKey',
) {
  exec { 'register_node_in_rackdoc':
    command => "/usr/bin/curl -sS -X POST '\${rackdoc_url}/api/v1/automation/webhook/host-upsert' -H 'Content-Type: application/json' -H 'X-API-Key: \${api_key}' -d '{\\"code\\":\\"\${facts['networking']['hostname']}\\",\\"hostname\\":\\"\${facts['networking']['hostname']}\\",\\"fqdn\\":\\"\${facts['networking']['fqdn']}\\",\\"primary_ip\\":\\"\${facts['networking']['ip']}\\"}'",
    unless  => "/usr/bin/test -f /var/lib/puppet/state/rackdoc_registered.lock",
  }
}''';

    final playbookUpsert = '''---
# Playbook Ansible: Alta / Actualización de Host en RackDoc + CMDB + Prometheus SD
- name: Registrar Servidor en RackDoc Red & Host y Prometheus
  hosts: all
  tasks:
    - name: Notificar alta a RackDoc Webhook
      ansible.builtin.uri:
        url: "http://localhost:8180/api/v1/automation/webhook/host-upsert"
        method: POST
        headers:
          X-API-Key: "$apiKey"
        body_format: json
        body:
          code: "{{ inventory_hostname | upper }}"
          hostname: "{{ ansible_hostname }}"
          fqdn: "{{ ansible_fqdn }}"
          asset_class: "virtual_machine"
          environment: "production"
          primary_ip: "{{ ansible_default_ipv4.address }}"
          host_rack_device_code: "SRV-ESXI-01"
          host_groups:
            - "HG-WEB-APACHE-NGINX"
          exporters:
            - type: "node_exporter"
              port: 9100
            - type: "nginx"
              port: 8080
              url: "http://{{ ansible_default_ipv4.address }}:8080/nginx_status"
          heartbeats:
            - name: "Portal Corporativo HTTPS"
              type: "https"
              port: 443
              url: "https://{{ ansible_fqdn }}/health"''';

    final playbookMaint = '''---
# Playbook Ansible: Ventana de Mantenimiento Automática (pre_tasks / post_tasks)
- name: Despliegue sin Falsas Alarmas
  hosts: webservers
  pre_tasks:
    - name: Activar modo Mantenimiento en RackDoc
      ansible.builtin.uri:
        url: "http://localhost:8180/api/v1/automation/webhook/maintenance"
        method: POST
        headers:
          X-API-Key: "$apiKey"
        body_format: json
        body:
          action: "start"
          title: "Despliegue Ansible Release"
          duration_minutes: 45
          host_group_code: "HG-WEB-APACHE-NGINX"
      delegate_to: localhost
      run_once: true
  post_tasks:
    - name: Desactivar modo Mantenimiento en RackDoc
      ansible.builtin.uri:
        url: "http://localhost:8180/api/v1/automation/webhook/maintenance"
        method: POST
        headers:
          X-API-Key: "$apiKey"
        body_format: json
        body:
          action: "stop"
          host_group_code: "HG-WEB-APACHE-NGINX"
      delegate_to: localhost
      run_once: true''';

    final selectedHost = _hosts.firstWhere(
      (h) => h['id'] == _selectedHostId,
      orElse: () => _hosts.isNotEmpty ? _hosts.first : <String, dynamic>{},
    );
    final hostMarkdown = _buildMonitoringInstallMarkdown(selectedHost);
    final hostCode = '${selectedHost['code'] ?? 'host'}'.toLowerCase();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // BLOQUE 1: ALTA Y SINCRONIZACIÓN VÍA API (CMDB + RED & HOST + CERTSCOPE + PROMETHEUS)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.bgSecondary,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.integration_instructions_rounded,
                    color: AppTheme.accentCyan,
                    size: 20,
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '1. CENTRO UNIFICADO DE DOCUMENTACIÓN API (cURL / JWT / ANSIBLE / PUPPET FACTER) — CMDB, RED & HOST Y CERTSCOPE',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Toda la documentación del dashboard está centralizada en este apartado. Clave X-API-Key activa: $apiKey • Regenera automáticamente /app/data/prometheus/targets_dynamic.json.',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  _buildCodeSnippetCard(
                    'A. Webhook Todo-en-Uno (cURL + X-API-Key: CMDB + Red & Host + CertScope + Prometheus)',
                    curlWebhook,
                  ),
                  _buildCodeSnippetCard(
                    'B. API REST Directa con Bearer Token JWT (6. CMDB / 7. CertScope)',
                    curlJwt,
                  ),
                  _buildCodeSnippetCard(
                    'C. Playbook Ansible: Alta / Actualización de Host + Prometheus SD',
                    playbookUpsert,
                  ),
                  _buildCodeSnippetCard(
                    'D. Playbook Ansible: Ventanas de Mantenimiento SRE (start / stop)',
                    playbookMaint,
                  ),
                  _buildCodeSnippetCard(
                    'E. Manifiesto Puppet (Facter) para Autoregistro de Nodos',
                    puppetManifest,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // BLOQUE 2: GENERADOR INTERACTIVO DE GUÍA MARKDOWN (.MD) DE AGENTES Y EXPORTERS POR HOST
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.bgSecondary,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.terminal_rounded,
                        color: AppTheme.accentTeal,
                        size: 20,
                      ),
                      SizedBox(width: 8),
                      Text(
                        '2. GUÍA DE INSTALACIÓN DE AGENTES Y EXPORTERS PROMETHEUS / SNMP (.MD POR HOST)',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (_hosts.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: AppTheme.bgCard,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.border),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<int>(
                              value: selectedHost['id'] as int?,
                              dropdownColor: AppTheme.bgCard,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary,
                              ),
                              items: _hosts
                                  .map(
                                    (h) => DropdownMenuItem<int>(
                                      value: h['id'] as int,
                                      child: Text(
                                        '${h['code']} — ${h['name']} (${h['heartbeat_ip']})',
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (val) {
                                if (val != null) {
                                  _rebuildState(() => _selectedHostId = val);
                                }
                              },
                            ),
                          ),
                        ),
                      ElevatedButton.icon(
                        onPressed: () => _downloadMarkdownGuide(
                          hostMarkdown,
                          'guia_monitorizacion_$hostCode.md',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.accentBlue,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(
                          Icons.download_for_offline_rounded,
                          size: 16,
                        ),
                        label: Text(
                          'Descargar guia_monitorizacion_$hostCode.md',
                          style: const TextStyle(
                            fontSize: 11.2,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                height: 300,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.bgPrimary,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.border),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    hostMarkdown,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // BLOQUE 3: MANIFIESTO JSON EN VIVO PARA AGENTES IA
        if (_aiContextManifest != null)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.bgSecondary,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.smart_toy_rounded,
                      color: AppTheme.accentPurple,
                      size: 20,
                    ),
                    SizedBox(width: 8),
                    Text(
                      '3. MANIFIESTO JSON EN VIVO PARA AGENTES DE IA (GET /api/v1/automation/ai-context)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _buildCodeSnippetCard(
                  'Esquema JSON de Capacidades, Endpoints y Contratos para Agentes IA / LLMs',
                  const JsonEncoder.withIndent('  ').convert(_aiContextManifest),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildCodeSnippetCard(String title, String code) {
    return Container(
      width: 520,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.accentCyan,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy_rounded, size: 15),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: code));
                  _showSnack('Copiado al portapapeles');
                },
              ),
            ],
          ),
          Container(
            height: 250,
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.bgPrimary,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                code,
                style: const TextStyle(
                  fontSize: 10.5,
                  fontFamily: 'monospace',
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
