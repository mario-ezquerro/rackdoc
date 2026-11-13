part of '../datacenter_floor_view.dart';

/// Lienzo arquitectónico 2D de sala técnica, cajas cenitales de racks, pines
/// arrastrables de dispositivos de planta, librería izquierda y barra de controles.
extension _DatacenterCanvas2dSectionExt on _DatacenterFloorViewState {
  Widget _buildTopDownRackBox({
    required RackSummary rk,
    required double canvasW,
    required double canvasH,
  }) {
    final normPos = _rackPositions[rk.id] ?? const Offset(0.25, 0.35);
    final baseSize = _rackSizes[rk.id] ?? const Size(120.0, 90.0);
    final rot = _rackRotations[rk.id] ?? 0;
    final isSelected = _selectedRackIds.contains(rk.id);

    final boxW = baseSize.width;
    final boxH = baseSize.height;
    final leftPx = (normPos.dx * canvasW)
        .clamp(8.0, (canvasW - boxW - 8.0).clamp(8.0, canvasW));
    final topPx = (normPos.dy * canvasH)
        .clamp(8.0, (canvasH - boxH - 8.0).clamp(8.0, canvasH));

    final isCold = rk.aisleType == 'cold';
    final frontStripColor = isCold
        ? AppPalette.sky600
        : AppPalette.blue600;

    return Positioned(
      left: leftPx,
      top: topPx,
      width: boxW,
      height: boxH,
      child: Tooltip(
        message:
            '${rk.code} (${rk.name})\n• 1 Clic: Seleccionar Rack (Mayús+Clic para selección múltiple)\n• Doble Clic: Abrir en 3. Rack Editor\n• Arrastrar: Mover Rack (o grupo seleccionado)',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _rebuildState(() {
              _selectedFloorDeviceId = null;
              _editingDeviceId = null;
              if (_isShiftPressed) {
                if (_selectedRackIds.contains(rk.id)) {
                  _selectedRackIds.remove(rk.id);
                } else {
                  _selectedRackIds.add(rk.id);
                }
              } else {
                _selectedRackIds
                  ..clear()
                  ..add(rk.id);
              }
            });
          },
          onDoubleTap: () => widget.onOpenRack(rk.id),
          onPanStart: (_) {
            _rebuildState(() {
              _selectedFloorDeviceId = null;
              _editingDeviceId = null;
              if (!_selectedRackIds.contains(rk.id)) {
                if (!_isShiftPressed) {
                  _selectedRackIds.clear();
                }
                _selectedRackIds.add(rk.id);
              }
            });
            final targetIds = _selectedRackIds.contains(rk.id)
                ? _selectedRackIds
                : <int>{rk.id};
            _pushUndoSnapshot(
              description: targetIds.length > 1
                  ? 'Mover ${targetIds.length} Racks'
                  : 'Mover Rack ${rk.code}',
              affectedRackIds: targetIds,
            );
          },
          onPanUpdate: (details) {
            final dxNorm = details.delta.dx / canvasW;
            final dyNorm = details.delta.dy / canvasH;
            final targetIds = _selectedRackIds.contains(rk.id)
                ? _selectedRackIds
                : <int>{rk.id};
            _rebuildState(() {
              for (final id in targetIds) {
                final cur = _rackPositions[id] ?? const Offset(0.25, 0.35);
                final nextX = (cur.dx + dxNorm).clamp(0.01, 0.92);
                final nextY = (cur.dy + dyNorm).clamp(0.01, 0.90);
                _rackPositions[id] = Offset(nextX, nextY);
              }
            });
          },
          onPanEnd: (_) {
            final targetIds = _selectedRackIds.contains(rk.id)
                ? _selectedRackIds.toList()
                : <int>[rk.id];
            _saveMultipleRacksGeometry(targetIds);
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.move,
            child: Container(
            decoration: BoxDecoration(
              color: isSelected
                  ? AppPalette.blue900
                  : AppPalette.slate900,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isSelected
                    ? const Color(0xFFFACC15)
                    : AppPalette.sky400,
                width: isSelected ? 2.8 : 1.8,
              ),
              boxShadow: [
                BoxShadow(
                  color: isSelected
                      ? const Color(0x66FACC15)
                      : const Color(0x33000000),
                  blurRadius: isSelected ? 12 : 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Indicador del lado FRONT del Rack según su rotación (0=Arriba, 90=Derecha, 180=Abajo, 270=Izquierda)
              _buildFrontEdgeStrip(rot, frontStripColor),

              // Contenido central del dibujo del Rack en planta (Numeración / Código + Nombre + Acciones)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Botón rotar orientación Front/Back
                        InkWell(
                          onTap: () {
                            _pushUndoSnapshot(
                              description: 'Rotar Rack ${rk.code}',
                              affectedRackIds: [rk.id],
                            );
                            _rebuildState(() {
                              _rackRotations[rk.id] = ((rot + 90) % 360);
                            });
                            _saveRackGeometry(rk.id);
                          },
                          child: const Tooltip(
                            message: 'Rotar orientación Front/Back del Rack 90°',
                            child: Icon(
                              Icons.rotate_right,
                              size: 14,
                              color: AppPalette.slate400,
                            ),
                          ),
                        ),
                        // Botón editar numeración / nombre y botón eliminar Rack
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            InkWell(
                              onTap: () => _showRenameRackDialog(rk),
                              child: const Tooltip(
                                message: 'Cambiar numeración o nombre del Rack',
                                child: Icon(
                                  Icons.edit_outlined,
                                  size: 13,
                                  color: AppPalette.slate400,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            InkWell(
                              onTap: () => _confirmDeleteRack(rk),
                              child: const Tooltip(
                                message: 'Eliminar este Rack',
                                child: Icon(
                                  Icons.delete_outline,
                                  size: 14,
                                  color: AppPalette.red300,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      rk.code,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.3,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      rk.name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppPalette.sky200,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${rk.totalUnits}U • ${rk.deviceCount} eq.',
                      style: const TextStyle(
                        color: AppPalette.slate400,
                        fontSize: 9.5,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (rk.powerCablesCount > 0 ||
                        rk.fiberCablesCount > 0 ||
                        rk.ethCablesCount > 0) ...[
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: 3,
                        runSpacing: 2,
                        alignment: WrapAlignment.center,
                        children: [
                          if (rk.powerCablesCount > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0x44EA580C),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: const Color(0xFFFB923C),
                                  width: 0.7,
                                ),
                              ),
                              child: Text(
                                '⚡${rk.powerCablesCount}',
                                style: const TextStyle(
                                  color: Color(0xFFFED7AA),
                                  fontSize: 8.0,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          if (rk.fiberCablesCount > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0x4406B6D4),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: const Color(0xFF22D3EE),
                                  width: 0.7,
                                ),
                              ),
                              child: Text(
                                '🌐${rk.fiberCablesCount}',
                                style: const TextStyle(
                                  color: Color(0xFFCFFAFE),
                                  fontSize: 8.0,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          if (rk.ethCablesCount > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0x442563EB),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: const Color(0xFF60A5FA),
                                  width: 0.7,
                                ),
                              ),
                              child: Text(
                                '🔌${rk.ethCablesCount}',
                                style: const TextStyle(
                                  color: AppPalette.blue100,
                                  fontSize: 8.0,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 2),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: rk.offlineCount > 0
                            ? const Color(0x44DC2626)
                            : (rk.warningCount > 0
                                ? const Color(0x44D97706)
                                : (rk.onlineCount > 0
                                    ? const Color(0x3316A34A)
                                    : const Color(0x3364748B))),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: rk.offlineCount > 0
                              ? const Color(0xFFF87171)
                              : (rk.warningCount > 0
                                  ? const Color(0xFFFBBF24)
                                  : (rk.onlineCount > 0
                                      ? const Color(0xFF4ADE80)
                                      : AppPalette.slate400)),
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        [
                          '⚪${rk.unmonitoredCount}',
                          '🟢${rk.onlineCount}',
                          if (rk.warningCount > 0) '🟠${rk.warningCount}',
                          '🔴${rk.offlineCount}',
                        ].join(' '),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8.5,
                          fontWeight: FontWeight.w800,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Spacer(),
                  ],
                ),
              ),

              // Tirador de Redimensionado (Resize Handle) en la esquina inferior derecha
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) {
                    _pushUndoSnapshot(
                      description: 'Redimensionar Rack ${rk.code}',
                      affectedRackIds: [rk.id],
                    );
                  },
                  onPanUpdate: (details) {
                    _rebuildState(() {
                      final curSize = _rackSizes[rk.id] ?? baseSize;
                      final nextW =
                          (curSize.width + details.delta.dx).clamp(76.0, 300.0);
                      final nextH =
                          (curSize.height + details.delta.dy).clamp(64.0, 280.0);
                      _rackSizes[rk.id] = Size(nextW, nextH);
                    });
                  },
                  onPanEnd: (_) => _saveRackGeometry(rk.id),
                  child: Tooltip(
                    message: 'Arrastra para dimensionar el tamaño del Rack en el plano',
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: const BoxDecoration(
                        color: AppPalette.sky400,
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(6),
                          bottomRight: Radius.circular(4),
                        ),
                      ),
                      child: const Icon(
                        Icons.open_in_full_rounded,
                        size: 11,
                        color: AppPalette.slate900,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        ),
        ),
      ),
    );
  }

  Widget _buildFrontEdgeStrip(int rot, Color color) {
    if (rot == 90) {
      return Positioned(
        right: 0,
        top: 0,
        bottom: 0,
        width: 5,
        child: Container(color: color),
      );
    } else if (rot == 180) {
      return Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        height: 5,
        child: Container(color: color),
      );
    } else if (rot == 270) {
      return Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: 5,
        child: Container(color: color),
      );
    }
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: 5,
      child: Container(color: color),
    );
  }

  // ===========================================================================
  // COLUMNA IZQUIERDA: DEVICES LIBRARY POR FAMILIAS DESPLEGABLES + A MEDIDA
  // ===========================================================================
  Widget _buildLeftDevicesLibraryPanel(FloorNode floor) {
    final query = _deviceLibrarySearch.trim().toLowerCase();
    final filteredCatalog = _allCatalogItems.where((item) {
      if (query.isEmpty) return true;
      return item.label.toLowerCase().contains(query) ||
          item.category.toLowerCase().contains(query) ||
          item.groupName.toLowerCase().contains(query) ||
          item.prefix.toLowerCase().contains(query);
    }).toList();

    final grouped = <String, List<_FloorDeviceCatalogItem>>{};
    for (final g in _DatacenterFloorViewState._libraryGroupOrder) {
      grouped[g] = [];
    }
    for (final item in filteredCatalog) {
      grouped.putIfAbsent(item.groupName, () => []).add(item);
    }

    IconData groupIconFor(String g) {
      if (g.startsWith('Sensores')) return Icons.thermostat_rounded;
      if (g.startsWith('Seguridad')) return Icons.videocam_outlined;
      if (g.startsWith('Red')) return Icons.hub_outlined;
      if (g.startsWith('Puestos')) return Icons.desktop_windows_outlined;
      return Icons.precision_manufacturing_outlined;
    }

    Color groupAccentFor(String g) {
      if (g.startsWith('Sensores')) return AppPalette.teal600;
      if (g.startsWith('Seguridad')) return AppPalette.slate900;
      if (g.startsWith('Red')) return AppPalette.blue600;
      if (g.startsWith('Puestos')) return AppPalette.blue900;
      return AppPalette.violet600;
    }

    return Container(
      width: 265,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: AppPalette.slate200)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'DEVICES LIBRARY',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
                      color: AppPalette.slate900,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => _rebuildState(() => _showLeftLibrary = false),
                  icon: const Icon(
                    Icons.keyboard_double_arrow_left_rounded,
                    size: 18,
                    color: AppPalette.slate500,
                  ),
                  tooltip: 'Ocultar Devices Library',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              'Arrastra un equipo o sensor a la planta para elegir su Rack de conexión',
              style: TextStyle(
                fontSize: 10.5,
                color: AppPalette.slate500,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: SizedBox(
              height: 32,
              child: TextField(
                onChanged: (v) => _rebuildState(() => _deviceLibrarySearch = v),
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  hintText: 'Buscar sensor, cámara, PC...',
                  hintStyle: const TextStyle(
                    fontSize: 11.5,
                    color: AppPalette.slate400,
                  ),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    size: 16,
                    color: AppPalette.slate400,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  filled: true,
                  fillColor: AppPalette.slate50,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: AppPalette.slate200),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: AppPalette.slate200),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: AppPalette.teal700,
                backgroundColor: const Color(0xFFF0FDFA),
                side: const BorderSide(color: AppPalette.teal600),
              ),
              onPressed: () => _showAddFloorDeviceModal(
                floor,
                initialCategory: 'printer',
                focusCmdbSelector: true,
              ),
              icon: const Icon(Icons.fact_check_outlined, size: 15),
              label: const Text(
                '+ Seleccionar Equipo CMDB',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: AppPalette.violet600,
                backgroundColor: const Color(0xFFF5F3FF),
                side: const BorderSide(color: Color(0xFFC4B5FD)),
              ),
              onPressed: () => _showCreateCustomDeviceTypeModal(floor),
              icon: const Icon(Icons.add_box_outlined, size: 15),
              label: const Text(
                '+ Nuevo Tipo a Medida',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const Divider(height: 1, color: AppPalette.slate200),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              children: [
                for (final entry in grouped.entries)
                  if (entry.value.isNotEmpty) ...[
                    // Cabecera desplegable de Familia
                    InkWell(
                      onTap: () {
                        _rebuildState(() {
                          if (_expandedLibraryGroups.contains(entry.key)) {
                            _expandedLibraryGroups.remove(entry.key);
                          } else {
                            _expandedLibraryGroups.add(entry.key);
                          }
                        });
                      },
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        margin: const EdgeInsets.only(top: 4, bottom: 3),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppPalette.slate50,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AppPalette.slate200),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              groupIconFor(entry.key),
                              size: 14,
                              color: groupAccentFor(entry.key),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                entry.key,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  color: groupAccentFor(entry.key),
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: AppPalette.slate300,
                                ),
                              ),
                              child: Text(
                                '${entry.value.length}',
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.bold,
                                  color: AppPalette.slate600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              (_expandedLibraryGroups.contains(entry.key) ||
                                      query.isNotEmpty)
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 16,
                              color: AppPalette.slate500,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_expandedLibraryGroups.contains(entry.key) ||
                        query.isNotEmpty)
                      for (final item in entry.value)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3, left: 4),
                          child: _buildLibraryCatalogTile(floor, item),
                        ),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLibraryCatalogTile(
    FloorNode floor,
    _FloorDeviceCatalogItem item,
  ) {
    final countInFloor = item.category == 'rack'
        ? floor.rooms.fold<int>(0, (s, r) => s + r.racks.length)
        : floor.floorDevices.where((d) => d.category == item.category).length;

    final tileContent = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppPalette.slate100),
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: item.pinColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              item.icon,
              size: 14,
              color: item.pinColor,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              item.label,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: AppPalette.slate800,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (countInFloor > 0)
            Container(
              margin: const EdgeInsets.only(right: 4),
              padding: const EdgeInsets.symmetric(
                horizontal: 5,
                vertical: 1,
              ),
              decoration: BoxDecoration(
                color: AppPalette.slate100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$countInFloor',
                style: const TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.bold,
                  color: AppPalette.slate500,
                ),
              ),
            ),
          if (item.customTypeId != null)
            InkWell(
              onTap: () async {
                await widget.api.deleteCustomFloorDeviceType(
                  item.customTypeId!,
                );
                await _loadCustomFloorDeviceTypes();
              },
              borderRadius: BorderRadius.circular(4),
              child: const Tooltip(
                message: 'Eliminar este tipo personalizado de la librería',
                child: Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(
                    Icons.delete_outline,
                    size: 14,
                    color: AppPalette.slate400,
                  ),
                ),
              ),
            ),
          InkWell(
            onTap: () {
              if (item.category == 'rack') {
                _showDrawNewRackDialog(floor);
              } else {
                _showAddFloorDeviceModal(
                  floor,
                  initialCategory: item.category,
                );
              }
            },
            borderRadius: BorderRadius.circular(4),
            child: const Tooltip(
              message: 'Colocar en planta y elegir Rack de conexión',
              child: Padding(
                padding: EdgeInsets.all(2),
                child: Icon(
                  Icons.add_circle_outline_rounded,
                  size: 16,
                  color: AppPalette.blue600,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return Draggable<String>(
      data: item.category,
      feedback: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(20),
        color: item.pinColor,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 7,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(item.icon, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              Text(
                item.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.45,
        child: tileContent,
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: tileContent,
      ),
    );
  }

  // ===========================================================================
  // PIN DE GOTA (TEARDROP PIN) EN EL PLANO 2D PARA CADA DISPOSITIVO / SENSOR
  // ===========================================================================
  Widget _buildFloorDevicePin({
    required FloorDeviceNode dev,
    required double canvasW,
    required double canvasH,
  }) {
    final normPos = _floorDevicePositions[dev.id] ?? Offset(dev.posX, dev.posY);
    final isSelected = _selectedFloorDeviceId == dev.id;
    final effectiveCategory = isSelected ? _devCategory : dev.category;
    final effectiveStatus = isSelected ? _devStatus : dev.status;
    final effectiveLinkedRackId =
        isSelected ? _devLinkedRackId : dev.linkedRackId;
    final catItem = _catalogItemFor(effectiveCategory);
    final isOutlet = effectiveCategory == 'telecom_outlet';

    // Buscar código del Rack conectado para mostrarlo en el tooltip y badge
    String linkedRackCode = '';
    if (effectiveLinkedRackId != null && _floor != null) {
      for (final rm in _floor!.rooms) {
        for (final rk in rm.racks) {
          if (rk.id == effectiveLinkedRackId) {
            linkedRackCode = rk.code;
            break;
          }
        }
      }
    }

    // Coordenadas de la punta del pin
    final centerX = (normPos.dx * canvasW).clamp(20.0, canvasW - 20.0);
    final centerY = (normPos.dy * canvasH).clamp(24.0, canvasH - 16.0);

    final Color pinBgColor =
        isSelected ? AppPalette.blue600 : catItem.pinColor;

    final effectiveMonitored =
        isSelected ? _fdMonitorEnabled : dev.monitoringEnabled;
    Color statusDotColor = AppPalette.slate400; // Gris: Sin Heartbeat
    if (effectiveMonitored) {
      if (effectiveStatus == 'offline') {
        statusDotColor = const Color(0xFFEF4444); // Rojo: Todo falla
      } else if (effectiveStatus == 'warning') {
        statusDotColor = AppPalette.amber500; // Naranja: Fallo parcial
      } else {
        statusDotColor = const Color(0xFF22C55E); // Verde: Todo OK
      }
    }

    return Positioned(
      left: centerX - 16,
      top: centerY - 34,
      child: Tooltip(
        message: [
          '${dev.code} • ${dev.name}',
          'Familia: ${catItem.groupName}',
          if (linkedRackCode.isNotEmpty) 'Conectado a Rack: $linkedRackCode',
          if (dev.linkedRackPort.isNotEmpty)
            'Puerto/Sonda en Rack: ${dev.linkedRackPort}',
          if (dev.roomCode.isNotEmpty) 'Sala/Zona: ${dev.roomCode}',
          if (dev.ipAddress.isNotEmpty) 'IP: ${dev.ipAddress}',
          if (dev.notes.isNotEmpty) dev.notes,
          if (dev.contactFirstName.isNotEmpty || dev.contactLastName.isNotEmpty)
            'Contacto: ${dev.contactFirstName} ${dev.contactLastName}',
          '• Clic: Abrir Settings  • Arrastrar: Mover en planta',
        ].join('\n'),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _selectFloorDevice(dev),
          onPanStart: (_) {
            _pushUndoSnapshot(
              description: 'Mover dispositivo ${dev.code}',
              affectedDeviceIds: [dev.id],
            );
            _selectFloorDevice(dev);
          },
          onPanUpdate: (details) {
            final dxNorm = details.delta.dx / canvasW;
            final dyNorm = details.delta.dy / canvasH;
            _rebuildState(() {
              final cur =
                  _floorDevicePositions[dev.id] ?? Offset(dev.posX, dev.posY);
              _floorDevicePositions[dev.id] = Offset(
                (cur.dx + dxNorm).clamp(0.02, 0.96),
                (cur.dy + dyNorm).clamp(0.04, 0.95),
              );
            });
          },
          onPanEnd: (_) => _saveFloorDevicePosition(dev.id),
          child: MouseRegion(
            cursor: SystemMouseCursors.move,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Gota (Teardrop Marker) con icono blanco
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: pinBgColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFFFACC15)
                              : Colors.white,
                          width: isSelected ? 2.4 : 1.6,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: isSelected
                                ? const Color(0x882563EB)
                                : const Color(0x38000000),
                            blurRadius: isSelected ? 10 : 5,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Icon(
                        catItem.icon,
                        size: 15,
                        color: Colors.white,
                      ),
                    ),
                    CustomPaint(
                      size: const Size(10, 6),
                      painter: _PinTailPainter(color: pinBgColor),
                    ),
                  ],
                ),
                const SizedBox(width: 3),
                // Etiqueta junto al pin (ej. TMP01, CAM01, DP01, Bi01, Bi02...)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppPalette.blue900
                        : Colors.white.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: isSelected
                          ? const Color(0xFFFACC15)
                          : (catItem.isSensor
                              ? catItem.pinColor.withValues(alpha: 0.55)
                              : AppPalette.slate300),
                      width: isSelected ? 1.5 : 1.0,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x18000000),
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isOutlet) ...[
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: statusDotColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        dev.code,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: isSelected
                              ? Colors.white
                              : (isOutlet
                                  ? AppPalette.slate600
                                  : AppPalette.slate900),
                        ),
                      ),
                      if (linkedRackCode.isNotEmpty &&
                          (catItem.isSensor || isSelected)) ...[
                        const SizedBox(width: 4),
                        Text(
                          '→$linkedRackCode',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: isSelected
                                ? const Color(0xFFFDE047)
                                : AppPalette.amber700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // COLUMNA DERECHA: SETTINGS PANEL (Igual a la captura de referencia)
  // ===========================================================================
  Widget _buildRightSettingsPanel(
    FloorNode floor,
    List<RackSummary> floorRacks,
  ) {
    FloorDeviceNode? selectedDev;
    if (_selectedFloorDeviceId != null) {
      for (final d in floor.floorDevices) {
        if (d.id == _selectedFloorDeviceId) {
          selectedDev = d;
          break;
        }
      }
    }

    RackSummary? selectedRack;
    if (selectedDev == null && _selectedRackIds.isNotEmpty) {
      final firstId = _selectedRackIds.first;
      for (final r in floorRacks) {
        if (r.id == firstId) {
          selectedRack = r;
          break;
        }
      }
    }

    final floorOutlets = floor.floorDevices
        .where((d) => d.category == 'telecom_outlet')
        .toList();

    return Container(
      width: 310,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(left: BorderSide(color: AppPalette.slate200)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Cabecera Settings
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppPalette.slate200)),
            ),
            child: Row(
              children: [
                if (selectedDev != null) ...[
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: _catalogItemFor(selectedDev.category).pinColor,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      _catalogItemFor(selectedDev.category).icon,
                      size: 15,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selectedDev.code,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w900,
                            color: AppPalette.slate900,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          _catalogItemFor(selectedDev.category).label,
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: AppPalette.slate500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => _saveSelectedFloorDeviceSettings(),
                    icon: const Icon(
                      Icons.save_outlined,
                      size: 18,
                      color: AppPalette.blue600,
                    ),
                    tooltip: 'Guardar cambios',
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    onPressed: () => _confirmDeleteFloorDevice(selectedDev!),
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: AppPalette.red600,
                    ),
                    tooltip: 'Eliminar dispositivo',
                    visualDensity: VisualDensity.compact,
                  ),
                ] else if (selectedRack != null) ...[
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: AppPalette.blue900,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(
                      Icons.dns_outlined,
                      size: 15,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selectedRack.code,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w900,
                            color: AppPalette.slate900,
                          ),
                        ),
                        const Text(
                          'Rack Cabinet',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: AppPalette.slate500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  const Icon(
                    Icons.tune_rounded,
                    size: 18,
                    color: AppPalette.blue900,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Settings & Floor Inventory',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.slate900,
                      ),
                    ),
                  ),
                ],
                IconButton(
                  onPressed: () => _rebuildState(() => _showRightSettings = false),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: AppPalette.slate500,
                  ),
                  tooltip: 'Cerrar panel Settings',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          if (_settingsSavedBanner != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _settingsSaveError
                    ? AppPalette.red50
                    : const Color(0xFFECFDF5),
                border: Border(
                  bottom: BorderSide(
                    color: _settingsSaveError
                        ? AppPalette.red200
                        : const Color(0xFFA7F3D0),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _settingsSaveError
                        ? Icons.error_outline_rounded
                        : Icons.check_circle_rounded,
                    size: 14,
                    color: _settingsSaveError
                        ? AppPalette.red600
                        : const Color(0xFF059669),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _settingsSavedBanner!,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: _settingsSaveError
                            ? AppPalette.red700
                            : const Color(0xFF065F46),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Cuerpo del panel derecho según selección
          Expanded(
            child: selectedDev != null
                ? _buildFloorDeviceSettingsForm(
                    selectedDev,
                    floorRacks,
                    floorOutlets,
                  )
                : (selectedRack != null
                    ? _buildSelectedRackSettingsSummary(floor, selectedRack)
                    : _buildFloorOverviewSettingsList(floor, floorRacks)),
          ),
        ],
      ),
    );
  }

  /// Área principal: librería de equipos, lienzo del plano y panel de ajustes.
  Widget _buildAreaPrincipal(FloorNode? floor, List<RackSummary> floorRacks, String floorImageUrl) {
    return Expanded(
        child: floor == null
            ? const Center(child: Text('Crea una planta para empezar.'))
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // COLUMNA IZQUIERDA: DEVICES LIBRARY
                  if (_showLeftLibrary && !widget.isKioskMode)
                    SelectionContainer.disabled(
                      child: _buildLeftDevicesLibraryPanel(floor),
                    ),

                  // COLUMNA CENTRAL: LIENZO INTERACTIVO DE PLANTA 2D CON DRAG TARGET Y CABLEADO
                  Expanded(
                    child: SelectionContainer.disabled(
                      child: Padding(
                        padding: EdgeInsets.all(widget.isKioskMode ? 6 : 12),
                        child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: AppPalette.slate300,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x0A000000),
                              blurRadius: 12,
                              offset: Offset(0, 4),
                            ),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final canvasW = constraints.maxWidth;
                            final canvasH = constraints.maxHeight;
                            final marqueeRect = (_marqueeStart != null &&
                                    _marqueeCurrent != null)
                                ? Rect.fromPoints(
                                    _marqueeStart!,
                                    _marqueeCurrent!,
                                  )
                                : null;

                            return DragTarget<String>(
                              onWillAcceptWithDetails: (_) => true,
                              onAcceptWithDetails: (details) {
                                final renderBox = context.findRenderObject()
                                    as RenderBox?;
                                if (renderBox == null) return;
                                final localPos = renderBox.globalToLocal(
                                  details.offset,
                                );
                                final normX = (localPos.dx / canvasW).clamp(
                                  0.04,
                                  0.94,
                                );
                                final normY = (localPos.dy / canvasH).clamp(
                                  0.06,
                                  0.92,
                                );
                                _dropNewDeviceFromLibrary(
                                  floor: floor,
                                  category: details.data,
                                  normX: normX,
                                  normY: normY,
                                );
                              },
                              builder: (context, candidateData, _) {
                                final isDraggingNew =
                                    candidateData.isNotEmpty;
                                return Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    // Lienzo desplazable con Modo Mano (Barra Espaciadora)
                                    Transform.translate(
                                      offset: _canvasPanOffset,
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          // A. Fondo interactivo: clic en vacío limpia selección, arrastrar dibuja caja de selección (Marquee)
                                          GestureDetector(
                                            behavior:
                                                HitTestBehavior.opaque,
                                            onTap: () {
                                              _rebuildState(() {
                                                if (!_isShiftPressed) {
                                                  _selectedRackIds.clear();
                                                }
                                                _selectedFloorDeviceId =
                                                    null;
                                                _editingDeviceId = null;
                                              });
                                            },
                                            onPanStart: (details) {
                                              _rebuildState(() {
                                                if (!_isShiftPressed) {
                                                  _selectedRackIds.clear();
                                                }
                                                _selectedFloorDeviceId =
                                                    null;
                                                _editingDeviceId = null;
                                                _marqueeStart =
                                                    details.localPosition;
                                                _marqueeCurrent =
                                                    details.localPosition;
                                              });
                                            },
                                            onPanUpdate: (details) {
                                              if (_marqueeStart == null) {
                                                return;
                                              }
                                              final cur =
                                                  details.localPosition;
                                              final selRect =
                                                  Rect.fromPoints(
                                                _marqueeStart!,
                                                cur,
                                              );
                                              _rebuildState(() {
                                                _marqueeCurrent = cur;
                                                for (final rk
                                                    in floorRacks) {
                                                  final normPos =
                                                      _rackPositions[
                                                              rk.id] ??
                                                          const Offset(
                                                            0.25,
                                                            0.35,
                                                          );
                                                  final sz =
                                                      _rackSizes[rk.id] ??
                                                          const Size(
                                                            120.0,
                                                            90.0,
                                                          );
                                                  final leftPx = (normPos
                                                              .dx *
                                                          canvasW)
                                                      .clamp(
                                                    8.0,
                                                    (canvasW -
                                                            sz.width -
                                                            8.0)
                                                        .clamp(
                                                          8.0,
                                                          canvasW,
                                                        ),
                                                  );
                                                  final topPx = (normPos
                                                              .dy *
                                                          canvasH)
                                                      .clamp(
                                                    8.0,
                                                    (canvasH -
                                                            sz.height -
                                                            8.0)
                                                        .clamp(
                                                          8.0,
                                                          canvasH,
                                                        ),
                                                  );
                                                  final rkRect =
                                                      Rect.fromLTWH(
                                                    leftPx,
                                                    topPx,
                                                    sz.width,
                                                    sz.height,
                                                  );
                                                  if (selRect.overlaps(
                                                    rkRect,
                                                  )) {
                                                    _selectedRackIds.add(
                                                      rk.id,
                                                    );
                                                  } else if (!_isShiftPressed) {
                                                    _selectedRackIds.remove(
                                                      rk.id,
                                                    );
                                                  }
                                                }
                                              });
                                            },
                                            onPanEnd: (_) {
                                              _rebuildState(() {
                                                _marqueeStart = null;
                                                _marqueeCurrent = null;
                                              });
                                            },
                                            child: Stack(
                                              fit: StackFit.expand,
                                              children: [
                                                CustomPaint(
                                                  painter:
                                                      _ArchitecturalGridPainter(),
                                                ),
                                                if (floorImageUrl
                                                    .isNotEmpty)
                                                  Center(
                                                    child: Transform.scale(
                                                      scale:
                                                          _floorImageScale,
                                                      child: Image.network(
                                                        floorImageUrl,
                                                        fit: BoxFit.contain,
                                                        errorBuilder:
                                                            (ctx, err, _) {
                                                          WidgetsBinding
                                                              .instance
                                                              .addPostFrameCallback(
                                                                  (_) {
                                                            if (mounted &&
                                                                !_floorPlanLoadError) {
                                                              _rebuildState(
                                                                () =>
                                                                    _floorPlanLoadError =
                                                                        true,
                                                              );
                                                            }
                                                          });
                                                          return const SizedBox
                                                              .shrink();
                                                        },
                                                      ),
                                                    ),
                                                  ),
                                                // A2. Líneas de Cableado Estructurado en Planta (Rack <-> Rack, Acometidas de Rack, Rack -> Roseta/Sensor y Roseta -> Puesto)
                                                if (_showFloorCables)
                                                  IgnorePointer(
                                                    child: CustomPaint(
                                                      painter:
                                                          _FloorConnectionsPainter(
                                                        racks: floorRacks,
                                                        rackPositions:
                                                            _rackPositions,
                                                        rackSizes:
                                                            _rackSizes,
                                                        floorDevices: floor
                                                            .floorDevices,
                                                        interRackLinks: floor
                                                            .interRackLinks,
                                                        devicePositions:
                                                            _floorDevicePositions,
                                                        selectedDeviceId:
                                                            _selectedFloorDeviceId,
                                                        selectedLinkedRackId:
                                                            _devLinkedRackId,
                                                        selectedLinkedOutletId:
                                                            _devLinkedOutletId,
                                                        selectedRackIds:
                                                            _selectedRackIds,
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),

                                          // B. Dibujos de los Racks en Vista de Planta (Top-Down)
                                          for (final rk in floorRacks)
                                            _buildTopDownRackBox(
                                              rk: rk,
                                              canvasW: canvasW,
                                              canvasH: canvasH,
                                            ),

                                          // B2. Pines de Dispositivos de Planta (Cámaras, Rosetas Bi01, PCs, Control de Acceso, APs...)
                                          for (final dev
                                              in floor.floorDevices)
                                            _buildFloorDevicePin(
                                              dev: dev,
                                              canvasW: canvasW,
                                              canvasH: canvasH,
                                            ),

                                          // C. Caja de selección visual (Marquee) al arrastrar con el ratón
                                          if (marqueeRect != null)
                                            Positioned(
                                              left: marqueeRect.left,
                                              top: marqueeRect.top,
                                              width: marqueeRect.width,
                                              height: marqueeRect.height,
                                              child: IgnorePointer(
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    color: const Color(
                                                      0xFF2563EB,
                                                    ).withValues(
                                                      alpha: 0.16,
                                                    ),
                                                    border: Border.all(
                                                      color: const Color(
                                                        0xFF2563EB,
                                                      ),
                                                      width: 1.8,
                                                    ),
                                                    borderRadius:
                                                        BorderRadius
                                                            .circular(4),
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),

                                    // Capa superior cuando se pulsa la Barra Espaciadora (Modo Mano para arrastrar todo el dashboard)
                                    if (_isPanHandMode)
                                      Positioned.fill(
                                        child: MouseRegion(
                                          cursor: _isSpaceDragging
                                              ? SystemMouseCursors.grabbing
                                              : SystemMouseCursors.grab,
                                          child: GestureDetector(
                                            behavior:
                                                HitTestBehavior.opaque,
                                            onPanStart: (_) {
                                              _rebuildState(
                                                () =>
                                                    _isSpaceDragging = true,
                                              );
                                            },
                                            onPanUpdate: (details) {
                                              _rebuildState(() {
                                                _canvasPanOffset +=
                                                    details.delta;
                                              });
                                            },
                                            onPanEnd: (_) {
                                              _rebuildState(
                                                () => _isSpaceDragging =
                                                    false,
                                              );
                                            },
                                            onPanCancel: () {
                                              _rebuildState(
                                                () => _isSpaceDragging =
                                                    false,
                                              );
                                            },
                                            child: Align(
                                              alignment:
                                                  Alignment.topCenter,
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.only(
                                                  top: 12,
                                                ),
                                                child: Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 14,
                                                    vertical: 6,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: const Color(
                                                      0xEE0F172A,
                                                    ),
                                                    borderRadius:
                                                        BorderRadius
                                                            .circular(20),
                                                    border: Border.all(
                                                      color: const Color(
                                                        0xFF38BDF8,
                                                      ),
                                                      width: 1.4,
                                                    ),
                                                  ),
                                                  child: const Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Icon(
                                                        Icons
                                                            .pan_tool_alt_rounded,
                                                        size: 15,
                                                        color: Color(
                                                          0xFF38BDF8,
                                                        ),
                                                      ),
                                                      SizedBox(width: 6),
                                                      Text(
                                                        'Modo Mano activo — Arrastra con el ratón para mover el dashboard',
                                                        style: TextStyle(
                                                          color:
                                                              Colors.white,
                                                          fontSize: 11.5,
                                                          fontWeight:
                                                              FontWeight
                                                                  .w800,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),

                                    if (isDraggingNew)
                                      IgnorePointer(
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: AppPalette.blue600
                                                .withValues(alpha: 0.06),
                                            border: Border.all(
                                              color:
                                                  AppPalette.blue600,
                                              width: 2.5,
                                            ),
                                          ),
                                          alignment: Alignment.topCenter,
                                          padding: const EdgeInsets.only(
                                            top: 14,
                                          ),
                                          child: Container(
                                            padding:
                                                const EdgeInsets.symmetric(
                                              horizontal: 14,
                                              vertical: 6,
                                            ),
                                            decoration: BoxDecoration(
                                              color:
                                                  AppPalette.blue900,
                                              borderRadius:
                                                  BorderRadius.circular(20),
                                            ),
                                            child: const Text(
                                              'Suelta aquí para colocar el dispositivo en la planta',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),

                                    if (_floorPlanLoadError &&
                                        floorImageUrl.isNotEmpty)
                                      Positioned(
                                        bottom: 14,
                                        left: 14,
                                        child: Container(
                                          padding:
                                              const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 10,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius:
                                                BorderRadius.circular(10),
                                            border: Border.all(
                                              color:
                                                  AppPalette.amber300,
                                              width: 1.5,
                                            ),
                                            boxShadow: const [
                                              BoxShadow(
                                                color: Colors.black12,
                                                blurRadius: 10,
                                                offset: Offset(0, 3),
                                              ),
                                            ],
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(
                                                Icons.broken_image_outlined,
                                                color: AppPalette.amber600,
                                                size: 20,
                                              ),
                                              const SizedBox(width: 10),
                                              const Text(
                                                'El plano de fondo anterior no se encuentra disponible. Mostrando cuadrícula técnica.',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight:
                                                      FontWeight.w600,
                                                  color: AppPalette.slate700,
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              FilledButton.tonalIcon(
                                                onPressed: () async {
                                                  _rebuildState(
                                                    () =>
                                                        _floorPlanLoadError =
                                                            false,
                                                  );
                                                  await _uploadFloorBlueprint(
                                                    floor,
                                                  );
                                                },
                                                icon: const Icon(
                                                  Icons
                                                      .upload_file_outlined,
                                                  size: 15,
                                                ),
                                                label: const Text(
                                                  'Subir Nuevo Plano',
                                                  style: TextStyle(
                                                    fontSize: 11.5,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              TextButton(
                                                onPressed: () async {
                                                  _rebuildState(
                                                    () =>
                                                        _floorPlanLoadError =
                                                            false,
                                                  );
                                                  await widget.api
                                                      .deleteCustomPlanImage(
                                                    targetType: 'floor',
                                                    targetId: floor.id,
                                                  );
                                                  widget.onRefresh();
                                                },
                                                child: const Text(
                                                  'Usar solo cuadrícula',
                                                  style: TextStyle(
                                                    fontSize: 11.5,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),

                                    // D. Leyenda inferior de Cableado de Planta (Eléctrica, Fibra, Ethernet, Sensores y Rosetas)
                                    if (_showFloorCables &&
                                        (floor.floorDevices.isNotEmpty ||
                                            floorRacks.isNotEmpty))
                                      Positioned(
                                        bottom: 10,
                                        right: 12,
                                        child: IgnorePointer(
                                          child: Container(
                                            padding:
                                                const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 6,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.white
                                                  .withValues(alpha: 0.94),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              border: Border.all(
                                                color:
                                                    AppPalette.slate300,
                                              ),
                                            ),
                                            child: const Wrap(
                                              spacing: 10,
                                              runSpacing: 4,
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: [
                                                Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      Icons.bolt_rounded,
                                                      size: 14,
                                                      color:
                                                          AppPalette.orange600,
                                                    ),
                                                    SizedBox(width: 2),
                                                    Text(
                                                      'Eléctrica (PWR)',
                                                      style: TextStyle(
                                                        fontSize: 9.5,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        color: Color(
                                                          0xFF334155,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      Icons.cable_rounded,
                                                      size: 14,
                                                      color:
                                                          AppPalette.cyan500,
                                                    ),
                                                    SizedBox(width: 3),
                                                    Text(
                                                      'Fibra (FIB / Inter-Rack)',
                                                      style: TextStyle(
                                                        fontSize: 9.5,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        color: Color(
                                                          0xFF334155,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      Icons
                                                          .settings_ethernet_rounded,
                                                      size: 14,
                                                      color:
                                                          AppPalette.blue600,
                                                    ),
                                                    SizedBox(width: 3),
                                                    Text(
                                                      'Ethernet (ETH)',
                                                      style: TextStyle(
                                                        fontSize: 9.5,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        color: Color(
                                                          0xFF334155,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      Icons.horizontal_rule,
                                                      size: 15,
                                                      color:
                                                          AppPalette.amber500,
                                                    ),
                                                    SizedBox(width: 3),
                                                    Text(
                                                      'Rack → Sensor / Roseta',
                                                      style: TextStyle(
                                                        fontSize: 9.5,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color: Color(
                                                          0xFF334155,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      Icons.horizontal_rule,
                                                      size: 15,
                                                      color:
                                                          AppPalette.blue500,
                                                    ),
                                                    SizedBox(width: 3),
                                                    Text(
                                                      'Roseta → Puesto',
                                                      style: TextStyle(
                                                        fontSize: 9.5,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color: Color(
                                                          0xFF334155,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),

                                    // E. Barra Flotante de Colocación/Alineación cuando hay Racks seleccionados
                                    if (_selectedRackIds.isNotEmpty)
                                      Positioned(
                                        top: 12,
                                        left: 16,
                                        right: 16,
                                        child: Center(
                                          child: Material(
                                            elevation: 6,
                                            borderRadius:
                                                BorderRadius.circular(10),
                                            color: AppPalette.slate900,
                                            child: Padding(
                                              padding: const EdgeInsets
                                                  .symmetric(
                                                horizontal: 14,
                                                vertical: 8,
                                              ),
                                              child: Wrap(
                                                crossAxisAlignment:
                                                    WrapCrossAlignment
                                                        .center,
                                                spacing: 8,
                                                runSpacing: 6,
                                                children: [
                                                  Container(
                                                    padding:
                                                        const EdgeInsets
                                                            .symmetric(
                                                      horizontal: 8,
                                                      vertical: 3,
                                                    ),
                                                    decoration:
                                                        BoxDecoration(
                                                      color: const Color(
                                                        0xFF2563EB,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius
                                                              .circular(12),
                                                    ),
                                                    child: Text(
                                                      '${_selectedRackIds.length} ${_selectedRackIds.length == 1 ? 'Rack seleccionado' : 'Racks seleccionados'}',
                                                      style:
                                                          const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 11,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                      ),
                                                    ),
                                                  ),
                                                  if (_selectedRackIds
                                                          .length ==
                                                      1)
                                                    FilledButton.icon(
                                                      style: FilledButton
                                                          .styleFrom(
                                                        backgroundColor:
                                                            const Color(
                                                          0xFF10B981,
                                                        ),
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                      ),
                                                      onPressed: () =>
                                                          widget.onOpenRack(
                                                        _selectedRackIds
                                                            .first,
                                                      ),
                                                      icon: const Icon(
                                                        Icons.open_in_new,
                                                        size: 14,
                                                      ),
                                                      label: const Text(
                                                        'Abrir en Rack Editor (Doble Clic)',
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                        ),
                                                      ),
                                                    ),
                                                  if (_selectedRackIds
                                                          .length >=
                                                      2) ...[
                                                    OutlinedButton.icon(
                                                      style: OutlinedButton
                                                          .styleFrom(
                                                        foregroundColor:
                                                            Colors.white,
                                                        side:
                                                            const BorderSide(
                                                          color: Color(
                                                            0xFF475569,
                                                          ),
                                                        ),
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                      ),
                                                      onPressed: () =>
                                                          _alignSelectedRacksHorizontally(
                                                        canvasW: canvasW,
                                                        packTightly: false,
                                                      ),
                                                      icon: const Icon(
                                                        Icons
                                                            .align_vertical_center_rounded,
                                                        size: 14,
                                                      ),
                                                      label: const Text(
                                                        'Alinear en Fila',
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                        ),
                                                      ),
                                                    ),
                                                    OutlinedButton.icon(
                                                      style: OutlinedButton
                                                          .styleFrom(
                                                        foregroundColor:
                                                            Colors.white,
                                                        side:
                                                            const BorderSide(
                                                          color: Color(
                                                            0xFF475569,
                                                          ),
                                                        ),
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                      ),
                                                      onPressed: () =>
                                                          _alignSelectedRacksHorizontally(
                                                        canvasW: canvasW,
                                                        packTightly: true,
                                                      ),
                                                      icon: const Icon(
                                                        Icons
                                                            .view_column_outlined,
                                                        size: 14,
                                                      ),
                                                      label: const Text(
                                                        'Juntar en Fila (Pasillo)',
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                        ),
                                                      ),
                                                    ),
                                                    OutlinedButton.icon(
                                                      style: OutlinedButton
                                                          .styleFrom(
                                                        foregroundColor:
                                                            Colors.white,
                                                        side:
                                                            const BorderSide(
                                                          color: Color(
                                                            0xFF475569,
                                                          ),
                                                        ),
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                      ),
                                                      onPressed: () =>
                                                          _alignSelectedRacksVertically(
                                                        canvasH: canvasH,
                                                        packTightly: false,
                                                      ),
                                                      icon: const Icon(
                                                        Icons
                                                            .align_horizontal_center_rounded,
                                                        size: 14,
                                                      ),
                                                      label: const Text(
                                                        'Alinear en Columna',
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                        ),
                                                      ),
                                                    ),
                                                    OutlinedButton.icon(
                                                      style: OutlinedButton
                                                          .styleFrom(
                                                        foregroundColor:
                                                            Colors.white,
                                                        side:
                                                            const BorderSide(
                                                          color: Color(
                                                            0xFF475569,
                                                          ),
                                                        ),
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                      ),
                                                      onPressed: () =>
                                                          _alignSelectedRacksVertically(
                                                        canvasH: canvasH,
                                                        packTightly: true,
                                                      ),
                                                      icon: const Icon(
                                                        Icons
                                                            .table_rows_outlined,
                                                        size: 14,
                                                      ),
                                                      label: const Text(
                                                        'Juntar en Columna',
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                        ),
                                                      ),
                                                    ),
                                                    OutlinedButton.icon(
                                                      style: OutlinedButton
                                                          .styleFrom(
                                                        foregroundColor:
                                                            Colors.white,
                                                        side:
                                                            const BorderSide(
                                                          color: Color(
                                                            0xFF475569,
                                                          ),
                                                        ),
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                      ),
                                                      onPressed:
                                                          _equalizeSelectedRacksSize,
                                                      icon: const Icon(
                                                        Icons.aspect_ratio,
                                                        size: 14,
                                                      ),
                                                      label: const Text(
                                                        'Igualar Tamaño',
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                  IconButton(
                                                    onPressed: () =>
                                                        _rebuildState(
                                                      () => _selectedRackIds
                                                          .clear(),
                                                    ),
                                                    icon: const Icon(
                                                      Icons.close,
                                                      size: 16,
                                                      color: Colors.white70,
                                                    ),
                                                    tooltip:
                                                        'Limpiar selección',
                                                    visualDensity:
                                                        VisualDensity
                                                            .compact,
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            );
                          },
                        ),
                      ),
                    ),
                    ),
                  ),

                  // COLUMNA DERECHA: PANEL DE SETTINGS (Dispositivo o Rack seleccionado)
                  if (_showRightSettings && !widget.isKioskMode)
                    _buildRightSettingsPanel(floor, floorRacks),
                ],
              ),
      );
  }

  DiagramExportDocument _buildFloorExportDocument(
    FloorNode floor,
    List<RackSummary> floorRacks,
  ) {
    final loc = _location;
    final locTitle = loc != null ? '${loc.name} (${loc.code})' : 'Datacenter';
    const double canvasW = 1440.0;
    const double canvasH = 920.0;

    final zones = <DiagramExportZone>[];
    for (int i = 0; i < floor.rooms.length; i++) {
      final rm = floor.rooms[i];
      zones.add(
        DiagramExportZone(
          id: 'room_${rm.id}',
          title: 'Sala ${rm.name}',
          subtitle: '${rm.racks.length} Racks',
          x: 24.0 + (i * 20.0),
          y: 24.0 + (i * 20.0),
          width: canvasW - 48.0 - (i * 40.0),
          height: canvasH - 48.0 - (i * 40.0),
          colorHex: '#64748B',
        ),
      );
    }

    final nodes = <DiagramExportNode>[];
    for (int i = 0; i < floorRacks.length; i++) {
      final rk = floorRacks[i];
      final normPos =
          _rackPositions[rk.id] ??
          Offset(0.18 + (i % 4) * 0.20, 0.22 + (i ~/ 4) * 0.26);
      final sz = _rackSizes[rk.id] ?? const Size(175.0, 96.0);
      final status = rk.offlineCount > 0
          ? 'offline'
          : (rk.warningCount > 0
                ? 'warning'
                : (rk.onlineCount > 0 ? 'online' : 'unmonitored'));
      nodes.add(
        DiagramExportNode(
          id: 'rack_${rk.id}',
          code: rk.code,
          name: '${rk.name} (${rk.totalUnits}U • ${rk.deviceCount} eq.)',
          subtitle: 'RACK',
          ip: 'ETH:${rk.ethCablesCount} FIB:${rk.fiberCablesCount} PWR:${rk.powerCablesCount}',
          modelName: rk.responsiblePerson.isNotEmpty
              ? 'Resp: ${rk.responsiblePerson}'
              : 'Armario ${rk.totalUnits}U',
          serialNumber: '',
          status: status,
          x: (normPos.dx * (canvasW - 210)).clamp(30.0, canvasW - 200),
          y: (normPos.dy * (canvasH - 130)).clamp(30.0, canvasH - 120),
          width: sz.width.clamp(165.0, 230.0),
          height: sz.height.clamp(82.0, 130.0),
          colorHex: status == 'offline'
              ? '#DC2626'
              : (status == 'warning' ? '#D97706' : '#1E3A8A'),
        ),
      );
    }

    for (final dev in floor.floorDevices) {
      final normPos =
          _floorDevicePositions[dev.id] ?? Offset(dev.posX, dev.posY);
      final modelName = (dev.customFields['model_name'] ?? '').toString().trim();
      final serialNum =
          (dev.customFields['serial_number'] ?? '').toString().trim();
      nodes.add(
        DiagramExportNode(
          id: 'fdev_${dev.id}',
          code: dev.code,
          name: dev.name,
          subtitle: dev.deviceType.toUpperCase(),
          ip: dev.ipAddress,
          modelName: modelName,
          serialNumber: serialNum,
          status: dev.status,
          x: (normPos.dx * (canvasW - 190)).clamp(30.0, canvasW - 185),
          y: (normPos.dy * (canvasH - 110)).clamp(30.0, canvasH - 105),
          width: 170.0,
          height: 76.0,
          colorHex: dev.status == 'offline'
              ? '#DC2626'
              : (dev.deviceType == 'telecom_outlet' ? '#D97706' : '#0284C7'),
        ),
      );
    }

    final edges = <DiagramExportEdge>[];
    // 1. Enlaces Inter-Rack
    for (int i = 0; i < floor.interRackLinks.length; i++) {
      final lnk = floor.interRackLinks[i];
      final srcRackId = lnk['source_rack_id'];
      final dstRackId = lnk['target_rack_id'];
      if (srcRackId == null || dstRackId == null) continue;
      final mg = (lnk['media_group'] ?? 'fiber').toString();
      final srcEnd =
          '${lnk['source_device_code'] ?? ''}:${lnk['source_port_number'] ?? ''}';
      final dstEnd =
          '${lnk['target_device_code'] ?? ''}:${lnk['target_port_number'] ?? ''}';
      edges.add(
        DiagramExportEdge(
          id: 'ir_${lnk['id'] ?? i}',
          sourceId: 'rack_$srcRackId',
          targetId: 'rack_$dstRackId',
          label: '$srcEnd ⟷ $dstEnd',
          detail: mg.toUpperCase(),
          colorHex: mg == 'fiber'
              ? '#06B6D4'
              : (mg == 'power' ? '#EA580C' : '#2563EB'),
        ),
      );
    }

    // 2. Enlaces de Dispositivos de Planta -> Roseta o Rack
    for (final dev in floor.floorDevices) {
      if (dev.linkedOutletId != null) {
        edges.add(
          DiagramExportEdge(
            id: 'fdev_out_${dev.id}',
            sourceId: 'fdev_${dev.id}',
            targetId: 'fdev_${dev.linkedOutletId}',
            label: '${dev.code} ➔ Roseta',
            detail: 'UTP RJ45',
            colorHex: '#2563EB',
            dashed: true,
          ),
        );
      } else if (dev.linkedRackId != null) {
        final portInfo = dev.linkedRackDeviceCode.isNotEmpty
            ? ' (${dev.linkedRackDeviceCode})'
            : '';
        edges.add(
          DiagramExportEdge(
            id: 'fdev_rk_${dev.id}',
            sourceId: 'fdev_${dev.id}',
            targetId: 'rack_${dev.linkedRackId}',
            label: '${dev.code}$portInfo',
            detail: dev.vlan != null ? 'VLAN ${dev.vlan}' : 'STRUCTURED',
            colorHex: '#D97706',
            dashed: true,
          ),
        );
      }
    }

    return DiagramExportDocument(
      moduleName: '2. Datacenters (Planta 2D)',
      title: '$locTitle — ${floor.name}',
      subtitle:
          'Planta 2D • ${floorRacks.length} Racks • ${floor.floorDevices.length} Equipos/Sensores • ${edges.length} Enlaces',
      fileBaseName: 'esquema_planta_${floor.name.toLowerCase()}',
      canvasWidth: canvasW,
      canvasHeight: canvasH,
      zones: zones,
      nodes: nodes,
      edges: edges,
    );
  }

  /// Barra de controles de la vista de planta (capas, zoom y modos).
  Widget _buildBarraControlesPlanta(FloorNode floor, List<RackSummary> floorRacks) {
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: const BoxDecoration(
          color: AppPalette.slate50,
          border: Border(bottom: BorderSide(color: AppPalette.slate200)),
        ),
        child: Row(
          children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                backgroundColor: _showLeftLibrary
                    ? AppPalette.blue50
                    : Colors.white,
                side: BorderSide(
                  color: _showLeftLibrary
                      ? AppPalette.blue500
                      : AppPalette.slate300,
                ),
              ),
              onPressed: () =>
                  _rebuildState(() => _showLeftLibrary = !_showLeftLibrary),
              icon: const Icon(Icons.widgets_outlined, size: 15),
              label: Text(
                _showLeftLibrary
                    ? 'Devices Library: ON'
                    : 'Devices Library: OFF',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                backgroundColor: _showFloorCables
                    ? AppPalette.amber50
                    : Colors.white,
                side: BorderSide(
                  color: _showFloorCables
                      ? AppPalette.amber500
                      : AppPalette.slate300,
                ),
              ),
              onPressed: () =>
                  _rebuildState(() => _showFloorCables = !_showFloorCables),
              icon: Icon(
                Icons.timeline_rounded,
                size: 15,
                color: _showFloorCables
                    ? AppPalette.amber600
                    : AppPalette.slate500,
              ),
              label: Text(
                _showFloorCables
                    ? 'Cableado Estructurado: ON (${floor.floorDevices.length} disp.)'
                    : 'Cableado Estructurado: OFF',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _showFloorCables
                      ? AppPalette.amber700
                      : AppPalette.slate600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            DiagramExportMenuButton(
              documentBuilder: () =>
                  _buildFloorExportDocument(floor, floorRacks),
              onExportExcel: () {
                final url = Uri.parse(widget.api.getExcelExportUrl());
                launchUrl(url, mode: LaunchMode.externalApplication);
              },
            ),
            const SizedBox(width: 8),
            // Botón Deshacer (Ctrl+Z en Windows/Linux o Cmd+Z en Mac)
            Tooltip(
              message:
                  'Deshacer último movimiento de Rack o Dispositivo (Ctrl+Z / ⌘Z)',
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: _undoStack.isNotEmpty
                      ? AppPalette.slate50
                      : Colors.white,
                ),
                onPressed: _undoStack.isEmpty ? null : _performUndo,
                icon: const Icon(Icons.undo_rounded, size: 15),
                label: Text(
                  _undoStack.isEmpty
                      ? 'Deshacer (⌘Z / Ctrl+Z)'
                      : 'Deshacer (${_undoStack.length})',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Botón Modo Mano (Barra Espaciadora) para mover el dashboard
            Tooltip(
              message:
                  'Mantén pulsada la Barra Espaciadora (o activa este botón) para convertir el ratón en una mano y mover todo el dashboard',
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  backgroundColor: _isPanHandMode
                      ? AppPalette.slate900
                      : Colors.white,
                  foregroundColor: _isPanHandMode
                      ? Colors.white
                      : AppPalette.slate700,
                  side: BorderSide(
                    color: _isPanHandMode
                        ? AppPalette.sky400
                        : AppPalette.slate300,
                  ),
                ),
                onPressed: () => _rebuildState(
                  () => _isHandToolPinned = !_isHandToolPinned,
                ),
                icon: Icon(
                  Icons.pan_tool_alt_rounded,
                  size: 15,
                  color: _isPanHandMode
                      ? AppPalette.sky400
                      : AppPalette.slate600,
                ),
                label: Text(
                  _isPanHandMode
                      ? 'Mano: ACTIVA (Espacio)'
                      : 'Mano (Espacio)',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            if (_canvasPanOffset != Offset.zero) ...[
              const SizedBox(width: 4),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Restablecer posición centrada del lienzo',
                onPressed: () =>
                    _rebuildState(() => _canvasPanOffset = Offset.zero),
                icon: const Icon(
                  Icons.center_focus_strong_rounded,
                  size: 16,
                  color: AppPalette.blue600,
                ),
              ),
            ],
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Espacio + Arrastrar: Mover Dashboard ✋  •  Ctrl+Z / ⌘Z: Deshacer  •  Doble Clic en Rack: Abrir en Rack Editor',
                style: TextStyle(
                  fontSize: 11,
                  color: AppPalette.slate700,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (floorRacks.isNotEmpty) ...[
              TextButton.icon(
                onPressed: () {
                  _rebuildState(() {
                    _selectedFloorDeviceId = null;
                    if (_selectedRackIds.length == floorRacks.length) {
                      _selectedRackIds.clear();
                    } else {
                      _selectedRackIds
                        ..clear()
                        ..addAll(floorRacks.map((r) => r.id));
                    }
                  });
                },
                icon: Icon(
                  _selectedRackIds.length == floorRacks.length
                      ? Icons.deselect
                      : Icons.select_all,
                  size: 15,
                ),
                label: Text(
                  _selectedRackIds.length == floorRacks.length
                      ? 'Deseleccionar Racks'
                      : 'Sel. Racks (${floorRacks.length})',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              const SizedBox(width: 6),
            ],
            const Text(
              'Escala:',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppPalette.slate600,
              ),
            ),
            SizedBox(
              width: 110,
              child: Slider(
                value: _floorImageScale,
                min: 0.4,
                max: 2.5,
                divisions: 21,
                label: '${(_floorImageScale * 100).round()}%',
                onChanged: (v) {
                  _rebuildState(() => _floorImageScale = v);
                },
                onChangeEnd: (v) => _saveFloorScale(floor, v),
              ),
            ),
            Text(
              '${(_floorImageScale * 100).round()}%',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: AppPalette.slate900,
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                backgroundColor: _showRightSettings
                    ? AppPalette.blue50
                    : Colors.white,
                side: BorderSide(
                  color: _showRightSettings
                      ? AppPalette.blue500
                      : AppPalette.slate300,
                ),
              ),
              onPressed: () =>
                  _rebuildState(() => _showRightSettings = !_showRightSettings),
              icon: const Icon(Icons.tune_rounded, size: 15),
              label: const Text(
                'Settings',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
  }

  /// Cabecera: selector de sede, plantas y acciones del datacenter.
  Widget _buildCabeceraDatacenter(LocationNode loc, FloorNode? floor) {
    return Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: AppPalette.slate200)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: widget.onBackToLocations,
                  icon: const Icon(Icons.arrow_back_rounded, size: 20),
                  tooltip: 'Volver al Mapa Global de Locations',
                ),
                const SizedBox(width: 6),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.apartment_rounded,
                          size: 20,
                          color: AppPalette.blue900,
                        ),
                        const SizedBox(width: 8),
                        DropdownButton<int>(
                          value: loc.id,
                          underline: const SizedBox.shrink(),
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.slate900,
                          ),
                          items: widget.locations
                              .map(
                                (l) => DropdownMenuItem<int>(
                                  value: l.id,
                                  child: Text('${l.name} (${l.code})'),
                                ),
                              )
                              .toList(),
                          onChanged: (id) {
                            if (id != null) {
                              _rebuildState(() => _selectedFloorId = null);
                              widget.onChangeLocation(id);
                            }
                          },
                        ),
                      ],
                    ),
                    Text(
                      'PBX  >  Locations  >  ${loc.code}  >  ${floor?.name ?? 'Sin Planta'} (Vista de Planta 2D)',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppPalette.slate500,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                if (loc.monitoredCount > 0) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: loc.offlineCount > 0
                          ? AppPalette.red50
                          : AppPalette.green50,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: loc.offlineCount > 0
                            ? AppPalette.red200
                            : const Color(0xFFBBF7D0),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.monitor_heart_rounded,
                          size: 14,
                          color: loc.offlineCount > 0
                              ? AppPalette.red600
                              : AppPalette.green600,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          [
                            'Datacenter Monitorizados: ${loc.monitoredCount}',
                            if (loc.onlineCount > 0)
                              '🟢 ${loc.onlineCount}',
                            if (loc.offlineCount > 0)
                              '🔴 ${loc.offlineCount}',
                            if (loc.warningCount > 0)
                              '🟠 ${loc.warningCount}',
                          ].join(' • '),
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppPalette.slate900,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                if (widget.onToggleKioskMode != null) ...[
                  OutlinedButton.icon(
                    onPressed: widget.onToggleKioskMode,
                    icon: const Icon(Icons.tv_rounded, size: 16),
                    label: const Text(
                      'Modo Kiosco',
                      style: TextStyle(fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppPalette.slate900,
                      side: const BorderSide(color: AppPalette.slate400),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                if (floor != null) ...[
                  DiagramExportMenuButton(
                    buttonLabel: 'Exportar Planta (.dia / .png / .pdf / .xlsx)',
                    documentBuilder: () => _buildFloorExportDocument(
                      floor,
                      [for (final rm in floor.rooms) ...rm.racks],
                    ),
                    onExportExcel: () {
                      final url = Uri.parse(widget.api.getExcelExportUrl());
                      launchUrl(url, mode: LaunchMode.externalApplication);
                    },
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: _uploading
                        ? null
                        : () => _uploadFloorBlueprint(floor),
                    icon:
                        const Icon(Icons.upload_file_outlined, size: 16),
                    label: Text(
                      _uploading
                          ? 'Subiendo...'
                          : (floor.mapImageUrl.isNotEmpty
                              ? 'Cambiar Plano de Planta (JPG/PNG/GIF)'
                              : 'Subir Plano de Planta (JPG/PNG/GIF)'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  if (floor.mapImageUrl.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    IconButton(
                      onPressed: () async {
                        await widget.api.deleteCustomPlanImage(
                          targetType: 'floor',
                          targetId: floor.id,
                        );
                        widget.onRefresh();
                      },
                      icon: const Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: AppPalette.red600,
                      ),
                      tooltip: 'Quitar imagen de fondo de esta planta',
                    ),
                  ],
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: () => _showDrawNewRackDialog(floor),
                    icon: const Icon(Icons.dns_outlined, size: 16),
                    label: const Text('+ Rack'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppPalette.blue900,
                      side: const BorderSide(color: AppPalette.blue300),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => _showAddFloorDeviceModal(
                      floor,
                      initialCategory: 'printer',
                      focusCmdbSelector: true,
                    ),
                    icon: const Icon(
                      Icons.fact_check_outlined,
                      size: 16,
                    ),
                    label: const Text('+ Desde CMDB'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppPalette.teal700,
                      backgroundColor: const Color(0xFFF0FDFA),
                      side: const BorderSide(color: AppPalette.teal600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => _showAddFloorDeviceModal(floor),
                    icon: const Icon(
                      Icons.add_location_alt_outlined,
                      size: 17,
                    ),
                    label: const Text('+ Device'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppPalette.blue600,
                    ),
                  ),
                ],
              ],
            ),

            const SizedBox(height: 12),

            // BARRA DE PESTAÑAS DE PLANTAS DEL EDIFICIO (Floor 1, Floor 2, Floor 3...)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Text(
                    'PLANTAS DEL EDIFICIO:',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: AppPalette.slate500,
                    ),
                  ),
                  const SizedBox(width: 12),
                  ...loc.floors.map((fl) {
                    final isSel = fl.id == floor?.id;
                    int rCount = 0;
                    for (final r in fl.rooms) {
                      rCount += r.racks.length;
                    }
                    final dCount = fl.floorDevices.length;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8, bottom: 8),
                      child: InkWell(
                        onTap: () {
                          _rebuildState(() {
                            _selectedFloorId = fl.id;
                            _selectedFloorDeviceId = null;
                            _editingDeviceId = null;
                            _syncFloorState();
                          });
                        },
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isSel
                                ? AppPalette.slate900
                                : AppPalette.slate100,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: isSel
                                  ? AppPalette.slate900
                                  : AppPalette.slate300,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.layers,
                                size: 15,
                                color: isSel
                                    ? AppPalette.sky400
                                    : AppPalette.slate600,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                fl.name,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: isSel
                                      ? Colors.white
                                      : AppPalette.slate800,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: isSel
                                      ? Colors.white24
                                      : AppPalette.slate200,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  [
                                    '$rCount racks',
                                    if (dCount > 0) '$dCount disp.',
                                    '⚪${fl.unmonitoredCount}',
                                    '🟢${fl.onlineCount}',
                                    if (fl.warningCount > 0)
                                      '🟠${fl.warningCount}',
                                    '🔴${fl.offlineCount}',
                                  ].join(' • '),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: isSel
                                        ? Colors.white
                                        : AppPalette.slate700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              InkWell(
                                onTap: () => _confirmDeleteFloor(fl),
                                child: Tooltip(
                                  message:
                                      'Eliminar esta Planta (${fl.name})',
                                  child: Icon(
                                    Icons.delete_outline,
                                    size: 15,
                                    color: isSel
                                        ? AppPalette.red300
                                        : AppPalette.red600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextButton.icon(
                      onPressed: () => _showAddFloorDialog(loc),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('+ Añadir Planta'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
  }
}
