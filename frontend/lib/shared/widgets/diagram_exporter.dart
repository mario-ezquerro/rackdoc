import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/file_downloader.dart';
import '../../core/theme.dart';

class DiagramExportZone {
  final String id;
  final String title;
  final String subtitle;
  final double x; // Coordenada en px (sobre lienzo base 1400x900)
  final double y;
  final double width;
  final double height;
  final String colorHex;

  const DiagramExportZone({
    required this.id,
    required this.title,
    this.subtitle = '',
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.colorHex = '#3B82F6',
  });
}

class DiagramExportNode {
  final String id;
  final String code;
  final String name;
  final String ip;
  final String subtitle;
  final String modelName;
  final String serialNumber;
  final String status; // 'online' | 'offline' | 'warning' | 'unmonitored'
  final double x; // Coordenada en px (sobre lienzo base 1400x900)
  final double y;
  final double width;
  final double height;
  final String colorHex;

  const DiagramExportNode({
    required this.id,
    required this.code,
    required this.name,
    this.ip = '',
    this.subtitle = '',
    this.modelName = '',
    this.serialNumber = '',
    this.status = 'online',
    required this.x,
    required this.y,
    this.width = 210,
    this.height = 82,
    this.colorHex = '#1E293B',
  });
}

class DiagramExportEdge {
  final String id;
  final String sourceId;
  final String targetId;
  final String label;
  final String detail;
  final String colorHex;
  final bool dashed;

  const DiagramExportEdge({
    required this.id,
    required this.sourceId,
    required this.targetId,
    this.label = '',
    this.detail = '',
    this.colorHex = '#2563EB',
    this.dashed = false,
  });
}

class DiagramExportDocument {
  final String moduleName;
  final String title;
  final String subtitle;
  final String fileBaseName;
  final double canvasWidth;
  final double canvasHeight;
  final List<DiagramExportZone> zones;
  final List<DiagramExportNode> nodes;
  final List<DiagramExportEdge> edges;
  final GlobalKey? repaintBoundaryKey;

  const DiagramExportDocument({
    required this.moduleName,
    required this.title,
    this.subtitle = '',
    required this.fileBaseName,
    this.canvasWidth = 1400,
    this.canvasHeight = 900,
    this.zones = const [],
    required this.nodes,
    required this.edges,
    this.repaintBoundaryKey,
  });
}

/// Botón desplegable unificado "Exportar Esquema ▾" que permite al usuario elegir
/// en el momento cualquiera de los formatos (.dia, .drawio, .png, .svg, .pdf).
class DiagramExportMenuButton extends StatefulWidget {
  final DiagramExportDocument Function() documentBuilder;
  final bool compact;
  final bool darkStyle;

  const DiagramExportMenuButton({
    super.key,
    required this.documentBuilder,
    this.compact = false,
    this.darkStyle = false,
  });

  @override
  State<DiagramExportMenuButton> createState() =>
      _DiagramExportMenuButtonState();
}

class _DiagramExportMenuButtonState extends State<DiagramExportMenuButton> {
  bool _exporting = false;

  Future<void> _handleFormatSelection(String format) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final doc = widget.documentBuilder();
      final safeBase = doc.fileBaseName
          .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')
          .replaceAll(RegExp(r'_+'), '_');

      late Uint8List bytes;
      late String ext;
      late String mime;
      late String label;

      switch (format) {
        case 'dia':
          final xml = DiagramExporter.buildDiaXml(doc);
          bytes = Uint8List.fromList(utf8.encode(xml));
          ext = 'dia';
          mime = 'application/x-dia-diagram';
          label = 'GNOME Dia (.dia)';
          break;
        case 'drawio':
          final xml = DiagramExporter.buildDrawioXml(doc);
          bytes = Uint8List.fromList(utf8.encode(xml));
          ext = 'drawio';
          mime = 'application/vnd.jgraph.mxfile';
          label = 'Draw.io / diagrams.net (.drawio)';
          break;
        case 'svg':
          final svg = DiagramExporter.buildSvg(doc);
          bytes = Uint8List.fromList(utf8.encode(svg));
          ext = 'svg';
          mime = 'image/svg+xml';
          label = 'Vectorial Escalable (.svg)';
          break;
        case 'png':
          bytes = await DiagramExporter.buildPngBytes(doc);
          ext = 'png';
          mime = 'image/png';
          label = 'Imagen Alta Resolución (.png)';
          break;
        case 'pdf':
        default:
          bytes = DiagramExporter.buildPdfBytes(doc);
          ext = 'pdf';
          mime = 'application/pdf';
          label = 'Informe y Esquema Técnico (.pdf)';
          break;
      }

      final filename = '$safeBase.$ext';
      await downloadBytesAsFile(
        bytes: bytes,
        filename: filename,
        mimeType: mime,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppPalette.slate900,
            content: Text(
              '✓ Esquema exportado en formato $label: $filename (${doc.nodes.length} equipos, ${doc.edges.length} enlaces)',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppPalette.red600,
            content: Text('Error al exportar esquema: $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Exportar esquema de equipos y enlaces (.dia, .png, .pdf, .drawio, .svg)',
      onSelected: _handleFormatSelection,
      itemBuilder: (ctx) => [
        const PopupMenuItem<String>(
          enabled: false,
          height: 30,
          child: Text(
            'ELIGE FORMATO DE EXPORTACIÓN DEL ESQUEMA',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w900,
              color: AppPalette.slate500,
              letterSpacing: 0.4,
            ),
          ),
        ),
        const PopupMenuDivider(height: 6),
        PopupMenuItem<String>(
          value: 'dia',
          child: _buildMenuRow(
            icon: Icons.account_tree_outlined,
            color: const Color(0xFF0284C7),
            title: 'Formato .DIA (GNOME Dia XML)',
            subtitle: 'Cajas, capas y flujos conectados editables en Dia',
          ),
        ),
        PopupMenuItem<String>(
          value: 'png',
          child: _buildMenuRow(
            icon: Icons.image_outlined,
            color: const Color(0xFF16A34A),
            title: 'Imagen .PNG (Alta Resolución 2x)',
            subtitle: 'Captura nítida del esquema visual y sus conexiones',
          ),
        ),
        PopupMenuItem<String>(
          value: 'pdf',
          child: _buildMenuRow(
            icon: Icons.picture_as_pdf_outlined,
            color: const Color(0xFFDC2626),
            title: 'Documento .PDF (Esquema + Tabla Técnica)',
            subtitle: 'Plano A4 apaisado con cajetín, diagrama y matriz de enlaces',
          ),
        ),
        const PopupMenuDivider(height: 6),
        PopupMenuItem<String>(
          value: 'drawio',
          child: _buildMenuRow(
            icon: Icons.schema_outlined,
            color: const Color(0xFFD97706),
            title: 'Formato .DRAWIO (diagrams.net / Visio)',
            subtitle: 'Diagrama de bloques y conectores para Draw.io',
          ),
        ),
        PopupMenuItem<String>(
          value: 'svg',
          child: _buildMenuRow(
            icon: Icons.polyline_rounded,
            color: const Color(0xFF7C3AED),
            title: 'Vectorial .SVG (Zoom Infinito Web/CAD)',
            subtitle: 'Gráfico vectorial escalable sin pérdida de calidad',
          ),
        ),
      ],
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: widget.compact ? 9 : 11,
          vertical: widget.compact ? 5 : 6.5,
        ),
        decoration: BoxDecoration(
          color: widget.darkStyle
              ? AppPalette.slate800
              : const Color(0xFFEFF6FF),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: widget.darkStyle
                ? AppPalette.slate600
                : AppPalette.blue300,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_exporting)
              const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(
                Icons.ios_share_rounded,
                size: widget.compact ? 14 : 15,
                color: widget.darkStyle ? Colors.white : AppPalette.blue700,
              ),
            const SizedBox(width: 6),
            Text(
              'Exportar Esquema',
              style: TextStyle(
                fontSize: widget.compact ? 11 : 11.5,
                fontWeight: FontWeight.w800,
                color: widget.darkStyle ? Colors.white : AppPalette.blue900,
              ),
            ),
            const SizedBox(width: 3),
            Icon(
              Icons.arrow_drop_down_rounded,
              size: 17,
              color: widget.darkStyle ? Colors.white70 : AppPalette.blue700,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuRow({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
  }) {
    return Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(icon, size: 17, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppPalette.slate900,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 10.2,
                  color: AppPalette.slate500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class DiagramExporter {
  static String _escXml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static String _normHex(String hex, {String fallback = '#1E293B'}) {
    final clean = hex.trim().replaceAll('#', '');
    if (clean.length == 6) return '#${clean.toUpperCase()}';
    if (clean.length == 8) return '#${clean.substring(2).toUpperCase()}';
    return fallback;
  }

  // ===========================================================================
  // 1. EXPORTADOR FORMATO NATIVO GNOME DIA (.dia XML)
  // ===========================================================================
  static String buildDiaXml(DiagramExportDocument doc) {
    // En Dia 1 unidad equivale aproximadamente a 1 cm (~28 px)
    const double scale = 28.0;
    final sb = StringBuffer();
    sb.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    sb.writeln('<dia:diagram xmlns:dia="http://www.lysator.liu.se/~alla/dia/">');
    sb.writeln('  <dia:diagramdata>');
    sb.writeln('    <dia:attribute name="background">');
    sb.writeln('      <dia:color val="#ffffff"/>');
    sb.writeln('    </dia:attribute>');
    sb.writeln('    <dia:attribute name="paper">');
    sb.writeln('      <dia:composite type="paper">');
    sb.writeln('        <dia:attribute name="name"><dia:string>#A4#</dia:string></dia:attribute>');
    sb.writeln('        <dia:attribute name="is_portrait"><dia:boolean val="false"/></dia:attribute>');
    sb.writeln('      </dia:composite>');
    sb.writeln('    </dia:attribute>');
    sb.writeln('  </dia:diagramdata>');

    int objSeq = 0;
    final Map<String, String> nodeDiaIds = {};
    final Map<String, DiagramExportNode> nodeMap = {};

    // CAPA 1: Zonas / Salas / Bastidores
    if (doc.zones.isNotEmpty) {
      sb.writeln('  <dia:layer name="1. Zonas y Bastidores" visible="true" active="false">');
      for (final z in doc.zones) {
        final oid = 'Z${objSeq++}';
        final x = (z.x / scale).toStringAsFixed(2);
        final y = (z.y / scale).toStringAsFixed(2);
        final w = (z.width / scale).toStringAsFixed(2);
        final h = (z.height / scale).toStringAsFixed(2);
        final text = z.subtitle.isNotEmpty ? '${z.title}\n(${z.subtitle})' : z.title;
        sb.writeln('    <dia:object type="Flowchart - Box" version="0" id="$oid">');
        sb.writeln('      <dia:attribute name="obj_pos"><dia:point val="$x,$y"/></dia:attribute>');
        sb.writeln('      <dia:attribute name="elem_corner"><dia:point val="$x,$y"/></dia:attribute>');
        sb.writeln('      <dia:attribute name="elem_width"><dia:real val="$w"/></dia:attribute>');
        sb.writeln('      <dia:attribute name="elem_height"><dia:real val="$h"/></dia:attribute>');
        sb.writeln('      <dia:attribute name="border_width"><dia:real val="0.08"/></dia:attribute>');
        sb.writeln('      <dia:attribute name="border_color"><dia:color val="${_normHex(z.colorHex)}"/></dia:attribute>');
        sb.writeln('      <dia:attribute name="inner_color"><dia:color val="#F8FAFC"/></dia:attribute>');
        sb.writeln('      <dia:attribute name="show_background"><dia:boolean val="true"/></dia:attribute>');
        sb.writeln('      <dia:attribute name="text">');
        sb.writeln('        <dia:composite type="text">');
        sb.writeln('          <dia:attribute name="string"><dia:string>#${_escXml(text)}#</dia:string></dia:attribute>');
        sb.writeln('        </dia:composite>');
        sb.writeln('      </dia:attribute>');
        sb.writeln('    </dia:object>');
      }
      sb.writeln('  </dia:layer>');
    }

    // CAPA 2: Equipos / Dispositivos / Hosts
    sb.writeln('  <dia:layer name="2. Equipos y Nodos" visible="true" active="true">');
    for (final n in doc.nodes) {
      final oid = 'O${objSeq++}';
      nodeDiaIds[n.id] = oid;
      nodeMap[n.id] = n;

      final x = (n.x / scale).toStringAsFixed(2);
      final y = (n.y / scale).toStringAsFixed(2);
      final w = (n.width / scale).toStringAsFixed(2);
      final h = (n.height / scale).toStringAsFixed(2);

      final lines = <String>[
        '[${n.code}] ${n.name}',
        if (n.ip.isNotEmpty) 'IP: ${n.ip}',
        if (n.subtitle.isNotEmpty) n.subtitle,
        if (n.modelName.isNotEmpty || n.serialNumber.isNotEmpty)
          [
            if (n.modelName.isNotEmpty) 'Mod: ${n.modelName}',
            if (n.serialNumber.isNotEmpty) 'S/N: ${n.serialNumber}',
          ].join(' | '),
      ];

      final borderCol = n.status == 'online'
          ? '#16A34A'
          : (n.status == 'offline' ? '#DC2626' : _normHex(n.colorHex));

      sb.writeln('    <dia:object type="Flowchart - Box" version="0" id="$oid">');
      sb.writeln('      <dia:attribute name="obj_pos"><dia:point val="$x,$y"/></dia:attribute>');
      sb.writeln('      <dia:attribute name="elem_corner"><dia:point val="$x,$y"/></dia:attribute>');
      sb.writeln('      <dia:attribute name="elem_width"><dia:real val="$w"/></dia:attribute>');
      sb.writeln('      <dia:attribute name="elem_height"><dia:real val="$h"/></dia:attribute>');
      sb.writeln('      <dia:attribute name="border_width"><dia:real val="0.10"/></dia:attribute>');
      sb.writeln('      <dia:attribute name="border_color"><dia:color val="$borderCol"/></dia:attribute>');
      sb.writeln('      <dia:attribute name="inner_color"><dia:color val="#FFFFFF"/></dia:attribute>');
      sb.writeln('      <dia:attribute name="show_background"><dia:boolean val="true"/></dia:attribute>');
      sb.writeln('      <dia:attribute name="padding"><dia:real val="0.25"/></dia:attribute>');
      sb.writeln('      <dia:attribute name="text">');
      sb.writeln('        <dia:composite type="text">');
      sb.writeln('          <dia:attribute name="string"><dia:string>#${_escXml(lines.join('\n'))}#</dia:string></dia:attribute>');
      sb.writeln('          <dia:attribute name="height"><dia:real val="0.45"/></dia:attribute>');
      sb.writeln('        </dia:composite>');
      sb.writeln('      </dia:attribute>');
      sb.writeln('    </dia:object>');
    }
    sb.writeln('  </dia:layer>');

    // CAPA 3: Enlaces / Latiguillos / Flujos conectados a las cajas
    sb.writeln('  <dia:layer name="3. Enlaces y Flujos" visible="true" active="false">');
    for (final e in doc.edges) {
      final srcOid = nodeDiaIds[e.sourceId];
      final dstOid = nodeDiaIds[e.targetId];
      final srcNode = nodeMap[e.sourceId];
      final dstNode = nodeMap[e.targetId];
      if (srcOid == null || dstOid == null || srcNode == null || dstNode == null) {
        continue;
      }
      final edgeOid = 'E${objSeq++}';
      final x1 = ((srcNode.x + srcNode.width / 2) / scale).toStringAsFixed(2);
      final y1 = ((srcNode.y + srcNode.height / 2) / scale).toStringAsFixed(2);
      final x2 = ((dstNode.x + dstNode.width / 2) / scale).toStringAsFixed(2);
      final y2 = ((dstNode.y + dstNode.height / 2) / scale).toStringAsFixed(2);
      final midX = (((srcNode.x + dstNode.x) / 2) / scale).toStringAsFixed(2);

      sb.writeln('    <dia:object type="Standard - ZigZagLine" version="1" id="$edgeOid">');
      sb.writeln('      <dia:attribute name="obj_pos"><dia:point val="$x1,$y1"/></dia:attribute>');
      sb.writeln('      <dia:attribute name="orth_points">');
      sb.writeln('        <dia:point val="$x1,$y1"/>');
      sb.writeln('        <dia:point val="$midX,$y1"/>');
      sb.writeln('        <dia:point val="$midX,$y2"/>');
      sb.writeln('        <dia:point val="$x2,$y2"/>');
      sb.writeln('      </dia:attribute>');
      sb.writeln('      <dia:attribute name="line_color"><dia:color val="${_normHex(e.colorHex, fallback: '#2563EB')}"/></dia:attribute>');
      sb.writeln('      <dia:attribute name="line_width"><dia:real val="0.08"/></dia:attribute>');
      sb.writeln('      <dia:attribute name="end_arrow"><dia:enum val="22"/></dia:attribute>');
      sb.writeln('      <dia:connections>');
      sb.writeln('        <dia:connection handle="0" to="$srcOid" connection="8"/>');
      sb.writeln('        <dia:connection handle="1" to="$dstOid" connection="2"/>');
      sb.writeln('      </dia:connections>');
      sb.writeln('    </dia:object>');
    }
    sb.writeln('  </dia:layer>');
    sb.writeln('</dia:diagram>');
    return sb.toString();
  }

  // ===========================================================================
  // 2. EXPORTADOR FORMATO DRAW.IO / DIAGRAMS.NET (.drawio XML)
  // ===========================================================================
  static String buildDrawioXml(DiagramExportDocument doc) {
    final sb = StringBuffer();
    sb.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    sb.writeln('<mxfile host="RackDoc" modified="${DateTime.now().toIso8601String()}" version="21.0.0" type="device">');
    sb.writeln('  <diagram id="rackdoc-diag" name="${_escXml(doc.title)}">');
    sb.writeln('    <mxGraphModel dx="1420" dy="900" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="${doc.canvasWidth.round()}" pageHeight="${doc.canvasHeight.round()}">');
    sb.writeln('      <root>');
    sb.writeln('        <mxCell id="0"/>');
    sb.writeln('        <mxCell id="1" parent="0"/>');

    for (final z in doc.zones) {
      final col = _normHex(z.colorHex, fallback: '#3B82F6');
      final label = z.subtitle.isNotEmpty ? '<b>${_escXml(z.title)}</b><br/>${_escXml(z.subtitle)}' : '<b>${_escXml(z.title)}</b>';
      sb.writeln(
        '        <mxCell id="zone_${_escXml(z.id)}" value="$label" style="rounded=1;whiteSpace=wrap;html=1;verticalAlign=top;align=left;spacingLeft=10;fillColor=#F8FAFC;strokeColor=$col;strokeWidth=2;dashed=1;" vertex="1" parent="1">',
      );
      sb.writeln(
        '          <mxGeometry x="${z.x.round()}" y="${z.y.round()}" width="${z.width.round()}" height="${z.height.round()}" as="geometry"/>',
      );
      sb.writeln('        </mxCell>');
    }

    for (final n in doc.nodes) {
      final stroke = n.status == 'online'
          ? '#16A34A'
          : (n.status == 'offline' ? '#DC2626' : _normHex(n.colorHex));
      final htmlParts = <String>[
        '<b>[${_escXml(n.code)}] ${_escXml(n.name)}</b>',
        if (n.ip.isNotEmpty) '<font color="#1D4ED8">${_escXml(n.ip)}</font>',
        if (n.subtitle.isNotEmpty) _escXml(n.subtitle),
        if (n.modelName.isNotEmpty || n.serialNumber.isNotEmpty)
          '<font size="1">${_escXml([if (n.modelName.isNotEmpty) n.modelName, if (n.serialNumber.isNotEmpty) "S/N:${n.serialNumber}"].join(" • "))}</font>',
      ];
      sb.writeln(
        '        <mxCell id="node_${_escXml(n.id)}" value="${htmlParts.join('&lt;br/&gt;')}" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#FFFFFF;strokeColor=$stroke;strokeWidth=2;shadow=1;" vertex="1" parent="1">',
      );
      sb.writeln(
        '          <mxGeometry x="${n.x.round()}" y="${n.y.round()}" width="${n.width.round()}" height="${n.height.round()}" as="geometry"/>',
      );
      sb.writeln('        </mxCell>');
    }

    for (final e in doc.edges) {
      final col = _normHex(e.colorHex, fallback: '#2563EB');
      final dashStyle = e.dashed ? 'dashed=1;' : '';
      final lbl = _escXml(e.label.isNotEmpty ? e.label : e.detail);
      sb.writeln(
        '        <mxCell id="edge_${_escXml(e.id)}" value="$lbl" style="edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;jettySize=auto;html=1;strokeColor=$col;strokeWidth=2;$dashStyle" edge="1" parent="1" source="node_${_escXml(e.sourceId)}" target="node_${_escXml(e.targetId)}">',
      );
      sb.writeln('          <mxGeometry relative="1" as="geometry"/>');
      sb.writeln('        </mxCell>');
    }

    sb.writeln('      </root>');
    sb.writeln('    </mxGraphModel>');
    sb.writeln('  </diagram>');
    sb.writeln('</mxfile>');
    return sb.toString();
  }

  // ===========================================================================
  // 3. EXPORTADOR FORMATO VECTORIAL ESCALABLE (.svg)
  // ===========================================================================
  static String buildSvg(DiagramExportDocument doc) {
    final double w = math.max(doc.canvasWidth, 1280);
    final double h = math.max(doc.canvasHeight + 90, 860);
    final Map<String, DiagramExportNode> nodeMap = {
      for (final n in doc.nodes) n.id: n,
    };

    final sb = StringBuffer();
    sb.writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w.round()} ${h.round()}" width="${w.round()}" height="${h.round()}" font-family="Inter, -apple-system, BlinkMacSystemFont, Segoe UI, Roboto, sans-serif">',
    );
    sb.writeln('  <rect width="100%" height="100%" fill="#F8FAFC"/>');

    // Cabecera técnica superior
    sb.writeln('  <rect x="0" y="0" width="${w.round()}" height="68" fill="#0F172A"/>');
    sb.writeln(
      '  <text x="24" y="29" fill="#FFFFFF" font-size="17" font-weight="800">${_escXml(doc.moduleName)} — ${_escXml(doc.title)}</text>',
    );
    sb.writeln(
      '  <text x="24" y="50" fill="#94A3B8" font-size="12">${_escXml(doc.subtitle)} • Equipos: ${doc.nodes.length} • Enlaces: ${doc.edges.length} • Exportado: ${DateTime.now().toIso8601String().substring(0, 16).replaceFirst("T", " ")}</text>',
    );

    sb.writeln('  <g transform="translate(0, 74)">');

    // Zonas / Cajas
    for (final z in doc.zones) {
      final col = _normHex(z.colorHex, fallback: '#3B82F6');
      sb.writeln(
        '    <rect x="${z.x.toStringAsFixed(1)}" y="${z.y.toStringAsFixed(1)}" width="${z.width.toStringAsFixed(1)}" height="${z.height.toStringAsFixed(1)}" rx="10" fill="$col" fill-opacity="0.06" stroke="$col" stroke-width="1.8" stroke-dasharray="6,4"/>',
      );
      sb.writeln(
        '    <text x="${(z.x + 12).toStringAsFixed(1)}" y="${(z.y + 20).toStringAsFixed(1)}" fill="$col" font-size="12" font-weight="800">${_escXml(z.title)}${z.subtitle.isNotEmpty ? " (${_escXml(z.subtitle)})" : ""}</text>',
      );
    }

    // Enlaces (Curvas Bezier con etiqueta central)
    for (final e in doc.edges) {
      final s = nodeMap[e.sourceId];
      final t = nodeMap[e.targetId];
      if (s == null || t == null) continue;
      final x1 = s.x + s.width / 2;
      final y1 = s.y + s.height / 2;
      final x2 = t.x + t.width / 2;
      final y2 = t.y + t.height / 2;
      final cx1 = (x1 + x2) / 2;
      final cy1 = y1;
      final cx2 = (x1 + x2) / 2;
      final cy2 = y2;
      final col = _normHex(e.colorHex, fallback: '#2563EB');
      final dash = e.dashed ? ' stroke-dasharray="5,4"' : '';

      sb.writeln(
        '    <path d="M ${x1.toStringAsFixed(1)} ${y1.toStringAsFixed(1)} C ${cx1.toStringAsFixed(1)} ${cy1.toStringAsFixed(1)}, ${cx2.toStringAsFixed(1)} ${cy2.toStringAsFixed(1)}, ${x2.toStringAsFixed(1)} ${y2.toStringAsFixed(1)}" fill="none" stroke="$col" stroke-width="2.2"$dash/>',
      );
      if (e.label.isNotEmpty) {
        final mx = (x1 + x2) / 2;
        final my = (y1 + y2) / 2;
        final lw = math.max(54.0, e.label.length * 6.2 + 14);
        sb.writeln(
          '    <rect x="${(mx - lw / 2).toStringAsFixed(1)}" y="${(my - 10).toStringAsFixed(1)}" width="${lw.toStringAsFixed(1)}" height="18" rx="5" fill="#FFFFFF" stroke="$col" stroke-width="1"/>',
        );
        sb.writeln(
          '    <text x="${mx.toStringAsFixed(1)}" y="${(my + 2.5).toStringAsFixed(1)}" text-anchor="middle" fill="#0F172A" font-size="9.5" font-weight="700">${_escXml(e.label)}</text>',
        );
      }
    }

    // Nodos / Equipos
    for (final n in doc.nodes) {
      final isOnline = n.status == 'online';
      final isOffline = n.status == 'offline';
      final dotCol = isOnline ? '#16A34A' : (isOffline ? '#DC2626' : '#94A3B8');
      final borderCol = _normHex(n.colorHex, fallback: '#334155');
      sb.writeln(
        '    <rect x="${n.x.toStringAsFixed(1)}" y="${n.y.toStringAsFixed(1)}" width="${n.width.toStringAsFixed(1)}" height="${n.height.toStringAsFixed(1)}" rx="8" fill="#FFFFFF" stroke="$borderCol" stroke-width="1.8"/>',
      );
      sb.writeln(
        '    <circle cx="${(n.x + 13).toStringAsFixed(1)}" cy="${(n.y + 17).toStringAsFixed(1)}" r="4.5" fill="$dotCol"/>',
      );
      sb.writeln(
        '    <text x="${(n.x + 23).toStringAsFixed(1)}" y="${(n.y + 20).toStringAsFixed(1)}" fill="#0F172A" font-size="11.5" font-weight="800">[${_escXml(n.code)}] ${_escXml(n.name.length > 24 ? "${n.name.substring(0, 24)}…" : n.name)}</text>',
      );
      if (n.ip.isNotEmpty || n.subtitle.isNotEmpty) {
        final line2 = [
          if (n.ip.isNotEmpty) n.ip,
          if (n.subtitle.isNotEmpty) n.subtitle,
        ].join(' • ');
        sb.writeln(
          '    <text x="${(n.x + 12).toStringAsFixed(1)}" y="${(n.y + 38).toStringAsFixed(1)}" fill="#1D4ED8" font-size="10.2" font-family="monospace" font-weight="700">${_escXml(line2.length > 34 ? "${line2.substring(0, 34)}…" : line2)}</text>',
        );
      }
      if (n.modelName.isNotEmpty || n.serialNumber.isNotEmpty) {
        final line3 = [
          if (n.modelName.isNotEmpty) n.modelName,
          if (n.serialNumber.isNotEmpty) 'S/N: ${n.serialNumber}',
        ].join(' | ');
        sb.writeln(
          '    <text x="${(n.x + 12).toStringAsFixed(1)}" y="${(n.y + 54).toStringAsFixed(1)}" fill="#475569" font-size="9.5">${_escXml(line3.length > 36 ? "${line3.substring(0, 36)}…" : line3)}</text>',
        );
      }
    }

    sb.writeln('  </g>');
    sb.writeln('</svg>');
    return sb.toString();
  }

  // ===========================================================================
  // 4. EXPORTADOR IMAGEN ALTA RESOLUCIÓN (.png)
  // ===========================================================================
  static Future<Uint8List> buildPngBytes(DiagramExportDocument doc) async {
    // Si la vista proporcionó un RepaintBoundary montado, capturamos el widget en vivo a 2x
    final key = doc.repaintBoundaryKey;
    if (key != null && key.currentContext != null) {
      final renderObj = key.currentContext!.findRenderObject();
      if (renderObj is RenderRepaintBoundary) {
        final image = await renderObj.toImage(pixelRatio: 2.0);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        if (byteData != null) {
          return byteData.buffer.asUint8List();
        }
      }
    }

    // Renderizado directo en Canvas 2x de alta nitidez (funciona siempre, incluso sin RepaintBoundary)
    final double w = math.max(doc.canvasWidth, 1360);
    final double h = math.max(doc.canvasHeight + 90, 880);
    const double scale = 2.0;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(scale, scale);

    // Fondo general
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, h),
      Paint()..color = const Color(0xFFF8FAFC),
    );

    // Cabecera oscura
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w, 68),
      Paint()..color = const Color(0xFF0F172A),
    );
    _drawCanvasText(
      canvas,
      '${doc.moduleName} — ${doc.title}',
      const Offset(22, 16),
      fontSize: 16,
      fontWeight: FontWeight.w900,
      color: Colors.white,
      maxWidth: w - 44,
    );
    _drawCanvasText(
      canvas,
      '${doc.subtitle} • Equipos: ${doc.nodes.length} • Enlaces: ${doc.edges.length}',
      const Offset(22, 41),
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
      color: const Color(0xFF94A3B8),
      maxWidth: w - 44,
    );

    canvas.save();
    canvas.translate(0, 74);

    // Zonas
    for (final z in doc.zones) {
      final col = _parseColor(z.colorHex, const Color(0xFF3B82F6));
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(z.x, z.y, z.width, z.height),
        const Radius.circular(10),
      );
      canvas.drawRRect(rrect, Paint()..color = col.withValues(alpha: 0.07));
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = col.withValues(alpha: 0.65)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
      _drawCanvasText(
        canvas,
        z.subtitle.isNotEmpty ? '${z.title} (${z.subtitle})' : z.title,
        Offset(z.x + 10, z.y + 8),
        fontSize: 11.5,
        fontWeight: FontWeight.w800,
        color: col,
        maxWidth: z.width - 20,
      );
    }

    final nodeMap = {for (final n in doc.nodes) n.id: n};

    // Enlaces
    for (final e in doc.edges) {
      final s = nodeMap[e.sourceId];
      final t = nodeMap[e.targetId];
      if (s == null || t == null) continue;
      final p1 = Offset(s.x + s.width / 2, s.y + s.height / 2);
      final p2 = Offset(t.x + t.width / 2, t.y + t.height / 2);
      final col = _parseColor(e.colorHex, const Color(0xFF2563EB));
      final path = Path()
        ..moveTo(p1.dx, p1.dy)
        ..cubicTo((p1.dx + p2.dx) / 2, p1.dy, (p1.dx + p2.dx) / 2, p2.dy, p2.dx, p2.dy);
      canvas.drawPath(
        path,
        Paint()
          ..color = col
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2,
      );
      if (e.label.isNotEmpty) {
        final mid = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
        final pillW = math.max(58.0, e.label.length * 6.0 + 14);
        final pillRect = RRect.fromRectAndRadius(
          Rect.fromCenter(center: mid, width: pillW, height: 18),
          const Radius.circular(5),
        );
        canvas.drawRRect(pillRect, Paint()..color = Colors.white);
        canvas.drawRRect(
          pillRect,
          Paint()
            ..color = col
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.1,
        );
        _drawCanvasText(
          canvas,
          e.label,
          Offset(mid.dx - pillW / 2 + 5, mid.dy - 6),
          fontSize: 9.2,
          fontWeight: FontWeight.w800,
          color: const Color(0xFF0F172A),
          maxWidth: pillW - 10,
        );
      }
    }

    // Nodos
    for (final n in doc.nodes) {
      final rect = Rect.fromLTWH(n.x, n.y, n.width, n.height);
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(8));
      final borderCol = _parseColor(n.colorHex, const Color(0xFF334155));
      canvas.drawRRect(rrect, Paint()..color = Colors.white);
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = borderCol
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8,
      );

      final dotCol = n.status == 'online'
          ? const Color(0xFF16A34A)
          : (n.status == 'offline'
                ? const Color(0xFFDC2626)
                : const Color(0xFF94A3B8));
      canvas.drawCircle(Offset(n.x + 12, n.y + 15), 4.5, Paint()..color = dotCol);

      _drawCanvasText(
        canvas,
        '[${n.code}] ${n.name}',
        Offset(n.x + 21, n.y + 8),
        fontSize: 11,
        fontWeight: FontWeight.w800,
        color: const Color(0xFF0F172A),
        maxWidth: n.width - 26,
      );
      if (n.ip.isNotEmpty || n.subtitle.isNotEmpty) {
        _drawCanvasText(
          canvas,
          [if (n.ip.isNotEmpty) n.ip, if (n.subtitle.isNotEmpty) n.subtitle].join(' • '),
          Offset(n.x + 10, n.y + 26),
          fontSize: 9.8,
          fontWeight: FontWeight.w700,
          color: const Color(0xFF1D4ED8),
          maxWidth: n.width - 18,
        );
      }
      if (n.modelName.isNotEmpty || n.serialNumber.isNotEmpty) {
        _drawCanvasText(
          canvas,
          [
            if (n.modelName.isNotEmpty) n.modelName,
            if (n.serialNumber.isNotEmpty) 'S/N:${n.serialNumber}',
          ].join(' | '),
          Offset(n.x + 10, n.y + 42),
          fontSize: 9.0,
          fontWeight: FontWeight.w600,
          color: const Color(0xFF475569),
          maxWidth: n.width - 18,
        );
      }
    }

    canvas.restore();
    final picture = recorder.endRecording();
    final img = await picture.toImage((w * scale).round(), (h * scale).round());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  static void _drawCanvasText(
    Canvas canvas,
    String text,
    Offset offset, {
    required double fontSize,
    required FontWeight fontWeight,
    required Color color,
    required double maxWidth,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: color,
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(20, maxWidth));
    tp.paint(canvas, offset);
  }

  static Color _parseColor(String hex, Color fallback) {
    final clean = hex.trim().replaceAll('#', '');
    if (clean.length == 6) {
      final v = int.tryParse('FF$clean', radix: 16);
      if (v != null) return Color(v);
    }
    return fallback;
  }

  // ===========================================================================
  // 5. EXPORTADOR DOCUMENTO PDF TÉCNICO A4 APAISADO (.pdf)
  // ===========================================================================
  static Uint8List buildPdfBytes(DiagramExportDocument doc) {
    // Genera un PDF 1.4 vectorial A4 Apaisado (842 x 595 pt) con:
    // - Página 1: Cajetín técnico + Esquema visual de Cajas y Enlaces
    // - Página 2 (si hay enlaces/equipos): Listado técnico de Equipos (Modelo, S/N, IP) y Enlaces
    const double pageW = 842.0;
    const double pageH = 595.0;

    final double scaleX = (pageW - 60) / math.max(doc.canvasWidth, 1200);
    final double scaleY = (pageH - 130) / math.max(doc.canvasHeight, 780);
    final double s = math.min(scaleX, scaleY);

    double tx(double x) => 30.0 + x * s;
    double ty(double y) => pageH - 85.0 - y * s;

    final p1 = StringBuffer();
    // Cabecera PDF Página 1
    p1.writeln('0.06 0.09 0.16 rg');
    p1.writeln('20 ${pageH - 65} ${pageW - 40} 46 re f');
    p1.writeln('BT /F1 13 Tf 1 1 1 rg 32 ${pageH - 40} Td (${_pdfStr('${doc.moduleName} - ${doc.title}')}) Tj ET');
    p1.writeln(
      'BT /F1 8.5 Tf 0.75 0.82 0.90 rg 32 ${pageH - 55} Td (${_pdfStr('${doc.subtitle} | Equipos: ${doc.nodes.length} | Enlaces: ${doc.edges.length} | Fecha: ${DateTime.now().toIso8601String().substring(0, 16).replaceFirst("T", " ")}')}) Tj ET',
    );

    // Marco del lienzo
    p1.writeln('0.85 0.88 0.92 RG 1 w');
    p1.writeln('20 20 ${pageW - 40} ${pageH - 92} re S');

    // Zonas
    for (final z in doc.zones) {
      final zx = tx(z.x);
      final zy = ty(z.y + z.height);
      final zw = z.width * s;
      final zh = z.height * s;
      p1.writeln('0.96 0.98 1.0 rg 0.23 0.51 0.96 RG 0.8 w');
      p1.writeln('${zx.toStringAsFixed(1)} ${zy.toStringAsFixed(1)} ${zw.toStringAsFixed(1)} ${zh.toStringAsFixed(1)} re B');
      p1.writeln(
        'BT /F1 7.5 Tf 0.12 0.25 0.68 rg ${(zx + 5).toStringAsFixed(1)} ${(zy + zh - 11).toStringAsFixed(1)} Td (${_pdfStr(z.title)}) Tj ET',
      );
    }

    final nodeMap = {for (final n in doc.nodes) n.id: n};

    // Enlaces
    for (final e in doc.edges) {
      final src = nodeMap[e.sourceId];
      final dst = nodeMap[e.targetId];
      if (src == null || dst == null) continue;
      final x1 = tx(src.x + src.width / 2);
      final y1 = ty(src.y + src.height / 2);
      final x2 = tx(dst.x + dst.width / 2);
      final y2 = ty(dst.y + dst.height / 2);
      p1.writeln('0.15 0.39 0.92 RG 1.2 w');
      p1.writeln('${x1.toStringAsFixed(1)} ${y1.toStringAsFixed(1)} m ${x2.toStringAsFixed(1)} ${y2.toStringAsFixed(1)} l S');
      if (e.label.isNotEmpty) {
        final mx = (x1 + x2) / 2;
        final my = (y1 + y2) / 2;
        p1.writeln(
          'BT /F1 6.2 Tf 0.10 0.25 0.60 rg ${(mx - 18).toStringAsFixed(1)} ${(my + 2).toStringAsFixed(1)} Td (${_pdfStr(e.label)}) Tj ET',
        );
      }
    }

    // Nodos
    for (final n in doc.nodes) {
      final nx = tx(n.x);
      final ny = ty(n.y + n.height);
      final nw = math.max(68.0, n.width * s);
      final nh = math.max(26.0, n.height * s);
      p1.writeln('1 1 1 rg 0.20 0.25 0.33 RG 1 w');
      p1.writeln('${nx.toStringAsFixed(1)} ${ny.toStringAsFixed(1)} ${nw.toStringAsFixed(1)} ${nh.toStringAsFixed(1)} re B');
      p1.writeln(
        'BT /F1 6.8 Tf 0.06 0.09 0.16 rg ${(nx + 4).toStringAsFixed(1)} ${(ny + nh - 9).toStringAsFixed(1)} Td (${_pdfStr('[${n.code}] ${n.name}')}) Tj ET',
      );
      if (n.ip.isNotEmpty) {
        p1.writeln(
          'BT /F1 6.0 Tf 0.11 0.30 0.84 rg ${(nx + 4).toStringAsFixed(1)} ${(ny + nh - 17).toStringAsFixed(1)} Td (${_pdfStr('IP: ${n.ip}${n.modelName.isNotEmpty ? " | ${n.modelName}" : ""}')}) Tj ET',
        );
      }
      if (n.serialNumber.isNotEmpty && nh >= 30) {
        p1.writeln(
          'BT /F1 5.6 Tf 0.35 0.40 0.48 rg ${(nx + 4).toStringAsFixed(1)} ${(ny + nh - 24).toStringAsFixed(1)} Td (${_pdfStr('S/N: ${n.serialNumber}')}) Tj ET',
        );
      }
    }

    // Página 2: Tabla técnica de Inventario del Esquema y Matriz de Enlaces
    final p2 = StringBuffer();
    p2.writeln('0.06 0.09 0.16 rg');
    p2.writeln('20 ${pageH - 55} ${pageW - 40} 36 re f');
    p2.writeln(
      'BT /F1 11.5 Tf 1 1 1 rg 32 ${pageH - 41} Td (${_pdfStr('ANEXO TECNICO: INVENTARIO DE EQUIPOS (MODELO / S/N) Y MATRIZ DE ENLACES - ${doc.title}')}) Tj ET',
    );

    double curY = pageH - 75;
    p2.writeln('BT /F1 9 Tf 0.06 0.09 0.16 rg 24 $curY Td (${_pdfStr('1. EQUIPOS EN EL ESQUEMA (${doc.nodes.length}):')}) Tj ET');
    curY -= 14;
    for (final n in doc.nodes.take(22)) {
      final rowTxt =
          '[${n.code}] ${n.name}  |  IP: ${n.ip.isEmpty ? "-" : n.ip}  |  Modelo: ${n.modelName.isEmpty ? "-" : n.modelName}  |  S/N: ${n.serialNumber.isEmpty ? "-" : n.serialNumber}  |  Estado: ${n.status.toUpperCase()}';
      p2.writeln('BT /F1 7.3 Tf 0.15 0.20 0.28 rg 28 $curY Td (${_pdfStr(rowTxt)}) Tj ET');
      curY -= 11;
    }

    curY -= 8;
    if (curY > 60 && doc.edges.isNotEmpty) {
      p2.writeln('BT /F1 9 Tf 0.06 0.09 0.16 rg 24 $curY Td (${_pdfStr('2. CONEXIONES Y FLUJO DE ENLACES (${doc.edges.length}):')}) Tj ET');
      curY -= 14;
      for (final e in doc.edges.take(18)) {
        final sCode = nodeMap[e.sourceId]?.code ?? e.sourceId;
        final tCode = nodeMap[e.targetId]?.code ?? e.targetId;
        final edgeTxt = '$sCode  --->  $tCode   |   ${e.label} ${e.detail.isNotEmpty ? "(${e.detail})" : ""}';
        p2.writeln('BT /F1 7.3 Tf 0.11 0.30 0.78 rg 28 $curY Td (${_pdfStr(edgeTxt)}) Tj ET');
        curY -= 11;
        if (curY < 30) break;
      }
    }

    return _assemblePdfDocument([p1.toString(), p2.toString()], pageW, pageH);
  }

  static String _pdfStr(String input) {
    final ascii = input
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('Á', 'A')
        .replaceAll('É', 'E')
        .replaceAll('Í', 'I')
        .replaceAll('Ó', 'O')
        .replaceAll('Ú', 'U')
        .replaceAll('ñ', 'n')
        .replaceAll('Ñ', 'N')
        .replaceAll('•', '|')
        .replaceAll('—', '-')
        .replaceAll('➔', '->')
        .replaceAll('⇄', '<->')
        .replaceAll(RegExp(r'[^\x20-\x7E]'), '');
    final trimmed = ascii.length > 135 ? '${ascii.substring(0, 132)}...' : ascii;
    return trimmed
        .replaceAll(r'\', r'\\')
        .replaceAll('(', r'\(')
        .replaceAll(')', r'\)');
  }

  static Uint8List _assemblePdfDocument(
    List<String> pageStreams,
    double pageW,
    double pageH,
  ) {
    final objects = <String>[];
    // Obj 1: Catalog
    objects.add('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
    // Obj 2: Pages (reservado, se rellena abajo)
    objects.add('');
    // Obj 3: Font Helvetica
    objects.add(
      '3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n',
    );

    final pageObjIds = <int>[];
    int nextId = 4;
    for (final stream in pageStreams) {
      final pageId = nextId++;
      final contentId = nextId++;
      pageObjIds.add(pageId);
      final streamBytes = latin1.encode(stream);
      objects.add(
        '$pageId 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${pageW.round()} ${pageH.round()}] /Resources << /Font << /F1 3 0 R >> >> /Contents $contentId 0 R >>\nendobj\n',
      );
      objects.add(
        '$contentId 0 obj\n<< /Length ${streamBytes.length} >>\nstream\n$stream\nendstream\nendobj\n',
      );
    }

    final kids = pageObjIds.map((id) => '$id 0 R').join(' ');
    objects[1] =
        '2 0 obj\n<< /Type /Pages /Kids [$kids] /Count ${pageObjIds.length} >>\nendobj\n';

    final out = StringBuffer();
    out.write('%PDF-1.4\n');
    final offsets = <int>[];
    for (final obj in objects) {
      offsets.add(out.toString().length);
      out.write(obj);
    }
    final xrefStart = out.toString().length;
    out.write('xref\n0 ${objects.length + 1}\n');
    out.write('0000000000 65535 f \n');
    for (final off in offsets) {
      out.write('${off.toString().padLeft(10, '0')} 00000 n \n');
    }
    out.write(
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xrefStart\n%%EOF\n',
    );
    return Uint8List.fromList(latin1.encode(out.toString()));
  }
}
