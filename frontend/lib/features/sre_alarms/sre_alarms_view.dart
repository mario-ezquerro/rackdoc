import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../network_hosts/network_hosts_view.dart';

/// Vista principal del módulo **`8. Alarmas SRE`**.
///
/// Proporciona un punto de entrada explícito e independiente para el centro de
/// operaciones SRE de RackDoc, estructurado en cuatro pestañas:
/// 1. **Estado de Dispositivos & Alarmas en Vivo** (priorización por severidad,
///    antigüedad de alarma y saltos directos a los 7 módulos del DCIM).
/// 2. **Avisos, Contactos AD/Local & Matriz de 5 Columnas** (arrastrar y soltar
///    grupos de hosts, grupos de guardia y usuarios conocidos + mantenimientos).
/// 3. **Objetivos SLO / Error Budgets & Políticas SRE**.
/// 4. **Centro de Automatización Ansible, API REST (`cURL` / `Puppet`) & IA**.
class SreAlarmsView extends StatelessWidget {
  final RackDocApiClient api;
  final bool canEdit;
  final int initialTabIndex;
  final void Function(int? locationId)? onNavigateToLocation;
  final void Function(int? locationId, int? floorId, int? floorDeviceId)?
      onNavigateToFloorDevice;
  final void Function(int rackId, int? deviceId)? onNavigateToRackDevice;
  final void Function(int? assetId, int? stackId, int? stackNodeId)?
      onNavigateToNetworkHost;
  final void Function(int? rackId)? onNavigateToDashboard;
  final void Function(String? assetCode)? onNavigateToCmdb;
  final void Function(String? hostCodeOrIp)? onNavigateToCertScope;

  const SreAlarmsView({
    super.key,
    required this.api,
    this.canEdit = true,
    this.initialTabIndex = 0,
    this.onNavigateToLocation,
    this.onNavigateToFloorDevice,
    this.onNavigateToRackDevice,
    this.onNavigateToNetworkHost,
    this.onNavigateToDashboard,
    this.onNavigateToCmdb,
    this.onNavigateToCertScope,
  });

  @override
  Widget build(BuildContext context) {
    return NetworkHostsView(
      api: api,
      canEdit: canEdit,
      isSreAlarmsMode: true,
      initialSreTabIndex: initialTabIndex,
      onNavigateToLocation: onNavigateToLocation,
      onNavigateToFloorDevice: onNavigateToFloorDevice,
      onNavigateToRackDevice: onNavigateToRackDevice,
      onNavigateToNetworkHost: onNavigateToNetworkHost,
      onNavigateToDashboard: onNavigateToDashboard,
      onNavigateToCmdb: onNavigateToCmdb,
      onNavigateToCertScope: onNavigateToCertScope,
    );
  }
}
