class AisleNode {
  final int id;
  final String code;
  final String name;
  final String aisleType;

  AisleNode({
    required this.id,
    required this.code,
    required this.name,
    required this.aisleType,
  });

  factory AisleNode.fromJson(Map<String, dynamic> json) {
    return AisleNode(
      id: json['id'] as int,
      code: (json['code'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      aisleType: (json['aisle_type'] ?? 'cold') as String,
    );
  }
}

class RackSummary {
  final int id;
  final String code;
  final String name;
  final int totalUnits;
  final String manufacturer;
  final String modelName;
  final String responsiblePerson;
  final int? aisleId;
  final String aisleName;
  final String aisleType;
  final double posX;
  final double posY;
  final double widthPx;
  final double depthPx;
  final int rotationDeg;
  final int deviceCount;
  final int monitoredCount;
  final int onlineCount;
  final int offlineCount;
  final int warningCount;
  final List<Map<String, dynamic>> monitoredDevices;

  RackSummary({
    required this.id,
    required this.code,
    required this.name,
    required this.totalUnits,
    required this.manufacturer,
    required this.modelName,
    required this.responsiblePerson,
    this.aisleId,
    required this.aisleName,
    required this.aisleType,
    required this.posX,
    required this.posY,
    required this.widthPx,
    required this.depthPx,
    required this.rotationDeg,
    required this.deviceCount,
    this.monitoredCount = 0,
    this.onlineCount = 0,
    this.offlineCount = 0,
    this.warningCount = 0,
    this.monitoredDevices = const [],
  });

  factory RackSummary.fromJson(Map<String, dynamic> json) {
    return RackSummary(
      id: json['id'] as int,
      code: (json['code'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      totalUnits: (json['total_units'] ?? 42) as int,
      manufacturer: (json['manufacturer'] ?? '') as String,
      modelName: (json['model_name'] ?? '') as String,
      responsiblePerson: (json['responsible_person'] ?? '') as String,
      aisleId: json['aisle_id'] as int?,
      aisleName: (json['aisle_name'] ?? 'General') as String,
      aisleType: (json['aisle_type'] ?? 'standard') as String,
      posX: ((json['pos_x'] ?? 0.25) as num).toDouble(),
      posY: ((json['pos_y'] ?? 0.35) as num).toDouble(),
      widthPx: ((json['width_px'] ?? 110.0) as num).toDouble(),
      depthPx: ((json['depth_px'] ?? 86.0) as num).toDouble(),
      rotationDeg: (json['rotation_deg'] ?? 0) as int,
      deviceCount: (json['device_count'] ?? 0) as int,
      monitoredCount: (json['monitored_count'] ?? 0) as int,
      onlineCount: (json['online_count'] ?? 0) as int,
      offlineCount: (json['offline_count'] ?? 0) as int,
      warningCount: (json['warning_count'] ?? 0) as int,
      monitoredDevices: ((json['monitored_devices'] ?? []) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
    );
  }
}

class RoomNode {
  final int id;
  final String name;
  final double widthM;
  final double depthM;
  final String mapImageUrl;
  final List<AisleNode> aisles;
  final List<RackSummary> racks;

  RoomNode({
    required this.id,
    required this.name,
    required this.widthM,
    required this.depthM,
    required this.mapImageUrl,
    required this.aisles,
    required this.racks,
  });

  factory RoomNode.fromJson(Map<String, dynamic> json) {
    return RoomNode(
      id: json['id'] as int,
      name: (json['name'] ?? '') as String,
      widthM: ((json['width_m'] ?? 10.0) as num).toDouble(),
      depthM: ((json['depth_m'] ?? 8.0) as num).toDouble(),
      mapImageUrl: (json['map_image_url'] ?? '') as String,
      aisles: ((json['aisles'] ?? []) as List)
          .map((e) => AisleNode.fromJson(e as Map<String, dynamic>))
          .toList(),
      racks: ((json['racks'] ?? []) as List)
          .map((e) => RackSummary.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class FloorNode {
  final int id;
  final String name;
  final int levelNumber;
  final String mapImageUrl;
  final double mapScale;
  final int monitoredCount;
  final int onlineCount;
  final int offlineCount;
  final int warningCount;
  final List<RoomNode> rooms;

  FloorNode({
    required this.id,
    required this.name,
    required this.levelNumber,
    required this.mapImageUrl,
    required this.mapScale,
    this.monitoredCount = 0,
    this.onlineCount = 0,
    this.offlineCount = 0,
    this.warningCount = 0,
    required this.rooms,
  });

  factory FloorNode.fromJson(Map<String, dynamic> json) {
    return FloorNode(
      id: json['id'] as int,
      name: (json['name'] ?? '') as String,
      levelNumber: (json['level_number'] ?? 1) as int,
      mapImageUrl: (json['map_image_url'] ?? '') as String,
      mapScale: ((json['map_scale'] ?? 1.0) as num).toDouble(),
      monitoredCount: (json['monitored_count'] ?? 0) as int,
      onlineCount: (json['online_count'] ?? 0) as int,
      offlineCount: (json['offline_count'] ?? 0) as int,
      warningCount: (json['warning_count'] ?? 0) as int,
      rooms: ((json['rooms'] ?? []) as List)
          .map((e) => RoomNode.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class LocationNode {
  final int id;
  final String code;
  final String name;
  final double latitude;
  final double longitude;
  final String address;
  final String description;
  final String mapImageUrl;
  final double planPosX;
  final double planPosY;
  final double planWidth;
  final double planHeight;
  final double mapScale;
  final int floorsCount;
  final int roomsCount;
  final int racksCount;
  final int totalRackUnits;
  final int monitoredCount;
  final int onlineCount;
  final int offlineCount;
  final int warningCount;
  final List<FloorNode> floors;

  LocationNode({
    required this.id,
    required this.code,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.address,
    required this.description,
    required this.mapImageUrl,
    required this.planPosX,
    required this.planPosY,
    required this.planWidth,
    required this.planHeight,
    required this.mapScale,
    required this.floorsCount,
    required this.roomsCount,
    required this.racksCount,
    required this.totalRackUnits,
    this.monitoredCount = 0,
    this.onlineCount = 0,
    this.offlineCount = 0,
    this.warningCount = 0,
    required this.floors,
  });

  factory LocationNode.fromJson(Map<String, dynamic> json) {
    return LocationNode(
      id: json['id'] as int,
      code: (json['code'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      latitude: ((json['latitude'] ?? 48.2082) as num).toDouble(),
      longitude: ((json['longitude'] ?? 16.3738) as num).toDouble(),
      address: (json['address'] ?? '') as String,
      description: (json['description'] ?? '') as String,
      mapImageUrl: (json['map_image_url'] ?? '') as String,
      planPosX: ((json['plan_pos_x'] ?? 0.25) as num).toDouble(),
      planPosY: ((json['plan_pos_y'] ?? 0.35) as num).toDouble(),
      planWidth: ((json['plan_width'] ?? 160.0) as num).toDouble(),
      planHeight: ((json['plan_height'] ?? 90.0) as num).toDouble(),
      mapScale: ((json['map_scale'] ?? 1.0) as num).toDouble(),
      floorsCount: (json['floors_count'] ?? 0) as int,
      roomsCount: (json['rooms_count'] ?? 0) as int,
      racksCount: (json['racks_count'] ?? 0) as int,
      totalRackUnits: (json['total_rack_units'] ?? 0) as int,
      monitoredCount: (json['monitored_count'] ?? 0) as int,
      onlineCount: (json['online_count'] ?? 0) as int,
      offlineCount: (json['offline_count'] ?? 0) as int,
      warningCount: (json['warning_count'] ?? 0) as int,
      floors: ((json['floors'] ?? []) as List)
          .map((e) => FloorNode.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class DeviceTemplateModel {
  final int id;
  final String category;
  final String libraryGroup;
  final String manufacturer;
  final String modelName;
  final int uHeight;
  final bool isFullDepth;
  final String defaultColor;
  final Map<String, dynamic> layoutSpec;

  DeviceTemplateModel({
    required this.id,
    required this.category,
    required this.libraryGroup,
    required this.manufacturer,
    required this.modelName,
    required this.uHeight,
    required this.isFullDepth,
    required this.defaultColor,
    required this.layoutSpec,
  });

  factory DeviceTemplateModel.fromJson(Map<String, dynamic> json) {
    return DeviceTemplateModel(
      id: json['id'] as int,
      category: (json['category'] ?? 'miscellaneous') as String,
      libraryGroup: (json['library_group'] ?? 'General') as String,
      manufacturer: (json['manufacturer'] ?? 'Generic') as String,
      modelName: (json['model_name'] ?? '') as String,
      uHeight: (json['u_height'] ?? 1) as int,
      isFullDepth: (json['is_full_depth'] ?? false) as bool,
      defaultColor: (json['default_color'] ?? '#F8FAFC') as String,
      layoutSpec: Map<String, dynamic>.from((json['layout_spec'] ?? {}) as Map),
    );
  }

  String get photoUrl => (layoutSpec['photo_url'] ?? '').toString().trim();

  bool get isAdjustableU =>
      (layoutSpec['adjustable_u'] == true) ||
      category == 'rack_tray' ||
      category == 'miscellaneous';

  bool get isRoofFan =>
      (layoutSpec['device_subtype'] ?? '') == 'roof_fan' ||
      modelName.toLowerCase().contains('ventilador');

  Map<String, dynamic> toJson() => {
        'id': id,
        'category': category,
        'library_group': libraryGroup,
        'manufacturer': manufacturer,
        'model_name': modelName,
        'u_height': uHeight,
        'is_full_depth': isFullDepth,
        'default_color': defaultColor,
        'layout_spec': layoutSpec,
      };
}

class PortModel {
  final int id;
  final int rackDeviceId;
  final String portNumber;
  final String label;
  final String face; // 'front' | 'back'
  final String portType;
  final int rowIndex;
  final int colIndex;
  final double relX;
  final double relY;

  PortModel({
    required this.id,
    required this.rackDeviceId,
    required this.portNumber,
    required this.label,
    required this.face,
    required this.portType,
    required this.rowIndex,
    required this.colIndex,
    required this.relX,
    required this.relY,
  });

  factory PortModel.fromJson(Map<String, dynamic> json) {
    return PortModel(
      id: json['id'] as int,
      rackDeviceId: json['rack_device_id'] as int,
      portNumber: (json['port_number'] ?? '') as String,
      label: (json['label'] ?? '') as String,
      face: (json['face'] ?? 'front') as String,
      portType: (json['port_type'] ?? 'rj45') as String,
      rowIndex: (json['row_index'] ?? 0) as int,
      colIndex: (json['col_index'] ?? 0) as int,
      relX: ((json['rel_x'] ?? 0.5) as num).toDouble(),
      relY: ((json['rel_y'] ?? 0.5) as num).toDouble(),
    );
  }
}

class RackDeviceModel {
  final int id;
  final int rackId;
  final int templateId;
  final String code;
  final String name;
  final String hostname;
  final String fqdn;
  final int startU;
  final String mountedFace; // 'front' | 'back'
  final String ipAddress;
  final String subnetMask;
  final String gateway;
  final String macAddress;
  final int? vlanMgmt;
  final List<Map<String, dynamic>> managementLinks;
  final bool monitoringEnabled;
  final String monitorMethod;
  final int monitorPort;
  final String status; // 'online' | 'offline' | 'warning' | 'unknown'
  final double? lastPingMs;
  final String? lastCheckedAt;
  final String serialNumber;
  final Map<String, dynamic> customFields;
  final String notes;
  final DeviceTemplateModel template;
  final List<PortModel> ports;

  RackDeviceModel({
    required this.id,
    required this.rackId,
    required this.templateId,
    required this.code,
    required this.name,
    required this.hostname,
    required this.fqdn,
    required this.startU,
    required this.mountedFace,
    required this.ipAddress,
    required this.subnetMask,
    required this.gateway,
    required this.macAddress,
    this.vlanMgmt,
    required this.managementLinks,
    required this.monitoringEnabled,
    required this.monitorMethod,
    required this.monitorPort,
    required this.status,
    this.lastPingMs,
    this.lastCheckedAt,
    required this.serialNumber,
    required this.customFields,
    required this.notes,
    required this.template,
    required this.ports,
  });

  int get uHeight {
    final override = customFields['u_height_override'];
    if (override != null) {
      final parsed = int.tryParse(override.toString());
      if (parsed != null && parsed >= 1 && parsed <= 48) {
        return parsed;
      }
    }
    return template.uHeight;
  }

  int get endU => startU + uHeight - 1;

  String get photoUrl {
    final customPhoto = (customFields['photo_url'] ?? '').toString().trim();
    if (customPhoto.isNotEmpty) return customPhoto;
    return template.photoUrl;
  }

  bool get showPhotoOverride => customFields['show_photo'] != false;

  bool get isExternalFeed =>
      mountedFace == 'external' || (customFields['is_external_feed'] == true);

  String get feedType => (customFields['feed_type'] ?? 'power').toString();

  bool get isFiberFeed => feedType == 'fiber';

  String get feedColorHex =>
      (customFields['feed_color'] ?? (isFiberFeed ? '#0284C7' : '#DC2626')).toString();

  int get socketCount =>
      int.tryParse((customFields['socket_count'] ?? ports.length).toString()) ??
      ports.length;

  bool isVisibleOnFace(String activeFace) {
    if (isExternalFeed) return false;
    return true;
  }

  List<PortModel> portsForFace(String activeFace) {
    if (isExternalFeed) return ports;
    return ports.where((p) => p.face == activeFace).toList();
  }

  factory RackDeviceModel.fromJson(Map<String, dynamic> json) {
    return RackDeviceModel(
      id: json['id'] as int,
      rackId: json['rack_id'] as int,
      templateId: json['template_id'] as int,
      code: (json['code'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      hostname: (json['hostname'] ?? '') as String,
      fqdn: (json['fqdn'] ?? '') as String,
      startU: (json['start_u'] ?? 1) as int,
      mountedFace: (json['mounted_face'] ?? 'front') as String,
      ipAddress: (json['ip_address'] ?? '') as String,
      subnetMask: (json['subnet_mask'] ?? '255.255.255.0') as String,
      gateway: (json['gateway'] ?? '') as String,
      macAddress: (json['mac_address'] ?? '') as String,
      vlanMgmt: json['vlan_mgmt'] as int?,
      managementLinks: ((json['management_links'] ?? []) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      monitoringEnabled: (json['monitoring_enabled'] ?? false) as bool,
      monitorMethod: (json['monitor_method'] ?? 'icmp') as String,
      monitorPort: (json['monitor_port'] ?? 22) as int,
      status: (json['status'] ?? 'unknown') as String,
      lastPingMs: json['last_ping_ms'] != null
          ? (json['last_ping_ms'] as num).toDouble()
          : null,
      lastCheckedAt: json['last_checked_at']?.toString(),
      serialNumber: (json['serial_number'] ?? '') as String,
      customFields: Map<String, dynamic>.from((json['custom_fields'] ?? {}) as Map),
      notes: (json['notes'] ?? '') as String,
      template: DeviceTemplateModel.fromJson(
        Map<String, dynamic>.from(json['template'] as Map),
      ),
      ports: ((json['ports'] ?? []) as List)
          .map((e) => PortModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}

class ConnectionEndpointInfoModel {
  final int portId;
  final String portNumber;
  final String portType;
  final String face;
  final int deviceId;
  final String deviceCode;
  final String deviceName;
  final int rackId;
  final String rackCode;
  final String rackName;
  final int startU;

  ConnectionEndpointInfoModel({
    required this.portId,
    required this.portNumber,
    required this.portType,
    required this.face,
    required this.deviceId,
    required this.deviceCode,
    required this.deviceName,
    required this.rackId,
    required this.rackCode,
    required this.rackName,
    required this.startU,
  });

  factory ConnectionEndpointInfoModel.fromJson(Map<String, dynamic> json) {
    return ConnectionEndpointInfoModel(
      portId: json['port_id'] as int,
      portNumber: (json['port_number'] ?? '') as String,
      portType: (json['port_type'] ?? 'rj45') as String,
      face: (json['face'] ?? 'front') as String,
      deviceId: json['device_id'] as int,
      deviceCode: (json['device_code'] ?? '') as String,
      deviceName: (json['device_name'] ?? '') as String,
      rackId: json['rack_id'] as int,
      rackCode: (json['rack_code'] ?? '') as String,
      rackName: (json['rack_name'] ?? '') as String,
      startU: (json['start_u'] ?? 1) as int,
    );
  }
}

class ConnectionModel {
  final int id;
  final int sourcePortId;
  final int targetPortId;
  final String cableType; // utp_cat6a | fiber_om4 | fiber_os2 | power_ac
  final String colorHex;
  final String routingChannel; // left | right | auto
  final String label;
  final int? vlan;
  final double lengthM;
  final String notes;
  final ConnectionEndpointInfoModel sourceInfo;
  final ConnectionEndpointInfoModel targetInfo;

  ConnectionModel({
    required this.id,
    required this.sourcePortId,
    required this.targetPortId,
    required this.cableType,
    required this.colorHex,
    required this.routingChannel,
    required this.label,
    this.vlan,
    required this.lengthM,
    required this.notes,
    required this.sourceInfo,
    required this.targetInfo,
  });

  bool get isOutbound => sourceInfo.rackId != targetInfo.rackId;
  bool get isPassThrough =>
      sourceInfo.rackId == targetInfo.rackId &&
      sourceInfo.face != targetInfo.face;

  String get categoryGroup {
    if (cableType.startsWith('fiber')) return 'fiber';
    if (cableType.startsWith('power')) return 'power';
    return 'network';
  }

  factory ConnectionModel.fromJson(Map<String, dynamic> json) {
    return ConnectionModel(
      id: json['id'] as int,
      sourcePortId: json['source_port_id'] as int,
      targetPortId: json['target_port_id'] as int,
      cableType: (json['cable_type'] ?? 'utp_cat6a') as String,
      colorHex: (json['color_hex'] ?? '#2563EB') as String,
      routingChannel: (json['routing_channel'] ?? 'auto') as String,
      label: (json['label'] ?? '') as String,
      vlan: json['vlan'] as int?,
      lengthM: ((json['length_m'] ?? 1.5) as num).toDouble(),
      notes: (json['notes'] ?? '') as String,
      sourceInfo: ConnectionEndpointInfoModel.fromJson(
        Map<String, dynamic>.from(json['source_info'] as Map),
      ),
      targetInfo: ConnectionEndpointInfoModel.fromJson(
        Map<String, dynamic>.from(json['target_info'] as Map),
      ),
    );
  }
}

class RackDetailModel {
  final int id;
  final String code;
  final String name;
  final int totalUnits;
  final String manufacturer;
  final String modelName;
  final String serialNumber;
  final String responsiblePerson;
  final String purchaseDate;
  final String operationStart;
  final String notes;
  final int roomId;
  final int? aisleId;
  final Map<String, dynamic> breadcrumb;
  final List<AisleNode> availableAisles;
  final List<RackDeviceModel> devices;
  final List<ConnectionModel> connections;

  RackDetailModel({
    required this.id,
    required this.code,
    required this.name,
    required this.totalUnits,
    required this.manufacturer,
    required this.modelName,
    required this.serialNumber,
    required this.responsiblePerson,
    required this.purchaseDate,
    required this.operationStart,
    required this.notes,
    required this.roomId,
    this.aisleId,
    required this.breadcrumb,
    required this.availableAisles,
    required this.devices,
    required this.connections,
  });

  factory RackDetailModel.fromJson(Map<String, dynamic> json) {
    return RackDetailModel(
      id: json['id'] as int,
      code: (json['code'] ?? '') as String,
      name: (json['name'] ?? '') as String,
      totalUnits: (json['total_units'] ?? 42) as int,
      manufacturer: (json['manufacturer'] ?? '') as String,
      modelName: (json['model_name'] ?? '') as String,
      serialNumber: (json['serial_number'] ?? '') as String,
      responsiblePerson: (json['responsible_person'] ?? '') as String,
      purchaseDate: (json['purchase_date'] ?? '') as String,
      operationStart: (json['operation_start'] ?? '') as String,
      notes: (json['notes'] ?? '') as String,
      roomId: (json['room_id'] ?? 1) as int,
      aisleId: json['aisle_id'] as int?,
      breadcrumb: Map<String, dynamic>.from((json['breadcrumb'] ?? {}) as Map),
      availableAisles: ((json['available_aisles'] ?? []) as List)
          .map((e) => AisleNode.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      devices: ((json['devices'] ?? []) as List)
          .map((e) => RackDeviceModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      connections: ((json['connections'] ?? []) as List)
          .map((e) => ConnectionModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}

class UserModel {
  final int id;
  final String username;
  final String email;
  final String fullName;
  final String role; // 'admin' | 'editor' | 'operator' | 'viewer'
  final String authSource; // 'local' | 'ad'
  final int? adServerId;
  final String? adServerName;
  final String adDn;
  final bool isActive;

  UserModel({
    required this.id,
    required this.username,
    required this.email,
    required this.fullName,
    required this.role,
    required this.authSource,
    this.adServerId,
    this.adServerName,
    required this.adDn,
    required this.isActive,
  });

  bool get isAdmin => role == 'admin';
  bool get canEdit => role == 'admin' || role == 'editor';
  bool get canConnectRemote =>
      role == 'admin' || role == 'editor' || role == 'operator';

  String get roleLabel {
    switch (role) {
      case 'admin':
        return 'Administrador';
      case 'editor':
        return 'Editor';
      case 'operator':
        return 'Ver y Conectarse';
      case 'viewer':
      default:
        return 'Solo Ver';
    }
  }

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      id: (json['id'] ?? 1) as int,
      username: (json['username'] ?? '') as String,
      email: (json['email'] ?? '') as String,
      fullName: (json['full_name'] ?? '') as String,
      role: (json['role'] ?? 'viewer') as String,
      authSource: (json['auth_source'] ?? 'local') as String,
      adServerId: json['ad_server_id'] as int?,
      adServerName: json['ad_server_name'] as String?,
      adDn: (json['ad_dn'] ?? '') as String,
      isActive: (json['is_active'] ?? true) as bool,
    );
  }
}

class ADServerModel {
  final int id;
  final String name;
  final String host;
  final int port;
  final bool useSsl;
  final String domain;
  final String baseDn;
  final String bindDn;
  final String userFilter;
  final String defaultRole;
  final List<Map<String, dynamic>> groupRoleMapping;
  final bool isActive;

  ADServerModel({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.useSsl,
    required this.domain,
    required this.baseDn,
    required this.bindDn,
    required this.userFilter,
    required this.defaultRole,
    this.groupRoleMapping = const [],
    required this.isActive,
  });

  factory ADServerModel.fromJson(Map<String, dynamic> json) {
    final rawUrl = (json['ldap_url'] ?? json['host'] ?? '').toString();
    final isLdaps = rawUrl.startsWith('ldaps://') || (json['use_ssl'] == true);
    return ADServerModel(
      id: json['id'] as int,
      name: (json['name'] ?? '') as String,
      host: rawUrl,
      port: (json['port'] ?? (isLdaps ? 636 : 389)) as int,
      useSsl: isLdaps,
      domain: (json['domain'] ?? '') as String,
      baseDn: (json['base_dn'] ?? '') as String,
      bindDn: (json['bind_dn'] ?? '') as String,
      userFilter: (json['user_filter'] ?? '') as String,
      defaultRole: (json['default_role'] ?? 'viewer') as String,
      groupRoleMapping: ((json['group_role_mapping'] ?? []) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      isActive: (json['enabled'] ?? json['is_active'] ?? true) as bool,
    );
  }
}

