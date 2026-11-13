part of '../network_hosts_view.dart';

/// Pestañas 2 y 3 de `8. Alarmas SRE`: matriz interactiva de 5 columnas
/// (grupos de hosts, grupos de guardia, contactos y usuarios conocidos AD/Local),
/// ventanas de mantenimiento, historial de envíos y objetivos SLO/SRE.
extension _NetworkHostsSreRoutingAndSloExt on _NetworkHostsViewState {
  // ===========================================================================
  // TAB 5: AVISOS DE ALARMAS (MATRIZ 4 COLUMNAS ESTILO ACTIVE DIRECTORY + DRAG & DROP + SMTP)
  // ===========================================================================

  Widget _buildAlertsContactsAndMaintenanceTab() {
    if (_hostGroups.isNotEmpty &&
        (_selectedAlertHostGroupId == null ||
            !_hostGroups.any((hg) => hg['id'] == _selectedAlertHostGroupId))) {
      _selectedAlertHostGroupId = _hostGroups.first['id'] as int;
    }
    if (_alertContactGroups.isNotEmpty &&
        (_selectedAlertUserGroupId == null ||
            !_alertContactGroups.any(
              (cg) => cg['id'] == _selectedAlertUserGroupId,
            ))) {
      _selectedAlertUserGroupId = _alertContactGroups.first['id'] as int;
    }
    if (_alertContacts.isNotEmpty &&
        (_selectedAlertContactId == null ||
            !_alertContacts.any((c) => c['id'] == _selectedAlertContactId))) {
      _selectedAlertContactId = _alertContacts.first['id'] as int;
    }

    final smtp = _smtpConfig;
    final smtpHost = (smtp['smtp_host'] as String? ?? '').trim();
    final smtpEnabled = smtp['enabled'] != false;
    final smtpConfigured = smtpHost.isNotEmpty && smtpEnabled;

    return Column(
      children: [
        // 1. Barra superior: Servidor SMTP + Sincronización Active Directory/Control de Acceso + Altas a Medida
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: const BoxDecoration(
            color: AppTheme.bgSecondary,
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final leftButtons = Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // Botón Principal: Dar de Alta / Configurar Servidor para Mandar Correos (SMTP)
                  ElevatedButton.icon(
                    onPressed: _showSmtpServerConfigDialog,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: smtpConfigured
                          ? AppTheme.accentTeal
                          : AppTheme.accentBlue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                    ),
                    icon: const Icon(Icons.mark_email_unread_rounded, size: 16),
                    label: Text(
                      smtpConfigured
                          ? '✉️ Servidor Correo SMTP (${smtp['smtp_host']}:${smtp['smtp_port']}) • Activo'
                          : '✉️ Dar de Alta Servidor Correo SMTP',
                      style: const TextStyle(
                        fontSize: 11.2,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final res = await widget.api.getNetworkHostsOverview(
                        syncAd: true,
                      );
                      await _loadDirectoryUsers();
                      if (!mounted) return;
                      _rebuildState(() => _overview = res);
                      _showSnack(
                        'Usuarios y Grupos sincronizados con Control de Acceso (Local + Active Directory).',
                      );
                    },
                    icon: const Icon(
                      Icons.sync_rounded,
                      size: 15,
                      color: AppTheme.accentPurple,
                    ),
                    label: const Text(
                      'Sincronizar Control de Acceso & AD',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (widget.canEdit) ...[
                    OutlinedButton.icon(
                      onPressed: () => _showCreateHostGroupDialog(),
                      icon: const Icon(
                        Icons.dns_rounded,
                        size: 14,
                        color: AppTheme.accentCyan,
                      ),
                      label: const Text(
                        '+ Grupo de Host',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _showCreateContactGroupDialog(),
                      icon: const Icon(
                        Icons.groups_rounded,
                        size: 15,
                        color: AppTheme.accentBlue,
                      ),
                      label: const Text(
                        '+ Grupo Usuarios (AD/Local/Medida)',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _showCreateContactDialog(),
                      icon: const Icon(
                        Icons.person_add_alt_1_rounded,
                        size: 14,
                        color: AppTheme.success,
                      ),
                      label: const Text(
                        '+ Usuario / Contacto',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _showCreateMaintenanceDialog,
                      icon: const Icon(Icons.build_circle_rounded, size: 14),
                      label: const Text(
                        '+ Mantenimiento',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ],
              );

              final rightButtons = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      final res = await widget.api.triggerTestAlert(
                        assetId: _selectedHostId,
                      );
                      _rebuildState(() => _overview = res);
                      _showSnack(
                        'Correo/Alerta de prueba disparado y registrado en la bitácora.',
                      );
                    },
                    icon: const Icon(
                      Icons.send_rounded,
                      size: 14,
                      color: AppTheme.warning,
                    ),
                    label: const Text(
                      'Probar Envío Alarma',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: _showAlertBottomLogs
                        ? 'Ocultar Bitácora Inferior'
                        : 'Mostrar Bitácora y Mantenimientos',
                    onPressed: () => _rebuildState(
                      () => _showAlertBottomLogs = !_showAlertBottomLogs,
                    ),
                    icon: Icon(
                      _showAlertBottomLogs
                          ? Icons.keyboard_arrow_down_rounded
                          : Icons.keyboard_arrow_up_rounded,
                      size: 18,
                    ),
                  ),
                ],
              );

              if (constraints.maxWidth >= 1050) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: leftButtons),
                    const SizedBox(width: 12),
                    rightButtons,
                  ],
                );
              }
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  leftButtons,
                  rightButtons,
                ],
              );
            },
          ),
        ),
        // Banner explicativo del flujo izquierda -> derecha con Drag & Drop (5 Columnas)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: AppTheme.accentBlue.withValues(alpha: 0.07),
            border: const Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: const Row(
            children: [
              Icon(
                Icons.drag_indicator_rounded,
                size: 15,
                color: AppTheme.accentBlue,
              ),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Flujo Active Directory & Alarmas (5 Columnas):  [1. Grupo de Host] ➔ [2. Hosts del Grupo] ⬅(Arrastra alarmas)⬅ [3. Grupo de Usuarios] ➔ [4. Usuarios del Grupo + Ficha AD] ⬅(Arrastra al grupo)⬅ [5. Usuarios Conocidos (AD/Local/Directorio)].',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        // 2. Matriz Principal de 5 Columnas (Izquierda a Derecha)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // COLUMNA 1: GRUPOS DE HOST (DROP TARGET)
                Expanded(
                  flex: 20,
                  child: _buildAlertsCol1HostGroups(),
                ),
                _buildAlertsFlowConnectorArrow('contiene\nhosts ➔'),
                // COLUMNA 2: HOSTS DEL GRUPO SELECCIONADO (DROP TARGET)
                Expanded(
                  flex: 20,
                  child: _buildAlertsCol2HostsInGroup(),
                ),
                _buildAlertsFlowConnectorArrow('⬅ arrastra\nalarmas'),
                // COLUMNA 3: GRUPOS DE USUARIOS (AD / LOCAL / A MEDIDA) — DRAGGABLE & DROP TARGET DE USUARIOS
                Expanded(
                  flex: 20,
                  child: _buildAlertsCol3UserGroups(),
                ),
                _buildAlertsFlowConnectorArrow('miembros\ngrupo ➔'),
                // COLUMNA 4: USUARIOS DEL GRUPO SELECCIONADO + FICHA ACTIVE DIRECTORY (DROP TARGET DE COL 5)
                Expanded(
                  flex: 21,
                  child: _buildAlertsCol4UsersAndAdCard(),
                ),
                _buildAlertsFlowConnectorArrow('⬅ arrastra\nal grupo'),
                // COLUMNA 5: USUARIOS CONOCIDOS (DIRECTORIO AD / LOCAL / RACKDOC) — DRAGGABLE HACIA COL 4, 3, 2, 1
                Expanded(
                  flex: 21,
                  child: _buildAlertsCol5KnownUsers(),
                ),
              ],
            ),
          ),
        ),
        // 3. Barra inferior plegable: Ventanas de Mantenimiento y Bitácora de Correos Enviados
        if (_showAlertBottomLogs) _buildAlertsBottomMaintenanceAndLogsBar(),
      ],
    );
  }

  Widget _buildAlertsFlowConnectorArrow(String label) {
    return SizedBox(
      width: 44,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              decoration: BoxDecoration(
                color: AppTheme.bgCard,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: AppTheme.border),
              ),
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 8.2,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textMuted,
                  height: 1.15,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // COLUMNA 1 (IZQUIERDA): GRUPOS DE HOST (DROP TARGET DE GRUPOS/USUARIOS)
  // ---------------------------------------------------------------------------
  Widget _buildAlertsCol1HostGroups() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: const BoxDecoration(
              color: AppTheme.bgCard,
              borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
              border: Border(bottom: BorderSide(color: AppTheme.border)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.accentCyan.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    '1',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.accentCyan,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'GRUPOS DE HOST (${_hostGroups.length})',
                    style: const TextStyle(
                      fontSize: 11.2,
                      fontWeight: FontWeight.w900,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.canEdit)
                  IconButton(
                    tooltip: 'Nuevo Grupo de Host',
                    constraints: const BoxConstraints(),
                    padding: EdgeInsets.zero,
                    onPressed: () => _showCreateHostGroupDialog(),
                    icon: const Icon(
                      Icons.add_circle_outline_rounded,
                      size: 16,
                      color: AppTheme.accentCyan,
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            color: AppTheme.accentCyan.withValues(alpha: 0.05),
            child: const Text(
              '💡 Suelta aquí un Grupo de Usuarios (Col 3) o Usuario (Col 4) para asignarle las alarmas de todo el grupo.',
              style: TextStyle(fontSize: 9.5, color: AppTheme.textSecondary),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _hostGroups.length,
              itemBuilder: (ctx, i) {
                final hg = _hostGroups[i];
                final hgId = hg['id'] as int;
                final isSelected = hgId == _selectedAlertHostGroupId;
                final memberCodes =
                    ((hg['member_codes'] as List?) ?? []).cast<String>();

                // Buscar regla de enrutamiento para este HostGroup
                final hgRules = _notificationRules
                    .where(
                      (r) =>
                          r['scope_type'] == 'host_group' &&
                          r['host_group_id'] == hgId,
                    )
                    .toList();
                final assignedCgIds = <int>{};
                final assignedContactIds = <int>{};
                for (final r in hgRules) {
                  for (final id in ((r['contact_group_ids'] as List?) ?? [])) {
                    assignedCgIds.add(id as int);
                  }
                  for (final id in ((r['contact_ids'] as List?) ?? [])) {
                    assignedContactIds.add(id as int);
                  }
                }

                return DragTarget<String>(
                  onWillAcceptWithDetails: (details) =>
                      widget.canEdit &&
                      (details.data.startsWith('ug:') ||
                          details.data.startsWith('u:') ||
                          details.data.startsWith('du:')),
                  onAcceptWithDetails: (details) => _handleDropRecipientOnTarget(
                    dragToken: details.data,
                    scopeType: 'host_group',
                    hostGroupId: hgId,
                    targetName: '${hg['name']} (${hg['code']})',
                  ),
                  builder: (ctx, candidateData, rejectedData) {
                    final isHoveringDrop = candidateData.isNotEmpty;
                    return GestureDetector(
                      onTap: () =>
                          _rebuildState(() => _selectedAlertHostGroupId = hgId),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isHoveringDrop
                              ? AppTheme.accentTeal.withValues(alpha: 0.14)
                              : (isSelected
                                    ? AppTheme.accentCyan.withValues(
                                        alpha: 0.09,
                                      )
                                    : AppTheme.bgPrimary),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isHoveringDrop
                                ? AppTheme.accentTeal
                                : (isSelected
                                      ? AppTheme.accentCyan
                                      : AppTheme.border),
                            width: (isHoveringDrop || isSelected) ? 1.8 : 1.0,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.folder_special_rounded,
                                  size: 16,
                                  color: AppTheme.accentCyan,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    '${hg['name']}',
                                    style: const TextStyle(
                                      fontSize: 11.4,
                                      fontWeight: FontWeight.w800,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (widget.canEdit) ...[
                                  IconButton(
                                    tooltip: 'Editar HostGroup y sus Hosts',
                                    constraints: const BoxConstraints(),
                                    padding: const EdgeInsets.only(left: 4),
                                    onPressed: () =>
                                        _showCreateHostGroupDialog(existing: hg),
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 14,
                                      color: AppTheme.textMuted,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Eliminar Grupo de Host',
                                    constraints: const BoxConstraints(),
                                    padding: const EdgeInsets.only(left: 5),
                                    onPressed: () =>
                                        _confirmAndDeleteHostGroup(hg),
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                      size: 14.5,
                                      color: AppTheme.error,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                Text(
                                  '${hg['code']}',
                                  style: const TextStyle(
                                    fontSize: 9.8,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.textMuted,
                                  ),
                                ),
                                const Spacer(),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppTheme.bgElevated,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '${memberCodes.length} hosts',
                                    style: const TextStyle(
                                      fontSize: 9.2,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 7),
                            // Destinatarios de Alarma asignados a este HostGroup
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: AppTheme.bgSecondary,
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(
                                  color: isHoveringDrop
                                      ? AppTheme.accentTeal
                                      : AppTheme.border.withValues(alpha: 0.8),
                                ),
                              ),
                              child: (assignedCgIds.isEmpty &&
                                      assignedContactIds.isEmpty)
                                  ? const Text(
                                      '📥 Arrastra aquí un Grupo de Usuarios o Usuario para asignar alarmas',
                                      style: TextStyle(
                                        fontSize: 9.4,
                                        fontStyle: FontStyle.italic,
                                        color: AppTheme.textMuted,
                                      ),
                                    )
                                  : Wrap(
                                      spacing: 4,
                                      runSpacing: 4,
                                      children: [
                                        ...assignedCgIds.map((cgId) {
                                          final cg = _alertContactGroups
                                              .where((g) => g['id'] == cgId)
                                              .firstOrNull;
                                          if (cg == null) {
                                            return const SizedBox.shrink();
                                          }
                                          return _buildAssignedRecipientPill(
                                            label: '👥 ${cg['name']}',
                                            email: '${cg['group_email'] ?? ''}',
                                            color: AppTheme.accentTeal,
                                            onRemove: widget.canEdit
                                                ? () =>
                                                      _removeRecipientFromTarget(
                                                        scopeType: 'host_group',
                                                        hostGroupId: hgId,
                                                        removeCgId: cgId,
                                                      )
                                                : null,
                                          );
                                        }),
                                        ...assignedContactIds.map((cId) {
                                          final c = _alertContacts
                                              .where((u) => u['id'] == cId)
                                              .firstOrNull;
                                          if (c == null) {
                                            return const SizedBox.shrink();
                                          }
                                          return _buildAssignedRecipientPill(
                                            label: '👤 ${c['full_name']}',
                                            email: '${c['email'] ?? ''}',
                                            color: AppTheme.accentPurple,
                                            onRemove: widget.canEdit
                                                ? () =>
                                                      _removeRecipientFromTarget(
                                                        scopeType: 'host_group',
                                                        hostGroupId: hgId,
                                                        removeContactId: cId,
                                                      )
                                                : null,
                                          );
                                        }),
                                      ],
                                    ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // COLUMNA 2: HOSTS DEL GRUPO SELECCIONADO (DROP TARGET INDIVIDUAL POR HOST)
  // ---------------------------------------------------------------------------
  Widget _buildAlertsCol2HostsInGroup() {
    final selectedHg = _hostGroups
        .where((hg) => hg['id'] == _selectedAlertHostGroupId)
        .firstOrNull;
    final memberAssetIds =
        ((selectedHg?['member_asset_ids'] as List?) ?? []).cast<int>().toSet();
    final groupHosts = selectedHg == null
        ? _hosts
        : _hosts.where((h) => memberAssetIds.contains(h['id'] as int)).toList();

    // Grupos heredados del HostGroup padre
    final inheritedCgIds = <int>{};
    if (selectedHg != null) {
      for (final r in _notificationRules.where(
        (r) =>
            r['scope_type'] == 'host_group' &&
            r['host_group_id'] == selectedHg['id'],
      )) {
        for (final id in ((r['contact_group_ids'] as List?) ?? [])) {
          inheritedCgIds.add(id as int);
        }
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: const BoxDecoration(
              color: AppTheme.bgCard,
              borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
              border: Border(bottom: BorderSide(color: AppTheme.border)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.accentBlue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    '2',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.accentBlue,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    selectedHg != null
                        ? 'HOSTS EN ${selectedHg['code']} (${groupHosts.length})'
                        : 'HOSTS (${groupHosts.length})',
                    style: const TextStyle(
                      fontSize: 11.2,
                      fontWeight: FontWeight.w900,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.canEdit && selectedHg != null)
                  IconButton(
                    tooltip: 'Añadir o editar Hosts de este Grupo',
                    constraints: const BoxConstraints(),
                    padding: EdgeInsets.zero,
                    onPressed: () =>
                        _showCreateHostGroupDialog(existing: selectedHg),
                    icon: const Icon(
                      Icons.add_circle_outline_rounded,
                      size: 16,
                      color: AppTheme.accentBlue,
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            color: AppTheme.accentBlue.withValues(alpha: 0.05),
            child: const Text(
              '💡 Cada Host hereda las alarmas de su HostGroup y también admite arrastrarle un Grupo o Usuario directo.',
              style: TextStyle(fontSize: 9.5, color: AppTheme.textSecondary),
            ),
          ),
          Expanded(
            child: groupHosts.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Este Grupo de Host aún no tiene máquinas asignadas.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: groupHosts.length,
                    itemBuilder: (ctx, i) {
                      final h = groupHosts[i];
                      final assetId = h['id'] as int;
                      final nagiosState =
                          (h['nagios_host_state'] as String?) ?? 'UP';
                      final stateColor = nagiosState == 'UP'
                          ? AppTheme.success
                          : (nagiosState == 'DOWN'
                                ? AppTheme.error
                                : AppTheme.warning);

                      // Reglas directas para este Host individual
                      final hostRules = _notificationRules
                          .where(
                            (r) =>
                                r['scope_type'] == 'single_host' &&
                                r['asset_id'] == assetId,
                          )
                          .toList();
                      final directCgIds = <int>{};
                      final directContactIds = <int>{};
                      for (final r in hostRules) {
                        for (final id
                            in ((r['contact_group_ids'] as List?) ?? [])) {
                          directCgIds.add(id as int);
                        }
                        for (final id in ((r['contact_ids'] as List?) ?? [])) {
                          directContactIds.add(id as int);
                        }
                      }

                      return DragTarget<String>(
                        onWillAcceptWithDetails: (details) =>
                            widget.canEdit &&
                            (details.data.startsWith('ug:') ||
                                details.data.startsWith('u:') ||
                                details.data.startsWith('du:')),
                        onAcceptWithDetails: (details) =>
                            _handleDropRecipientOnTarget(
                              dragToken: details.data,
                              scopeType: 'single_host',
                              assetId: assetId,
                              targetName: 'Host ${h['code']}',
                            ),
                        builder: (ctx, candidateData, rejectedData) {
                          final isHoveringDrop = candidateData.isNotEmpty;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(9),
                            decoration: BoxDecoration(
                              color: isHoveringDrop
                                  ? AppTheme.accentTeal.withValues(alpha: 0.14)
                                  : AppTheme.bgPrimary,
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(
                                color: isHoveringDrop
                                    ? AppTheme.accentTeal
                                    : AppTheme.border,
                                width: isHoveringDrop ? 1.8 : 1.0,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: stateColor,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        '${h['code']} • ${h['name']}',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w800,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Text(
                                      '${h['heartbeat_ip'] ?? ''}',
                                      style: const TextStyle(
                                        fontSize: 9.5,
                                        fontFamily: 'monospace',
                                        color: AppTheme.textMuted,
                                      ),
                                    ),
                                    if (widget.canEdit && selectedHg != null) ...[
                                      const SizedBox(width: 4),
                                      InkWell(
                                        onTap: () => _removeHostFromHostGroup(
                                          selectedHg,
                                          assetId,
                                        ),
                                        child: const Tooltip(
                                          message:
                                              'Quitar este Host del Grupo de Host actual',
                                          child: Icon(
                                            Icons.delete_outline_rounded,
                                            size: 13.5,
                                            color: AppTheme.error,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Wrap(
                                  spacing: 4,
                                  runSpacing: 4,
                                  children: [
                                    ...inheritedCgIds.map((cgId) {
                                      final cg = _alertContactGroups
                                          .where((g) => g['id'] == cgId)
                                          .firstOrNull;
                                      if (cg == null) {
                                        return const SizedBox.shrink();
                                      }
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppTheme.accentCyan.withValues(
                                            alpha: 0.10,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          border: Border.all(
                                            color: AppTheme.accentCyan
                                                .withValues(alpha: 0.35),
                                          ),
                                        ),
                                        child: Text(
                                          '↪ Hereda: ${cg['name']}',
                                          style: const TextStyle(
                                            fontSize: 8.9,
                                            fontWeight: FontWeight.w700,
                                            color: AppTheme.accentCyan,
                                          ),
                                        ),
                                      );
                                    }),
                                    ...directCgIds.map((cgId) {
                                      final cg = _alertContactGroups
                                          .where((g) => g['id'] == cgId)
                                          .firstOrNull;
                                      if (cg == null) {
                                        return const SizedBox.shrink();
                                      }
                                      return _buildAssignedRecipientPill(
                                        label: '🎯 Directo: ${cg['name']}',
                                        email: '${cg['group_email'] ?? ''}',
                                        color: AppTheme.accentTeal,
                                        onRemove: widget.canEdit
                                            ? () => _removeRecipientFromTarget(
                                                scopeType: 'single_host',
                                                assetId: assetId,
                                                removeCgId: cgId,
                                              )
                                            : null,
                                      );
                                    }),
                                    ...directContactIds.map((cId) {
                                      final c = _alertContacts
                                          .where((u) => u['id'] == cId)
                                          .firstOrNull;
                                      if (c == null) {
                                        return const SizedBox.shrink();
                                      }
                                      return _buildAssignedRecipientPill(
                                        label: '👤 Directo: ${c['full_name']}',
                                        email: '${c['email'] ?? ''}',
                                        color: AppTheme.accentPurple,
                                        onRemove: widget.canEdit
                                            ? () => _removeRecipientFromTarget(
                                                scopeType: 'single_host',
                                                assetId: assetId,
                                                removeContactId: cId,
                                              )
                                            : null,
                                      );
                                    }),
                                    if (inheritedCgIds.isEmpty &&
                                        directCgIds.isEmpty &&
                                        directContactIds.isEmpty)
                                      const Text(
                                        'Arrastra aquí un grupo o usuario para alerta específica',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontStyle: FontStyle.italic,
                                          color: AppTheme.textMuted,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // COLUMNA 3: GRUPOS DE USUARIOS (AD / LOCAL / A MEDIDA) — DRAGGABLE & DROP TARGET DE COL 5
  // ---------------------------------------------------------------------------
  Widget _buildAlertsCol3UserGroups() {
    final filteredGroups = _alertContactGroups.where((cg) {
      if (_alertGroupSourceFilter == 'all') return true;
      return (cg['source_type'] as String? ?? 'custom') ==
          _alertGroupSourceFilter;
    }).toList();

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: const BoxDecoration(
              color: AppTheme.bgCard,
              borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
              border: Border(bottom: BorderSide(color: AppTheme.border)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.accentPurple.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    '3',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.accentPurple,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'GRUPOS DE USUARIOS (${filteredGroups.length})',
                    style: const TextStyle(
                      fontSize: 11.2,
                      fontWeight: FontWeight.w900,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.canEdit)
                  IconButton(
                    tooltip: 'Crear Grupo de Usuarios a Medida o AD',
                    constraints: const BoxConstraints(),
                    padding: EdgeInsets.zero,
                    onPressed: () => _showCreateContactGroupDialog(),
                    icon: const Icon(
                      Icons.add_circle_outline_rounded,
                      size: 16,
                      color: AppTheme.accentPurple,
                    ),
                  ),
              ],
            ),
          ),
          // Filtros de origen: Todos | Active Directory | Locales | A Medida
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppTheme.border)),
            ),
            child: Wrap(
              spacing: 5,
              runSpacing: 4,
              children: [
                _buildSourceFilterChip('all', 'Todos'),
                _buildSourceFilterChip('ad', 'Active Directory'),
                _buildSourceFilterChip('local', 'Locales'),
                _buildSourceFilterChip('custom', 'A Medida'),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: filteredGroups.length,
              itemBuilder: (ctx, i) {
                final cg = filteredGroups[i];
                final cgId = cg['id'] as int;
                final isSelected = cgId == _selectedAlertUserGroupId;
                final srcType = (cg['source_type'] as String?) ?? 'custom';
                final srcBadge = (cg['source_badge'] as String?) ?? 'A Medida';
                final memberIds =
                    ((cg['member_contact_ids'] as List?) ?? []).cast<int>();
                final alertHgs =
                    ((cg['alerting_host_group_codes'] as List?) ?? [])
                        .cast<String>();

                return DragTarget<String>(
                  onWillAcceptWithDetails: (details) =>
                      widget.canEdit &&
                      (details.data.startsWith('u:') ||
                          details.data.startsWith('du:')),
                  onAcceptWithDetails: (details) =>
                      _handleDropUserIntoContactGroup(
                        dragToken: details.data,
                        targetGroup: cg,
                      ),
                  builder: (ctx, candidateData, rejectedData) {
                    final isHoveringUserDrop = candidateData.isNotEmpty;
                    final cardBody = GestureDetector(
                      onTap: () => _rebuildState(() {
                        _selectedAlertUserGroupId = cgId;
                        _showAllUsersInCol4 = false;
                        if (memberIds.isNotEmpty &&
                            !memberIds.contains(_selectedAlertContactId)) {
                          _selectedAlertContactId = memberIds.first;
                        }
                      }),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isHoveringUserDrop
                              ? AppTheme.success.withValues(alpha: 0.14)
                              : (isSelected
                                    ? AppTheme.accentPurple.withValues(
                                        alpha: 0.09,
                                      )
                                    : AppTheme.bgPrimary),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isHoveringUserDrop
                                ? AppTheme.success
                                : (isSelected
                                      ? AppTheme.accentPurple
                                      : AppTheme.border),
                            width: (isHoveringUserDrop || isSelected)
                                ? 1.8
                                : 1.0,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.drag_indicator_rounded,
                                  size: 15,
                                  color: AppTheme.accentPurple,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    '${cg['name']}',
                                    style: const TextStyle(
                                      fontSize: 11.3,
                                      fontWeight: FontWeight.w800,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                _buildOriginBadge(srcType, srcBadge),
                                if (widget.canEdit) ...[
                                  const SizedBox(width: 4),
                                  InkWell(
                                    onTap: () => _showCreateContactGroupDialog(
                                      existing: cg,
                                    ),
                                    child: const Tooltip(
                                      message: 'Editar Grupo de Usuarios',
                                      child: Icon(
                                        Icons.edit_outlined,
                                        size: 14,
                                        color: AppTheme.textMuted,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  InkWell(
                                    onTap: () =>
                                        _confirmAndDeleteContactGroup(cg),
                                    child: const Tooltip(
                                      message: 'Eliminar Grupo de Usuarios',
                                      child: Icon(
                                        Icons.delete_outline_rounded,
                                        size: 14.5,
                                        color: AppTheme.error,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 5),
                            // Correo propio del Grupo de Usuarios
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.bgSecondary,
                                borderRadius: BorderRadius.circular(5),
                                border: Border.all(color: AppTheme.border),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.alternate_email_rounded,
                                    size: 12,
                                    color: AppTheme.accentCyan,
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: Text(
                                      (cg['group_email'] as String? ?? '')
                                              .isNotEmpty
                                          ? 'Correo grupo: ${cg['group_email']}'
                                          : 'Sin correo de lista (usa correo de cada miembro)',
                                      style: const TextStyle(
                                        fontSize: 9.8,
                                        fontFamily: 'monospace',
                                        fontWeight: FontWeight.w700,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 5),
                            Row(
                              children: [
                                Text(
                                  '👥 ${memberIds.length} miembros',
                                  style: const TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                                const Spacer(),
                                if (alertHgs.isNotEmpty)
                                  Flexible(
                                    child: Text(
                                      '🔔 Recibe de: ${alertHgs.join(", ")}',
                                      style: const TextStyle(
                                        fontSize: 9.0,
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.accentTeal,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  )
                                else
                                  const Text(
                                    'Arrastra a Col 1 o Col 2',
                                    style: TextStyle(
                                      fontSize: 9.0,
                                      color: AppTheme.textMuted,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );

                    if (!widget.canEdit) return cardBody;
                    return SelectionContainer.disabled(
                      child: Draggable<String>(
                        data: 'ug:$cgId',
                        feedback: Material(
                          elevation: 8,
                          borderRadius: BorderRadius.circular(10),
                          color: AppTheme.accentPurple,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 9,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.groups_rounded,
                                  size: 16,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Asignar Grupo: ${cg['name']} (${cg['group_email']})',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        childWhenDragging: Opacity(opacity: 0.45, child: cardBody),
                        child: cardBody,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // COLUMNA 4: USUARIOS DEL GRUPO SELECCIONADO + FICHA ACTIVE DIRECTORY (DROP TARGET DE COL 5)
  // ---------------------------------------------------------------------------
  Widget _buildAlertsCol4UsersAndAdCard() {
    final selectedCg = _alertContactGroups
        .where((cg) => cg['id'] == _selectedAlertUserGroupId)
        .firstOrNull;
    final groupMemberIds =
        ((selectedCg?['member_contact_ids'] as List?) ?? [])
            .cast<int>()
            .toSet();

    final visibleUsers = (_showAllUsersInCol4 || selectedCg == null)
        ? _alertContacts
        : _alertContacts
              .where((c) => groupMemberIds.contains(c['id'] as int))
              .toList();

    final selectedUser =
        _alertContacts
            .where((c) => c['id'] == _selectedAlertContactId)
            .firstOrNull ??
        (visibleUsers.isNotEmpty ? visibleUsers.first : null);

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          widget.canEdit &&
          selectedCg != null &&
          (details.data.startsWith('u:') || details.data.startsWith('du:')),
      onAcceptWithDetails: (details) {
        if (selectedCg != null) {
          _handleDropUserIntoContactGroup(
            dragToken: details.data,
            targetGroup: selectedCg,
          );
        }
      },
      builder: (ctx, candidateData, rejectedData) {
        final isHoveringDrop = candidateData.isNotEmpty;
        return Container(
          decoration: BoxDecoration(
            color: isHoveringDrop
                ? AppTheme.success.withValues(alpha: 0.08)
                : AppTheme.bgSecondary,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isHoveringDrop ? AppTheme.success : AppTheme.border,
              width: isHoveringDrop ? 2.0 : 1.0,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 9,
                ),
                decoration: const BoxDecoration(
                  color: AppTheme.bgCard,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.success.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Text(
                        '4',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.success,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _showAllUsersInCol4
                            ? 'TODOS (${visibleUsers.length})'
                            : (selectedCg != null
                                  ? 'EN ${selectedCg['code']} (${visibleUsers.length})'
                                  : 'USUARIOS DEL GRUPO (${visibleUsers.length})'),
                        style: const TextStyle(
                          fontSize: 10.9,
                          fontWeight: FontWeight.w900,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => _rebuildState(
                        () => _showAllUsersInCol4 = !_showAllUsersInCol4,
                      ),
                      child: Text(
                        _showAllUsersInCol4 ? 'Solo grupo' : 'Todos',
                        style: const TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (widget.canEdit) ...[
                      const SizedBox(width: 3),
                      IconButton(
                        tooltip: selectedCg != null
                            ? 'Seleccionar y añadir usuarios existentes al grupo "${selectedCg['name']}"'
                            : 'Seleccionar usuarios existentes de RackDoc / AD',
                        constraints: const BoxConstraints(),
                        padding: EdgeInsets.zero,
                        onPressed: () async {
                          final elegidas = await _showPersonPickerDialog(
                            seleccionados: groupMemberIds,
                            tituloContexto: selectedCg != null
                                ? '${selectedCg['name']}'
                                : 'RackDoc (alta masiva)',
                          );
                          if (elegidas == null) return;
                          if (selectedCg != null) {
                            final merged = <int>{
                              ...groupMemberIds,
                              ...elegidas,
                            }.toList();
                            final res = await widget.api.upsertAlertContactGroup({
                              'code': selectedCg['code'],
                              'name': selectedCg['name'],
                              'description': selectedCg['description'] ?? '',
                              'group_email': selectedCg['group_email'] ?? '',
                              'channel_webhook_url':
                                  selectedCg['channel_webhook_url'] ?? '',
                              'member_contact_ids': merged,
                            });
                            if (!mounted) return;
                            _rebuildState(() {
                              _overview = res;
                              _showAllUsersInCol4 = false;
                              if (elegidas.isNotEmpty) {
                                _selectedAlertContactId = elegidas.first;
                              }
                            });
                            _showSnack(
                              'Usuarios añadidos al grupo "${selectedCg['name']}" (${merged.length} miembros).',
                            );
                          }
                        },
                        icon: const Icon(
                          Icons.group_add_rounded,
                          size: 15,
                          color: AppTheme.accentCyan,
                        ),
                      ),
                      const SizedBox(width: 3),
                      IconButton(
                        tooltip: 'Nuevo Usuario / Contacto desde cero',
                        constraints: const BoxConstraints(),
                        padding: EdgeInsets.zero,
                        onPressed: () => _showCreateContactDialog(),
                        icon: const Icon(
                          Icons.person_add_alt_1_rounded,
                          size: 15,
                          color: AppTheme.success,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                color: AppTheme.success.withValues(alpha: 0.05),
                child: Text(
                  selectedCg != null
                      ? '📥 Arrastra usuarios desde la Columna 5 (Derecha) hacia aquí para incluirlos en "${selectedCg['name']}".'
                      : '💡 Selecciona un Grupo en la Columna 3 o arrastra usuarios desde la Columna 5.',
                  style: const TextStyle(
                    fontSize: 9.2,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ),
              // Lista superior de usuarios del grupo (también arrastrables hacia Col 1 y Col 2)
              Expanded(
                flex: 5,
                child: visibleUsers.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            selectedCg != null
                                ? 'Sin usuarios en "${selectedCg['name']}". Arrastra usuarios conocidos desde la Columna 5 (derecha) o pulsa el icono de añadir personas.'
                                : 'Sin usuarios en este grupo.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 10.2,
                              color: AppTheme.textMuted,
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: visibleUsers.length,
                        itemBuilder: (ctx, i) {
                          final c = visibleUsers[i];
                          final cId = c['id'] as int;
                          final isSelected = selectedUser?['id'] == cId;
                          final srcType =
                              (c['source_type'] as String?) ?? 'custom';
                          final srcBadge =
                              (c['source_badge'] as String?) ?? 'A Medida';
                          final hostCodes =
                              ((c['alerting_host_codes'] as List?) ?? [])
                                  .cast<String>();

                          final userTile = GestureDetector(
                            onTap: () =>
                                _rebuildState(() => _selectedAlertContactId = cId),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 120),
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? AppTheme.success.withValues(alpha: 0.09)
                                    : AppTheme.bgPrimary,
                                borderRadius: BorderRadius.circular(9),
                                border: Border.all(
                                  color: isSelected
                                      ? AppTheme.success
                                      : AppTheme.border,
                                  width: isSelected ? 1.8 : 1.0,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.person_rounded,
                                        size: 15,
                                        color: AppTheme.success,
                                      ),
                                      const SizedBox(width: 5),
                                      Expanded(
                                        child: Text(
                                          '${c['full_name']}',
                                          style: const TextStyle(
                                            fontSize: 11.0,
                                            fontWeight: FontWeight.w800,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      _buildOriginBadge(srcType, srcBadge),
                                      if (widget.canEdit) ...[
                                        const SizedBox(width: 4),
                                        InkWell(
                                          onTap: () =>
                                              _showCreateContactDialog(
                                                existing: c,
                                              ),
                                          child: const Tooltip(
                                            message: 'Editar Usuario / Contacto',
                                            child: Icon(
                                              Icons.edit_outlined,
                                              size: 13.5,
                                              color: AppTheme.textMuted,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 5),
                                        InkWell(
                                          onTap: () =>
                                              _handleRemoveOrDeleteUserFromCol4(
                                                contact: c,
                                                selectedCg: _showAllUsersInCol4
                                                    ? null
                                                    : selectedCg,
                                              ),
                                          child: Tooltip(
                                            message:
                                                (!_showAllUsersInCol4 &&
                                                    selectedCg != null)
                                                ? 'Quitar usuario del grupo o eliminar'
                                                : 'Eliminar Usuario / Contacto',
                                            child: const Icon(
                                              Icons.delete_outline_rounded,
                                              size: 14,
                                              color: AppTheme.error,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.mail_outline_rounded,
                                        size: 11,
                                        color: AppTheme.accentCyan,
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          '${c['email']}',
                                          style: const TextStyle(
                                            fontSize: 9.6,
                                            fontFamily: 'monospace',
                                            fontWeight: FontWeight.w700,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Text(
                                        '🔔 ${hostCodes.length} hosts',
                                        style: const TextStyle(
                                          fontSize: 9.0,
                                          fontWeight: FontWeight.w800,
                                          color: AppTheme.accentTeal,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );

                          if (!widget.canEdit) return userTile;
                          return SelectionContainer.disabled(
                            child: Draggable<String>(
                              data: 'u:$cId',
                              feedback: Material(
                                elevation: 8,
                                borderRadius: BorderRadius.circular(9),
                                color: AppTheme.success,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  child: Text(
                                    '👤 Asignar Usuario: ${c['full_name']} (${c['email']})',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                              childWhenDragging: Opacity(
                                opacity: 0.45,
                                child: userTile,
                              ),
                              child: userTile,
                            ),
                          );
                        },
                      ),
              ),
              // Ficha Inferior estilo Active Directory ("MemberOf" y "Hosts que le envían alarmas")
              if (selectedUser != null)
                Expanded(
                  flex: 6,
                  child: _buildActiveDirectoryUserInspector(selectedUser),
                ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // COLUMNA 5 (DERECHA): USUARIOS CONOCIDOS (DIRECTORIO AD / LOCAL / CONTACTOS) — DRAGGABLE
  // ---------------------------------------------------------------------------
  List<Map<String, dynamic>> _buildMergedKnownUsersList() {
    final result = <Map<String, dynamic>>[];
    final emailsSeen = <String>{};
    final codesSeen = <String>{};

    for (final c in _alertContacts) {
      final em = '${c['email'] ?? ''}'.trim().toLowerCase();
      final cd = '${c['code'] ?? ''}'.trim().toUpperCase();
      if (em.isNotEmpty) emailsSeen.add(em);
      if (cd.isNotEmpty) codesSeen.add(cd);
      result.add({...c, '_is_contact': true});
    }

    // Añadir también cualquier usuario conocido de Control de Acceso / Active Directory que aún no sea AlertContact
    final rawKnown = ((_overview['known_directory_users'] as List?) ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    for (final u in _directoryUsers) {
      if (!rawKnown.any((rk) => rk['id'] == u.id)) {
        rawKnown.add({
          'id': u.id,
          'username': u.username,
          'full_name': u.fullName.isEmpty ? u.username : u.fullName,
          'email': u.email,
          'role': u.role,
          'auth_source': u.authSource,
          'ad_dn': u.adDn,
          'is_active': u.isActive,
        });
      }
    }

    for (final ku in rawKnown) {
      final uname = '${ku['username'] ?? ''}'.trim();
      final em =
          '${ku['email'] ?? '$uname@empresa.local'}'.trim().toLowerCase();
      final authSrc = '${ku['auth_source'] ?? 'local'}'.toLowerCase();
      final genCode =
          'USR-${authSrc == 'ad' ? 'AD' : 'LOCAL'}-${uname.toUpperCase().replaceAll('.', '-')}'
              .substring(
                0,
                ('USR-${authSrc == 'ad' ? 'AD' : 'LOCAL'}-${uname.toUpperCase().replaceAll('.', '-')}')
                    .length
                    .clamp(0, 48),
              );
      if (emailsSeen.contains(em) || codesSeen.contains(genCode)) continue;
      emailsSeen.add(em);
      codesSeen.add(genCode);
      result.add({
        'id': -(ku['id'] as int),
        'directory_user_id': ku['id'],
        'username': uname,
        'code': genCode,
        'full_name': '${ku['full_name'] ?? uname}',
        'email': em,
        'role_title': authSrc == 'ad'
            ? '[Active Directory] Rol RBAC: ${ku['role']}'
            : '[Usuario Local] Rol RBAC: ${ku['role']}',
        'source_type': authSrc == 'ad' ? 'ad' : 'local',
        'source_badge': authSrc == 'ad' ? 'Active Directory' : 'Usuario Local',
        'ad_dn': '${ku['ad_dn'] ?? ''}',
        'member_of_group_ids': const <int>[],
        'member_of_groups': const <Map<String, dynamic>>[],
        'alerting_host_codes': const <String>[],
        '_is_contact': false,
      });
    }
    return result;
  }

  Widget _buildAlertsCol5KnownUsers() {
    final selectedCg = _alertContactGroups
        .where((cg) => cg['id'] == _selectedAlertUserGroupId)
        .firstOrNull;
    final groupMemberIds =
        ((selectedCg?['member_contact_ids'] as List?) ?? [])
            .cast<int>()
            .toSet();

    final allKnown = _buildMergedKnownUsersList();
    final q = _knownUsersSearchQuery.trim().toLowerCase();
    final filteredKnown = allKnown.where((u) {
      if (_knownUsersSourceFilter != 'all' &&
          (u['source_type'] as String? ?? 'custom') !=
              _knownUsersSourceFilter) {
        return false;
      }
      if (q.isEmpty) return true;
      final haystack =
          '${u['full_name'] ?? ''} ${u['email'] ?? ''} ${u['code'] ?? ''} ${u['role_title'] ?? ''}'
              .toLowerCase();
      return haystack.contains(q);
    }).toList();

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: const BoxDecoration(
              color: AppTheme.bgCard,
              borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
              border: Border(bottom: BorderSide(color: AppTheme.border)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.accentTeal.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    '5',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.accentTeal,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'USUARIOS CONOCIDOS (${filteredKnown.length})',
                    style: const TextStyle(
                      fontSize: 10.9,
                      fontWeight: FontWeight.w900,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.canEdit)
                  IconButton(
                    tooltip: 'Crear nuevo Usuario / Contacto en el Directorio',
                    constraints: const BoxConstraints(),
                    padding: EdgeInsets.zero,
                    onPressed: () => _showCreateContactDialog(),
                    icon: const Icon(
                      Icons.person_add_alt_1_rounded,
                      size: 16,
                      color: AppTheme.accentTeal,
                    ),
                  ),
              ],
            ),
          ),
          // Buscador y filtros de origen en Columna 5
          Container(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppTheme.border)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 28,
                  child: TextField(
                    onChanged: (v) =>
                        _rebuildState(() => _knownUsersSearchQuery = v),
                    style: const TextStyle(fontSize: 10.5),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Buscar usuario conocido (AD, Local, Correo)…',
                      hintStyle: const TextStyle(fontSize: 10),
                      prefixIcon: const Icon(Icons.search_rounded, size: 14),
                      prefixIconConstraints: const BoxConstraints(minWidth: 28),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    _buildKnownUserFilterChip('all', 'Todos'),
                    _buildKnownUserFilterChip('ad', 'AD'),
                    _buildKnownUserFilterChip('local', 'Locales'),
                    _buildKnownUserFilterChip('custom', 'A Medida'),
                  ],
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            color: AppTheme.accentTeal.withValues(alpha: 0.05),
            child: const Text(
              '💡 Arrastra cualquier usuario hacia Col 4 / Col 3 para meterlo en un Grupo, o hacia Col 1 / Col 2 para asignarle alarmas.',
              style: TextStyle(fontSize: 9.1, color: AppTheme.textSecondary),
            ),
          ),
          Expanded(
            child: filteredKnown.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'No hay usuarios que coincidan con el filtro.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: filteredKnown.length,
                    itemBuilder: (ctx, i) {
                      final u = filteredKnown[i];
                      final isContact = u['_is_contact'] == true;
                      final cId = u['id'] as int;
                      final alreadyInSelectedGroup =
                          isContact && groupMemberIds.contains(cId);
                      final srcType =
                          (u['source_type'] as String?) ?? 'custom';
                      final srcBadge =
                          (u['source_badge'] as String?) ?? 'A Medida';
                      final dragToken = isContact
                          ? 'u:$cId'
                          : 'du:${u['directory_user_id']}';

                      final card = GestureDetector(
                        onTap: () {
                          if (isContact) {
                            _rebuildState(() => _selectedAlertContactId = cId);
                          }
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppTheme.bgPrimary,
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(
                              color: alreadyInSelectedGroup
                                  ? AppTheme.success.withValues(alpha: 0.55)
                                  : AppTheme.border,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.drag_indicator_rounded,
                                    size: 14,
                                    color: AppTheme.accentTeal,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      '${u['full_name']}',
                                      style: const TextStyle(
                                        fontSize: 10.9,
                                        fontWeight: FontWeight.w800,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  _buildOriginBadge(srcType, srcBadge),
                                  if (widget.canEdit) ...[
                                    const SizedBox(width: 4),
                                    InkWell(
                                      onTap: () async {
                                        if (isContact) {
                                          await _showCreateContactDialog(
                                            existing: u,
                                          );
                                        } else {
                                          final ensured =
                                              await _ensureContactFromDirectoryEntry(
                                                u,
                                              );
                                          if (ensured != null) {
                                            await _showCreateContactDialog(
                                              existing: ensured,
                                            );
                                          }
                                        }
                                      },
                                      child: const Tooltip(
                                        message: 'Editar Usuario / Contacto',
                                        child: Icon(
                                          Icons.edit_outlined,
                                          size: 13.5,
                                          color: AppTheme.textMuted,
                                        ),
                                      ),
                                    ),
                                    if (isContact) ...[
                                      const SizedBox(width: 5),
                                      InkWell(
                                        onTap: () =>
                                            _confirmAndDeleteContact(u),
                                        child: const Tooltip(
                                          message:
                                              'Eliminar Usuario / Contacto',
                                          child: Icon(
                                            Icons.delete_outline_rounded,
                                            size: 14,
                                            color: AppTheme.error,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ],
                              ),
                              const SizedBox(height: 3),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.mail_outline_rounded,
                                    size: 11,
                                    color: AppTheme.accentCyan,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      '${u['email']}',
                                      style: const TextStyle(
                                        fontSize: 9.4,
                                        fontFamily: 'monospace',
                                        fontWeight: FontWeight.w700,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (selectedCg != null && widget.canEdit)
                                    alreadyInSelectedGroup
                                        ? Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 5,
                                              vertical: 1.5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: AppTheme.success
                                                  .withValues(alpha: 0.14),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: const Text(
                                              '✓ En grupo',
                                              style: TextStyle(
                                                fontSize: 8.5,
                                                fontWeight: FontWeight.w800,
                                                color: AppTheme.success,
                                              ),
                                            ),
                                          )
                                        : InkWell(
                                            onTap: () =>
                                                _handleDropUserIntoContactGroup(
                                                  dragToken: dragToken,
                                                  targetGroup: selectedCg,
                                                ),
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 5,
                                                    vertical: 1.5,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: AppTheme.accentTeal
                                                    .withValues(alpha: 0.14),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                                border: Border.all(
                                                  color: AppTheme.accentTeal
                                                      .withValues(alpha: 0.45),
                                                ),
                                              ),
                                              child: const Text(
                                                '⬅ Al grupo',
                                                style: TextStyle(
                                                  fontSize: 8.5,
                                                  fontWeight: FontWeight.w800,
                                                  color: AppTheme.accentTeal,
                                                ),
                                              ),
                                            ),
                                          ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );

                      if (!widget.canEdit) return card;
                      return SelectionContainer.disabled(
                        child: Draggable<String>(
                          data: dragToken,
                          feedback: Material(
                            elevation: 8,
                            borderRadius: BorderRadius.circular(9),
                            color: AppTheme.accentTeal,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.person_add_alt_1_rounded,
                                    size: 15,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Arrastrar Usuario: ${u['full_name']} (${u['email']})',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          childWhenDragging: Opacity(opacity: 0.45, child: card),
                          child: card,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildKnownUserFilterChip(String key, String label) {
    final selected = _knownUsersSourceFilter == key;
    return InkWell(
      onTap: () => _rebuildState(() => _knownUsersSourceFilter = key),
      borderRadius: BorderRadius.circular(5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.accentTeal.withValues(alpha: 0.15)
              : AppTheme.bgPrimary,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: selected ? AppTheme.accentTeal : AppTheme.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 8.8,
            fontWeight: FontWeight.w800,
            color: selected ? AppTheme.accentTeal : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildActiveDirectoryUserInspector(Map<String, dynamic> user) {
    final memberOfGroups =
        ((user['member_of_groups'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
    final alertingHgs =
        ((user['alerting_host_group_codes'] as List?) ?? []).cast<String>();
    final alertingHosts =
        ((user['alerting_host_codes'] as List?) ?? []).cast<String>();

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: const BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(11)),
        border: Border(top: BorderSide(color: AppTheme.border, width: 1.2)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.badge_rounded,
                  size: 15,
                  color: AppTheme.accentBlue,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    'FICHA ACTIVE DIRECTORY: ${user['full_name']}',
                    style: const TextStyle(
                      fontSize: 10.6,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.accentBlue,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'DN / Origen: ${user['ad_dn'] ?? user['role_title'] ?? ''}',
              style: const TextStyle(
                fontSize: 9.0,
                fontFamily: 'monospace',
                color: AppTheme.textMuted,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              'Correo personal: ${user['email']} • Horario: ${user['schedule_period'] ?? '24x7'}',
              style: const TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 7),
            const Text(
              '1. GRUPOS A LOS QUE PERTENECE (MemberOf):',
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w900,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            if (memberOfGroups.isEmpty)
              const Text(
                'No pertenece a ningún grupo todavía.',
                style: TextStyle(fontSize: 9.2, color: AppTheme.textMuted),
              )
            else
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: memberOfGroups
                    .map(
                      (g) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.accentPurple.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(
                            color: AppTheme.accentPurple.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Text(
                          '👥 ${g['name']} (${g['group_email']})',
                          style: const TextStyle(
                            fontSize: 8.8,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.accentPurple,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            const SizedBox(height: 8),
            const Text(
              '2. HOSTS Y GRUPOS DE HOST QUE LE ENVÍAN ALARMAS:',
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w900,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            if (alertingHgs.isEmpty && alertingHosts.isEmpty)
              const Text(
                'Ningún Host asignado aún. Arrastra su Grupo (Col 3) o este Usuario (Col 4 / Col 5) hacia un Grupo de Host (Col 1) o Host (Col 2).',
                style: TextStyle(fontSize: 9.0, color: AppTheme.textMuted),
              )
            else
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  ...alertingHgs.map(
                    (hgc) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.accentCyan.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '📁 $hgc',
                        style: const TextStyle(
                          fontSize: 8.8,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.accentCyan,
                        ),
                      ),
                    ),
                  ),
                  ...alertingHosts.map(
                    (hc) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.accentTeal.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '🖥️ $hc',
                        style: const TextStyle(
                          fontSize: 8.8,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.accentTeal,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceFilterChip(String key, String label) {
    final selected = _alertGroupSourceFilter == key;
    return InkWell(
      onTap: () => _rebuildState(() => _alertGroupSourceFilter = key),
      borderRadius: BorderRadius.circular(5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.accentPurple.withValues(alpha: 0.15)
              : AppTheme.bgPrimary,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: selected ? AppTheme.accentPurple : AppTheme.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 9.2,
            fontWeight: FontWeight.w800,
            color: selected ? AppTheme.accentPurple : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildOriginBadge(String srcType, String srcBadge) {
    final Color c = srcType == 'ad'
        ? AppTheme.accentBlue
        : (srcType == 'local' ? AppTheme.accentTeal : AppTheme.warning);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        srcBadge,
        style: TextStyle(
          fontSize: 8.4,
          fontWeight: FontWeight.w800,
          color: c,
        ),
      ),
    );
  }

  Widget _buildAssignedRecipientPill({
    required String label,
    required String email,
    required Color color,
    VoidCallback? onRemove,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              email.isNotEmpty ? '$label ($email)' : label,
              style: TextStyle(
                fontSize: 8.9,
                fontWeight: FontWeight.w800,
                color: color,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onRemove != null) ...[
            const SizedBox(width: 4),
            InkWell(
              onTap: onRemove,
              child: Icon(Icons.close_rounded, size: 12, color: color),
            ),
          ],
        ],
      ),
    );
  }

  Future<Map<String, dynamic>?> _ensureContactFromDirectoryEntry(
    Map<String, dynamic> dirEntry,
  ) async {
    final code = '${dirEntry['code'] ?? ''}'.trim().toUpperCase();
    final res = await widget.api.upsertAlertContact({
      'code': code,
      'full_name': '${dirEntry['full_name'] ?? ''}',
      'email': '${dirEntry['email'] ?? ''}',
      'role_title': '${dirEntry['role_title'] ?? ''}',
      'schedule_period': '24x7',
    });
    if (mounted) {
      _rebuildState(() => _overview = res);
    }
    final contacts = ((res['alert_contacts'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    return contacts
        .where((c) => '${c['code']}'.toUpperCase() == code)
        .firstOrNull;
  }

  Future<int?> _resolveContactIdFromDragToken(String dragToken) async {
    if (dragToken.startsWith('u:')) {
      return int.tryParse(dragToken.split(':').last);
    }
    if (dragToken.startsWith('du:')) {
      final dirId = int.tryParse(dragToken.split(':').last);
      if (dirId == null) return null;
      final known = _buildMergedKnownUsersList()
          .where((e) => e['directory_user_id'] == dirId)
          .firstOrNull;
      if (known == null) return null;
      final created = await _ensureContactFromDirectoryEntry(known);
      return created?['id'] as int?;
    }
    return null;
  }

  Future<void> _handleDropUserIntoContactGroup({
    required String dragToken,
    required Map<String, dynamic> targetGroup,
  }) async {
    final cid = await _resolveContactIdFromDragToken(dragToken);
    if (cid == null) return;
    final cgId = targetGroup['id'] as int;
    final currentMembers =
        ((targetGroup['member_contact_ids'] as List?) ?? [])
            .cast<int>()
            .toSet();
    if (currentMembers.contains(cid)) {
      _showSnack('El usuario ya pertenece al grupo "${targetGroup['name']}".');
      return;
    }
    currentMembers.add(cid);
    final res = await widget.api.upsertAlertContactGroup({
      'code': targetGroup['code'],
      'name': targetGroup['name'],
      'description': targetGroup['description'] ?? '',
      'group_email': targetGroup['group_email'] ?? '',
      'channel_webhook_url': targetGroup['channel_webhook_url'] ?? '',
      'member_contact_ids': currentMembers.toList(),
    });
    if (!mounted) return;
    _rebuildState(() {
      _overview = res;
      _selectedAlertUserGroupId = cgId;
      _selectedAlertContactId = cid;
      _showAllUsersInCol4 = false;
    });
    _showSnack('Usuario añadido al grupo "${targetGroup['name']}".');
  }

  Future<void> _confirmAndDeleteHostGroup(Map<String, dynamic> hg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar Grupo de Host'),
        content: Text(
          '¿Seguro que deseas eliminar el Grupo de Host "${hg['name']}" (${hg['code']})?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_outline_rounded, size: 16),
            label: const Text('Eliminar Grupo de Host'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final res = await widget.api.deleteHostGroup(hg['id'] as int);
    if (!mounted) return;
    _rebuildState(() => _overview = res);
    _showSnack('Grupo de Host "${hg['name']}" eliminado.');
  }

  Future<void> _removeHostFromHostGroup(
    Map<String, dynamic> hg,
    int assetId,
  ) async {
    final members =
        ((hg['member_asset_ids'] as List?) ?? []).cast<int>().toSet()
          ..remove(assetId);
    final res = await widget.api.upsertHostGroup({
      'code': hg['code'],
      'name': hg['name'],
      'category': hg['category'] ?? 'compute',
      'environment': hg['environment'] ?? 'production',
      'color_hex': hg['color_hex'] ?? '#06B6D4',
      'description': hg['description'] ?? '',
      'member_asset_ids': members.toList(),
    });
    if (!mounted) return;
    _rebuildState(() => _overview = res);
    _showSnack('Host quitado del grupo "${hg['name']}".');
  }

  Future<void> _confirmAndDeleteContactGroup(Map<String, dynamic> cg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar Grupo de Usuarios'),
        content: Text(
          '¿Seguro que deseas eliminar el Grupo de Usuarios "${cg['name']}" (${cg['code']})?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_outline_rounded, size: 16),
            label: const Text('Eliminar Grupo'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final res = await widget.api.deleteAlertContactGroup(cg['id'] as int);
    if (!mounted) return;
    _rebuildState(() => _overview = res);
    _showSnack('Grupo de Usuarios "${cg['name']}" eliminado.');
  }

  Future<void> _confirmAndDeleteContact(Map<String, dynamic> c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar Usuario / Contacto'),
        content: Text(
          '¿Seguro que deseas eliminar el usuario "${c['full_name']}" (${c['email']}) de las alarmas SRE?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_outline_rounded, size: 16),
            label: const Text('Eliminar Usuario'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final res = await widget.api.deleteAlertContact(c['id'] as int);
    if (!mounted) return;
    _rebuildState(() => _overview = res);
    _showSnack('Usuario "${c['full_name']}" eliminado.');
  }

  Future<void> _handleRemoveOrDeleteUserFromCol4({
    required Map<String, dynamic> contact,
    required Map<String, dynamic>? selectedCg,
  }) async {
    if (selectedCg == null) {
      await _confirmAndDeleteContact(contact);
      return;
    }
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Gestionar "${contact['full_name']}"'),
        content: Text(
          '¿Deseas quitar a "${contact['full_name']}" únicamente del grupo "${selectedCg['name']}" '
          'o eliminar su contacto permanentemente?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancelar'),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'delete_all'),
            icon: const Icon(
              Icons.delete_forever_rounded,
              size: 16,
              color: AppTheme.error,
            ),
            label: const Text(
              'Eliminar Contacto del Sistema',
              style: TextStyle(color: AppTheme.error),
            ),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, 'remove_from_group'),
            icon: const Icon(Icons.person_remove_rounded, size: 16),
            label: Text('Quitar de "${selectedCg['name']}"'),
          ),
        ],
      ),
    );
    if (action == 'remove_from_group') {
      final cid = contact['id'] as int;
      final members =
          ((selectedCg['member_contact_ids'] as List?) ?? [])
              .cast<int>()
              .toSet()
            ..remove(cid);
      final res = await widget.api.upsertAlertContactGroup({
        'code': selectedCg['code'],
        'name': selectedCg['name'],
        'description': selectedCg['description'] ?? '',
        'group_email': selectedCg['group_email'] ?? '',
        'channel_webhook_url': selectedCg['channel_webhook_url'] ?? '',
        'member_contact_ids': members.toList(),
      });
      if (!mounted) return;
      _rebuildState(() => _overview = res);
      _showSnack(
        'Usuario "${contact['full_name']}" quitado del grupo "${selectedCg['name']}".',
      );
    } else if (action == 'delete_all') {
      final res = await widget.api.deleteAlertContact(contact['id'] as int);
      if (!mounted) return;
      _rebuildState(() => _overview = res);
      _showSnack('Usuario "${contact['full_name']}" eliminado.');
    }
  }

  Future<void> _handleDropRecipientOnTarget({
    required String dragToken,
    required String scopeType,
    int? hostGroupId,
    int? assetId,
    required String targetName,
  }) async {
    final isGroup = dragToken.startsWith('ug:');
    int? id;
    if (isGroup) {
      id = int.tryParse(dragToken.split(':').last);
    } else {
      id = await _resolveContactIdFromDragToken(dragToken);
    }
    if (id == null) return;

    final res = await widget.api.createNotificationRule({
      'name': 'Enrutamiento AD/Alarma -> $targetName',
      'description': 'Asignado arrastrando en Matriz Active Directory',
      'enabled': true,
      'scope_type': scopeType,
      'host_group_id': hostGroupId,
      'asset_id': assetId,
      'contact_group_ids': isGroup ? [id] : <int>[],
      'contact_ids': isGroup ? <int>[] : [id],
      'send_email': true,
      'send_webhook': true,
      'only_on_hard_state': true,
    });
    _rebuildState(() => _overview = res);
    _showSnack('Alarma asignada a $targetName.');
  }

  Future<void> _removeRecipientFromTarget({
    required String scopeType,
    int? hostGroupId,
    int? assetId,
    int? removeCgId,
    int? removeContactId,
  }) async {
    final matchingRules = _notificationRules.where((r) {
      if (scopeType == 'host_group') {
        return r['scope_type'] == 'host_group' &&
            r['host_group_id'] == hostGroupId;
      }
      return r['scope_type'] == 'single_host' && r['asset_id'] == assetId;
    }).toList();

    final currentCgIds = <int>{};
    final currentContactIds = <int>{};
    for (final r in matchingRules) {
      for (final id in ((r['contact_group_ids'] as List?) ?? [])) {
        currentCgIds.add(id as int);
      }
      for (final id in ((r['contact_ids'] as List?) ?? [])) {
        currentContactIds.add(id as int);
      }
    }
    if (removeCgId != null) currentCgIds.remove(removeCgId);
    if (removeContactId != null) currentContactIds.remove(removeContactId);

    final res = await widget.api.createNotificationRule({
      'name': 'Enrutamiento Actualizado',
      'description': '__REPLACE__',
      'enabled': true,
      'scope_type': scopeType,
      'host_group_id': hostGroupId,
      'asset_id': assetId,
      'contact_group_ids': currentCgIds.toList(),
      'contact_ids': currentContactIds.toList(),
      'send_email': true,
      'send_webhook': true,
      'only_on_hard_state': true,
    });
    _rebuildState(() => _overview = res);
  }

  Widget _buildAlertsBottomMaintenanceAndLogsBar() {
    return Container(
      height: 125,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: AppTheme.bgSecondary,
        border: Border(top: BorderSide(color: AppTheme.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Ventanas de mantenimiento
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '🛠️ VENTANAS DE MANTENIMIENTO (${_maintenanceWindows.length})',
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.accentCyan,
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: ListView(
                    children: _maintenanceWindows
                        .map(
                          (w) => Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.build_circle_rounded,
                                  size: 13,
                                  color: w['is_active'] == true
                                      ? AppTheme.accentCyan
                                      : AppTheme.textMuted,
                                ),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: Text(
                                    '${w['title']} (${w['is_active'] == true ? "ACTIVA" : "FINALIZADA"}) • ${w['reason']}',
                                    style: const TextStyle(fontSize: 10),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (w['is_active'] == true && widget.canEdit)
                                  TextButton(
                                    style: TextButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                      ),
                                      minimumSize: Size.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: () async {
                                      final res = await widget.api
                                          .stopMaintenanceWindow(
                                            w['id'] as int,
                                          );
                                      _rebuildState(() => _overview = res);
                                    },
                                    child: const Text(
                                      'Finalizar',
                                      style: TextStyle(fontSize: 9.5),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 20),
          // Bitácora de envíos de correo / webhook
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '📨 BITÁCORA DE CORREOS Y AVISOS ENVIADOS (${_alertLogs.length})',
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.warning,
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: ListView(
                    children: _alertLogs
                        .take(12)
                        .map(
                          (lg) => Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(
                              '• [${lg['event_state']}] ${lg['asset_code']} ➔ ${lg['recipients_summary']} (${_NetworkHostsViewState._rotuloEntrega(lg['delivery_status'])})',
                              style: const TextStyle(fontSize: 9.8),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 2 (EN MODO 8. ALARMAS SRE): OBJETIVOS SLO / SLI, ERROR BUDGETS & SRE
  // ===========================================================================

  Widget _buildSloSreObjectivesTab() {
    final s = _summary;
    final hostsUp = (s['hosts_up'] as int?) ?? 0;
    final hostsDown = (s['hosts_down'] as int?) ?? 0;
    final hostsUnreach = (s['hosts_unreachable'] as int?) ?? 0;
    final totalHosts = hostsUp + hostsDown + hostsUnreach;
    final hostSli = totalHosts > 0 ? (hostsUp / totalHosts) * 100.0 : 100.0;

    final svcOk = (s['services_ok'] as int?) ?? 0;
    final svcWarn = (s['services_warning'] as int?) ?? 0;
    final svcCrit = (s['services_critical'] as int?) ?? 0;
    final totalServices = svcOk + svcWarn + svcCrit;
    final serviceSli =
        totalServices > 0 ? (svcOk / totalServices) * 100.0 : 100.0;

    // Cálculo de Latencia y Saturación sobre los hosts inventariados
    final allChecks = <Map<String, dynamic>>[
      for (final h in _hosts)
        ...((h['service_checks'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map)),
    ];
    int fastChecks = 0;
    double avgLatencyMs = 0.0;
    if (allChecks.isNotEmpty) {
      double sumLat = 0.0;
      for (final chk in allChecks) {
        final ms = (chk['latency_ms'] as num?)?.toDouble() ?? 12.0;
        sumLat += ms;
        if (ms < 50.0) fastChecks++;
      }
      avgLatencyMs = sumLat / allChecks.length;
    }
    final latencySli =
        allChecks.isNotEmpty ? (fastChecks / allChecks.length) * 100.0 : 100.0;

    int unsaturatedHosts = 0;
    double maxCpuSeen = 0.0;
    double maxMemSeen = 0.0;
    for (final h in _hosts) {
      final cpu = (h['cpu_pct'] as num?)?.toDouble() ?? 0.0;
      final mem = (h['memory_pct'] as num?)?.toDouble() ?? 0.0;
      final disk = (h['disk_pct'] as num?)?.toDouble() ?? 0.0;
      if (cpu > maxCpuSeen) maxCpuSeen = cpu;
      if (mem > maxMemSeen) maxMemSeen = mem;
      if (cpu < 85.0 && mem < 90.0 && disk < 90.0) {
        unsaturatedHosts++;
      }
    }
    final saturationSli =
        _hosts.isNotEmpty ? (unsaturatedHosts / _hosts.length) * 100.0 : 100.0;

    // Continuidad criptográfica CertScope SSL/TLS
    final certSummary =
        (_certScopeOverview?['summary'] as Map?)?.cast<String, dynamic>() ?? {};
    final totalCerts = (certSummary['total'] as int?) ?? 0;
    final expiredCerts = (certSummary['expired'] as int?) ?? 0;
    final certSli = totalCerts > 0
        ? (((totalCerts - expiredCerts).clamp(0, totalCerts)) / totalCerts) *
              100.0
        : 100.0;

    // Ventana mensual SRE: 30 días = 43.200 minutos
    const windowMinutes = 43200.0;

    Map<String, dynamic> calcErrorBudget({
      required double currentSli,
      required double targetSlo,
    }) {
      final allowedErrorPct = (100.0 - targetSlo).clamp(0.001, 100.0);
      final budgetTotalMin = windowMinutes * (allowedErrorPct / 100.0);
      final currentErrorPct = (100.0 - currentSli).clamp(0.0, 100.0);
      final consumedRatio =
          (currentErrorPct / allowedErrorPct).clamp(0.0, 10.0);
      final consumedMin =
          (budgetTotalMin * consumedRatio).clamp(0.0, budgetTotalMin);
      final remainingMin =
          (budgetTotalMin - consumedMin).clamp(0.0, budgetTotalMin);
      final burnRate = consumedRatio;
      return {
        'budget_total_min': budgetTotalMin,
        'consumed_min': consumedMin,
        'remaining_min': remainingMin,
        'remaining_pct':
            ((remainingMin / budgetTotalMin) * 100.0).clamp(0.0, 100.0),
        'burn_rate': burnRate,
      };
    }

    final sloDefinitions = <Map<String, dynamic>>[
      {
        'code': 'SLO-INFRA-AVAIL',
        'title': 'Disponibilidad de Infraestructura (Hosts & Racks)',
        'signal': 'Availability (Golden Signal)',
        'sli_formula': 'hosts_up / (hosts_up + hosts_down + hosts_unreachable)',
        'target_slo': 99.90,
        'current_sli': hostSli,
        'detail':
            '$hostsUp UP de $totalHosts activos • $hostsDown DOWN • $hostsUnreach UNREACHABLE',
        'icon': Icons.dns_rounded,
        'color': AppTheme.accentCyan,
      },
      {
        'code': 'SLO-SVC-HEARTBEAT',
        'title': 'Disponibilidad de Servicios Críticos (HTTP/TCP/DB)',
        'signal': 'Errors / Success Rate',
        'sli_formula': 'services_ok / total_active_service_checks',
        'target_slo': 99.50,
        'current_sli': serviceSli,
        'detail':
            '$svcOk OK de $totalServices chequeos • $svcWarn WARNING • $svcCrit CRITICAL',
        'icon': Icons.monitor_heart_rounded,
        'color': AppTheme.success,
      },
      {
        'code': 'SLO-NET-LATENCY',
        'title': 'Latencia de Red y Respuesta de Servicios (< 50 ms)',
        'signal': 'Latency (Golden Signal)',
        'sli_formula': 'checks_with_latency_under_50ms / total_checks',
        'target_slo': 99.00,
        'current_sli': latencySli,
        'detail':
            '$fastChecks/${allChecks.length} respuestas < 50 ms • Media actual: ${avgLatencyMs.toStringAsFixed(1)} ms',
        'icon': Icons.speed_rounded,
        'color': AppTheme.accentBlue,
      },
      {
        'code': 'SLO-CAP-SATURATION',
        'title': 'Capacidad Libre sin Saturación (CPU < 85%, RAM/Disco < 90%)',
        'signal': 'Saturation (Golden Signal)',
        'sli_formula': 'hosts_within_safe_thresholds / total_monitored_hosts',
        'target_slo': 98.00,
        'current_sli': saturationSli,
        'detail':
            '$unsaturatedHosts/${_hosts.length} dentro de umbral • Pico CPU ${maxCpuSeen.toStringAsFixed(0)}% • Pico RAM ${maxMemSeen.toStringAsFixed(0)}%',
        'icon': Icons.memory_rounded,
        'color': AppTheme.accentPurple,
      },
      {
        'code': 'SLO-SEC-CERTSCOPE',
        'title': 'Continuidad Criptográfica SSL/TLS (0 Certificados Expirados)',
        'signal': 'Security & Compliance SLO',
        'sli_formula': '(total_certs - expired_certs) / total_certs',
        'target_slo': 100.00,
        'current_sli': certSli,
        'detail':
            '${totalCerts - expiredCerts}/$totalCerts vigentes en 7. CertScope • $expiredCerts expirados',
        'icon': Icons.verified_user_rounded,
        'color': AppTheme.accentTeal,
      },
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 1. Banner Superior de Filosofía SRE (SLI / SLO / SLA / Error Budget)
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
                        Icons.track_changes_rounded,
                        color: AppTheme.accentCyan,
                        size: 22,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'PANEL DE FIABILIDAD SRE (SITE RELIABILITY ENGINEERING) — OBJETIVOS SLO, MÉTRICAS SLI & ERROR BUDGETS (30 DÍAS)',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _tabController.animateTo(0),
                        icon: const Icon(
                          Icons.notifications_active_rounded,
                          size: 14,
                        ),
                        label: const Text(
                          'Configurar Enrutamiento Alarmas',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _tabController.animateTo(2),
                        icon: const Icon(Icons.menu_book_rounded, size: 14),
                        label: const Text(
                          'Playbooks Ansible & Documentación',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Basado en las prácticas de Google SRE: un SLI (Service Level Indicator) mide en tiempo real el comportamiento de la infraestructura desde Prometheus, Nagios Heartbeats, CMDB y CertScope; un SLO (Service Level Objective) fija el umbral objetivo de fiabilidad; y el Error Budget (Presupuesto de Error en una ventana móvil de 30 días = 43.200 min) determina si se pueden desplegar cambios rápido o si hay que priorizar estabilidad y remediación.',
                style: TextStyle(fontSize: 11.4, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 12),
              // Los 4 Golden Signals aplicados a RackDoc
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _buildGoldenSignalMiniCard(
                    signal: '1. LATENCIA (Latency)',
                    metric: '${avgLatencyMs.toStringAsFixed(1)} ms media',
                    desc: 'Tiempo de respuesta ICMP/TCP/HTTP en 4. Red & Host',
                    color: AppTheme.accentBlue,
                    icon: Icons.timer_outlined,
                  ),
                  _buildGoldenSignalMiniCard(
                    signal: '2. TRÁFICO (Traffic)',
                    metric:
                        '${s['total_snmp_ports'] ?? 0} bocas / ${_techStacks.length} stacks',
                    desc: 'Caudal de red SNMP y peticiones req/s en Prometheus',
                    color: AppTheme.accentCyan,
                    icon: Icons.swap_calls_rounded,
                  ),
                  _buildGoldenSignalMiniCard(
                    signal: '3. ERRORES (Errors)',
                    metric:
                        '$hostsDown Hosts DOWN • $svcCrit Checks CRITICAL',
                    desc: 'Fallos explícitos HTTP 5xx, timeouts TCP o caída SNMP',
                    color: (hostsDown + svcCrit) == 0
                        ? AppTheme.success
                        : AppTheme.error,
                    icon: Icons.error_outline_rounded,
                  ),
                  _buildGoldenSignalMiniCard(
                    signal: '4. SATURACIÓN (Saturation)',
                    metric:
                        'Máx CPU ${maxCpuSeen.toStringAsFixed(0)}% • RAM ${maxMemSeen.toStringAsFixed(0)}%',
                    desc: 'Capacidad comprometida en CPU, RAM, Disco o Bocas',
                    color: maxCpuSeen < 85 ? AppTheme.accentTeal : AppTheme.warning,
                    icon: Icons.speed_rounded,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 2. Tarjetas de Objetivos SLO & Error Budgets (30 días = 43.200 min)
        const Text(
          'OBJETIVOS DE NIVEL DE SERVICIO (SLO) ACTIVOS Y PRESUPUESTO DE ERROR (ERROR BUDGET 30 DÍAS)',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.4,
            color: AppTheme.accentCyan,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            for (final slo in sloDefinitions)
              _buildSloObjectiveCard(
                slo: slo,
                budget: calcErrorBudget(
                  currentSli: slo['current_sli'] as double,
                  targetSlo: slo['target_slo'] as double,
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),

        // 3. Matriz SRE por HostGroup / Stack de Negocio y Política de Actuación ante Burn Rate
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 58,
              child: Container(
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
                          Icons.layers_rounded,
                          color: AppTheme.accentCyan,
                          size: 18,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'CUMPLIMIENTO SLI / SLO POR GRUPO DE HOST Y SERVICIO DE NEGOCIO',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    for (final hg in _hostGroups)
                      Builder(
                        builder: (context) {
                          final hgId = hg['id'] as int;
                          final members = _hosts.where((h) {
                            final ids =
                                ((h['host_group_ids'] as List?) ?? []).cast<int>();
                            return ids.contains(hgId);
                          }).toList();
                          final upCount = members
                              .where((h) => h['nagios_state'] == 'UP')
                              .length;
                          final sliPct = members.isNotEmpty
                              ? (upCount / members.length) * 100.0
                              : 100.0;
                          final meetsSlo = sliPct >= 99.0;
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.bgCard,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: meetsSlo
                                    ? AppTheme.border
                                    : AppTheme.error.withValues(alpha: 0.6),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  meetsSlo
                                      ? Icons.check_circle_rounded
                                      : Icons.warning_amber_rounded,
                                  size: 16,
                                  color: meetsSlo
                                      ? AppTheme.success
                                      : AppTheme.error,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${hg['name']} (${hg['code']})',
                                        style: const TextStyle(
                                          fontSize: 11.8,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      Text(
                                        '${members.length} hosts asociados • $upCount UP • Enrutado a ${((hg['contact_group_names'] as List?) ?? []).join(', ').isEmpty ? 'Guardia SRE Global' : ((hg['contact_group_names'] as List?) ?? []).join(', ')}',
                                        style: const TextStyle(
                                          fontSize: 10.5,
                                          color: AppTheme.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: (meetsSlo
                                            ? AppTheme.success
                                            : AppTheme.error)
                                        .withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    'SLI ${sliPct.toStringAsFixed(1)}% (SLO 99.0%)',
                                    style: TextStyle(
                                      fontSize: 10.8,
                                      fontWeight: FontWeight.w900,
                                      color: meetsSlo
                                          ? AppTheme.success
                                          : AppTheme.error,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 42,
              child: Container(
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
                          Icons.policy_rounded,
                          color: AppTheme.warning,
                          size: 18,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'POLÍTICA SRE DE ERROR BUDGET Y REGLAS DE ESCALADO',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _buildSrePolicyRuleItem(
                      badge: 'Burn Rate < 1.0x (Verde)',
                      title: 'Presupuesto Saludable — Despliegues Abiertos',
                      desc:
                          'Se permiten despliegues continuos vía Ansible. Las ventanas de mantenimiento programadas (`POST /api/v1/automation/webhook/maintenance`) congelan el consumo de Error Budget y silencian falsos avisos.',
                      color: AppTheme.success,
                    ),
                    const SizedBox(height: 8),
                    _buildSrePolicyRuleItem(
                      badge: 'Burn Rate 1.0x – 2.5x (Ámbar)',
                      title: 'Consumo Acelerado — Alerta Preventiva a Guardia',
                      desc:
                          'Se envía notificación SMTP a los grupos AD asignados al HostGroup afectado. Se revisan cuellos de botella en las gráficas TSDB de Prometheus (CPU/RAM/Latencia) y certificados próximos a caducar.',
                      color: AppTheme.warning,
                    ),
                    const SizedBox(height: 8),
                    _buildSrePolicyRuleItem(
                      badge: 'Burn Rate > 2.5x o Budget 0% (Rojo)',
                      title: 'Error Budget Agotado — Freeze de Cambios & Postmortem',
                      desc:
                          'Se congelan despliegues no críticos (salvo parches de seguridad o remediación). El incidente requiere diagnóstico en la topología padre/hijo (evitando tormentas de alarmas por nodos UNREACHABLE).',
                      color: AppTheme.error,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildGoldenSignalMiniCard({
    required String signal,
    required String metric,
    required String desc,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      width: 285,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(icon, size: 17, color: color),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  signal,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  metric,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  desc,
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSloObjectiveCard({
    required Map<String, dynamic> slo,
    required Map<String, dynamic> budget,
  }) {
    final currentSli = slo['current_sli'] as double;
    final targetSlo = slo['target_slo'] as double;
    final meetsSlo = currentSli >= targetSlo;
    final remainingPct = budget['remaining_pct'] as double;
    final remainingMin = budget['remaining_min'] as double;
    final totalMin = budget['budget_total_min'] as double;
    final burnRate = budget['burn_rate'] as double;
    final statusColor = meetsSlo
        ? AppTheme.success
        : (remainingPct > 25.0 ? AppTheme.warning : AppTheme.error);

    return Container(
      width: 480,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: statusColor.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                slo['icon'] as IconData,
                size: 18,
                color: slo['color'] as Color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${slo['code']} — ${slo['title']}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  meetsSlo ? 'CUMPLIENDO SLO' : 'SLO EN RIESGO',
                  style: TextStyle(
                    fontSize: 9.8,
                    fontWeight: FontWeight.w900,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Señal: ${slo['signal']} • Fórmula SLI: ${slo['sli_formula']}',
            style: const TextStyle(
              fontSize: 10.2,
              fontFamily: 'monospace',
              color: AppTheme.textMuted,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildTechMetricBadge(
                'SLI Actual',
                '${currentSli.toStringAsFixed(2)}%',
                statusColor,
              ),
              _buildTechMetricBadge(
                'Objetivo SLO',
                '${targetSlo.toStringAsFixed(2)}%',
                AppTheme.accentCyan,
              ),
              _buildTechMetricBadge(
                'Burn Rate',
                '${burnRate.toStringAsFixed(2)}x',
                burnRate <= 1.0 ? AppTheme.success : AppTheme.warning,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Error Budget restante (30d): ${remainingPct.toStringAsFixed(0)}%',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textSecondary,
                ),
              ),
              Text(
                '${remainingMin.toStringAsFixed(0)} min libres de ${totalMin.toStringAsFixed(0)} min/mes',
                style: const TextStyle(
                  fontSize: 10.2,
                  color: AppTheme.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: (remainingPct / 100.0).clamp(0.0, 1.0),
              minHeight: 7,
              backgroundColor: AppTheme.bgPrimary,
              valueColor: AlwaysStoppedAnimation<Color>(statusColor),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${slo['detail']}',
            style: const TextStyle(
              fontSize: 10.8,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSrePolicyRuleItem({
    required String badge,
    required String title,
    required String desc,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: 9.8,
                    fontWeight: FontWeight.w900,
                    color: color,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11.2,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            desc,
            style: const TextStyle(
              fontSize: 10.5,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
