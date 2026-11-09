import 'package:flutter/material.dart';
import '../../core/widgets/avisos.dart';
import '../../core/theme.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/api_client.dart';
import '../../core/image_file_picker.dart';
import '../../models/datacenter_models.dart';

class LocationsView extends StatefulWidget {
  final RackDocApiClient api;
  final List<LocationNode> locations;
  final VoidCallback onRefresh;
  final ValueChanged<int> onOpenDatacenter;
  final ValueChanged<int> onOpenRack;
  final bool isKioskMode;
  final VoidCallback? onToggleKioskMode;

  const LocationsView({
    super.key,
    required this.api,
    required this.locations,
    required this.onRefresh,
    required this.onOpenDatacenter,
    required this.onOpenRack,
    this.isKioskMode = false,
    this.onToggleKioskMode,
  });

  @override
  State<LocationsView> createState() => _LocationsViewState();
}

class _LocationsViewState extends State<LocationsView> {
  final MapController _mapController = MapController();
  final TextEditingController _osmSearchCtrl = TextEditingController();
  int? _selectedLocationId;

  // Modo del mapa superior: 'api_map' (OpenStreetMap) o 'custom_plan' (Imagen subida)
  String _mapViewMode = 'api_map';
  // Estilo de teselas OpenStreetMap: 'osm_standard' | 'osm_light' | 'osm_topo'
  String _osmTileStyle = 'osm_standard';
  bool _relocateByClickOnOsm = false;

  // Control de arrastre en vivo de Datacenters en OpenStreetMap y en Mapa Subido
  int? _draggingOsmLocId;
  bool _isDraggingCustomBox = false;
  final Map<int, LatLng> _liveOsmCoords = {};

  bool _searchingOsm = false;
  List<Map<String, dynamic>> _osmSearchResults = [];

  bool _uploading = false;
  double _mapImageScale = 1.0;

  // Posiciones y tamaños en vivo de cada Datacenter sobre el mapa subido
  final Map<int, Offset> _dcPositions = {};
  final Map<int, Size> _dcSizes = {};

  LocationNode? get _selectedLocation {
    if (widget.locations.isEmpty) return null;
    if (_selectedLocationId == null) return widget.locations.first;
    return widget.locations.firstWhere(
      (l) => l.id == _selectedLocationId,
      orElse: () => widget.locations.first,
    );
  }

  /// Obtiene la URL de la imagen del mapa general (guardada en la primera sede que tenga mapa subido).
  LocationNode? get _mapCarrierLocation {
    if (widget.locations.isEmpty) return null;
    for (final l in widget.locations) {
      if (l.mapImageUrl.isNotEmpty) return l;
    }
    return widget.locations.first;
  }

  @override
  void initState() {
    super.initState();
    _syncDatacenterBoxes();
  }

  @override
  void didUpdateWidget(covariant LocationsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncDatacenterBoxes();
  }

  @override
  void dispose() {
    _osmSearchCtrl.dispose();
    super.dispose();
  }

  void _syncDatacenterBoxes() {
    final carrier = _mapCarrierLocation;
    if (carrier != null) {
      _mapImageScale = carrier.mapScale.clamp(0.4, 2.5);
    }

    final seenCoords = <String, int>{};

    for (int i = 0; i < widget.locations.length; i++) {
      final loc = widget.locations[i];

      // Coordenadas en OpenStreetMap: si dos Datacenters tienen exactamente la misma coordenada,
      // los separamos ligeramente en pantalla para que no se tapen y puedas arrastrar cada uno.
      double lat = loc.latitude;
      double lon = loc.longitude;
      final key = '${lat.toStringAsFixed(4)},${lon.toStringAsFixed(4)}';
      final countAtSameSpot = seenCoords[key] ?? 0;
      seenCoords[key] = countAtSameSpot + 1;
      if (countAtSameSpot > 0) {
        lon += countAtSameSpot * 0.008;
        lat -= countAtSameSpot * 0.003;
      }
      if (_draggingOsmLocId != loc.id) {
        _liveOsmCoords[loc.id] = LatLng(lat, lon);
      }

      // Posiciones normalizadas en Mapa Subido (JPG/PNG/GIF)
      double px = loc.planPosX;
      double py = loc.planPosY;
      if ((px - 0.25).abs() < 0.01 && (py - 0.35).abs() < 0.01 && i > 0) {
        px = (0.18 + i * 0.26).clamp(0.10, 0.78);
        py = (0.28 + (i % 2) * 0.22).clamp(0.15, 0.75);
      }
      if (!_isDraggingCustomBox) {
        _dcPositions[loc.id] = Offset(px, py);
        _dcSizes[loc.id] = Size(
          loc.planWidth.clamp(110.0, 320.0),
          loc.planHeight.clamp(68.0, 220.0),
        );
      }
    }
  }

  Future<void> _saveDatacenterGeometry(int locId) async {
    final pos = _dcPositions[locId];
    final sz = _dcSizes[locId];
    if (pos == null || sz == null) return;
    try {
      await widget.api.updateLocation(locId, {
        'plan_pos_x': double.parse(pos.dx.toStringAsFixed(4)),
        'plan_pos_y': double.parse(pos.dy.toStringAsFixed(4)),
        'plan_width': sz.width.roundToDouble(),
        'plan_height': sz.height.roundToDouble(),
      });
      widget.onRefresh();
    } catch (_) {}
  }

  Future<void> _saveGlobalMapScale(double newScale) async {
    setState(() => _mapImageScale = newScale);
    final carrier = _mapCarrierLocation;
    if (carrier == null) return;
    try {
      await widget.api.updateLocation(carrier.id, {'map_scale': newScale});
    } catch (_) {}
  }

  Future<void> _runOsmMapSearch() async {
    final q = _osmSearchCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() => _searchingOsm = true);
    try {
      final results = await widget.api.searchOpenStreetMap(q);
      if (!mounted) return;
      setState(() => _osmSearchResults = results);
      if (results.isNotEmpty) {
        final first = results.first;
        final lat = first['lat'] as double;
        final lon = first['lon'] as double;
        _mapController.move(LatLng(lat, lon), 16.0);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).aviso('Error buscando en OpenStreetMap: $e');
    } finally {
      if (mounted) setState(() => _searchingOsm = false);
    }
  }

  Future<void> _moveDatacenterToOsmCoords({
    required int locationId,
    required String locationCode,
    required double lat,
    required double lon,
    String? address,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final payload = <String, dynamic>{
        'latitude': double.parse(lat.toStringAsFixed(6)),
        'longitude': double.parse(lon.toStringAsFixed(6)),
      };
      if (address != null && address.isNotEmpty) {
        payload['address'] = address;
      }
      setState(() {
        _liveOsmCoords[locationId] = LatLng(lat, lon);
        _osmSearchResults = [];
        _relocateByClickOnOsm = false;
      });
      await widget.api.updateLocation(locationId, payload);
      widget.onRefresh();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(
            'Datacenter $locationCode situado en (${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)})',
          ),
        ),
      );
    } catch (e) {
      messenger.avisoError('Error guardando coordenadas: $e');
    }
  }

  Future<void> _confirmDeleteLocation(LocationNode loc) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Eliminar Datacenter "${loc.code}"'),
        content: Text(
          '¿Estás seguro de que quieres eliminar el Datacenter "${loc.name} (${loc.code})"?\n\n'
          'Se borrarán también todas sus plantas (${loc.floorsCount}) y racks (${loc.racksCount}) asociados.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.red600,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('Sí, eliminar Datacenter'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await widget.api.deleteLocation(loc.id);
        if (_selectedLocationId == loc.id) {
          _selectedLocationId = null;
        }
        widget.onRefresh();
        messenger.aviso('Datacenter "${loc.code}" eliminado.');
      } catch (e) {
        messenger.avisoError('Error eliminando Datacenter: $e');
      }
    }
  }

  Future<void> _uploadGlobalLocationsMap() async {
    final carrier = _mapCarrierLocation;
    if (carrier == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await pickPlanImageFile();
      if (picked == null) return;

      setState(() => _uploading = true);
      await widget.api.uploadCustomPlanImage(
        targetType: 'location',
        targetId: carrier.id,
        filename: picked.name,
        fileBytes: picked.bytes,
      );
      setState(() => _mapViewMode = 'custom_plan');
      widget.onRefresh();
      messenger.aviso('Mapa general (${picked.name}) subido. Ahora puedes arrastrar y dimensionar tus Datacenters sobre él.');
    } catch (e) {
      messenger.avisoError('Error subiendo mapa: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _downloadExcel({int? locationId}) async {
    final url = Uri.parse(widget.api.getExcelExportUrl(locationId: locationId));
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  Future<void> _showLocationFormDialog({LocationNode? existing}) async {
    final messenger = ScaffoldMessenger.of(context);
    final isEdit = existing != null;
    final existingCodes = widget.locations
        .map((l) => l.code.toUpperCase())
        .toSet();
    int nextNum = widget.locations.length + 1;
    String defaultCode = 'CPD-${nextNum.toString().padLeft(2, '0')}';
    while (existingCodes.contains(defaultCode.toUpperCase())) {
      nextNum++;
      defaultCode = 'CPD-${nextNum.toString().padLeft(2, '0')}';
    }
    final defaultName = 'Datacenter $defaultCode';

    final codeCtrl = TextEditingController(text: existing?.code ?? defaultCode);
    final nameCtrl = TextEditingController(
      text: existing?.name ?? defaultName,
    );
    final latCtrl = TextEditingController(
      text: existing != null ? existing.latitude.toString() : '40.4168',
    );
    final lngCtrl = TextEditingController(
      text: existing != null ? existing.longitude.toString() : '-3.7038',
    );
    final addrCtrl = TextEditingController(
      text: existing?.address.isNotEmpty == true
          ? existing!.address
          : 'Calle Alcalá, Madrid',
    );
    final searchOsmCtrl = TextEditingController(text: existing?.address ?? '');
    List<Map<String, dynamic>> modalResults = [];
    bool modalLoading = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(
            isEdit
                ? 'Editar Datacenter (${existing.code}) en OpenStreetMap'
                : 'Añadir Nuevo Datacenter (Location)',
          ),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: codeCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Código (ej. HQ, MAD01)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: nameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Nombre del Datacenter',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // Buscador directo en OpenStreetMap (Nominatim)
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppPalette.slate100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppPalette.slate300),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(
                              Icons.travel_explore_rounded,
                              size: 16,
                              color: AppPalette.blue900,
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Buscar dirección en OpenStreetMap (Autocompletar Coordenadas)',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppPalette.blue900,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: searchOsmCtrl,
                                decoration: const InputDecoration(
                                  hintText:
                                      'Ej: Calle Alcalá 45, Madrid / Gran Vía, Bilbao...',
                                  isDense: true,
                                  filled: true,
                                  fillColor: Colors.white,
                                  border: OutlineInputBorder(),
                                ),
                                onSubmitted: (_) async {
                                  setModalState(() => modalLoading = true);
                                  try {
                                    final res = await widget.api
                                        .searchOpenStreetMap(searchOsmCtrl.text);
                                    setModalState(() => modalResults = res);
                                  } finally {
                                    setModalState(() => modalLoading = false);
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.tonalIcon(
                              onPressed: modalLoading
                                  ? null
                                  : () async {
                                      setModalState(() => modalLoading = true);
                                      try {
                                        final res = await widget.api
                                            .searchOpenStreetMap(
                                              searchOsmCtrl.text,
                                            );
                                        setModalState(() => modalResults = res);
                                      } finally {
                                        setModalState(
                                          () => modalLoading = false,
                                        );
                                      }
                                    },
                              icon: const Icon(Icons.search, size: 16),
                              label: Text(modalLoading ? '...' : 'Buscar OSM'),
                            ),
                          ],
                        ),
                        if (modalResults.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 140),
                            child: ListView.separated(
                              shrinkWrap: true,
                              itemCount: modalResults.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1),
                              itemBuilder: (_, idx) {
                                final r = modalResults[idx];
                                final disp = r['display_name'] as String;
                                final lat = r['lat'] as double;
                                final lon = r['lon'] as double;
                                return ListTile(
                                  dense: true,
                                  visualDensity: VisualDensity.compact,
                                  leading: const Icon(
                                    Icons.place_outlined,
                                    size: 18,
                                    color: AppPalette.blue600,
                                  ),
                                  title: Text(
                                    disp,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  subtitle: Text(
                                    'Lat: ${lat.toStringAsFixed(5)} • Lon: ${lon.toStringAsFixed(5)}',
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                  onTap: () {
                                    setModalState(() {
                                      addrCtrl.text = disp;
                                      latCtrl.text = lat.toStringAsFixed(6);
                                      lngCtrl.text = lon.toStringAsFixed(6);
                                      if (!isEdit &&
                                          nameCtrl.text.trim() == defaultName) {
                                        final parts = disp
                                            .split(',')
                                            .map((s) => s.trim())
                                            .where((s) => s.isNotEmpty)
                                            .toList();
                                        if (parts.isNotEmpty) {
                                          nameCtrl.text =
                                              'CPD ${parts.first}';
                                        }
                                      }
                                      modalResults = [];
                                    });
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: latCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Latitud (OSM)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: lngCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Longitud (OSM)',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: addrCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Dirección física',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (isEdit)
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(ctx, false);
                  _confirmDeleteLocation(existing);
                },
                icon: const Icon(
                  Icons.delete_outline,
                  size: 16,
                  color: AppPalette.red600,
                ),
                label: const Text(
                  'Eliminar Datacenter',
                  style: TextStyle(color: AppPalette.red600),
                ),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(isEdit ? 'Guardar Cambios' : 'Crear Datacenter'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      final lat = double.tryParse(latCtrl.text.trim()) ?? 40.4168;
      final lon = double.tryParse(lngCtrl.text.trim()) ?? -3.7038;
      try {
        if (isEdit) {
          await widget.api.updateLocation(existing.id, {
            'code': codeCtrl.text.trim(),
            'name': nameCtrl.text.trim(),
            'latitude': lat,
            'longitude': lon,
            'address': addrCtrl.text.trim(),
          });
          messenger.aviso('Datacenter "${nameCtrl.text.trim()}" actualizado correctamente.');
        } else {
          final created = await widget.api.createLocation(
            code: codeCtrl.text.trim(),
            name: nameCtrl.text.trim(),
            latitude: lat,
            longitude: lon,
            address: addrCtrl.text.trim(),
          );
          final newId = created['id'] as int?;
          if (newId != null && mounted) {
            setState(() {
              _selectedLocationId = newId;
            });
          }
          messenger.aviso('Datacenter "${created['name'] ?? nameCtrl.text.trim()}" (${created['code'] ?? codeCtrl.text.trim()}) creado correctamente.');
        }
        widget.onRefresh();
        if (_mapViewMode == 'api_map') {
          _mapController.move(LatLng(lat, lon), 14.0);
        }
      } catch (e) {
        messenger.avisoError('Error al guardar Datacenter: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedLocation;
    final carrier = _mapCarrierLocation;
    final customMapUrl = carrier != null
        ? widget.api.resolvePlanImageUrl(carrier.mapImageUrl)
        : '';

    final centerLatLng = selected != null
        ? (_liveOsmCoords[selected.id] ??
            LatLng(selected.latitude, selected.longitude))
        : const LatLng(48.2082, 16.3738);

    final lockScroll = _isDraggingCustomBox || _draggingOsmLocId != null;

    return Container(
      color: AppPalette.slate50,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. CABECERA SUPERIOR (oculta botones de edición en Modo Kiosco)
          if (!widget.isKioskMode)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(bottom: BorderSide(color: AppPalette.slate200)),
              ),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Locations — Mapa de Centros de Datos',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppPalette.slate900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'PBX  >  Locations${selected != null ? '  >  ${selected.code} (${selected.name})' : ''}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppPalette.slate500,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  if (widget.onToggleKioskMode != null) ...[
                    OutlinedButton.icon(
                      onPressed: widget.onToggleKioskMode,
                      icon: const Icon(Icons.tv_rounded, size: 17),
                      label: const Text('Modo Kiosco'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppPalette.slate900,
                        side: const BorderSide(color: AppPalette.slate400),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  OutlinedButton.icon(
                    onPressed: _uploading ? null : _uploadGlobalLocationsMap,
                    icon: const Icon(Icons.upload_file_outlined, size: 18),
                    label: Text(
                      _uploading
                          ? 'Subiendo...'
                          : 'Subir Mapa Propio (JPG/PNG/GIF)',
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: () => _downloadExcel(locationId: selected?.id),
                    icon: const Icon(Icons.table_view_outlined, size: 18),
                    label: const Text('Exportar Excel (.xlsx)'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: () => _showLocationFormDialog(),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add location'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppPalette.blue900,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ),

          // 2. CUERPO PRINCIPAL: MAPA (OpenStreetMap o IMAGEN SUBIDA CON DATACENTERS ARRASTRABLES) + TARJETAS
          Expanded(
            child: SingleChildScrollView(
              physics: lockScroll
                  ? const NeverScrollableScrollPhysics()
                  : const ClampingScrollPhysics(),
              padding: EdgeInsets.all(widget.isKioskMode ? 14 : 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Barra de modo del mapa y selector de capa OpenStreetMap / escala de imagen
                  if (!widget.isKioskMode) ...[
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      alignment: WrapAlignment.spaceBetween,
                      children: [
                        SegmentedButton<String>(
                          segments: [
                            const ButtonSegment(
                              value: 'api_map',
                              icon: Icon(Icons.map_outlined, size: 16),
                              label: Text('OpenStreetMap (Interactivo)'),
                            ),
                            ButtonSegment(
                              value: 'custom_plan',
                              icon: const Icon(Icons.image_outlined, size: 16),
                              label: Text(
                                customMapUrl.isNotEmpty
                                    ? 'Mapa Subido (JPG/PNG/GIF ✓)'
                                    : 'Mapa Subido (JPG/PNG/GIF)',
                              ),
                            ),
                          ],
                          selected: {_mapViewMode},
                          onSelectionChanged: (s) {
                            setState(() => _mapViewMode = s.first);
                          },
                        ),

                        if (_mapViewMode == 'api_map')
                          Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              const Text(
                                'Capa OSM:',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppPalette.slate600,
                                ),
                              ),
                              SegmentedButton<String>(
                                segments: const [
                                  ButtonSegment(
                                    value: 'osm_standard',
                                    label: Text(
                                      'OSM Estándar (Calles/Color)',
                                      style: TextStyle(fontSize: 11),
                                    ),
                                  ),
                                  ButtonSegment(
                                    value: 'osm_light',
                                    label: Text(
                                      'OSM Claro',
                                      style: TextStyle(fontSize: 11),
                                    ),
                                  ),
                                  ButtonSegment(
                                    value: 'osm_topo',
                                    label: Text(
                                      'Topográfico',
                                      style: TextStyle(fontSize: 11),
                                    ),
                                  ),
                                ],
                                selected: {_osmTileStyle},
                                onSelectionChanged: (s) {
                                  setState(() => _osmTileStyle = s.first);
                                },
                              ),
                              FilterChip(
                                selected: _relocateByClickOnOsm,
                                selectedColor: AppPalette.blue100,
                                checkmarkColor: AppPalette.blue900,
                                avatar: const Icon(
                                  Icons.pin_drop_outlined,
                                  size: 16,
                                  color: AppPalette.blue900,
                                ),
                                label: Text(
                                  selected != null
                                      ? 'Situar ${selected.code} con clic'
                                      : 'Situar con clic',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                onSelected: (v) {
                                  setState(() => _relocateByClickOnOsm = v);
                                },
                              ),
                            ],
                          ),

                        if (_mapViewMode == 'custom_plan')
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'Tamaño/Escala Imagen:',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppPalette.slate600,
                                ),
                              ),
                              SizedBox(
                                width: 140,
                                child: Slider(
                                  value: _mapImageScale,
                                  min: 0.4,
                                  max: 2.5,
                                  divisions: 21,
                                  label: '${(_mapImageScale * 100).round()}%',
                                  onChanged: (v) {
                                    setState(() => _mapImageScale = v);
                                  },
                                  onChangeEnd: _saveGlobalMapScale,
                                ),
                              ),
                              Text(
                                '${(_mapImageScale * 100).round()}%',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],

                  // VISOR DEL MAPA (420px alto normal / 580px en Modo Kiosco)
                  Container(
                    height: widget.isKioskMode ? 580 : 420,
                    decoration: BoxDecoration(
                      color: AppPalette.slate200,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppPalette.slate300),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x0A000000),
                          blurRadius: 8,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _mapViewMode == 'custom_plan'
                        ? _buildCustomImageWithDraggableDatacenters(
                            customMapUrl: customMapUrl,
                            selected: selected,
                          )
                        : _buildGeographicOpenStreetMap(selected, centerLatLng),
                  ),

                  const SizedBox(height: 22),

                  // 3. TARJETAS DE DATACENTERS
                  const Text(
                    'Centros de Datos (Pulsa una tarjeta para seleccionarla en el mapa • Arrastra el pin en el mapa para moverlo • "Abrir Plantas" para ver Racks)',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppPalette.slate900,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: widget.locations.map((loc) {
                      final isSelected = loc.id == selected?.id;
                      return InkWell(
                        onTap: () {
                          setState(() => _selectedLocationId = loc.id);
                          if (_mapViewMode == 'api_map') {
                            final targetPos = _liveOsmCoords[loc.id] ??
                                LatLng(loc.latitude, loc.longitude);
                            _mapController.move(
                              targetPos,
                              _mapController.camera.zoom,
                            );
                          }
                        },
                        onDoubleTap: () => widget.onOpenDatacenter(loc.id),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: 380,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isSelected
                                  ? AppPalette.blue600
                                  : AppPalette.slate200,
                              width: isSelected ? 2 : 1,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x06000000),
                                blurRadius: 6,
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
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? AppPalette.blue900
                                          : AppPalette.slate900,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Icon(
                                      Icons.business_rounded,
                                      color: Colors.white,
                                      size: 19,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          loc.name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14,
                                            color: AppPalette.slate900,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          '${loc.code}${loc.address.isNotEmpty ? ' • ${loc.address}' : ''}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: AppPalette.slate500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    tooltip:
                                        'Editar dirección / coordenadas en OpenStreetMap',
                                    icon: const Icon(
                                      Icons.edit_location_alt_outlined,
                                      size: 18,
                                      color: AppPalette.slate600,
                                    ),
                                    onPressed: () =>
                                        _showLocationFormDialog(existing: loc),
                                  ),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    tooltip: 'Eliminar este Datacenter',
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 18,
                                      color: AppPalette.red600,
                                    ),
                                    onPressed: () =>
                                        _confirmDeleteLocation(loc),
                                  ),
                                  const SizedBox(width: 4),
                                  FilledButton.tonalIcon(
                                    onPressed: () =>
                                        widget.onOpenDatacenter(loc.id),
                                    icon: const Icon(
                                      Icons.layers_outlined,
                                      size: 14,
                                    ),
                                    label: const Text(
                                      'Plantas',
                                      style: TextStyle(fontSize: 11),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  _StatColumn(
                                    label: '# Floors (Plantas)',
                                    value: '${loc.floorsCount}',
                                  ),
                                  _StatColumn(
                                    label: '# Rooms (Salas)',
                                    value: '${loc.roomsCount}',
                                  ),
                                  _StatColumn(
                                    label: '# Racks (${loc.totalRackUnits}U)',
                                    value: '${loc.racksCount}',
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: loc.offlineCount > 0
                                      ? AppPalette.red50
                                      : (loc.warningCount > 0
                                          ? AppPalette.amber50
                                          : (loc.onlineCount > 0
                                              ? AppPalette.green50
                                              : AppPalette.slate50)),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: loc.offlineCount > 0
                                        ? AppPalette.red200
                                        : (loc.warningCount > 0
                                            ? const Color(0xFFFDE68A)
                                            : (loc.onlineCount > 0
                                                ? const Color(0xFFBBF7D0)
                                                : AppPalette.slate300)),
                                  ),
                                ),
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.monitor_heart_rounded,
                                      size: 14,
                                      color: loc.offlineCount > 0
                                          ? AppPalette.red600
                                          : (loc.warningCount > 0
                                              ? AppPalette.amber600
                                              : (loc.onlineCount > 0
                                                  ? AppPalette.green600
                                                  : AppPalette.slate500)),
                                    ),
                                    const Text(
                                      'Heartbeat:',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w800,
                                        color: AppPalette.slate900,
                                      ),
                                    ),
                                    _StatusDotPill(
                                      color: AppPalette.slate400,
                                      count: loc.unmonitoredCount,
                                      label: 'Gris',
                                    ),
                                    _StatusDotPill(
                                      color: AppPalette.green600,
                                      count: loc.onlineCount,
                                      label: 'Verde',
                                    ),
                                    _StatusDotPill(
                                      color: AppPalette.amber600,
                                      count: loc.warningCount,
                                      label: 'Naranja',
                                    ),
                                    _StatusDotPill(
                                      color: AppPalette.red600,
                                      count: loc.offlineCount,
                                      label: 'Rojo',
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Visor del Mapa Propio (JPG/PNG/GIF) donde puedes arrastrar y dimensionar los Datacenters.
  Widget _buildCustomImageWithDraggableDatacenters({
    required String customMapUrl,
    required LocationNode? selected,
  }) {
    if (customMapUrl.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.image_outlined,
              size: 48,
              color: AppPalette.slate500,
            ),
            const SizedBox(height: 10),
            const Text(
              'Sube una imagen JPG, PNG o GIF para situar y dimensionar tus Datacenters sobre ella',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppPalette.slate700,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _uploadGlobalLocationsMap,
              icon: const Icon(Icons.upload_file),
              label: const Text('Seleccionar Mapa JPG / PNG / GIF'),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final canvasW = constraints.maxWidth;
        final canvasH = constraints.maxHeight;

        return Stack(
          fit: StackFit.expand,
          children: [
            // Imagen de fondo escalable
            Container(
              color: AppPalette.slate100,
              child: Center(
                child: Transform.scale(
                  scale: _mapImageScale,
                  child: Image.network(
                    customMapUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (ctx, err, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),

            // Cajas arrastrables y dimensionables de cada Datacenter (HQ, HQ_NEW, PRD...)
            for (final loc in widget.locations)
              Builder(
                builder: (ctx) {
                  final pos =
                      _dcPositions[loc.id] ?? const Offset(0.25, 0.35);
                  final sz = _dcSizes[loc.id] ?? const Size(160.0, 90.0);
                  final isSel = loc.id == selected?.id;

                  final leftPx = (pos.dx * canvasW).clamp(
                    8.0,
                    (canvasW - sz.width - 8.0).clamp(8.0, canvasW),
                  );
                  final topPx = (pos.dy * canvasH).clamp(
                    8.0,
                    (canvasH - sz.height - 8.0).clamp(8.0, canvasH),
                  );

                  return Positioned(
                    left: leftPx,
                    top: topPx,
                    width: sz.width,
                    height: sz.height,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () =>
                            setState(() => _selectedLocationId = loc.id),
                        onDoubleTap: () => widget.onOpenDatacenter(loc.id),
                        onPanStart: (_) {
                          setState(() {
                            _isDraggingCustomBox = true;
                            _selectedLocationId = loc.id;
                          });
                        },
                        onPanUpdate: (details) {
                          setState(() {
                            final cur = _dcPositions[loc.id] ??
                                const Offset(0.25, 0.35);
                            final nx = (cur.dx + details.delta.dx / canvasW)
                                .clamp(0.01, 0.92);
                            final ny = (cur.dy + details.delta.dy / canvasH)
                                .clamp(0.01, 0.90);
                            _dcPositions[loc.id] = Offset(nx, ny);
                          });
                        },
                        onPanEnd: (_) {
                          setState(() => _isDraggingCustomBox = false);
                          _saveDatacenterGeometry(loc.id);
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSel
                                ? const Color(0xEE1E3A8A)
                                : const Color(0xDD0F172A),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isSel
                                  ? AppPalette.sky400
                                  : Colors.white70,
                              width: isSel ? 2.5 : 1.5,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 8,
                                offset: Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Stack(
                            children: [
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(10, 6, 10, 6),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      children: [
                                        const Icon(
                                          Icons.open_with_rounded,
                                          color: AppPalette.sky400,
                                          size: 14,
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            '${loc.code} — ${loc.name}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w700,
                                              fontSize: 11.5,
                                            ),
                                          ),
                                        ),
                                        InkWell(
                                          onTap: () =>
                                              _confirmDeleteLocation(loc),
                                          child: const Tooltip(
                                            message: 'Eliminar este Datacenter',
                                            child: Icon(
                                              Icons.delete_outline,
                                              size: 14,
                                              color: AppPalette.red300,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    Text(
                                      [
                                        '${loc.floorsCount} plantas • ${loc.racksCount} racks',
                                        '⚪${loc.unmonitoredCount}',
                                        '🟢${loc.onlineCount}',
                                        if (loc.warningCount > 0)
                                          '🟠${loc.warningCount}',
                                        '🔴${loc.offlineCount}',
                                      ].join(' '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: AppPalette.sky200,
                                        fontSize: 10,
                                      ),
                                    ),
                                    SizedBox(
                                      height: 22,
                                      child: FilledButton.icon(
                                        onPressed: () =>
                                            widget.onOpenDatacenter(loc.id),
                                        style: FilledButton.styleFrom(
                                          backgroundColor:
                                              AppPalette.blue600,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                        ),
                                        icon: const Icon(
                                          Icons.meeting_room_outlined,
                                          size: 12,
                                        ),
                                        label: const Text(
                                          'Entrar al Edificio',
                                          style: TextStyle(fontSize: 10),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Tirador esquina inferior derecha para DIMENSIONAR (resize) el Datacenter
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onPanStart: (_) {
                                    setState(() {
                                      _isDraggingCustomBox = true;
                                      _selectedLocationId = loc.id;
                                    });
                                  },
                                  onPanUpdate: (details) {
                                    setState(() {
                                      final curSz = _dcSizes[loc.id] ?? sz;
                                      final nw =
                                          (curSz.width + details.delta.dx)
                                              .clamp(115.0, 360.0);
                                      final nh =
                                          (curSz.height + details.delta.dy)
                                              .clamp(72.0, 250.0);
                                      _dcSizes[loc.id] = Size(nw, nh);
                                    });
                                  },
                                  onPanEnd: (_) {
                                    setState(
                                      () => _isDraggingCustomBox = false,
                                    );
                                    _saveDatacenterGeometry(loc.id);
                                  },
                                  child: Tooltip(
                                    message:
                                        'Arrastra esta esquina para dimensionar el Datacenter en el mapa',
                                    child: Container(
                                      width: 18,
                                      height: 18,
                                      decoration: const BoxDecoration(
                                        color: AppPalette.sky400,
                                        borderRadius: BorderRadius.only(
                                          topLeft: Radius.circular(6),
                                          bottomRight: Radius.circular(6),
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
                  );
                },
              ),

            // Banner de instrucciones arriba a la izquierda
            Positioned(
              top: 10,
              left: 12,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppPalette.slate300),
                ),
                child: const Text(
                  'Arrastra cada Datacenter para ubicarlo en el mapa • Estira su esquina azul (◢) para dimensionarlo • Pulsa "Entrar al Edificio" para ver sus Plantas y Racks.',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppPalette.slate900,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  TileLayer _buildOsmTileLayer() {
    switch (_osmTileStyle) {
      case 'osm_light':
        return TileLayer(
          urlTemplate:
              'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
          subdomains: const ['a', 'b', 'c', 'd'],
          userAgentPackageName: 'com.rackdoc.dcim',
        );
      case 'osm_topo':
        return TileLayer(
          urlTemplate: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
          subdomains: const ['a', 'b', 'c'],
          userAgentPackageName: 'com.rackdoc.dcim',
        );
      case 'osm_standard':
      default:
        return TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.rackdoc.dcim',
        );
    }
  }

  Widget _buildGeographicOpenStreetMap(
    LocationNode? selected,
    LatLng centerLatLng,
  ) {
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: centerLatLng,
            initialZoom: 13.0,
            interactionOptions: InteractionOptions(
              flags: _draggingOsmLocId != null
                  ? InteractiveFlag.none
                  : InteractiveFlag.all,
            ),
            onTap: (tapPos, latlng) {
              if (_relocateByClickOnOsm && selected != null) {
                _moveDatacenterToOsmCoords(
                  locationId: selected.id,
                  locationCode: selected.code,
                  lat: latlng.latitude,
                  lon: latlng.longitude,
                );
              }
            },
          ),
          children: [
            _buildOsmTileLayer(),
            MarkerLayer(
              markers: widget.locations.map((loc) {
                final isSel = loc.id == selected?.id;
                final isDragging = _draggingOsmLocId == loc.id;
                final pos = _liveOsmCoords[loc.id] ??
                    LatLng(loc.latitude, loc.longitude);

                return Marker(
                  point: pos,
                  width: 165,
                  height: 82,
                  child: MouseRegion(
                    cursor: isDragging
                        ? SystemMouseCursors.grabbing
                        : SystemMouseCursors.grab,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        setState(() => _selectedLocationId = loc.id);
                      },
                      onDoubleTap: () => widget.onOpenDatacenter(loc.id),
                      onPanStart: (_) {
                        setState(() {
                          _selectedLocationId = loc.id;
                          _draggingOsmLocId = loc.id;
                        });
                      },
                      onPanUpdate: (details) {
                        final cam = _mapController.camera;
                        final curLatLng = _liveOsmCoords[loc.id] ??
                            LatLng(loc.latitude, loc.longitude);
                        final screenOffset = cam.latLngToScreenOffset(curLatLng);
                        final nextScreenOffset = screenOffset + details.delta;
                        final nextLatLng =
                            cam.screenOffsetToLatLng(nextScreenOffset);
                        setState(() {
                          _liveOsmCoords[loc.id] = nextLatLng;
                        });
                      },
                      onPanEnd: (_) {
                        final finalLatLng = _liveOsmCoords[loc.id];
                        setState(() => _draggingOsmLocId = null);
                        if (finalLatLng != null) {
                          _moveDatacenterToOsmCoords(
                            locationId: loc.id,
                            locationCode: loc.code,
                            lat: finalLatLng.latitude,
                            lon: finalLatLng.longitude,
                          );
                        }
                      },
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: isSel
                                  ? AppPalette.blue900
                                  : AppPalette.slate900,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: isSel
                                    ? AppPalette.sky400
                                    : Colors.white70,
                                width: isSel ? 2 : 1,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black26,
                                  blurRadius: 4,
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.open_with_rounded,
                                  size: 12,
                                  color: AppPalette.sky400,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    [
                                      loc.code,
                                      '⚪${loc.unmonitoredCount}',
                                      '🟢${loc.onlineCount}',
                                      if (loc.warningCount > 0)
                                        '🟠${loc.warningCount}',
                                      '🔴${loc.offlineCount}',
                                    ].join(' '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 2),
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: isDragging
                                  ? AppPalette.sky600
                                  : (isSel
                                      ? AppPalette.blue600
                                      : AppPalette.slate900),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white,
                                width: 2.5,
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black38,
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.apartment_rounded,
                              color: Colors.white,
                              size: 17,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),

        // Controles de Zoom a la izquierda
        Positioned(
          top: 12,
          left: 12,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppPalette.slate300),
              boxShadow: const [
                BoxShadow(color: Colors.black12, blurRadius: 4),
              ],
            ),
            child: Column(
              children: [
                IconButton(
                  icon: const Icon(Icons.add, size: 18),
                  tooltip: 'Acercar mapa OpenStreetMap',
                  onPressed: () {
                    final z = _mapController.camera.zoom;
                    _mapController.move(
                      _mapController.camera.center,
                      z + 1,
                    );
                  },
                ),
                const Divider(height: 1),
                IconButton(
                  icon: const Icon(Icons.remove, size: 18),
                  tooltip: 'Alejar mapa OpenStreetMap',
                  onPressed: () {
                    final z = _mapController.camera.zoom;
                    _mapController.move(
                      _mapController.camera.center,
                      z - 1,
                    );
                  },
                ),
              ],
            ),
          ),
        ),

        // Ayuda rápida para arrastrar los Datacenters en OpenStreetMap
        Positioned(
          top: 12,
          left: 64,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppPalette.slate300),
            ),
            child: const Text(
              'Arrastra cualquier Datacenter (✥) con el ratón para colocarlo en su sitio final • Doble clic para abrir sus Plantas.',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppPalette.slate900,
              ),
            ),
          ),
        ),

        // Buscador de calles / ciudades / edificios en OpenStreetMap (Nominatim) arriba a la derecha
        Positioned(
          top: 12,
          right: 12,
          width: 370,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.96),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppPalette.slate300),
                  boxShadow: const [
                    BoxShadow(color: Colors.black12, blurRadius: 6),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.travel_explore_rounded,
                      size: 18,
                      color: AppPalette.blue900,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _osmSearchCtrl,
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          hintText:
                              'Buscar calle, edificio o ciudad en OpenStreetMap...',
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        onSubmitted: (_) => _runOsmMapSearch(),
                      ),
                    ),
                    if (_osmSearchResults.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        tooltip: 'Cerrar resultados',
                        onPressed: () =>
                            setState(() => _osmSearchResults = []),
                      ),
                    FilledButton.tonal(
                      onPressed: _searchingOsm ? null : _runOsmMapSearch,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(60, 30),
                      ),
                      child: Text(
                        _searchingOsm ? '...' : 'Buscar',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
              if (_osmSearchResults.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 4),
                  constraints: const BoxConstraints(maxHeight: 210),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppPalette.slate300),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 8),
                    ],
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _osmSearchResults.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (ctx, i) {
                      final item = _osmSearchResults[i];
                      final disp = item['display_name'] as String;
                      final lat = item['lat'] as double;
                      final lon = item['lon'] as double;
                      return ListTile(
                        dense: true,
                        title: Text(
                          disp,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                        onTap: () {
                          _mapController.move(LatLng(lat, lon), 16.0);
                        },
                        trailing: selected != null
                            ? TextButton.icon(
                                onPressed: () => _moveDatacenterToOsmCoords(
                                  locationId: selected.id,
                                  locationCode: selected.code,
                                  lat: lat,
                                  lon: lon,
                                  address: disp,
                                ),
                                icon: const Icon(
                                  Icons.pin_drop_outlined,
                                  size: 14,
                                ),
                                label: Text(
                                  'Mover ${selected.code} aquí',
                                  style: const TextStyle(fontSize: 10),
                                ),
                              )
                            : null,
                      );
                    },
                  ),
                ),
            ],
          ),
        ),

        // Aviso cuando está activo el modo "Situar con clic en mapa"
        if (_relocateByClickOnOsm && selected != null)
          Positioned(
            bottom: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppPalette.blue900,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Modo activo: Haz clic en cualquier punto de OpenStreetMap para situar el Datacenter "${selected.code}" allí.',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),

        // Atribución oficial de OpenStreetMap abajo a la derecha
        Positioned(
          bottom: 6,
          right: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              '© OpenStreetMap contributors',
              style: TextStyle(fontSize: 10, color: AppPalette.slate600),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatColumn extends StatelessWidget {
  final String label;
  final String value;

  const _StatColumn({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: AppPalette.slate500,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppPalette.slate900,
          ),
        ),
      ],
    );
  }
}

class _StatusDotPill extends StatelessWidget {
  final Color color;
  final int count;
  final String label;

  const _StatusDotPill({
    required this.color,
    required this.count,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
      ],
    );
  }
}
