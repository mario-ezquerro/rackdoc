part of '../rack_editor_view.dart';

/// Renderizado de equipos enracados, fotografías realistas de chasis, barras
/// de herramientas flotantes, orejetas de montaje y tomas exteriores (Schuko/Fibra).
extension _RackEditorDevicesAndOutletsExt on _RackEditorViewState {
  Widget _buildExternalPowerOutletsZone({
    required List<RackDeviceModel> extOutlets,
    required Map<int, Color> connectedPortColors,
  }) {
    double runningTopInZone = _RackEditorViewState._extCardTopStart - (_RackEditorViewState._rackTopMargin - 20);
    final cardPositions = <double>[];
    final cardHeights = <double>[];
    for (final ext in extOutlets) {
      cardPositions.add(runningTopInZone);
      final h = _externalCardHeight(ext);
      cardHeights.add(h);
      runningTopInZone += h + _RackEditorViewState._extCardGap;
    }
    final totalHeight = runningTopInZone + 40.0;
    final nonFloorOutletsCount =
        extOutlets.where((e) => !e.isFloorDevicesFeed).length;

    return Positioned(
      left: _effectiveExtZoneLeft,
      top: _RackEditorViewState._rackTopMargin - 20,
      width: _RackEditorViewState._extZoneWidth,
      height: totalHeight + 60,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppPalette.slate900,
                borderRadius: BorderRadius.circular(8),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x18000000),
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.hub_rounded,
                    color: Color(0xFF2DD4BF),
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PLANTA / DATACENTER & TOMAS EXTERIORES',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 9.4,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.2,
                          ),
                        ),
                        Text(
                          'Impresoras, APs, Cámaras, Sensores, Schuko y Fibra',
                          style: TextStyle(
                            color: AppPalette.slate400,
                            fontSize: 8.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_canEdit) ...[
                    InkWell(
                      onTap: _showQuickAddFloorDeviceFromRackDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppPalette.teal600,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add_link, size: 11, color: Colors.white),
                            SizedBox(width: 2),
                            Text(
                              '+Planta',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 8.8,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () => _showAddOrEditExternalOutletDialog(
                        initialFeedType: 'power',
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppPalette.red600,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.bolt, size: 11, color: Colors.white),
                            SizedBox(width: 2),
                            Text(
                              '+Schuko',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 8.8,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () => _showAddOrEditExternalOutletDialog(
                        initialFeedType: 'fiber',
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppPalette.sky600,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add, size: 11, color: Colors.white),
                            SizedBox(width: 2),
                            Text(
                              '+Fibra',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 8.8,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          for (int idx = 0; idx < extOutlets.length; idx++)
            _buildSingleExternalOutletCard(
              ext: extOutlets[idx],
              topInZone: cardPositions[idx],
              cardHeight: cardHeights[idx],
              canDelete: _canEdit &&
                  !extOutlets[idx].isFloorDevicesFeed &&
                  nonFloorOutletsCount > 1,
              connectedPortColors: connectedPortColors,
            ),
        ],
      ),
    );
  }

  Widget _buildSingleExternalOutletCard({
    required RackDeviceModel ext,
    required double topInZone,
    required double cardHeight,
    required bool canDelete,
    required Map<int, Color> connectedPortColors,
  }) {
    final feedColor = CableGeometryBuilder.parseHexColor(ext.feedColorHex);
    final count = ext.ports.length;
    final isFiber = ext.isFiberFeed;
    final isFloorBox = ext.isFloorDevicesFeed;

    return Positioned(
      left: 0,
      top: topInZone,
      width: _RackEditorViewState._extZoneWidth,
      height: cardHeight,
      child: Container(
        decoration: BoxDecoration(
          color: isFloorBox ? AppPalette.slate50 : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: feedColor, width: 2.2),
          boxShadow: [
            BoxShadow(
              color: feedColor.withValues(alpha: 0.14),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              height: 36,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: feedColor,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(7),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isFloorBox
                          ? Icons.devices_other_rounded
                          : (isFiber
                              ? Icons.settings_input_hdmi_outlined
                              : Icons.bolt),
                      size: 15,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        isFloorBox
                            ? 'EQUIPOS & SENSORES DE PLANTA ($count)'
                            : '${ext.code} • ${ext.name}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10.4,
                          fontWeight: FontWeight.w800,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_canEdit && isFloorBox)
                      InkWell(
                        onTap: _showQuickAddFloorDeviceFromRackDialog,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.white70),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add, size: 11, color: Colors.white),
                              SizedBox(width: 2),
                              Text(
                                'Añadir',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 8.8,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_canEdit && !isFloorBox)
                      IconButton(
                        onPressed: () =>
                            _showAddOrEditExternalOutletDialog(existing: ext),
                        icon: const Icon(
                          Icons.edit_outlined,
                          size: 14,
                          color: Colors.white,
                        ),
                        tooltip: isFiber
                            ? 'Editar caja exterior de fibra y nº de conectores'
                            : 'Editar nombre, color o número de enchufes',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                      ),
                    if (canDelete)
                      IconButton(
                        onPressed: () => _deleteExternalOutlet(ext),
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 14,
                          color: Colors.white,
                        ),
                        tooltip: 'Eliminar esta toma exterior',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 10,
              top: 40,
              right: 8,
              child: Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: feedColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      isFloorBox
                          ? 'Clic en icono para tirar cable al Switch o Patch Panel'
                          : (isFiber
                              ? 'Fibra Óptica Exterior ($count conectores FO)'
                              : 'Enchufes Schuko 230V ($count tomas)'),
                      style: const TextStyle(
                        fontSize: 9.0,
                        fontWeight: FontWeight.w700,
                        color: AppPalette.slate600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_canEdit && !isFloorBox)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: AppPalette.slate100,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppPalette.slate300),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          InkWell(
                            onTap: count > 1
                                ? () => _quickAdjustExternalOutletCount(
                                      ext,
                                      count - (isFiber && count > 8 ? 2 : 1),
                                    )
                                : null,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 3),
                              child: Icon(
                                Icons.remove,
                                size: 11,
                                color: AppPalette.slate900,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: Text(
                              '$count',
                              style: const TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: AppPalette.slate900,
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: count < (isFiber ? 48 : 16)
                                ? () => _quickAdjustExternalOutletCount(
                                      ext,
                                      count + (isFiber && count >= 8 ? 2 : 1),
                                    )
                                : null,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 3),
                              child: Icon(
                                Icons.add,
                                size: 11,
                                color: AppPalette.slate900,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (isFloorBox && count == 0)
              Positioned(
                left: 12,
                right: 12,
                top: 62,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppPalette.slate300),
                  ),
                  child: const Text(
                    'Sin impresoras, cámaras, APs o sensores vinculados a este Rack. Pulsa "+Planta" arriba o vincúlalos en 2. Datacenters.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 9.2, color: AppPalette.slate500),
                  ),
                ),
              ),
            for (int pIdx = 0; pIdx < count; pIdx++)
              _buildExternalPortWidget(
                ext: ext,
                port: ext.ports[pIdx],
                index: pIdx,
                feedColor: feedColor,
                connectedColor: connectedPortColors[ext.ports[pIdx].id],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildExternalPortWidget({
    required RackDeviceModel ext,
    required PortModel port,
    required int index,
    required Color feedColor,
    required Color? connectedColor,
  }) {
    final isPending = _pendingSourcePort?.id == port.id;
    final isConnected = connectedColor != null;
    final localCenter = _externalPortLocalCenter(ext, index);

    // 1. RECUADRO DE EQUIPOS DE PLANTA (Impresoras, Cámaras, APs Wi-Fi, Sensores, Rosetas, PCs)
    if (ext.isFloorDevicesFeed) {
      final parts = port.label.split('|');
      final devType = parts.length >= 2 ? parts[1] : 'device';
      final devName = parts.length >= 3 && parts[2].trim().isNotEmpty
          ? parts[2].trim()
          : port.portNumber;
      final devIp = parts.length >= 4 ? parts[3].trim() : '';
      final devRoom = parts.length >= 5 ? parts[4].trim() : '';
      final meta = _floorDeviceVisualMeta(devType);

      String? connectedTargetLabel;
      if (_rack != null) {
        for (final c in _rack!.connections) {
          if (c.sourcePortId == port.id) {
            connectedTargetLabel =
                '${c.targetInfo.deviceCode}:${c.targetInfo.portNumber}';
            break;
          } else if (c.targetPortId == port.id) {
            connectedTargetLabel =
                '${c.sourceInfo.deviceCode}:${c.sourceInfo.portNumber}';
            break;
          }
        }
      }

      const tileW = 102.0;
      const tileH = 58.0;
      final leftPx = localCenter.dx - tileW / 2.0;
      final topPx = localCenter.dy - tileH / 2.0;
      final borderCol = isPending
          ? AppPalette.amber500
          : (isConnected ? (connectedColor) : meta.color);

      return Positioned(
        left: leftPx,
        top: topPx,
        width: tileW,
        height: tileH,
        child: Tooltip(
          message:
              '📡 EQUIPO / SENSOR DE PLANTA (${meta.typeLabel})\n'
              '• Código: ${port.portNumber} — $devName\n'
              '${devRoom.isNotEmpty ? '• Sala / Zona: $devRoom\n' : ''}'
              '${devIp.isNotEmpty ? '• IP: $devIp\n' : ''}'
              '• Estado en Rack: ${connectedTargetLabel != null ? 'Conectado a $connectedTargetLabel (Clic para seleccionar/borrar cable)' : 'Libre (Clic para tirar cable al Switch o Patch Panel)'}',
          child: InkWell(
            onTap: () => _handlePortTap(ext, port),
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3.5),
              decoration: BoxDecoration(
                color: isPending
                    ? const Color(0xFFECFDF5)
                    : (isConnected
                        ? borderCol.withValues(alpha: 0.11)
                        : Colors.white),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: borderCol,
                  width: isPending ? 2.4 : (isConnected ? 1.9 : 1.3),
                ),
                boxShadow: [
                  BoxShadow(
                    color: borderCol.withValues(
                      alpha: isPending || isConnected ? 0.22 : 0.08,
                    ),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 17,
                        height: 17,
                        decoration: BoxDecoration(
                          color: meta.color,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Icon(meta.icon, size: 11, color: Colors.white),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          port.portNumber,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 9.2,
                            fontWeight: FontWeight.w900,
                            color: AppPalette.slate900,
                          ),
                        ),
                      ),
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: isConnected
                              ? AppPalette.green600
                              : AppPalette.slate300,
                          borderRadius: BorderRadius.circular(2),
                          border: Border.all(
                            color: AppPalette.slate900,
                            width: 0.8,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    devName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 7.6,
                      fontWeight: FontWeight.w600,
                      color: AppPalette.slate600,
                    ),
                  ),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: isPending
                          ? AppPalette.amber600
                          : (connectedTargetLabel != null
                              ? borderCol
                              : AppPalette.slate100),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      isPending
                          ? 'Elige boca Switch/PP...'
                          : (connectedTargetLabel != null
                              ? '➔ $connectedTargetLabel'
                              : 'Clic ➔ Switch / PP'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 7.4,
                        fontWeight: FontWeight.w800,
                        color: (isPending || connectedTargetLabel != null)
                            ? Colors.white
                            : AppPalette.slate700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final isFiber = ext.isFiberFeed;
    final socketSize = isFiber ? 28.0 : 34.0;
    final leftPx = localCenter.dx - socketSize / 2.0;
    final topPx = localCenter.dy - socketSize / 2.0;

    if (isFiber) {
      // Conector óptico exterior LC/SC (Duplex Ferrule)
      return Positioned(
        left: leftPx,
        top: topPx,
        width: socketSize,
        height: socketSize + 13,
        child: Tooltip(
          message:
              '${ext.code} (${ext.name}) — Conector Fibra ${port.portNumber} (LC/SC)\n${isConnected ? 'Ocupado (Clic para seleccionar latiguillo)' : 'Libre (Clic para conectar fibra al Rack)'}',
          child: InkWell(
            onTap: () => _handlePortTap(ext, port),
            borderRadius: BorderRadius.circular(6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: socketSize,
                  height: socketSize - 4,
                  decoration: BoxDecoration(
                    color: isPending
                        ? AppPalette.emerald500
                        : (isConnected
                            ? feedColor
                            : feedColor.withValues(alpha: 0.12)),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: isPending ? Colors.amber : feedColor,
                      width: isPending ? 2.4 : 1.8,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: isConnected
                              ? Colors.white
                              : AppPalette.slate900,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isConnected ? feedColor : Colors.white,
                            width: 1.0,
                          ),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: isConnected
                              ? Colors.white
                              : AppPalette.slate900,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isConnected ? feedColor : Colors.white,
                            width: 1.0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  port.portNumber,
                  style: TextStyle(
                    fontSize: 7.8,
                    fontWeight: FontWeight.w800,
                    color: isConnected ? feedColor : AppPalette.slate700,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Positioned(
      left: leftPx,
      top: topPx,
      width: socketSize,
      height: socketSize + 14,
      child: Tooltip(
        message:
            '${ext.code} (${ext.name}) — Enchufe ${port.portNumber} (SCHUKO 230V)\n${isConnected ? 'Ocupado (Clic para seleccionar cable)' : 'Libre (Clic para enchufar a Front o Back)'}',
        child: InkWell(
          onTap: () => _handlePortTap(ext, port),
          borderRadius: BorderRadius.circular(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: socketSize,
                height: socketSize,
                decoration: BoxDecoration(
                  color: isPending
                      ? AppPalette.emerald500
                      : (isConnected
                          ? feedColor
                          : feedColor.withValues(alpha: 0.10)),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isPending ? Colors.amber : feedColor,
                    width: isPending ? 2.5 : 2.0,
                  ),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      top: 3,
                      child: Container(
                        width: 4,
                        height: 3,
                        color: isConnected ? Colors.white70 : feedColor,
                      ),
                    ),
                    Positioned(
                      bottom: 3,
                      child: Container(
                        width: 4,
                        height: 3,
                        color: isConnected ? Colors.white70 : feedColor,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 5.5,
                          height: 5.5,
                          decoration: BoxDecoration(
                            color: isConnected
                                ? Colors.white
                                : AppPalette.slate900,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 5.5,
                          height: 5.5,
                          decoration: BoxDecoration(
                            color: isConnected
                                ? Colors.white
                                : AppPalette.slate900,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                port.portNumber,
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w800,
                  color: isConnected ? feedColor : AppPalette.slate700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // CHASIS DE EQUIPO MONTADO EN RACK (ESTILO TÉCNICO PATCHBOX + FOTO REAL/BISEL + ARRASTRAR A U LIBRE)
  // ===========================================================================
  Widget _buildMountedDeviceWidget({
    required RackDeviceModel dev,
    required String face,
    required double innerLeft,
    required int totalUnits,
    required Map<int, Color> connectedPortColors,
  }) {
    final topU = dev.endU;
    final topY = _RackEditorViewState._rackTopMargin + (totalUnits - topU) * _RackEditorViewState._uHeightPx;
    final heightPx = dev.uHeight * _RackEditorViewState._uHeightPx;
    final isSelected = dev.id == _selectedDeviceId;
    final isHighlighted = dev.id == _highlightedDeviceId;
    final isHovered = dev.id == _hoveredDeviceId;
    final isActiveTarget = isHovered ||
        ((isSelected || isHighlighted) && _hoveredDeviceId == null);
    final facePorts = dev.portsForFace(face);
    final isRearAutoView = dev.mountedFace != face;
    final isTray = dev.template.category == 'rack_tray' ||
        dev.template.modelName.toLowerCase().contains('bandeja');
    final isRoofFan = dev.template.isRoofFan;

    final isOnline = dev.status == 'online';
    final isOffline = dev.status == 'offline';
    final statusColor = !dev.monitoringEnabled
        ? AppPalette.slate400
        : (isOnline
            ? AppPalette.green600
            : (isOffline
                ? AppPalette.red600
                : AppPalette.amber600));

    Widget buildChassisContent({required bool isDropTarget}) {
      return Container(
        decoration: BoxDecoration(
          // Sombreado claro del elemento sobre el que está el ratón y va a actuar (o seleccionado)
          color: isDropTarget
              ? const Color(0xFFFEE2E2)
              : (isHovered
                  ? AppPalette.blue100
                  : ((isHighlighted || isSelected)
                      ? const Color(0xFFD1D5DB)
                      : (isTray
                          ? AppPalette.slate100
                          : (isRearAutoView
                              ? AppPalette.slate50
                              : Colors.white)))),
          border: Border.symmetric(
            horizontal: BorderSide(
              color: isHovered
                  ? AppPalette.sky600
                  : ((isHighlighted || isSelected)
                      ? AppPalette.slate800
                      : AppPalette.slate300),
              width: (isHovered || isHighlighted || isSelected) ? 2.0 : 0.9,
            ),
            vertical: (isHovered || isHighlighted || isSelected)
                ? BorderSide(
                    color: isHovered
                        ? AppPalette.sky600
                        : AppPalette.slate800,
                    width: 1.4,
                  )
                : BorderSide.none,
          ),
          boxShadow: isHovered
              ? [
                  BoxShadow(
                    color: AppPalette.sky600.withValues(alpha: 0.30),
                    blurRadius: 9,
                    spreadRadius: 1,
                  ),
                ]
              : ((isHighlighted || isSelected)
                  ? [
                      BoxShadow(
                        color: AppPalette.slate600.withValues(alpha: 0.28),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : null),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Etiqueta en la regla U indicando el equipo activo sobre el que está el cursor o seleccionado
            if (isHovered || isHighlighted || isSelected)
              Positioned(
                left: -68,
                top: (heightPx / 2) - 10,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: isHovered
                          ? AppPalette.sky600
                          : AppPalette.slate700,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '▶ U${dev.startU}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ),

            // Fondo de Foto de Referencia o Bisel Gráfico Industrial (cuando "Foto Equipos: ON" está activo, o siempre para Ventiladores/Bandejas)
            if (_showEquipmentPhotos || isTray || isRoofFan)
              Positioned(
                left: _RackEditorViewState._railWidth + 24,
                right: _RackEditorViewState._railWidth + 4,
                top: 1,
                bottom: 1,
                child: _buildRealisticPhotoBezelOverlay(dev, face),
              ),

            // Orejetas laterales de anclaje sobre el raíl de 19" izquierdo y derecho
            // En la orejeta izquierda se inscribe verticalmente el código del equipo (FI-01, RT01, PBX01, SW01...)
            // salvo en Patch Panels de una sola letra (A, B, C, D, E, F) donde la letra va horizontal dentro del frontal
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: _RackEditorViewState._railWidth,
              child: _buildDeviceMountingEar(
                dev.uHeight,
                isLeft: true,
                verticalCode: dev.code.trim().length <= 1 ? null : dev.code,
                statusColor: statusColor,
                isActiveTarget: isActiveTarget,
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: _RackEditorViewState._railWidth,
              child: _buildDeviceMountingEar(
                dev.uHeight,
                isLeft: false,
                isActiveTarget: isActiveTarget,
              ),
            ),

            // Para Patch Panels con código de 1 sola letra (A, B, C, D, E, F), se dibuja en horizontal junto a la orejeta izquierda
            if (dev.code.trim().length == 1)
              Positioned(
                left: _RackEditorViewState._railWidth + 4,
                top: 0,
                bottom: 0,
                width: 22,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 4.5,
                        height: 4.5,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 2.5),
                      Text(
                        dev.code.trim(),
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w900,
                          color: AppPalette.slate900,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Etiqueta descriptiva sólo cuando "Foto Equipos: ON" está activo, en cara trasera, o en chasis con <= 4 bocas (servidores/SAI)
            if ((_showEquipmentPhotos ||
                    face == 'back' ||
                    facePorts.length <= 4) &&
                facePorts.length <= 12 &&
                !(isTray && dev.trayItems.isNotEmpty))
              Positioned(
                left: _RackEditorViewState._railWidth + 26,
                top: 3,
                child: Container(
                  padding: _showEquipmentPhotos
                      ? const EdgeInsets.symmetric(horizontal: 5, vertical: 1)
                      : EdgeInsets.zero,
                  decoration: _showEquipmentPhotos
                      ? BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.90),
                          borderRadius: BorderRadius.circular(3),
                          border: Border.all(
                            color: AppPalette.slate400,
                            width: 0.6,
                          ),
                        )
                      : null,
                  child: Text(
                    '${dev.name}${dev.uHeight > 1 ? ' (${dev.uHeight}U)' : ''}${isRearAutoView ? ' • [${face.toUpperCase()} U${dev.startU}]' : ''}${dev.ipAddress.isNotEmpty ? ' • ${dev.ipAddress}' : ''}${dev.monitoringEnabled ? ' • HB:${dev.monitorMethod.toUpperCase()}' : ''}',
                    style: const TextStyle(
                      fontSize: 8.2,
                      fontWeight: FontWeight.w700,
                      color: AppPalette.slate700,
                    ),
                  ),
                ),
              ),

            // Bocas / Puertos individuales (desplazados por _RackEditorViewState._railWidth porque el chasis incluye las orejetas)
            for (final port in facePorts)
              _buildPortWidget(
                dev: dev,
                port: port,
                face: face,
                devHeight: heightPx,
                connectedColor: connectedPortColors[port.id],
              ),
          ],
        ),
      );
    }

    return Positioned(
      left: innerLeft - _RackEditorViewState._railWidth,
      top: topY,
      width: _RackEditorViewState._rackInnerWidth + _RackEditorViewState._railWidth * 2,
      height: heightPx,
      child: DragTarget<Object>(
        onWillAcceptWithDetails: (details) {
          if (!_canEdit) return false;
          if (details.data is RackDeviceModel &&
              (details.data as RackDeviceModel).id == dev.id) {
            return false;
          }
          if (_hoveredDropU != dev.startU || _draggingData != details.data) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _rebuildState(() {
                  _draggingData = details.data;
                  _hoveredDropU = dev.startU;
                });
              }
            });
          }
          return true;
        },
        onLeave: (_) {
          if (_hoveredDropU == dev.startU) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _hoveredDropU == dev.startU) {
                _rebuildState(() => _hoveredDropU = null);
              }
            });
          }
        },
        onAcceptWithDetails: (details) {
          _handleDropOnUSlot(
            details.data,
            dev.startU,
            targetMountedDevice: dev,
          );
        },
        builder: (ctx, candidate, _) {
          final isDropTarget = candidate.isNotEmpty;
          final interactiveChassis = MouseRegion(
            cursor: _canEdit ? SystemMouseCursors.move : SystemMouseCursors.basic,
            onEnter: (_) => _rebuildState(() => _hoveredDeviceId = dev.id),
            onExit: (_) {
              if (_hoveredDeviceId == dev.id) {
                _rebuildState(() => _hoveredDeviceId = null);
              }
            },
            child: GestureDetector(
              onTap: () {
                if (_canEdit &&
                    isTray &&
                    _selectedTemplateForClick != null &&
                    _selectedTemplateForClick!.isTrayMiniDevice) {
                  _showManageTrayItemsDialog(
                    dev,
                    initialAddTemplate: _selectedTemplateForClick,
                  );
                  return;
                }
                _rebuildState(() {
                  _selectedDeviceId = dev.id;
                  _highlightedDeviceId = dev.id;
                  _selectedConnectionId = null;
                });
              },
              child: buildChassisContent(isDropTarget: isDropTarget),
            ),
          );

          if (!_canEdit) {
            return interactiveChassis;
          }

          return Draggable<Object>(
            data: dev,
            onDragStarted: () {
              _rebuildState(() {
                _draggingData = dev;
                _selectedDeviceId = dev.id;
              });
            },
            onDragEnd: (_) {
              if (mounted) {
                _rebuildState(() {
                  _draggingData = null;
                  _hoveredDropU = null;
                });
              }
            },
            onDraggableCanceled: (_, _) {
              if (mounted) {
                _rebuildState(() {
                  _draggingData = null;
                  _hoveredDropU = null;
                });
              }
            },
            feedback: Material(
              elevation: 10,
              borderRadius: BorderRadius.circular(6),
              color: Colors.transparent,
              child: Container(
                width: _RackEditorViewState._rackInnerWidth * 0.85,
                height: heightPx.clamp(38.0, 120.0),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: AppPalette.slate900.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: AppPalette.sky400,
                    width: 2.0,
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.open_with_rounded,
                      color: AppPalette.sky400,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Moviendo ${dev.code} (${dev.name}) • Requiere ${dev.uHeight}U libres',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            childWhenDragging: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: AppPalette.blue50.withValues(alpha: 0.60),
                  border: Border.all(
                    color: AppPalette.blue500,
                    width: 1.5,
                  ),
                ),
                child: Center(
                  child: Text(
                    'Moviendo ${dev.code} (${dev.uHeight}U) — Suelta en una posición con ${dev.uHeight}U libres',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppPalette.blue700,
                    ),
                  ),
                ),
              ),
            ),
            child: interactiveChassis,
          );
        },
      ),
    );
  }

  /// Barra flotante de controles rápidos del equipo montado, situada como pestaña justo encima del borde superior
  /// del chasis para no tapar jamás las bocas / puertos (1..48, SFP, etc.) del propio equipo.
  Widget _buildDeviceFloatingToolbar({
    required RackDeviceModel dev,
    required double innerLeft,
    required int totalUnits,
  }) {
    final topU = dev.endU;
    final topY = _RackEditorViewState._rackTopMargin + (totalUnits - topU) * _RackEditorViewState._uHeightPx;
    final rack = _rack;
    final nextUpU = rack != null ? _findNearestFreeU(rack, dev, 1) : null;
    final nextDownU = rack != null ? _findNearestFreeU(rack, dev, -1) : null;
    final isTray = dev.template.category == 'rack_tray' ||
        dev.template.modelName.toLowerCase().contains('bandeja');

    return Positioned(
      left: innerLeft + 4,
      top: topY - 21,
      child: MouseRegion(
        onEnter: (_) => _rebuildState(() => _hoveredDeviceId = dev.id),
        onExit: (_) {
          if (_hoveredDeviceId == dev.id) {
            _rebuildState(() => _hoveredDeviceId = null);
          }
        },
        child: Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Material(
            elevation: 4,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(6),
              bottom: Radius.circular(3),
            ),
            color: AppPalette.slate900.withValues(alpha: 0.94),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 5,
                vertical: 1.5,
              ),
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(6),
                  bottom: Radius.circular(3),
                ),
                border: Border.all(
                  color: AppPalette.sky400.withValues(alpha: 0.55),
                  width: 0.8,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      '▾ ${dev.code}',
                      style: const TextStyle(
                        fontSize: 9.0,
                        fontWeight: FontWeight.w900,
                        color: AppPalette.sky400,
                      ),
                    ),
                  ),
                  const Tooltip(
                    message:
                        'Arrastra el equipo directamente a cualquier posición con U libres',
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 2.5),
                      child: Icon(
                        Icons.open_with_rounded,
                        size: 12.5,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: nextUpU != null
                        ? () => _moveDeviceToU(dev, nextUpU)
                        : null,
                    child: Tooltip(
                      message: nextUpU != null
                          ? 'Subir a U$nextUpU (${dev.uHeight}U libres)'
                          : 'No hay ${dev.uHeight}U libres más arriba',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2.5),
                        child: Icon(
                          Icons.keyboard_arrow_up,
                          size: 14,
                          color: nextUpU != null
                              ? Colors.white
                              : Colors.white38,
                        ),
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: nextDownU != null
                        ? () => _moveDeviceToU(dev, nextDownU)
                        : null,
                    child: Tooltip(
                      message: nextDownU != null
                          ? 'Bajar a U$nextDownU (${dev.uHeight}U libres)'
                          : 'No hay ${dev.uHeight}U libres más abajo',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2.5),
                        child: Icon(
                          Icons.keyboard_arrow_down,
                          size: 14,
                          color: nextDownU != null
                              ? Colors.white
                              : Colors.white38,
                        ),
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () => _showMoveDeviceToUDialog(dev),
                    child: Tooltip(
                      message:
                          'Elegir U libre destino (Actual: U${dev.startU})',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Text(
                          'U${dev.startU}',
                          style: const TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.bold,
                            color: AppPalette.blue300,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 3,
                      vertical: 0.5,
                    ),
                    decoration: BoxDecoration(
                      color: AppPalette.slate800,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: AppPalette.slate600),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkWell(
                          onTap: dev.uHeight > 1
                              ? () => _quickAdjustDeviceUHeight(
                                    dev,
                                    dev.uHeight - 1,
                                  )
                              : null,
                          child: const Tooltip(
                            message: 'Reducir 1U de altura',
                            child: Icon(
                              Icons.remove,
                              size: 11,
                              color: AppPalette.sky400,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: Text(
                            '${dev.uHeight}U',
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: dev.uHeight < 16
                              ? () => _quickAdjustDeviceUHeight(
                                    dev,
                                    dev.uHeight + 1,
                                  )
                              : null,
                          child: const Tooltip(
                            message: 'Ampliar +1U de altura',
                            child: Icon(
                              Icons.add,
                              size: 11,
                              color: AppPalette.sky400,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isTray)
                    InkWell(
                      onTap: () => _showManageTrayItemsDialog(dev),
                      child: Tooltip(
                        message:
                            'Colocar o gestionar Mini-Equipos dentro de esta Bandeja (Routers, Switches, Mini-PCs)',
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: AppPalette.violet600,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.inbox_outlined,
                                size: 11,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                '+ Equipos (${dev.trayItems.length})',
                                style: const TextStyle(
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  InkWell(
                    onTap: () => _showHardwarePhotoSearchDialog(device: dev),
                    child: const Tooltip(
                      message:
                          'Buscar o cambiar Foto de Referencia del equipo',
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 3),
                        child: Icon(
                          Icons.photo_camera_outlined,
                          size: 12.5,
                          color: AppPalette.sky400,
                        ),
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () => _showInterRackConnectionDialog(
                      initialSourceDev: dev,
                    ),
                    child: const Tooltip(
                      message:
                          'Conectar fibra/cable desde este equipo hacia otro Rack',
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 3),
                        child: Icon(
                          Icons.compare_arrows,
                          size: 13,
                          color: Color(0xFF34D399),
                        ),
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () => _quickDeleteDevice(dev),
                    child: const Tooltip(
                      message: 'Borrar / Desmontar este equipo',
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 3),
                        child: Icon(
                          Icons.delete_outline,
                          size: 13,
                          color: Color(0xFFF87171),
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

  /// Dibuja la Foto de Referencia de Internet (si existe y Foto Equipos está ON) o una Carátula Fotográfica Hardware Realista (Front & Back).
  Widget _buildRealisticPhotoBezelOverlay(RackDeviceModel dev, String face) {
    final hasPhoto = _showEquipmentPhotos && dev.photoUrl.isNotEmpty;
    final cat = dev.template.category;
    final isRoofFan = dev.template.isRoofFan;
    final isTray = cat == 'rack_tray' ||
        dev.template.modelName.toLowerCase().contains('bandeja');

    if (hasPhoto && !(isTray && dev.trayItems.isNotEmpty)) {
      return IgnorePointer(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildCatalogHardwareFaceplate(dev, face),
              Opacity(
                opacity: 0.82,
                child: Image.network(
                  _resolvePhotoNetworkUrl(dev.photoUrl),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (isRoofFan) {
      // Módulo de Ventiladores de Techo 1U con 4 turbinas y pantalla digital de temperatura
      return IgnorePointer(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(width: 90),
            for (int f = 0; f < 4; f++)
              Container(
                width: 28,
                height: 28,
                margin: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  color: AppPalette.slate100,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: AppPalette.slate600,
                    width: 1.4,
                  ),
                ),
                child: const Icon(
                  Icons.cyclone,
                  size: 17,
                  color: AppPalette.sky600,
                ),
              ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: AppPalette.slate900,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: AppPalette.emerald500),
              ),
              child: const Text(
                '21.4°C • FAN OK',
                style: TextStyle(
                  color: Color(0xFF4ADE80),
                  fontSize: 7.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (isTray) {
      final trayItems = dev.trayItems;
      // Bandeja de Rack perforada con soporte visual para Mini-Equipos apoyados encima (Routers, Switches, Mini-PCs)
      return IgnorePointer(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: AppPalette.slate200.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(3),
            border: Border(
              bottom: const BorderSide(color: AppPalette.slate700, width: 3.5),
              left: const BorderSide(color: AppPalette.slate500, width: 1.5),
              right: const BorderSide(color: AppPalette.slate500, width: 1.5),
              top: BorderSide(
                color: AppPalette.slate400.withValues(alpha: 0.45),
                width: 0.8,
              ),
            ),
          ),
          child: trayItems.isEmpty
              ? Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.inbox_outlined,
                        size: 13,
                        color: AppPalette.slate600,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'BANDEJA RACK 19" (${dev.uHeight}U) • Arrastra aquí equipos de "Bandeja - Equipos Mini" o pulsa "+ Equipos"',
                        style: const TextStyle(
                          fontSize: 8.5,
                          fontWeight: FontWeight.w800,
                          color: AppPalette.slate700,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.only(
                    left: 4,
                    right: 4,
                    top: 2,
                    bottom: 3,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (int idx = 0; idx < trayItems.length; idx++)
                        Expanded(
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppPalette.slate800
                                  .withValues(alpha: 0.88),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: AppPalette.slate500,
                                width: 1.1,
                              ),
                            ),
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: Row(
                                children: [
                                  Icon(
                                    (trayItems[idx]['model_name'] ?? '')
                                                .toString()
                                                .toLowerCase()
                                                .contains('switch')
                                        ? Icons.commit
                                        : ((trayItems[idx]['model_name'] ?? '')
                                                    .toString()
                                                    .toLowerCase()
                                                    .contains('pc') ||
                                                (trayItems[idx]['model_name'] ??
                                                        '')
                                                    .toString()
                                                    .toLowerCase()
                                                    .contains('nuc') ||
                                                (trayItems[idx]['model_name'] ??
                                                        '')
                                                    .toString()
                                                    .toLowerCase()
                                                    .contains('raspberry')
                                            ? Icons.computer
                                            : Icons.router_outlined),
                                    size: 11,
                                    color: AppPalette.sky400,
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      '${trayItems[idx]['code'] ?? 'MINI-${idx + 1}'}: ${trayItems[idx]['name'] ?? trayItems[idx]['model_name'] ?? ''}'
                                      '${(trayItems[idx]['ip_address'] ?? '').toString().isNotEmpty ? ' (${trayItems[idx]['ip_address']})' : ''}',
                                      style: const TextStyle(
                                        fontSize: 8.0,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      );
    }

    if (_showEquipmentPhotos) {
      return IgnorePointer(
        child: _buildCatalogHardwareFaceplate(dev, face),
      );
    }

    return const SizedBox.shrink();
  }

  /// Renderiza una Carátula Fotográfica Hardware Realista (Front & Back) para cualquier equipo del catálogo.
  Widget _buildCatalogHardwareFaceplate(RackDeviceModel dev, String face) {
    final cat = dev.template.category;
    final mfg = dev.template.manufacturer.trim();
    final mfgLow = mfg.toLowerCase();
    final modelLow = dev.template.modelName.toLowerCase();
    final isBack = face.toLowerCase() == 'back';

    // Color de acento de marca oficial
    Color brandAccent = AppPalette.sky600;
    if (mfgLow.contains('hpe') || mfgLow.contains('hewlett')) {
      brandAccent = const Color(0xFF01A982); // HPE Green
    } else if (mfgLow.contains('dell')) {
      brandAccent = const Color(0xFF0076CE); // Dell Blue
    } else if (mfgLow.contains('cisco')) {
      brandAccent = const Color(0xFF049FD9); // Cisco Cyan
    } else if (mfgLow.contains('forti')) {
      brandAccent = const Color(0xFFEE3124); // Fortinet Red
    } else if (mfgLow.contains('mikrotik')) {
      brandAccent = AppPalette.blue600;
    } else if (mfgLow.contains('apc') || mfgLow.contains('schneider')) {
      brandAccent = AppPalette.emerald500;
    } else if (mfgLow.contains('netapp')) {
      brandAccent = const Color(0xFF0067C5);
    } else if (mfgLow.contains('pure')) {
      brandAccent = const Color(0xFFFE5000);
    } else if (mfgLow.contains('ibm')) {
      brandAccent = const Color(0xFF0F62FE);
    } else if (mfgLow.contains('patchbox')) {
      brandAccent = const Color(0xFFEC4899);
    }

    // 1. CARA TRASERA (BACK): Chasis de acero + Módulos de Ventiladores Hot-Swap + Fuentes Redundantes PSU1/PSU2
    if (isBack) {
      final isPassive = cat == 'patch_panel' ||
          cat == 'cable_manager' ||
          cat == 'miscellaneous';
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isPassive
                ? [
                    AppPalette.slate700.withValues(alpha: 0.72),
                    AppPalette.slate800.withValues(alpha: 0.78),
                  ]
                : [
                    AppPalette.slate600.withValues(alpha: 0.72),
                    AppPalette.slate800.withValues(alpha: 0.80),
                    AppPalette.slate900.withValues(alpha: 0.84),
                  ],
          ),
          borderRadius: BorderRadius.circular(2),
          border: Border.all(
            color: AppPalette.slate500.withValues(alpha: 0.65),
            width: 0.8,
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 120),
            if (!isPassive) ...[
              // Rejillas de ventiladores de extracción traseros
              for (int f = 0; f < 3; f++)
                Container(
                  width: 24,
                  height: 22,
                  margin: const EdgeInsets.symmetric(
                    horizontal: 3,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppPalette.slate900.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(
                      color: AppPalette.slate400.withValues(alpha: 0.55),
                      width: 0.8,
                    ),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.cyclone,
                      size: 13,
                      color: AppPalette.slate400,
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              // Módulos PSU redundantes (Hot-Swap)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppPalette.slate900.withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                    color: AppPalette.emerald500.withValues(alpha: 0.75),
                    width: 0.9,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 5,
                      height: 10,
                      decoration: BoxDecoration(
                        color: AppPalette.emerald500,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'REAR CHASSIS • ${mfg.toUpperCase()} DUAL PSU HOT-SWAP',
                      style: const TextStyle(
                        color: AppPalette.slate200,
                        fontSize: 7.2,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ] else
              const Text(
                'REAR TERMINATION BAR • IDC KRONE / GROUNDING',
                style: TextStyle(
                  color: AppPalette.slate300,
                  fontSize: 7.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
      );
    }

    // 2. CARA DELANTERA (FRONT) POR CATEGORÍA DE HARDWARE
    // 2A. SERVIDORES Y CABINAS SAN / NAS (HPE ProLiant, Dell PowerEdge, Supermicro, NetApp, IBM, Pure, Synology, QNAP)
    if (cat == 'server' || cat == 'storage_san' || cat == 'storage_nas') {
      final bayCols = dev.uHeight >= 2 ? 12 : 8;
      final bayRows = dev.uHeight >= 4 ? 2 : 1;
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppPalette.slate800.withValues(alpha: 0.86),
              AppPalette.slate900.withValues(alpha: 0.92),
            ],
          ),
          borderRadius: BorderRadius.circular(2),
          border: Border(
            left: BorderSide(color: brandAccent, width: 4),
            top: BorderSide(
              color: AppPalette.slate500.withValues(alpha: 0.6),
              width: 0.8,
            ),
            bottom: BorderSide(
              color: AppPalette.slate600.withValues(alpha: 0.8),
              width: 1.0,
            ),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(
            left: 118,
            right: 68,
            top: dev.uHeight >= 2 ? 18 : 13,
            bottom: 3,
          ),
          child: Column(
            children: [
              for (int r = 0; r < bayRows; r++)
                Expanded(
                  child: Row(
                    children: [
                      // Badge de marca a la izquierda de las bahías
                      if (r == 0)
                        Container(
                          margin: const EdgeInsets.only(right: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: brandAccent.withValues(alpha: 0.22),
                            borderRadius: BorderRadius.circular(3),
                            border: Border.all(color: brandAccent, width: 1.0),
                          ),
                          child: Text(
                            mfg.toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 7.5,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      for (int b = 0; b < bayCols; b++)
                        Expanded(
                          child: Container(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 1.2,
                              vertical: 1.0,
                            ),
                            decoration: BoxDecoration(
                              color: AppPalette.slate700
                                  .withValues(alpha: 0.92),
                              borderRadius: BorderRadius.circular(2),
                              border: Border.all(
                                color: AppPalette.slate400
                                    .withValues(alpha: 0.55),
                                width: 0.8,
                              ),
                            ),
                            child: Stack(
                              children: [
                                // Rejilla del caddy NVMe/SAS
                                Positioned(
                                  left: 2,
                                  right: 2,
                                  bottom: 2,
                                  height: 3,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: brandAccent.withValues(alpha: 0.7),
                                      borderRadius: BorderRadius.circular(1),
                                    ),
                                  ),
                                ),
                                // LEDs de estado del disco (Verde Online + Azul Actividad)
                                Positioned(
                                  top: 2,
                                  right: 2,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 3.5,
                                        height: 3.5,
                                        decoration: const BoxDecoration(
                                          color: Color(0xFF22C55E),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 1.5),
                                      Container(
                                        width: 3.0,
                                        height: 3.0,
                                        decoration: BoxDecoration(
                                          color: brandAccent,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }

    // 2B. SAI / UPS Y PDU (APC Smart-UPS, NetShelter PDU, Rittal Schuko)
    if (cat == 'ups' || cat == 'pdu') {
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppPalette.slate900.withValues(alpha: 0.88),
              AppPalette.slate800.withValues(alpha: 0.85),
            ],
          ),
          borderRadius: BorderRadius.circular(2),
          border: Border(
            left: BorderSide(color: brandAccent, width: 4),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 120),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppPalette.sky600.withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: AppPalette.sky400,
                  width: 1.1,
                ),
              ),
              child: Text(
                cat == 'ups'
                    ? '⚡ ${mfg.toUpperCase()} LCD • 230V ONLINE • BATT 100% • LOAD 34%'
                    : '⚡ ${mfg.toUpperCase()} METERED PDU • 230V • 6.2A',
                style: const TextStyle(
                  color: Color(0xFF7DD3FC),
                  fontSize: 7.8,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // 2C. PASACABLES DE CEPILLO (Brush Cable Manager)
    if (cat == 'cable_manager' || modelLow.contains('brush')) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppPalette.slate900,
              AppPalette.slate800,
              Color(0xFF090D16),
            ],
          ),
          borderRadius: BorderRadius.circular(2),
          border: Border.all(color: AppPalette.slate600, width: 1.2),
        ),
        child: Center(
          child: Text(
            'PASACABLES DE CEPILLO 19" • ${mfg.toUpperCase()} HIGH-DENSITY BRUSH STRIP',
            style: const TextStyle(
              color: AppPalette.slate400,
              fontSize: 7.8,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ),
      );
    }

    // 2D. PATCHBOX / PATCH PANEL
    if (cat == 'patchbox' || cat == 'patch_panel') {
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: cat == 'patchbox'
                ? [
                    AppPalette.slate800.withValues(alpha: 0.88),
                    AppPalette.slate900.withValues(alpha: 0.92),
                  ]
                : [
                    AppPalette.slate700.withValues(alpha: 0.82),
                    AppPalette.slate800.withValues(alpha: 0.86),
                  ],
          ),
          borderRadius: BorderRadius.circular(2),
          border: Border(
            left: BorderSide(color: brandAccent, width: 4),
          ),
        ),
      );
    }

    // 2E. SWITCHES, ROUTERS, FIREWALLS, GATEWAYS Y RESTO DE EQUIPOS DE RED
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppPalette.slate800.withValues(alpha: 0.78),
            AppPalette.slate900.withValues(alpha: 0.84),
          ],
        ),
        borderRadius: BorderRadius.circular(2),
        border: Border(
          left: BorderSide(color: brandAccent, width: 4.5),
          bottom: BorderSide(
            color: brandAccent.withValues(alpha: 0.55),
            width: 1.0,
          ),
        ),
      ),
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
            decoration: BoxDecoration(
              color: AppPalette.slate900.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: brandAccent, width: 0.9),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 4.5,
                  height: 4.5,
                  decoration: const BoxDecoration(
                    color: Color(0xFF22C55E),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 3),
                Text(
                  mfg.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 7.2,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceMountingEar(
    int uHeight, {
    bool isLeft = true,
    String? verticalCode,
    Color? statusColor,
    bool isActiveTarget = false,
  }) {
    final hasVerticalCode =
        isLeft && verticalCode != null && verticalCode.trim().isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: isActiveTarget
            ? AppPalette.sky200
            : const Color(0xFFDDE3EC),
        border: Border.symmetric(
          vertical: BorderSide(
            color: isActiveTarget
                ? AppPalette.sky600
                : const Color(0xFFB4BFCE),
            width: isActiveTarget ? 1.1 : 0.9,
          ),
        ),
      ),
      child: hasVerticalCode
          ? Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const SizedBox(height: 1.5),
                Container(
                  width: 3.6,
                  height: 3.6,
                  decoration: BoxDecoration(
                    color: AppPalette.slate50,
                    border: Border.all(
                      color: AppPalette.slate500,
                      width: 0.75,
                    ),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (statusColor != null) ...[
                            Container(
                              width: 4.2,
                              height: 4.2,
                              decoration: BoxDecoration(
                                color: statusColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 1.5),
                          ],
                          Text(
                            verticalCode.trim(),
                            style: const TextStyle(
                              fontSize: 7.4,
                              fontWeight: FontWeight.w900,
                              color: AppPalette.slate900,
                              letterSpacing: 0.1,
                              height: 1.0,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Container(
                  width: 3.6,
                  height: 3.6,
                  decoration: BoxDecoration(
                    color: AppPalette.slate50,
                    border: Border.all(
                      color: AppPalette.slate500,
                      width: 0.75,
                    ),
                  ),
                ),
                const SizedBox(height: 1.5),
              ],
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (int i = 0; i < uHeight * 3; i++)
                  Align(
                    alignment: isLeft
                        ? Alignment.centerLeft
                        : Alignment.centerRight,
                    child: Container(
                      margin: EdgeInsets.only(
                        left: isLeft ? 3.5 : 0,
                        right: isLeft ? 0 : 3.5,
                      ),
                      width: 4.2,
                      height: 4.2,
                      decoration: BoxDecoration(
                        color: AppPalette.slate50,
                        border: Border.all(
                          color: AppPalette.slate500,
                          width: 0.85,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  /// Dibuja cada puerto con geometría CAD técnica:
  /// - Conector RJ45 ("ETS" 8P8C escalonado con pestaña y pines de contacto superiores)
  /// - Casetes verticales PATCHBOX (24 módulos en 1 fila con clip superior, número 1..24 y boca RJ45 inferior)
  /// - Jaulas de Fibra SFP/SFP+ (rectángulo blanco con doble ranura horizontal de transceptor `[=]`)
  /// - Acopladores de Fibra LC/SC en bandejas FI-01 (cuadrado blanco hueco libre y doble marco azul con núcleo `[▣]` conectado)
  /// - Tomas eléctricas Schuko / IEC / Conector Macho IN
  Widget _buildPortWidget({
    required RackDeviceModel dev,
    required PortModel port,
    required String face,
    required double devHeight,
    required Color? connectedColor,
  }) {
    final isPendingSource = _pendingSourcePort?.id == port.id;
    final isConnected = connectedColor != null;
    final cat = dev.template.category;
    final isMalePlug = port.portType == 'power_plug_male' ||
        (cat == 'pdu' &&
            (port.portNumber.startsWith('IN') ||
                port.portNumber.startsWith('MACHO')));
    final isSchuko = port.portType == 'power_schuko' && !isMalePlug;
    final isPower = port.portType.contains('power') || isMalePlug;
    final isPatchboxCassette = cat == 'patchbox' && face == 'front';
    final isSfpCage =
        port.portType == 'sfp_plus' || port.portNumber.startsWith('SFP');
    final isFiberCoupler =
        !isSfpCage &&
        (port.portType == 'fiber_lc' ||
            port.portType == 'fiber_sc' ||
            (cat == 'gateway' && port.portType.contains('fiber')));

    final rx = _computeVisualRelX(dev, port);
    final ry = _computeVisualRelY(dev, port, face);

    final centerX = _RackEditorViewState._railWidth + rx * _RackEditorViewState._rackInnerWidth;
    final centerY = ry * devHeight;

    // Etiqueta corta para mostrar encima/debajo del puerto
    String shortLabel;
    if (isMalePlug) {
      shortLabel = 'MACHO';
    } else if (isSfpCage && cat == 'router') {
      final sfpNum =
          int.tryParse(port.portNumber.replaceAll(RegExp(r'[^0-9]'), '')) ?? 1;
      shortLabel = '${8 + sfpNum}'; // En RT01 las 4 jaulas SFP se numeran 9..12
    } else if (isSfpCage) {
      shortLabel = port.portNumber.replaceFirst(RegExp(r'^SFP\+?'), '');
    } else {
      shortLabel = port.portNumber.replaceFirst(RegExp(r'^(KR-|R-|F)'), '');
    }

    // 1. Caso especial: Casete vertical PATCHBOX (24 módulos en 1 sola fila ocupando el alto de 1U)
    if (isPatchboxCassette) {
      const cassetteW = 15.6;
      final cassetteH = (devHeight - 4.0).clamp(26.0, 34.0);
      final activeColor = isPendingSource
          ? AppPalette.emerald500
          : (connectedColor ?? AppPalette.slate900);
      return Positioned(
        left: centerX - cassetteW / 2,
        top: (devHeight - cassetteH) / 2,
        width: cassetteW,
        height: cassetteH,
        child: Tooltip(
          message:
              '${dev.code} • Casete PATCHBOX ${port.portNumber} (${port.portType.toUpperCase()})\n${isConnected ? 'Conectado (Clic para ver cable)' : 'Libre (Clic para tirar cable)'}',
          child: InkWell(
            onTap: () => _handlePortTap(dev, port),
            child: CustomPaint(
              size: Size(cassetteW, cassetteH),
              painter: _TechnicalPortPainter(
                kind: _TechPortKind.patchboxCassette,
                isConnected: isConnected,
                isPending: isPendingSource,
                color: activeColor,
                borderColor: isPendingSource
                    ? Colors.amber
                    : (connectedColor ?? AppPalette.slate500),
                label: shortLabel,
              ),
            ),
          ),
        ),
      );
    }

    final facePorts = dev.portsForFace(face);
    final isDenseFace = facePorts.length > 28;
    final jackW = isMalePlug
        ? 22.0
        : (isSchuko
            ? 16.0
            : (isPower
                ? 15.0
                : (isDenseFace
                    ? (isSfpCage ? 10.2 : 9.6)
                    : (isSfpCage ? 12.2 : (isFiberCoupler ? 11.0 : 11.2)))));
    final hasTwoRows = !isPatchboxCassette &&
        facePorts.any((p) => _isPortBottomRow(dev, p, face));
    final labelBelow = hasTwoRows && _isPortBottomRow(dev, port, face);

    final jackH = isMalePlug
        ? 15.0
        : (isSchuko
            ? 14.0
            : (isPower
                ? 11.0
                : (isDenseFace
                    ? 7.6
                    : (hasTwoRows
                        ? 8.2
                        : (isSfpCage ? 9.0 : (isFiberCoupler ? 9.2 : 9.0))))));

    Color jackFill;
    Color jackBorder;
    if (isPendingSource) {
      jackFill = AppPalette.emerald500;
      jackBorder = Colors.amber;
    } else if (isConnected) {
      jackFill = (isFiberCoupler || isSfpCage) ? Colors.white : connectedColor;
      jackBorder = connectedColor;
    } else if (isFiberCoupler || isSfpCage) {
      jackFill = Colors.white;
      jackBorder = AppPalette.slate700;
    } else if (isMalePlug) {
      jackFill = AppPalette.orange600;
      jackBorder = const Color(0xFFFACC15);
    } else if (isPower) {
      jackFill = const Color(0xFF450A0A);
      jackBorder = AppPalette.red800;
    } else {
      jackFill = AppPalette.slate900;
      jackBorder = AppPalette.slate600;
    }

    final halfWidth = isMalePlug ? 16.0 : (isDenseFace ? 8.0 : 10.0);
    final labelFontSize = isMalePlug ? 5.8 : (isDenseFace ? 5.4 : 6.0);
    const labelBandH = 8.0;

    return Positioned(
      left: centerX - halfWidth,
      top: labelBelow
          ? (centerY - jackH / 2)
          : (centerY - jackH / 2 - labelBandH),
      width: halfWidth * 2,
      height: jackH + labelBandH,
      child: Tooltip(
        message: isMalePlug
            ? '${dev.code} • Conector MACHO de Entrada (${port.portNumber})\nConéctalo a las Tomas Eléctricas Exteriores (TOMA-A / TOMA-B)'
            : '${dev.code} • Boca ${port.portNumber} (${port.portType.toUpperCase()} • ${port.face.toUpperCase()})\n${isConnected ? 'Conectado (Clic para ver cable)' : 'Libre (Clic para tirar cable)'}',
        child: InkWell(
          onTap: () => _handlePortTap(dev, port),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment:
                labelBelow ? MainAxisAlignment.start : MainAxisAlignment.end,
            children: [
              if (!labelBelow)
                Text(
                  shortLabel,
                  style: TextStyle(
                    fontSize: labelFontSize,
                    height: 1.0,
                    letterSpacing: isDenseFace ? -0.2 : 0.0,
                    fontWeight: FontWeight.w800,
                    color: isConnected
                        ? connectedColor
                        : (isMalePlug
                            ? const Color(0xFFC2410C)
                            : AppPalette.slate700),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.visible,
                ),
              if (!labelBelow) const SizedBox(height: 1),
              if (isPower)
                Container(
                  width: jackW,
                  height: jackH,
                  decoration: BoxDecoration(
                    color: jackFill,
                    borderRadius: BorderRadius.circular(
                      isMalePlug ? 4 : (isSchuko ? 7 : 1.5),
                    ),
                    border: Border.all(
                      color: jackBorder,
                      width: (isPendingSource || isMalePlug) ? 1.5 : 0.8,
                    ),
                  ),
                  child: isMalePlug
                      ? const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.power,
                              size: 10,
                              color: Colors.white,
                            ),
                            Text(
                              'IN',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 5.5,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        )
                      : Center(
                          child: Text(
                            shortLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 5.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                )
              else
                CustomPaint(
                  size: Size(jackW, jackH),
                  painter: _TechnicalPortPainter(
                    kind: isSfpCage
                        ? _TechPortKind.sfpCage
                        : (isFiberCoupler
                            ? _TechPortKind.fiberCoupler
                            : _TechPortKind.rj45),
                    isConnected: isConnected,
                    isPending: isPendingSource,
                    color: isPendingSource
                        ? AppPalette.emerald500
                        : (connectedColor ?? AppPalette.slate900),
                    borderColor: jackBorder,
                    latchDown: labelBelow,
                  ),
                ),
              if (labelBelow) const SizedBox(height: 1),
              if (labelBelow)
                Text(
                  shortLabel,
                  style: TextStyle(
                    fontSize: labelFontSize,
                    height: 1.0,
                    letterSpacing: isDenseFace ? -0.2 : 0.0,
                    fontWeight: FontWeight.w700,
                    color: isConnected
                        ? connectedColor
                        : AppPalette.slate700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.visible,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
