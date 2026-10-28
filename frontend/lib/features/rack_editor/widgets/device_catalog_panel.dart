import 'package:flutter/material.dart';
import '../../../models/datacenter_models.dart';

class DeviceCatalogPanel extends StatefulWidget {
  final List<DeviceTemplateModel> templates;
  final DeviceTemplateModel? selectedTemplateForClickMount;
  final ValueChanged<DeviceTemplateModel?> onSelectTemplate;
  final VoidCallback onCreateCustomTemplate;
  final String selectedLibraryGroup;
  final ValueChanged<String> onSelectLibraryGroup;
  final VoidCallback onExportLibrary;
  final VoidCallback onImportLibrary;
  final bool canEdit;

  const DeviceCatalogPanel({
    super.key,
    required this.templates,
    required this.selectedTemplateForClickMount,
    required this.onSelectTemplate,
    required this.onCreateCustomTemplate,
    required this.selectedLibraryGroup,
    required this.onSelectLibraryGroup,
    required this.onExportLibrary,
    required this.onImportLibrary,
    this.canEdit = true,
  });

  @override
  State<DeviceCatalogPanel> createState() => _DeviceCatalogPanelState();
}

class _DeviceCatalogPanelState extends State<DeviceCatalogPanel> {
  String _search = '';
  String? _expandedCategory;

  static const List<String> _defaultLibraries = [
    'Network',
    'Power',
    'Host - HP',
    'Host - Dell',
    'Patching & Passive',
  ];

  static const Map<String, String> _categoryTitles = {
    'switch': 'Switch (Network)',
    'router': 'Router (Network)',
    'firewall': 'Firewall (Network)',
    'gateway': 'Gateway / Voz',
    'pdu': 'Power — PDU y Enchufes Schuko',
    'ups': 'Power — UPS / SAI',
    'server': 'Server / Host (HP / Dell)',
    'patch_panel': 'Patch Panel',
    'patchbox': 'Patchbox',
    'cable_manager': 'Cable Manager',
    'rack_tray': 'Rack Tray',
    'rack_tray_device': 'Rack Tray Device',
    'miscellaneous': 'Miscellaneous',
  };

  static IconData _iconForCategory(String cat) {
    switch (cat) {
      case 'switch':
        return Icons.settings_ethernet;
      case 'router':
        return Icons.router_outlined;
      case 'firewall':
        return Icons.security_outlined;
      case 'server':
        return Icons.dns_outlined;
      case 'patch_panel':
      case 'patchbox':
        return Icons.view_week_outlined;
      case 'pdu':
      case 'ups':
        return Icons.bolt_outlined;
      case 'gateway':
        return Icons.hub_outlined;
      case 'rack_tray':
      case 'rack_tray_device':
        return Icons.shelves;
      case 'cable_manager':
        return Icons.linear_scale;
      default:
        return Icons.developer_board;
    }
  }

  List<String> _buildLibraryGroups() {
    final set = <String>{..._defaultLibraries};
    for (final t in widget.templates) {
      final g = t.libraryGroup.trim();
      if (g.isNotEmpty && g != 'External Power') {
        set.add(g);
      }
    }
    return ['all', ...set];
  }

  @override
  Widget build(BuildContext context) {
    final libraryGroups = _buildLibraryGroups();
    final activeLib = libraryGroups.contains(widget.selectedLibraryGroup)
        ? widget.selectedLibraryGroup
        : 'all';

    final grouped = <String, List<DeviceTemplateModel>>{};
    for (final key in _categoryTitles.keys) {
      grouped[key] = [];
    }

    for (final t in widget.templates) {
      if (t.category == 'external_outlet' ||
          t.libraryGroup == 'External Power') {
        continue;
      }
      if (activeLib != 'all' &&
          t.libraryGroup.toLowerCase() != activeLib.toLowerCase()) {
        continue;
      }
      if (_search.isNotEmpty) {
        final q = _search.toLowerCase();
        final match = t.modelName.toLowerCase().contains(q) ||
            t.manufacturer.toLowerCase().contains(q) ||
            t.category.toLowerCase().contains(q) ||
            t.libraryGroup.toLowerCase().contains(q);
        if (!match) continue;
      }
      grouped.putIfAbsent(t.category, () => []).add(t);
    }

    return Container(
      width: 265,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.widgets_outlined,
                      size: 17,
                      color: Color(0xFF1E3A8A),
                    ),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        'Devices & Librerías',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                    ),
                    if (widget.canEdit)
                      IconButton(
                        onPressed: widget.onCreateCustomTemplate,
                        icon: const Icon(Icons.add_circle_outline, size: 18),
                        tooltip:
                            'Crear nuevo dispositivo en la librería seleccionada',
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                // Selector de Librería / Grupo ("Network", "Power", "Host - HP", etc.)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFCBD5E1)),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: activeLib,
                      isExpanded: true,
                      isDense: true,
                      icon: const Icon(Icons.folder_open_outlined, size: 16),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0F172A),
                      ),
                      items: libraryGroups.map((g) {
                        final label =
                            g == 'all' ? '📚 Todas las Librerías' : '📦 $g';
                        return DropdownMenuItem<String>(
                          value: g,
                          child: Text(label, overflow: TextOverflow.ellipsis),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          widget.onSelectLibraryGroup(val);
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Botones Importar / Exportar por Grupo
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: widget.onExportLibrary,
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.download_outlined, size: 14),
                        label: Text(
                          activeLib == 'all'
                              ? 'Exportar Todo'
                              : 'Exportar Grupo',
                          style: const TextStyle(fontSize: 10.5),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (widget.canEdit)
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: widget.onImportLibrary,
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 4,
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                          icon: const Icon(Icons.upload_file_outlined, size: 14),
                          label: const Text(
                            'Importar JSON',
                            style: TextStyle(fontSize: 10.5),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  onChanged: (v) => setState(() => _search = v),
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'Buscar modelo, fabricante o grupo...',
                    prefixIcon: const Icon(Icons.search, size: 16),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              children: grouped.entries.map((entry) {
                final cat = entry.key;
                final items = entry.value;
                if ((_search.isNotEmpty || activeLib != 'all') &&
                    items.isEmpty) {
                  return const SizedBox.shrink();
                }
                final title = _categoryTitles[cat] ?? cat;
                final isExpanded = _expandedCategory == cat ||
                    _search.isNotEmpty ||
                    activeLib != 'all';

                return Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isExpanded
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFFE2E8F0),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      InkWell(
                        onTap: () {
                          setState(() {
                            _expandedCategory =
                                (_expandedCategory == cat) ? null : cat;
                          });
                        },
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _iconForCategory(cat),
                                size: 15,
                                color: (cat == 'pdu' || cat == 'ups')
                                    ? const Color(0xFFDC2626)
                                    : const Color(0xFF475569),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  title,
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF1E293B),
                                  ),
                                ),
                              ),
                              Text(
                                '${items.length}',
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Color(0xFF94A3B8),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (isExpanded && items.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                          decoration: const BoxDecoration(
                            color: Color(0xFFF8FAFC),
                            borderRadius: BorderRadius.vertical(
                              bottom: Radius.circular(6),
                            ),
                          ),
                          child: Column(
                            children: items.map((tpl) {
                              final isSelected =
                                  widget.selectedTemplateForClickMount?.id ==
                                      tpl.id;
                              return Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Draggable<DeviceTemplateModel>(
                                  data: tpl,
                                  maxSimultaneousDrags: widget.canEdit ? 1 : 0,
                                  feedback: Material(
                                    elevation: 8,
                                    borderRadius: BorderRadius.circular(6),
                                    child: Container(
                                      width: 240,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1E3A8A),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.drag_indicator,
                                            color: Colors.white,
                                            size: 16,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              '${tpl.manufacturer} ${tpl.modelName} (${tpl.uHeight}U)',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  child: InkWell(
                                    onTap: widget.canEdit
                                        ? () {
                                            widget.onSelectTemplate(
                                              isSelected ? null : tpl,
                                            );
                                          }
                                        : null,
                                    borderRadius: BorderRadius.circular(5),
                                    child: Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: isSelected
                                            ? const Color(0xFFDBEAFE)
                                            : Colors.white,
                                        borderRadius: BorderRadius.circular(5),
                                        border: Border.all(
                                          color: isSelected
                                              ? const Color(0xFF2563EB)
                                              : const Color(0xFFCBD5E1),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.drag_indicator,
                                            size: 14,
                                            color: Color(0xFF94A3B8),
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  tpl.modelName,
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                    color: Color(0xFF0F172A),
                                                  ),
                                                ),
                                                Text(
                                                  '${tpl.manufacturer} • ${tpl.uHeight}U • [${tpl.libraryGroup}]',
                                                  style: const TextStyle(
                                                    fontSize: 9.5,
                                                    color: Color(0xFF64748B),
                                                  ),
                                                ),
                                              ],
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
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}
