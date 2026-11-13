part of '../rack_editor_view.dart';

/// Renderizado del lienzo CAD 42U (vista simple y dual Front/Back), barra superior,
/// controles flotantes, cálculo geométrico de bocas y raíles EIA-310 de 19 pulgadas.
extension _RackEditorCanvasSectionExt on _RackEditorViewState {
  /// Construye un armario Rack completo (estructura metálica, raíles 19", regla U, slots vacíos y equipos de esa cara).
  List<Widget> _buildSingleRackCabinetStack({
    required RackDetailModel rack,
    required String face,
    required String faceBannerLabel,
    required Color faceBannerColor,
    required double outerLeft,
    required double innerLeft,
    required Set<int> occupiedUsOnFace,
    required Map<int, Color> connectedPortColors,
    required bool showDropPreview,
  }) {
    return [
      // A0. Etiqueta de Cara del Bastidor (FRONT / BACK)
      Positioned(
        left: outerLeft,
        top: _RackEditorViewState._rackTopMargin - 66,
        width: _RackEditorViewState._rackOuterWidth,
        height: 22,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: faceBannerColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
          ),
          child: Text(
            '${rack.code} — $faceBannerLabel',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ),
      ),

      // A1. Cabezal superior del armario Rack
      Positioned(
        left: outerLeft,
        top: _RackEditorViewState._rackTopMargin - 42,
        width: _RackEditorViewState._rackOuterWidth,
        height: 22,
        child: Container(
          decoration: BoxDecoration(
            color: AppPalette.slate50,
            border: Border.all(
              color: AppPalette.slate700,
              width: 1.4,
            ),
          ),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              height: 4,
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: AppPalette.slate700,
                    width: 1.2,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),

      // A1B. Techo técnico superior del Armario (Rittal Top Enclosure Cap encima de U42)
      Positioned(
        left: outerLeft,
        top: _RackEditorViewState._rackTopMargin - 38,
        width: _RackEditorViewState._rackOuterWidth,
        height: 18,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(
              top: const BorderSide(color: AppPalette.slate700, width: 1.3),
              left: const BorderSide(color: AppPalette.slate700, width: 1.3),
              right: const BorderSide(color: AppPalette.slate700, width: 1.3),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 24,
                decoration: const BoxDecoration(
                  border: Border(
                    right: BorderSide(color: AppPalette.slate600, width: 1.1),
                  ),
                ),
              ),
              Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppPalette.slate50,
                    border: Border.all(
                      color: AppPalette.slate500,
                      width: 0.9,
                    ),
                  ),
                ),
              ),
              Container(
                width: 24,
                decoration: const BoxDecoration(
                  border: Border(
                    left: BorderSide(color: AppPalette.slate600, width: 1.1),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),

      // A2. Marco exterior de doble pared del Armario Rack + Canaletas laterales
      Positioned(
        left: outerLeft,
        top: _RackEditorViewState._rackTopMargin - 20,
        width: _RackEditorViewState._rackOuterWidth,
        height: rack.totalUnits * _RackEditorViewState._uHeightPx + 40,
        child: Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(
              color: AppPalette.slate700,
              width: 1.4,
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(
                color: AppPalette.slate600,
                width: 1.15,
              ),
            ),
          ),
        ),
      ),

      // A3. Raíles verticales perforados de 19" con los 3 agujeros cuadrados por cada U
      Positioned(
        left: innerLeft - _RackEditorViewState._railWidth,
        top: _RackEditorViewState._rackTopMargin,
        width: _RackEditorViewState._railWidth,
        height: rack.totalUnits * _RackEditorViewState._uHeightPx,
        child: _buildPerforated19InchRail(rack.totalUnits, isLeft: true),
      ),
      Positioned(
        left: innerLeft + _RackEditorViewState._rackInnerWidth,
        top: _RackEditorViewState._rackTopMargin,
        width: _RackEditorViewState._railWidth,
        height: rack.totalUnits * _RackEditorViewState._uHeightPx,
        child: _buildPerforated19InchRail(rack.totalUnits, isLeft: false),
      ),

      // A4. Línea vertical continua de la regla U a la izquierda del armario
      Positioned(
        left: outerLeft - 18,
        top: _RackEditorViewState._rackTopMargin,
        width: 1.5,
        height: rack.totalUnits * _RackEditorViewState._uHeightPx,
        child: Container(color: AppPalette.slate600),
      ),

      // B. Regla numerada de Unidades U (42 .. 1) y Slots vacíos
      for (int u = rack.totalUnits; u >= 1; u--) ...[
        Positioned(
          left: outerLeft - 56,
          top: _RackEditorViewState._rackTopMargin + (rack.totalUnits - u) * _RackEditorViewState._uHeightPx,
          width: 44,
          height: _RackEditorViewState._uHeightPx,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                right: 2,
                top: 0,
                child: Container(
                  width: 6,
                  height: 1.3,
                  color: AppPalette.slate600,
                ),
              ),
              if (u == 1)
                Positioned(
                  right: 2,
                  bottom: 0,
                  child: Container(
                    width: 6,
                    height: 1.3,
                    color: AppPalette.slate600,
                  ),
                ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Text(
                    '$u',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: AppPalette.slate700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        if (!occupiedUsOnFace.contains(u))
          Positioned(
            left: innerLeft,
            top: _RackEditorViewState._rackTopMargin + (rack.totalUnits - u) * _RackEditorViewState._uHeightPx,
            width: _RackEditorViewState._rackInnerWidth,
            height: _RackEditorViewState._uHeightPx,
            child: DragTarget<Object>(
              onWillAcceptWithDetails: (details) {
                if (!_canEdit) return false;
                if (details.data is! DeviceTemplateModel &&
                    details.data is! RackDeviceModel) {
                  return false;
                }
                if (_hoveredDropU != u || _draggingData != details.data) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      _rebuildState(() {
                        _draggingData = details.data;
                        _hoveredDropU = u;
                      });
                    }
                  });
                }
                return true;
              },
              onLeave: (_) {
                if (_hoveredDropU == u) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _hoveredDropU == u) {
                      _rebuildState(() => _hoveredDropU = null);
                    }
                  });
                }
              },
              onAcceptWithDetails: (details) {
                _handleDropOnUSlot(details.data, u);
              },
              builder: (ctx, candidate, _) {
                final isHovering = candidate.isNotEmpty;
                return Tooltip(
                  message: _selectedTemplateForClick != null
                      ? 'Clic para instalar "${_selectedTemplateForClick!.modelName}" en U$u (${face.toUpperCase()})'
                      : 'Clic en "+" para elegir Grupo y Dispositivo a instalar en U$u (${face.toUpperCase()})',
                  child: InkWell(
                    onTap: _canEdit
                        ? () {
                            if (_selectedTemplateForClick != null) {
                              _handleDropOrMountTemplate(
                                _selectedTemplateForClick!,
                                u,
                                targetFace: face,
                              );
                            } else {
                              _showQuickInstallAtUDialog(u, face);
                            }
                          }
                        : null,
                    child: Container(
                    decoration: BoxDecoration(
                      color: isHovering
                          ? AppPalette.blue100
                          : Colors.transparent,
                      border: Border(
                        bottom: BorderSide(
                          color: AppPalette.slate200
                              .withValues(alpha: 0.55),
                          width: 0.7,
                        ),
                      ),
                    ),
                    child: Center(
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isHovering
                                ? AppPalette.blue600
                                : AppPalette.slate500,
                            width: 1.2,
                          ),
                        ),
                        child: Icon(
                          Icons.add,
                          size: 13,
                          color: isHovering
                              ? AppPalette.blue600
                              : AppPalette.slate500,
                        ),
                      ),
                    ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],

      // C. Dispositivos Montados en esta cara (Front o Back)
      for (final dev in rack.devices)
        if (dev.isVisibleOnFace(face))
          _buildMountedDeviceWidget(
            dev: dev,
            face: face,
            innerLeft: innerLeft,
            totalUnits: rack.totalUnits,
            connectedPortColors: connectedPortColors,
          ),

      // C0. Controles rápidos flotantes en pestaña superior exterior (para no tapar nunca las bocas del equipo)
      if (_canEdit && _pendingSourcePort == null && _draggingData == null)
        for (final dev in rack.devices)
          if (dev.isVisibleOnFace(face) &&
              (dev.id == _hoveredDeviceId ||
                  (dev.id == _selectedDeviceId && _hoveredDeviceId == null)))
            _buildDeviceFloatingToolbar(
              dev: dev,
              innerLeft: innerLeft,
              totalUnits: rack.totalUnits,
            ),

      // C1. Previsualización Multi-U en tiempo real al arrastrar un equipo
      if (showDropPreview && _hoveredDropU != null && _draggingData != null)
        Builder(
          builder: (_) {
            final int uH = _draggingData is RackDeviceModel
                ? (_draggingData as RackDeviceModel).uHeight
                : (_draggingData as DeviceTemplateModel).uHeight;
            final int? exId = _draggingData is RackDeviceModel
                ? (_draggingData as RackDeviceModel).id
                : null;
            final int startU = _hoveredDropU!;
            final int endU = startU + uH - 1;
            final bool canFit = _canFitAtU(
              rack,
              startU,
              uH,
              excludeDeviceId: exId,
            );
            final int clampedEndU = endU.clamp(1, rack.totalUnits);
            final double topPx = _RackEditorViewState._rackTopMargin +
                (rack.totalUnits - clampedEndU) * _RackEditorViewState._uHeightPx;
            final double boxH = (clampedEndU - startU + 1) * _RackEditorViewState._uHeightPx;
            final String rangeTxt =
                uH > 1 ? 'U$startU - U$endU ($uH U)' : 'U$startU (1U)';
            return Positioned(
              left: innerLeft,
              top: topPx,
              width: _RackEditorViewState._rackInnerWidth,
              height: boxH,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: (canFit
                            ? AppPalette.green600
                            : AppPalette.red600)
                        .withValues(alpha: 0.22),
                    border: Border.all(
                      color: canFit
                          ? AppPalette.green600
                          : AppPalette.red600,
                      width: 2.2,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: canFit
                            ? AppPalette.green700
                            : AppPalette.red700,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        canFit
                            ? '✓ Soltar en $rangeTxt (${uH}U libres)'
                            : '✕ No cabe en $rangeTxt (necesita ${uH}U libres)',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
    ];
  }

  /// Dibuja el raíl vertical de 19 pulgadas con las 3 perforaciones cuadradas EIA-310 por cada U (idéntico a la imagen).
  /// Controles flotantes superpuestos al lienzo (zoom, caras, filtros de cable).
  Widget _buildControlesFlotantes() {
    return Positioned(
        top: 14,
        left: 14,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: AppPalette.slate300),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x0D000000),
                    blurRadius: 6,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.zoom_in, size: 18),
                    tooltip: 'Acercar',
                    onPressed: () {
                      final m =
                          _transformController.value.clone();
                      m.scaleByDouble(1.2, 1.2, 1.0, 1.0);
                      _transformController.value = m;
                    },
                  ),
                  const Divider(height: 1),
                  IconButton(
                    icon: const Icon(Icons.zoom_out, size: 18),
                    tooltip: 'Alejar',
                    onPressed: () {
                      final m =
                          _transformController.value.clone();
                      m.scaleByDouble(
                        1 / 1.2,
                        1 / 1.2,
                        1.0,
                        1.0,
                      );
                      _transformController.value = m;
                    },
                  ),
                  const Divider(height: 1),
                  IconButton(
                    icon: const Icon(
                      Icons.crop_free_rounded,
                      size: 17,
                    ),
                    tooltip: 'Restablecer vista 100%',
                    onPressed: () {
                      _transformController.value =
                          Matrix4.identity();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),

            // Conmutador [Front | Back | Front & Back]
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
                border:
                    Border.all(color: AppPalette.slate300),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _FaceToggleButton(
                    label: 'Front',
                    active: _activeFace == 'front',
                    onTap: () => _setFaceMode('front'),
                  ),
                  _FaceToggleButton(
                    label: 'Back',
                    active: _activeFace == 'back',
                    onTap: () => _setFaceMode('back'),
                  ),
                  _FaceToggleButton(
                    label: 'Front & Back',
                    active: _activeFace == 'both',
                    onTap: () => _setFaceMode('both'),
                  ),
                ],
              ),
            ),

            const SizedBox(width: 10),

            // Conmutador de Foto Real / Bisel de Equipos ON / OFF
            InkWell(
              onTap: () => _rebuildState(
                () => _showEquipmentPhotos =
                    !_showEquipmentPhotos,
              ),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: _showEquipmentPhotos
                      ? AppPalette.slate900
                      : Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: _showEquipmentPhotos
                        ? AppPalette.sky400
                        : AppPalette.slate300,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _showEquipmentPhotos
                          ? Icons.photo_camera
                          : Icons.photo_camera_outlined,
                      size: 14,
                      color: _showEquipmentPhotos
                          ? AppPalette.sky400
                          : AppPalette.slate600,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _showEquipmentPhotos
                          ? 'Foto Equipos: ON'
                          : 'Foto Equipos: OFF',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: _showEquipmentPhotos
                            ? Colors.white
                            : AppPalette.slate600,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(width: 10),

            // Filtro rápido por Tipo de Cable
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 3,
              ),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
                border:
                    Border.all(color: AppPalette.slate300),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _FilterChipBtn(
                    label: 'Todos',
                    color: AppPalette.slate900,
                    active: _cableFilter == 'all',
                    onTap: () =>
                        _rebuildState(() => _cableFilter = 'all'),
                  ),
                  _FilterChipBtn(
                    label: 'Red UTP',
                    color: AppPalette.blue600,
                    active: _cableFilter == 'network',
                    onTap: () => _rebuildState(
                      () => _cableFilter = 'network',
                    ),
                  ),
                  _FilterChipBtn(
                    label: 'Fibra',
                    color: AppPalette.amber500,
                    active: _cableFilter == 'fiber',
                    onTap: () =>
                        _rebuildState(() => _cableFilter = 'fiber'),
                  ),
                  _FilterChipBtn(
                    label: 'Electricidad',
                    color: AppPalette.red600,
                    active: _cableFilter == 'power',
                    onTap: () =>
                        _rebuildState(() => _cableFilter = 'power'),
                  ),
                ],
              ),
            ),

            const SizedBox(width: 8),

            // Conmutador Modo Mano (Barra Espaciadora)
            Tooltip(
              message:
                  'Mantén pulsada la Barra Espaciadora (o activa este botón) para convertir el ratón en una mano y mover el dashboard',
              child: InkWell(
                onTap: () => _rebuildState(
                  () => _isHandToolPinned = !_isHandToolPinned,
                ),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: _isPanHandMode
                        ? AppPalette.slate900
                        : Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _isPanHandMode
                          ? AppPalette.sky400
                          : AppPalette.slate300,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.pan_tool_alt_rounded,
                        size: 14,
                        color: _isPanHandMode
                            ? AppPalette.sky400
                            : AppPalette.slate600,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _isPanHandMode
                            ? 'Mano: ACTIVA'
                            : 'Mano (Espacio)',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: _isPanHandMode
                              ? Colors.white
                              : AppPalette.slate600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            if (_canEdit) ...[
              const SizedBox(width: 8),
              // Botón Deshacer (Ctrl+Z en Windows/Linux o Cmd+Z en Mac)
              Tooltip(
                message:
                    'Deshacer último movimiento de equipo en el Rack (Ctrl+Z / ⌘Z)',
                child: InkWell(
                  onTap:
                      _undoStack.isEmpty ? null : _performUndo,
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: _undoStack.isNotEmpty
                          ? Colors.white
                          : AppPalette.slate50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: AppPalette.slate300,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.undo_rounded,
                          size: 14,
                          color: _undoStack.isNotEmpty
                              ? AppPalette.slate900
                              : AppPalette.slate400,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _undoStack.isEmpty
                              ? 'Deshacer (⌘Z)'
                              : 'Deshacer (${_undoStack.length})',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: _undoStack.isNotEmpty
                                ? AppPalette.slate900
                                : AppPalette.slate400,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
  }

  /// Lienzo con los bastidores 19", alzado delantero y trasero, y el cableado.
  Widget _buildBastidoresInteractivos(RackDetailModel rack, List<RackDeviceModel> extOutlets, double totalCanvasHeight, List<ComputedCableRoute> computedRoutes, Offset? activeSourceOffset, Map<int, Color> connectedPortColors, Set<int> occupiedUsFront, Set<int> occupiedUsBack, List<ConnectionModel> outboundConnections) {
    return InteractiveViewer(
        transformationController: _transformController,
        minScale: 0.38,
        maxScale: 2.8,
        boundaryMargin: const EdgeInsets.all(320),
        constrained: false,
        child: MouseRegion(
          onHover: (event) {
            if (_pendingSourcePort != null) {
              _rebuildState(
                () => _cursorCanvasPos = event.localPosition,
              );
              return;
            }
            int? hitId;
            double bestDist = 7.0;
            for (final r in computedRoutes) {
              final d =
                  CableGeometryBuilder.distanceToPolyline(
                event.localPosition,
                r.points,
              );
              if (d < bestDist) {
                bestDist = d;
                hitId = r.connection.id;
              }
            }
            if (hitId != _hoveredConnectionId) {
              _rebuildState(() => _hoveredConnectionId = hitId);
            }
          },
          child: GestureDetector(
            onSecondaryTap: () {
              if (_pendingSourcePort != null) {
                _rebuildState(() {
                  _pendingSourcePort = null;
                  _pendingSourceDevice = null;
                  _cursorCanvasPos = null;
                });
              }
            },
            onTapUp: (details) {
              for (final r in computedRoutes) {
                final d =
                    CableGeometryBuilder.distanceToPolyline(
                  details.localPosition,
                  r.points,
                );
                if (d < 8.0) {
                  _rebuildState(() {
                    _selectedConnectionId = r.connection.id;
                    _selectedDeviceId = null;
                  });
                  return;
                }
              }
            },
            child: SizedBox(
              width: _effectiveCanvasWidth,
              height: totalCanvasHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (_isDualFace) ...[
                    // BASTIDOR 1 (IZQUIERDA): ALZADO DELANTERO (FRONT)
                    ..._buildSingleRackCabinetStack(
                      rack: rack,
                      face: 'front',
                      faceBannerLabel: 'FRONT (DELANTE)',
                      faceBannerColor: AppPalette.slate900,
                      outerLeft: _RackEditorViewState._rackOuterLeft,
                      innerLeft: _RackEditorViewState._rackInnerLeft,
                      occupiedUsOnFace: occupiedUsFront,
                      connectedPortColors: connectedPortColors,
                      showDropPreview: true,
                    ),

                    // PASAMUROS CENTRAL FRONT ↔ BACK
                    Positioned(
                      left:
                          _RackEditorViewState._rackOuterLeft + _RackEditorViewState._rackOuterWidth + 28,
                      top: _RackEditorViewState._rackTopMargin - 42,
                      width: _RackEditorViewState._dualFaceGap - 56,
                      height:
                          rack.totalUnits * _RackEditorViewState._uHeightPx + 62,
                      child: IgnorePointer(
                        child: Column(
                          children: [
                            Container(
                              padding:
                                  const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: AppPalette.slate800,
                                borderRadius:
                                    BorderRadius.circular(12),
                                border: Border.all(
                                  color:
                                      AppPalette.sky400,
                                ),
                              ),
                              child: const Text(
                                '⇄ PASAMUROS F↔B',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Container(
                                width: 2,
                                margin:
                                    const EdgeInsets.symmetric(
                                  vertical: 6,
                                ),
                                color: AppPalette.slate300,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // BASTIDOR 2 (DERECHA): ALZADO TRASERO (BACK)
                    ..._buildSingleRackCabinetStack(
                      rack: rack,
                      face: 'back',
                      faceBannerLabel: 'BACK (DETRÁS)',
                      faceBannerColor: AppPalette.blue900,
                      outerLeft: _RackEditorViewState._backRackOuterLeft,
                      innerLeft: _RackEditorViewState._backRackInnerLeft,
                      occupiedUsOnFace: occupiedUsBack,
                      connectedPortColors: connectedPortColors,
                      showDropPreview: false,
                    ),
                  ] else ...[
                    // MODO INDIVIDUAL (SOLO FRONT O SOLO BACK)
                    ..._buildSingleRackCabinetStack(
                      rack: rack,
                      face: _activeFace,
                      faceBannerLabel: _activeFace == 'front'
                          ? 'FRONT (DELANTE)'
                          : 'BACK (DETRÁS)',
                      faceBannerColor: _activeFace == 'front'
                          ? AppPalette.slate900
                          : AppPalette.blue900,
                      outerLeft: _RackEditorViewState._rackOuterLeft,
                      innerLeft: _RackEditorViewState._rackInnerLeft,
                      occupiedUsOnFace: _activeFace == 'front'
                          ? occupiedUsFront
                          : occupiedUsBack,
                      connectedPortColors: connectedPortColors,
                      showDropPreview: true,
                    ),
                  ],

                  // C2. TOMAS ELÉCTRICAS EXTERIORES Y CAJAS EXTERIORES DE FIBRA
                  _buildExternalPowerOutletsZone(
                    extOutlets: extOutlets,
                    connectedPortColors: connectedPortColors,
                  ),

                  // D. Capa de Cables Ortogonales (Intra-Rack, Front↔Back e Inter-Rack)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: RackCablePainter(
                          routes: computedRoutes,
                          selectedConnectionId:
                              _selectedConnectionId,
                          hoveredConnectionId:
                              _hoveredConnectionId,
                          activeSourcePortOffset:
                              activeSourceOffset,
                          cursorPosition: _cursorCanvasPos,
                        ),
                      ),
                    ),
                  ),

                  // D2. OPCIÓN 3: BANDEROLAS "CROSS-CONNECT" CLICABLES EN EL LATERAL DEL RACK
                  ...computedRoutes
                      .where(
                        (r) =>
                            r.isOutbound &&
                            r.badgePosition != null,
                      )
                      .map((r) {
                    final c = r.connection;
                    final isSrcHere =
                        c.sourceInfo.rackId == rack.id;
                    final localEnd = isSrcHere
                        ? c.sourceInfo
                        : c.targetInfo;
                    final remoteEnd = isSrcHere
                        ? c.targetInfo
                        : c.sourceInfo;
                    final cCol =
                        CableGeometryBuilder.parseHexColor(
                      c.colorHex,
                    );
                    final isSel =
                        _selectedConnectionId == c.id;
                    final isHov =
                        _hoveredConnectionId == c.id;
                    final pin = r.badgePosition!;
                    return Positioned(
                      left: pin.dx + 4,
                      top: pin.dy - 12,
                      child: MouseRegion(
                        onEnter: (_) => _rebuildState(
                          () => _hoveredConnectionId = c.id,
                        ),
                        onExit: (_) {
                          if (_hoveredConnectionId == c.id) {
                            _rebuildState(
                              () => _hoveredConnectionId = null,
                            );
                          }
                        },
                        child: GestureDetector(
                          onTap: () {
                            _rebuildState(() {
                              _selectedConnectionId = c.id;
                              _selectedDeviceId = null;
                            });
                          },
                          onDoubleTap: () {
                            if (widget.onJumpToRackAndDevice !=
                                null) {
                              widget.onJumpToRackAndDevice!(
                                remoteEnd.rackId,
                                remoteEnd.deviceId,
                              );
                            } else {
                              widget.onSwitchRack(
                                remoteEnd.rackId,
                              );
                            }
                          },
                          child: Tooltip(
                            message:
                                'BANDEROLA CROSS-CONNECT INTER-RACK\n'
                                '• Origen local: ${localEnd.deviceCode}:${localEnd.portNumber} (${localEnd.face.toUpperCase()})\n'
                                '• Destino remoto: ${remoteEnd.rackCode} • ${remoteEnd.deviceCode}:${remoteEnd.portNumber}\n'
                                '• 1 Clic: Seleccionar cable y ver propiedades\n'
                                '• Doble Clic o botón ↗: Saltar a ${remoteEnd.rackCode} resaltando ${remoteEnd.deviceCode}',
                            child: AnimatedContainer(
                              duration: const Duration(
                                milliseconds: 140,
                              ),
                              padding:
                                  const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3.5,
                              ),
                              decoration: BoxDecoration(
                                color: isSel
                                    ? cCol
                                    : (isHov
                                        ? const Color(
                                            0xFF1E293B,
                                          )
                                        : const Color(
                                            0xFF0F172A,
                                          )),
                                borderRadius:
                                    const BorderRadius.only(
                                  topLeft: Radius.circular(3),
                                  bottomLeft:
                                      Radius.circular(3),
                                  topRight:
                                      Radius.circular(12),
                                  bottomRight:
                                      Radius.circular(12),
                                ),
                                border: Border.all(
                                  color: isSel || isHov
                                      ? Colors.white
                                      : cCol,
                                  width:
                                      isSel || isHov ? 1.8 : 1.4,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: cCol.withValues(
                                      alpha: isSel || isHov
                                          ? 0.48
                                          : 0.25,
                                    ),
                                    blurRadius:
                                        isSel || isHov ? 8 : 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(
                                      color: isSel
                                          ? Colors.white
                                          : cCol,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  const Icon(
                                    Icons.label_important,
                                    size: 11,
                                    color: AppPalette.sky400,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    '➔ ${remoteEnd.rackCode} • ${remoteEnd.deviceCode}:${remoteEnd.portNumber}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 9.2,
                                      fontWeight:
                                          FontWeight.w800,
                                      letterSpacing: 0.1,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  InkWell(
                                    onTap: () {
                                      if (widget
                                              .onJumpToRackAndDevice !=
                                          null) {
                                        widget
                                            .onJumpToRackAndDevice!(
                                          remoteEnd.rackId,
                                          remoteEnd.deviceId,
                                        );
                                      } else {
                                        widget.onSwitchRack(
                                          remoteEnd.rackId,
                                        );
                                      }
                                    },
                                    child: Container(
                                      padding:
                                          const EdgeInsets.all(
                                        2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white
                                            .withValues(
                                          alpha: 0.16,
                                        ),
                                        borderRadius:
                                            BorderRadius
                                                .circular(4),
                                      ),
                                      child: const Icon(
                                        Icons.open_in_new,
                                        size: 10,
                                        color:
                                            AppPalette.sky400,
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
                  }),

                  // D3. BANDEROLA CROSS-CONNECT FLOTANTE DE CONEXIÓN RÁPIDA CUANDO HAY UN PUERTO ORIGEN SELECCIONADO
                  if (_pendingSourcePort != null &&
                      activeSourceOffset != null)
                    Builder(
                      builder: (_) {
                        final srcPort = _pendingSourcePort!;
                        RackDeviceModel? srcDev;
                        for (final d in rack.devices) {
                          if (d.ports.any(
                            (p) => p.id == srcPort.id,
                          )) {
                            srcDev = d;
                            break;
                          }
                        }
                        final isBack =
                            (srcPort.face).toLowerCase() ==
                                'back';
                        final flagLeft = (_isDualFace && isBack)
                            ? (_RackEditorViewState._backRackOuterLeft +
                                _RackEditorViewState._rackOuterWidth +
                                12)
                            : (_RackEditorViewState._rackOuterLeft +
                                _RackEditorViewState._rackOuterWidth +
                                12);
                        return Positioned(
                          left: flagLeft,
                          top: activeSourceOffset.dy - 14,
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () {
                                final dev = srcDev;
                                final port = srcPort;
                                _rebuildState(() {
                                  _pendingSourcePort = null;
                                });
                                _showInterRackConnectionDialog(
                                  initialSourceDev: dev,
                                  initialSourcePort: port,
                                );
                              },
                              borderRadius:
                                  BorderRadius.circular(14),
                              child: Container(
                                padding:
                                    const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  gradient:
                                      const LinearGradient(
                                    colors: [
                                      AppPalette.sky600,
                                      AppPalette.blue600,
                                    ],
                                  ),
                                  borderRadius:
                                      const BorderRadius.only(
                                    topLeft: Radius.circular(4),
                                    bottomLeft:
                                        Radius.circular(4),
                                    topRight:
                                        Radius.circular(14),
                                    bottomRight:
                                        Radius.circular(14),
                                  ),
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 1.5,
                                  ),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Color(0x550284C7),
                                      blurRadius: 10,
                                      offset: Offset(0, 3),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize:
                                      MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.label_important,
                                      size: 13,
                                      color: Colors.white,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      '🏷️ ➔ Conectar ${srcDev?.code ?? ''}:${srcPort.portNumber} a Otro Rack...',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight:
                                            FontWeight.w900,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),

                  // E. BANDEJA AÉREA INTER-RACK SUPERIOR CON PÍLDORAS INTERACTIVAS DE SALTO A OTROS RACKS
                  Positioned(
                    left: _RackEditorViewState._rackOuterLeft,
                    top: 4,
                    width: _isDualFace
                        ? (_RackEditorViewState._backRackOuterLeft +
                            _RackEditorViewState._rackOuterWidth -
                            _RackEditorViewState._rackOuterLeft)
                        : _RackEditorViewState._rackOuterWidth,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: AppPalette.slate900,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: outboundConnections.isNotEmpty
                              ? AppPalette.emerald500
                              : AppPalette.slate600,
                          width: 1.5,
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x22000000),
                            blurRadius: 8,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.compare_arrows_rounded,
                            size: 16,
                            color: AppPalette.sky400,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'BANDEJA AÉREA INTER-RACK (${outboundConnections.length} fibras/cables hacia otros Racks):',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: outboundConnections.isEmpty
                                ? const Text(
                                    'Ningún cable sale a otro Rack aún. Pulsa "+ Conectar con Otro Rack" para enlazar fibras/cables entre Racks.',
                                    style: TextStyle(
                                      color: AppPalette.slate400,
                                      fontSize: 10,
                                    ),
                                    overflow:
                                        TextOverflow.ellipsis,
                                  )
                                : SingleChildScrollView(
                                    scrollDirection:
                                        Axis.horizontal,
                                    child: Row(
                                      children:
                                          outboundConnections
                                              .map((c) {
                                        final isSrcHere = c
                                                .sourceInfo
                                                .rackId ==
                                            rack.id;
                                        final localEnd =
                                            isSrcHere
                                                ? c.sourceInfo
                                                : c.targetInfo;
                                        final remoteEnd =
                                            isSrcHere
                                                ? c.targetInfo
                                                : c.sourceInfo;
                                        final cCol =
                                            CableGeometryBuilder
                                                .parseHexColor(
                                          c.colorHex,
                                        );
                                        final isSel =
                                            _selectedConnectionId ==
                                                c.id;
                                        return Padding(
                                          padding:
                                              const EdgeInsets
                                                  .only(
                                            right: 6,
                                          ),
                                          child: InkWell(
                                            onTap: () {
                                              _rebuildState(() {
                                                _selectedConnectionId =
                                                    c.id;
                                                _selectedDeviceId =
                                                    null;
                                              });
                                            },
                                            onDoubleTap: () {
                                              if (widget
                                                      .onJumpToRackAndDevice !=
                                                  null) {
                                                widget
                                                    .onJumpToRackAndDevice!(
                                                  remoteEnd
                                                      .rackId,
                                                  remoteEnd
                                                      .deviceId,
                                                );
                                              } else {
                                                widget
                                                    .onSwitchRack(
                                                  remoteEnd
                                                      .rackId,
                                                );
                                              }
                                            },
                                            child: Tooltip(
                                              message:
                                                  'Clic: Resaltar cable (${localEnd.deviceCode}:${localEnd.portNumber} ➔ ${remoteEnd.rackCode} ${remoteEnd.deviceCode}:${remoteEnd.portNumber})\nDoble Clic o icono ↗: Abrir ${remoteEnd.rackCode} en el Rack Editor',
                                              child: Container(
                                                padding:
                                                    const EdgeInsets
                                                        .symmetric(
                                                  horizontal: 8,
                                                  vertical: 3,
                                                ),
                                                decoration:
                                                    BoxDecoration(
                                                  color: isSel
                                                      ? cCol
                                                      : const Color(
                                                          0xFF1E293B,
                                                        ),
                                                  borderRadius:
                                                      BorderRadius
                                                          .circular(
                                                    14,
                                                  ),
                                                  border:
                                                      Border.all(
                                                    color: cCol,
                                                    width: 1.5,
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize
                                                          .min,
                                                  children: [
                                                    Container(
                                                      width: 7,
                                                      height: 7,
                                                      decoration:
                                                          BoxDecoration(
                                                        color: isSel
                                                            ? Colors.white
                                                            : cCol,
                                                        shape: BoxShape
                                                            .circle,
                                                      ),
                                                    ),
                                                    const SizedBox(
                                                      width: 5,
                                                    ),
                                                    Text(
                                                      '${localEnd.deviceCode}:${localEnd.portNumber} ⇢ ${remoteEnd.rackCode} (${remoteEnd.deviceCode}:${remoteEnd.portNumber})',
                                                      style:
                                                          const TextStyle(
                                                        color: Colors
                                                            .white,
                                                        fontSize:
                                                            9.8,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                    const SizedBox(
                                                      width: 5,
                                                    ),
                                                    InkWell(
                                                      onTap: () {
                                                        if (widget.onJumpToRackAndDevice !=
                                                            null) {
                                                          widget.onJumpToRackAndDevice!(
                                                            remoteEnd.rackId,
                                                            remoteEnd.deviceId,
                                                          );
                                                        } else {
                                                          widget.onSwitchRack(
                                                            remoteEnd.rackId,
                                                          );
                                                        }
                                                      },
                                                      child:
                                                          const Icon(
                                                        Icons
                                                            .open_in_new,
                                                        size:
                                                            11,
                                                        color: Color(
                                                          0xFF38BDF8,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  ),
                          ),
                          if (_canEdit) ...[
                            const SizedBox(width: 8),
                            InkWell(
                              onTap: () =>
                                  _showInterRackConnectionDialog(),
                              child: Container(
                                padding:
                                    const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color:
                                      AppPalette.sky600,
                                  borderRadius:
                                      BorderRadius.circular(6),
                                ),
                                child: const Row(
                                  mainAxisSize:
                                      MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.add_link,
                                      size: 13,
                                      color: Colors.white,
                                    ),
                                    SizedBox(width: 4),
                                    Text(
                                      '+ Conectar con Otro Rack',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight:
                                            FontWeight.w800,
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
                ],
              ),
            ),
          ),
        ),
      );
  }

  /// Barra superior del editor: migas, selección activa y acciones del rack.
  Widget _buildBarraSuperior(RackDetailModel rack, Map<String, dynamic> bc, RackDeviceModel? selDev, ConnectionModel? selConn, int? nextFreeUpU, int? nextFreeDownU) {
    return Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: AppPalette.slate200)),
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: widget.onBackToLocations,
                icon: const Icon(Icons.arrow_back_rounded, size: 20),
                tooltip: 'Volver al Mapa de Sedes y Pasillos',
              ),
              if (widget.onOpenElevationOverview != null) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message:
                      'Volver al Alzado Frontal de todos los Racks y sus conexiones',
                  child: OutlinedButton.icon(
                    onPressed: widget.onOpenElevationOverview,
                    icon: const Icon(Icons.view_column_rounded, size: 16),
                    label: const Text(
                      'Alzado de Racks',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppPalette.blue700,
                      backgroundColor: AppPalette.blue50,
                      side: const BorderSide(color: AppPalette.blue300),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ],
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rack.name,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppPalette.slate900,
                  ),
                ),
                InkWell(
                  onTap: widget.onBackToLocations,
                  child: Text(
                    'PBX  >  Locations  >  ${bc['location_code']}  >  ${bc['room_name']?.toString().split(' ').first ?? '28'}  >  ${rack.code}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppPalette.slate500,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 14),
            // Resumen de Heartbeat en este Rack: Gris (Sin HB), Verde (OK), Naranja (Parcial), Rojo (Caído)
            Builder(
              builder: (_) {
                final physDevs = rack.devices
                    .where((d) => !d.isExternalFeed)
                    .toList();
                final unmonCnt =
                    physDevs.where((d) => !d.monitoringEnabled).length;
                final monDevs =
                    physDevs.where((d) => d.monitoringEnabled).toList();
                final onlineCnt =
                    monDevs.where((d) => d.status == 'online').length;
                final offlineCnt =
                    monDevs.where((d) => d.status == 'offline').length;
                final warnCnt = monDevs.length - onlineCnt - offlineCnt;
                return Tooltip(
                  message:
                      'Heartbeat en este Rack:\n⚪ Gris ($unmonCnt): Heartbeat desactivado\n🟢 Verde ($onlineCnt): Todos los chequeos OK\n🟠 Naranja ($warnCnt): Fallo parcial (1+ chequeo falla)\n🔴 Rojo ($offlineCnt): Todos los chequeos fallan',
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: AppPalette.slate50,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: offlineCnt > 0
                            ? AppPalette.red300
                            : (warnCnt > 0
                                ? const Color(0xFFFDE68A)
                                : AppPalette.slate300),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.monitor_heart_outlined,
                          size: 14,
                          color: AppPalette.slate900,
                        ),
                        const SizedBox(width: 5),
                        const Text(
                          'HB:',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.slate900,
                          ),
                        ),
                        const SizedBox(width: 6),
                        // Gris: Sin Heartbeat
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: AppPalette.slate400,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '$unmonCnt',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.slate500,
                          ),
                        ),
                        const SizedBox(width: 7),
                        // Verde: OK
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: AppPalette.green600,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '$onlineCnt',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.green700,
                          ),
                        ),
                        const SizedBox(width: 7),
                        // Naranja: Fallo parcial
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: AppPalette.amber600,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '$warnCnt',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.amber700,
                          ),
                        ),
                        const SizedBox(width: 7),
                        // Rojo: Fallo total
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: AppPalette.red600,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '$offlineCnt',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.red700,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
            const Spacer(),

            // Selector / Buscador rápido de Equipos o Alarmas en este Rack (con resaltado de fondo gris)
            PopupMenuButton<int>(
              tooltip:
                  'Buscar o localizar un equipo / alarma en este Rack (resaltado con fondo gris)',
              onSelected: (devId) {
                _rebuildState(() {
                  _selectedDeviceId = devId;
                  _highlightedDeviceId = devId;
                });
              },
              itemBuilder: (ctx) {
                final list = rack.devices
                    .where((d) => !d.isExternalFeed)
                    .toList()
                  ..sort((a, b) => b.startU.compareTo(a.startU));
                return list.map((d) {
                  final isAlarm =
                      d.monitoringEnabled && d.status != 'online';
                  return PopupMenuItem<int>(
                    value: d.id,
                    child: Row(
                      children: [
                        Icon(
                          isAlarm
                              ? Icons.warning_amber_rounded
                              : (d.isRackTray
                                  ? Icons.inbox_outlined
                                  : Icons.dns_outlined),
                          size: 16,
                          color: isAlarm
                              ? AppPalette.red600
                              : AppPalette.slate700,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'U${d.startU} • ${d.code} — ${d.name}${d.isRackTray && d.trayItems.isNotEmpty ? ' [${d.trayItems.length} mini-eq]' : ''}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: d.id == _highlightedDeviceId ||
                                      d.id == _selectedDeviceId
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                              color: isAlarm
                                  ? AppPalette.red700
                                  : AppPalette.slate900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList();
              },
              child: Container(
                margin: const EdgeInsets.only(right: 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: _highlightedDeviceId != null
                      ? AppPalette.slate200
                      : AppPalette.slate50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppPalette.slate300),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.search_rounded,
                      size: 15,
                      color: AppPalette.slate700,
                    ),
                    SizedBox(width: 5),
                    Text(
                      'Localizar en Rack',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: AppPalette.slate800,
                      ),
                    ),
                    SizedBox(width: 3),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 16,
                      color: AppPalette.slate600,
                    ),
                  ],
                ),
              ),
            ),

            // Botón directo en Barra Superior para montar un equipo desde la CMDB (igual que en 2. Datacenters)
            if (_canEdit)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1E3A8A),
                    foregroundColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                  onPressed: _openInstallFromCmdbAtFirstFreeU,
                  icon: const Icon(Icons.account_tree_rounded, size: 15),
                  label: const Text(
                    '+ Desde CMDB',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),

            // Conmutador directo en barra superior: [Front | Back | Front & Back]
            Container(
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                color: AppPalette.slate50,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: AppPalette.slate300),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _FaceToggleButton(
                    label: 'Front',
                    active: _activeFace == 'front',
                    onTap: () => _setFaceMode('front'),
                  ),
                  _FaceToggleButton(
                    label: 'Back',
                    active: _activeFace == 'back',
                    onTap: () => _setFaceMode('back'),
                  ),
                  _FaceToggleButton(
                    label: 'Front & Back',
                    active: _activeFace == 'both',
                    onTap: () => _setFaceMode('both'),
                  ),
                ],
              ),
            ),

            // Barra rápida cuando hay un equipo seleccionado: Subir 1U, Bajar 1U, Ajustar U ocupadas, Equipos en Bandeja, Foto, Cable Inter-Rack, Borrar Equipo
            if (_canEdit && selDev != null && !selDev.isExternalFeed)
              Container(
                margin: const EdgeInsets.only(right: 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppPalette.blue50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppPalette.blue300),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${selDev.code} (U${selDev.startU}•${selDev.uHeight}U): ',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.blue900,
                      ),
                    ),
                    IconButton(
                      onPressed: nextFreeUpU != null
                          ? () => _moveDeviceToU(selDev, nextFreeUpU)
                          : null,
                      icon: const Icon(Icons.arrow_upward_rounded, size: 15),
                      tooltip: nextFreeUpU != null
                          ? 'Subir a siguiente posición con ${selDev.uHeight}U libres (U$nextFreeUpU)'
                          : 'No hay ${selDev.uHeight}U libres por encima',
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      onPressed: nextFreeDownU != null
                          ? () => _moveDeviceToU(selDev, nextFreeDownU)
                          : null,
                      icon: const Icon(
                        Icons.arrow_downward_rounded,
                        size: 15,
                      ),
                      tooltip: nextFreeDownU != null
                          ? 'Bajar a siguiente posición con ${selDev.uHeight}U libres (U$nextFreeDownU)'
                          : 'No hay ${selDev.uHeight}U libres por debajo',
                      visualDensity: VisualDensity.compact,
                    ),
                    // Control rápido de cuántas U ocupa (especialmente útil para Bandejas y equipos misceláneos)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppPalette.blue300),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          InkWell(
                            onTap: selDev.uHeight > 1
                                ? () => _quickAdjustDeviceUHeight(
                                      selDev,
                                      selDev.uHeight - 1,
                                    )
                                : null,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 3),
                              child: Icon(
                                Icons.remove,
                                size: 12,
                                color: AppPalette.blue700,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 3,
                            ),
                            child: Text(
                              '${selDev.uHeight}U',
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: AppPalette.blue900,
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: selDev.uHeight < 16
                                ? () => _quickAdjustDeviceUHeight(
                                      selDev,
                                      selDev.uHeight + 1,
                                    )
                                : null,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 3),
                              child: Icon(
                                Icons.add,
                                size: 12,
                                color: AppPalette.blue700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (selDev.isRackTray)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: FilledButton.tonalIcon(
                          onPressed: () =>
                              _showManageTrayItemsDialog(selDev),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFEDE9FE),
                            foregroundColor: const Color(0xFF6D28D9),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 4,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: const Icon(Icons.inbox_outlined, size: 14),
                          label: Text(
                            '+ Equipos en Bandeja (${selDev.trayItems.length})',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    TextButton.icon(
                      onPressed: () =>
                          _showConfigureDevicePortsDialog(selDev),
                      icon: const Icon(
                        Icons.settings_input_component,
                        size: 14,
                      ),
                      label: const Text(
                        'Bocas F/B',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () =>
                          _showHardwarePhotoSearchDialog(device: selDev),
                      icon: const Icon(Icons.photo_camera_outlined, size: 14),
                      label: const Text(
                        'Foto',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _showInterRackConnectionDialog(
                        initialSourceDev: selDev,
                      ),
                      icon: const Icon(Icons.compare_arrows, size: 14),
                      label: const Text(
                        'A Otro Rack',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _showMoveDeviceToUDialog(selDev),
                      icon: const Icon(Icons.swap_vert, size: 14),
                      label: const Text(
                        'Mover a U...',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _quickDeleteDevice(selDev),
                      style: TextButton.styleFrom(
                        foregroundColor: AppPalette.red600,
                      ),
                      icon: const Icon(Icons.delete_outline, size: 15),
                      label: const Text(
                        'Borrar',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Barra rápida cuando hay un cable seleccionado: Borrar Cable en 1 clic
            if (_canEdit && selConn != null)
              Container(
                margin: const EdgeInsets.only(right: 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppPalette.red50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppPalette.red300),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Cable ${selConn.sourceInfo.deviceCode}:${selConn.sourceInfo.portNumber} ➔ ${selConn.targetInfo.deviceCode}:${selConn.targetInfo.portNumber}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppPalette.red800,
                      ),
                    ),
                    const SizedBox(width: 6),
                    TextButton.icon(
                      onPressed: () async {
                        await widget.api.deleteConnection(selConn.id);
                        _rebuildState(() => _selectedConnectionId = null);
                        await _loadRack();
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: AppPalette.red600,
                      ),
                      icon: const Icon(Icons.link_off, size: 15),
                      label: const Text(
                        'Borrar Cable',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            if (_pendingSourcePort != null)
              Container(
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: AppPalette.blue100,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppPalette.blue600),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.cable,
                      size: 15,
                      color: AppPalette.blue700,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Tirando desde ${_pendingSourceDevice?.code}:${_pendingSourcePort?.portNumber} — Clic en boca destino (o pulsa Esc para cancelar)',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppPalette.blue900,
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () {
                        final srcDev = _pendingSourceDevice;
                        final srcPort = _pendingSourcePort;
                        _rebuildState(() {
                          _pendingSourcePort = null;
                          _pendingSourceDevice = null;
                        });
                        _showInterRackConnectionDialog(
                          initialSourceDev: srcDev,
                          initialSourcePort: srcPort,
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppPalette.blue700,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.compare_arrows,
                              size: 12,
                              color: Colors.white,
                            ),
                            SizedBox(width: 4),
                            Text(
                              'Llevar a Otro Rack...',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () => _rebuildState(() {
                        _pendingSourcePort = null;
                        _pendingSourceDevice = null;
                      }),
                      child: const Icon(
                        Icons.close,
                        size: 15,
                        color: AppPalette.blue900,
                      ),
                    ),
                  ],
                ),
              ),
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
              const SizedBox(width: 8),
            ],
            if (_canConnectRemote)
              OutlinedButton.icon(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await widget.api.pingAllRackDevices(rack.id);
                  await _loadRack();
                  if (mounted) {
                    messenger.aviso('Chequeo de Ping completado en todos los equipos del rack.');
                  }
                },
                icon: const Icon(Icons.network_ping, size: 16),
                label:
                    const Text('Ping Rack', style: TextStyle(fontSize: 12)),
              ),
            const SizedBox(width: 8),
            DiagramExportMenuButton(
              buttonLabel: 'Exportar Rack (.dia / .png / .pdf / .xlsx / .csv)',
              documentBuilder: () => _buildRackExportDocument(rack),
              onExportExcel: () {
                final url = Uri.parse(
                  widget.api.getExcelExportUrl(rackId: rack.id),
                );
                launchUrl(url, mode: LaunchMode.externalApplication);
              },
            ),
            if (_canEdit) ...[
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _confirmDeleteCurrentRack,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppPalette.red600,
                  side: const BorderSide(color: AppPalette.red300),
                ),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text(
                  'Eliminar Rack',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      );
  }

  DiagramExportDocument _buildRackExportDocument(RackDetailModel rack) {
    final double unitH = 26.0;
    final double rackTop = 60.0;
    final double rackFrameH = rack.totalUnits * unitH + 28.0;
    final double canvasW = 1480.0;
    final double canvasH = (rackTop + rackFrameH + 140.0).clamp(900.0, 2200.0);

    final zones = <DiagramExportZone>[
      DiagramExportZone(
        id: 'zone_front_${rack.id}',
        title: '${rack.code} — FRONT (Delante)',
        subtitle: '${rack.name} • ${rack.totalUnits}U',
        x: 60,
        y: rackTop,
        width: 420,
        height: rackFrameH,
        colorHex: '#1E293B',
      ),
      DiagramExportZone(
        id: 'zone_back_${rack.id}',
        title: '${rack.code} — BACK (Detrás)',
        subtitle: '${rack.name} • ${rack.totalUnits}U',
        x: 560,
        y: rackTop,
        width: 420,
        height: rackFrameH,
        colorHex: '#1E3A8A',
      ),
      DiagramExportZone(
        id: 'zone_ext_${rack.id}',
        title: 'Acometidas / Planta / Inter-Rack',
        subtitle: 'Equipos externos y enlaces salientes',
        x: 1050,
        y: rackTop,
        width: 370,
        height: rackFrameH,
        colorHex: '#0D9488',
      ),
    ];

    final nodes = <DiagramExportNode>[];
    final addedNodeIds = <String>{};
    int extIndex = 0;

    for (final dev in rack.devices) {
      final nodeId = 'dev_${dev.id}';
      addedNodeIds.add(nodeId);
      final isExt = dev.isExternalFeed;
      final isBack = dev.mountedFace == 'back';
      final double x = isExt ? 1075.0 : (isBack ? 585.0 : 85.0);
      final double y = isExt
          ? (rackTop + 44.0 + (extIndex++ * 92.0))
          : (rackTop + 22.0 + (rack.totalUnits - dev.endU) * unitH);
      final double h = isExt
          ? 74.0
          : (dev.uHeight * unitH - 2.0).clamp(24.0, 260.0);
      final modelStr =
          (dev.customFields['model_name'] ??
                  '${dev.template.manufacturer} ${dev.template.modelName}')
              .toString()
              .trim();
      final uTag = isExt
          ? 'EXT'
          : (dev.uHeight > 1
                ? 'U${dev.startU}-U${dev.endU}'
                : 'U${dev.startU}');

      nodes.add(
        DiagramExportNode(
          id: nodeId,
          code: '${dev.code} [$uTag]',
          name: dev.name,
          subtitle: isExt
              ? dev.feedType.toUpperCase()
              : '${dev.template.category.toUpperCase()} (${dev.mountedFace.toUpperCase()})',
          ip: dev.ipAddress,
          modelName: modelStr,
          serialNumber: dev.serialNumber,
          status: dev.monitoringEnabled ? dev.status : 'unmonitored',
          x: x,
          y: y,
          width: isExt ? 320.0 : 370.0,
          height: h,
          colorHex: isExt
              ? dev.feedColorHex
              : (dev.status == 'offline'
                    ? '#DC2626'
                    : (isBack ? '#1D4ED8' : '#0284C7')),
        ),
      );
    }

    final edges = <DiagramExportEdge>[];
    for (final c in rack.connections) {
      final srcId = 'dev_${c.sourceInfo.deviceId}';
      final dstId = 'dev_${c.targetInfo.deviceId}';

      if (!addedNodeIds.contains(srcId)) {
        addedNodeIds.add(srcId);
        nodes.add(
          DiagramExportNode(
            id: srcId,
            code: '${c.sourceInfo.rackCode}:${c.sourceInfo.deviceCode}',
            name: c.sourceInfo.deviceName,
            subtitle: 'INTER-RACK',
            x: 1075.0,
            y: rackTop + 44.0 + (extIndex++ * 92.0),
            width: 320.0,
            height: 70.0,
            colorHex: '#7C3AED',
          ),
        );
      }
      if (!addedNodeIds.contains(dstId)) {
        addedNodeIds.add(dstId);
        nodes.add(
          DiagramExportNode(
            id: dstId,
            code: '${c.targetInfo.rackCode}:${c.targetInfo.deviceCode}',
            name: c.targetInfo.deviceName,
            subtitle: 'INTER-RACK',
            x: 1075.0,
            y: rackTop + 44.0 + (extIndex++ * 92.0),
            width: 320.0,
            height: 70.0,
            colorHex: '#7C3AED',
          ),
        );
      }

      final vlanSuffix = c.vlan != null ? ' [VLAN ${c.vlan}]' : '';
      edges.add(
        DiagramExportEdge(
          id: 'conn_${c.id}',
          sourceId: srcId,
          targetId: dstId,
          label:
              '${c.sourceInfo.portNumber} ➔ ${c.targetInfo.portNumber}$vlanSuffix',
          detail: c.cableType,
          colorHex: c.colorHex,
          dashed: c.isOutbound,
        ),
      );
    }

    final locCode = (rack.breadcrumb['location_code'] ?? '').toString();
    final floorName = (rack.breadcrumb['floor_name'] ?? '').toString();
    final roomName = (rack.breadcrumb['room_name'] ?? '').toString();

    return DiagramExportDocument(
      moduleName: '3. Rack Editor',
      title: 'Rack ${rack.code} — ${rack.name}',
      subtitle:
          '$locCode > $floorName > $roomName • ${rack.totalUnits}U • ${rack.devices.length} Equipos • ${rack.connections.length} Cables',
      fileBaseName: 'esquema_rack_${rack.code.toLowerCase()}',
      canvasWidth: canvasW,
      canvasHeight: canvasH,
      zones: zones,
      nodes: nodes,
      edges: edges,
    );
  }

  Widget _buildPerforated19InchRail(int totalUnits, {bool isLeft = true}) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFDDE3EC),
        border: Border.symmetric(
          vertical: BorderSide(color: Color(0xFFB8C4D4), width: 0.9),
        ),
      ),
      child: Column(
        children: [
          for (int u = 0; u < totalUnits; u++)
            SizedBox(
              height: _RackEditorViewState._uHeightPx,
              child: Align(
                alignment:
                    isLeft ? Alignment.centerLeft : Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2.5),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (int h = 0; h < 3; h++)
                        Container(
                          width: 3.2,
                          height: 3.2,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border.all(
                              color: AppPalette.slate500,
                              width: 0.8,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ===========================================================================
  // WIDGET DE ZONA EXTERIOR: EQUIPOS DE PLANTA (IMPRESORAS, APs, CÁMARAS, SENSORES) + TOMAS SCHUKO & FIBRA
  // ===========================================================================
  ({IconData icon, Color color, String typeLabel}) _floorDeviceVisualMeta(
    String devType,
  ) {
    final t = devType.toLowerCase();
    if (t == 'printer') {
      return (
        icon: Icons.print_rounded,
        color: AppPalette.indigo600,
        typeLabel: 'Impresora Red',
      );
    }
    if (t == 'camera') {
      return (
        icon: Icons.videocam_rounded,
        color: const Color(0xFFE11D48),
        typeLabel: 'Cámara IP',
      );
    }
    if (t == 'access_control') {
      return (
        icon: Icons.fingerprint_rounded,
        color: AppPalette.orange600,
        typeLabel: 'Control Acceso',
      );
    }
    if (t == 'access_point') {
      return (
        icon: Icons.wifi_rounded,
        color: AppPalette.sky600,
        typeLabel: 'Punto Wi-Fi AP',
      );
    }
    if (t == 'desktop') {
      return (
        icon: Icons.desktop_windows_rounded,
        color: AppPalette.blue600,
        typeLabel: 'Ordenador / PC',
      );
    }
    if (t == 'phone') {
      return (
        icon: Icons.phone_in_talk_rounded,
        color: AppPalette.teal600,
        typeLabel: 'Teléfono VoIP',
      );
    }
    if (t == 'tv_display') {
      return (
        icon: Icons.tv_rounded,
        color: AppPalette.violet600,
        typeLabel: 'Pantalla / TV',
      );
    }
    if (t == 'telecom_outlet') {
      return (
        icon: Icons.settings_ethernet_rounded,
        color: AppPalette.amber600,
        typeLabel: 'Roseta RJ45',
      );
    }
    if (t.contains('temp')) {
      return (
        icon: Icons.thermostat_rounded,
        color: AppPalette.orange600,
        typeLabel: 'Sensor Temp.',
      );
    }
    if (t.contains('hum')) {
      return (
        icon: Icons.water_drop_rounded,
        color: const Color(0xFF0891B2),
        typeLabel: 'Sensor Humedad',
      );
    }
    if (t.contains('power') || t.contains('load')) {
      return (
        icon: Icons.bolt_rounded,
        color: const Color(0xFFCA8A04),
        typeLabel: 'Sensor Carga kW',
      );
    }
    if (t.contains('smoke') || t.contains('fire')) {
      return (
        icon: Icons.local_fire_department_rounded,
        color: AppPalette.red600,
        typeLabel: 'Detector Humo',
      );
    }
    if (t.contains('water') || t.contains('leak')) {
      return (
        icon: Icons.waves_rounded,
        color: AppPalette.blue600,
        typeLabel: 'Sensor Fuga Agua',
      );
    }
    return (
      icon: Icons.sensors_rounded,
      color: AppPalette.teal600,
      typeLabel: 'Equipo / Sensor',
    );
  }

  Future<void> _showQuickAddFloorDeviceFromRackDialog() async {
    if (!_canEdit) return;
    final rack = _rack;
    if (rack == null) return;
    final floorId = rack.breadcrumb['floor_id'] as int?;
    if (floorId == null) return;

    final messenger = ScaffoldMessenger.of(context);
    List<Map<String, dynamic>> cmdbAssets = [];
    try {
      final overview = await widget.api.fetchCmdbOverview();
      cmdbAssets = ((overview['assets'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      cmdbAssets.sort((a, b) {
        final aUnplaced =
            (a['rack_device_id'] == null && a['rack_id'] == null) ? 0 : 1;
        final bUnplaced =
            (b['rack_device_id'] == null && b['rack_id'] == null) ? 0 : 1;
        if (aUnplaced != bUnplaced) return aUnplaced.compareTo(bUnplaced);
        return (a['code'] ?? '')
            .toString()
            .compareTo((b['code'] ?? '').toString());
      });
    } catch (_) {}
    if (!mounted) return;

    String selectedType = 'printer';
    final codeCtrl = TextEditingController(text: 'PR02');
    final nameCtrl = TextEditingController(text: 'Impresora Multifunción Sala');
    final ipCtrl = TextEditingController(text: '10.28.25.55');
    final roomCtrl = TextEditingController(
      text: (rack.breadcrumb['room_name'] ?? 'CPD').toString(),
    );
    int? selectedCmdbAssetId;
    Map<String, dynamic>? selectedCmdbAsset;

    const presets = <({String key, String prefix, String label, String defName})>[
      (
        key: 'printer',
        prefix: 'PR',
        label: '🖨️ Impresora de Red (RJ45)',
        defName: 'Impresora Multifunción LaserJet',
      ),
      (
        key: 'access_point',
        prefix: 'AP',
        label: '📶 Punto de Acceso Wi-Fi (PoE)',
        defName: 'Punto de Acceso Wi-Fi 6E Techo',
      ),
      (
        key: 'camera',
        prefix: 'CAM',
        label: '📹 Cámara CCTV IP (PoE)',
        defName: 'Cámara Domo IP 4K',
      ),
      (
        key: 'access_control',
        prefix: 'AC',
        label: '🔐 Control de Acceso Puerta',
        defName: 'Terminal Biométrico RFID Puerta',
      ),
      (
        key: 'telecom_outlet',
        prefix: 'Bi',
        label: '🔌 Roseta de Red / Pared (RJ45)',
        defName: 'Caja Rosetas Pared Cat6A',
      ),
      (
        key: 'desktop',
        prefix: 'DP',
        label: '💻 Ordenador / Workstation',
        defName: 'Workstation Operador',
      ),
      (
        key: 'phone',
        prefix: 'PH',
        label: '☎️ Teléfono VoIP',
        defName: 'Teléfono IP Sobremesa',
      ),
      (
        key: 'sensor_temp',
        prefix: 'TMP',
        label: '🌡️ Sensor de Temperatura',
        defName: 'Sonda Temperatura Pasillo Frío',
      ),
      (
        key: 'sensor_humidity',
        prefix: 'HUM',
        label: '💧 Sensor de Humedad',
        defName: 'Sensor Humedad Relativa CPD',
      ),
      (
        key: 'sensor_power_load',
        prefix: 'PWR',
        label: '⚡ Sensor Carga Eléctrica (kW/A)',
        defName: 'Analizador Carga Eléctrica Cuadro',
      ),
    ];

    void applyCmdbToFloor(Map<String, dynamic> picked) {
      selectedCmdbAsset = picked;
      selectedCmdbAssetId = (picked['id'] as num?)?.toInt();
      final rawCode = (picked['code'] ?? '').toString().trim();
      if (rawCode.isNotEmpty && !rawCode.startsWith('DISC-')) {
        codeCtrl.text = rawCode;
      }
      final rawName = (picked['name'] ?? '').toString().trim();
      if (rawName.isNotEmpty && !rawName.startsWith('Equipo Detectado')) {
        nameCtrl.text = rawName;
      }
      final resIp = (picked['_resolved_ip'] ??
              picked['heartbeat_ip'] ??
              picked['ip_address'] ??
              '')
          .toString()
          .trim();
      if (resIp.isNotEmpty) {
        ipCtrl.text = resIp;
      }
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.hub_rounded, color: AppPalette.teal600, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Añadir Equipo / Sensor de Planta a ${rack.code}',
                  style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0FDFA),
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: const Color(0xFF99F6E4)),
                    ),
                    child: Text(
                      'Se añadirá al plano de Planta (2. Datacenters) vinculado a "${rack.code}" y aparecerá en este recuadro para que puedas tirar su cable al Switch o Patch Panel.',
                      style: const TextStyle(
                        fontSize: 11.2,
                        color: Color(0xFF115E59),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  // 0. SELECCIONAR EQUIPO YA EXISTENTE EN LA CMDB
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: selectedCmdbAsset != null
                          ? const Color(0xFFF0FDF4)
                          : const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: selectedCmdbAsset != null
                            ? const Color(0xFF22C55E)
                            : AppPalette.blue300,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.account_tree_rounded,
                              size: 15,
                              color: selectedCmdbAsset != null
                                  ? const Color(0xFF15803D)
                                  : AppPalette.blue900,
                            ),
                            const SizedBox(width: 6),
                            const Expanded(
                              child: Text(
                                '0. ¿Seleccionar equipo ya detectado / registrado en la CMDB?',
                                style: TextStyle(
                                  fontSize: 11.3,
                                  fontWeight: FontWeight.w900,
                                  color: AppPalette.slate900,
                                ),
                              ),
                            ),
                            if (selectedCmdbAsset != null)
                              TextButton.icon(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  foregroundColor: AppPalette.red600,
                                ),
                                onPressed: () {
                                  setModal(() {
                                    selectedCmdbAssetId = null;
                                    selectedCmdbAsset = null;
                                  });
                                },
                                icon: const Icon(Icons.link_off, size: 13),
                                label: const Text(
                                  'Desvincular',
                                  style: TextStyle(fontSize: 10.5),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        if (cmdbAssets.isNotEmpty) ...[
                          DropdownButtonFormField<int?>(
                            key: ValueKey('flr_cmdb_$selectedCmdbAssetId'),
                            initialValue: cmdbAssets
                                    .any((a) => a['id'] == selectedCmdbAssetId)
                                ? selectedCmdbAssetId
                                : null,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText:
                                  'Seleccionar directamente activo de 6. CMDB',
                              prefixIcon: Icon(
                                Icons.inventory_2_outlined,
                                size: 16,
                                color: AppPalette.blue700,
                              ),
                              isDense: true,
                              filled: true,
                              fillColor: Colors.white,
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                            ),
                            items: [
                              const DropdownMenuItem<int?>(
                                value: null,
                                child: Text(
                                  '— Crear nuevo equipo desde cero —',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: AppPalette.slate500,
                                  ),
                                ),
                              ),
                              ...cmdbAssets.map((a) {
                                final id = (a['id'] as num?)?.toInt();
                                final code = (a['code'] ?? '').toString();
                                final name = (a['name'] ?? '').toString();
                                final ip = (a['_resolved_ip'] ??
                                        a['heartbeat_ip'] ??
                                        a['ip_address'] ??
                                        '')
                                    .toString();
                                return DropdownMenuItem<int?>(
                                  value: id,
                                  child: Text(
                                    '[$code] $name ${ip.isNotEmpty ? "• IP: $ip" : ""}',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11.8,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                );
                              }),
                            ],
                            onChanged: (val) {
                              setModal(() {
                                if (val == null) {
                                  selectedCmdbAssetId = null;
                                  selectedCmdbAsset = null;
                                } else {
                                  final picked = cmdbAssets.firstWhere(
                                    (a) => a['id'] == val,
                                  );
                                  applyCmdbToFloor(picked);
                                }
                              });
                            },
                          ),
                          const SizedBox(height: 6),
                        ],
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              backgroundColor: Colors.white,
                              side: const BorderSide(color: AppPalette.blue600),
                            ),
                            onPressed: () async {
                              final picked = await CmdbAssetExplorerDialog.show(
                                ctx,
                                api: widget.api,
                                contextMode: 'floor',
                                preselectedAssetId: selectedCmdbAssetId,
                                title:
                                    'Seleccionar Equipo de la CMDB para Planta (${rack.code})',
                                subtitle:
                                    'Navega por las Redes / Subredes (Máscara CIDR) y elige el activo para autocompletar sus datos.',
                              );
                              if (picked != null) {
                                setModal(() {
                                  applyCmdbToFloor(picked);
                                  if (selectedCmdbAssetId != null &&
                                      !cmdbAssets.any(
                                        (a) => a['id'] == selectedCmdbAssetId,
                                      )) {
                                    cmdbAssets = [picked, ...cmdbAssets];
                                  }
                                });
                              }
                            },
                            icon: const Icon(
                              Icons.manage_search_rounded,
                              size: 16,
                              color: AppPalette.blue700,
                            ),
                            label: Text(
                              selectedCmdbAsset != null
                                  ? 'Cambiar Equipo CMDB ([${selectedCmdbAsset!['code']}])'
                                  : 'Abrir Explorador CMDB por Redes / Máscara...',
                              style: const TextStyle(
                                fontSize: 11.3,
                                fontWeight: FontWeight.w800,
                                color: AppPalette.blue900,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedType,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Tipo de Equipo o Sensor de Planta',
                      isDense: true,
                    ),
                    items: presets
                        .map(
                          (p) => DropdownMenuItem(
                            value: p.key,
                            child: Text(
                              p.label,
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (val) {
                      if (val == null) return;
                      final pr = presets.firstWhere((e) => e.key == val);
                      setModal(() {
                        selectedType = val;
                        if (selectedCmdbAsset == null) {
                          codeCtrl.text =
                              '${pr.prefix}0${DateTime.now().second % 9 + 1}';
                          nameCtrl.text = pr.defName;
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: codeCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Código (ej. PR02, AP03, CAM04)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: roomCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Zona / Sala en Planta',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Nombre Descriptivo',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: ipCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Dirección IP (opcional)',
                      isDense: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppPalette.teal600,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.add_link, size: 16),
              label: const Text('Añadir al Recuadro de Planta'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      try {
        await widget.api.createFloorDevice(floorId, {
          'room_id': rack.roomId,
          'room_code': roomCtrl.text.trim(),
          'device_type': selectedType,
          'code': codeCtrl.text.trim(),
          'name': nameCtrl.text.trim(),
          'pos_x': 0.42,
          'pos_y': 0.48,
          'ip_address': ipCtrl.text.trim(),
          'vlan': 20,
          'status': 'unmonitored',
          'monitoring_enabled': false,
          'linked_rack_id': rack.id,
          'linked_rack_device_code': '',
          'cmdb_asset_id': ?selectedCmdbAssetId,
        });
        await _loadRack();
        messenger.aviso('Equipo de planta "${codeCtrl.text.trim()}" añadido al recuadro de ${rack.code}. Haz clic en su icono para unirlo a un Switch o Patch Panel.');
      } catch (e) {
        messenger.avisoError('$e');
      }
    }
  }
}
