import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/datacenter_models.dart';

class RackDocApiClient {
  final String baseUrl;

  RackDocApiClient({String? baseUrl})
      : baseUrl = baseUrl ?? _resolveDefaultBaseUrl();

  static String _resolveDefaultBaseUrl() {
    const envUrl = String.fromEnvironment('API_BASE_URL', defaultValue: '');
    if (envUrl.isNotEmpty) {
      final normalizedEnv = envUrl == '/api' ? '/api/v1' : envUrl;
      if (normalizedEnv.startsWith('/') &&
          (Uri.base.scheme == 'http' || Uri.base.scheme == 'https')) {
        return '${Uri.base.origin}$normalizedEnv';
      }
      return normalizedEnv;
    }
    return 'http://127.0.0.1:8180/api/v1';
  }

  String get rootOrigin => baseUrl.replaceFirst(RegExp(r'/api(/v1)?$'), '');

  String getSwaggerDocsUrl() => '$rootOrigin/docs';
  String getRedocUrl() => '$rootOrigin/redoc';
  String getOpenApiSpecUrl() => '$rootOrigin/openapi.json';

  Map<String, String> get _headers => {
        'Content-Type': 'application/json; charset=UTF-8',
        'Accept': 'application/json',
      };

  dynamic _decodeResponse(http.Response response) {
    final bodyStr = utf8.decode(response.bodyBytes);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (bodyStr.isEmpty) return {};
      return jsonDecode(bodyStr);
    }
    try {
      final err = jsonDecode(bodyStr);
      throw Exception(err['detail'] ?? 'Error HTTP ${response.statusCode}');
    } catch (e) {
      if (e is Exception && e.toString().startsWith('Exception: ')) rethrow;
      throw Exception('Error HTTP ${response.statusCode}: $bodyStr');
    }
  }

  Future<List<LocationNode>> getLocations() async {
    final res = await http.get(Uri.parse('$baseUrl/locations'), headers: _headers);
    final data = _decodeResponse(res) as List;
    return data
        .map((e) => LocationNode.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<Map<String, dynamic>> createLocation({
    required String code,
    required String name,
    required double latitude,
    required double longitude,
    String address = '',
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/locations'),
      headers: _headers,
      body: jsonEncode({
        'code': code,
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'address': address,
      }),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<void> createFloor({
    required int locationId,
    required String name,
    required int levelNumber,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/floors'),
      headers: _headers,
      body: jsonEncode({
        'location_id': locationId,
        'name': name,
        'level_number': levelNumber,
      }),
    );
    _decodeResponse(res);
  }

  Future<void> updateLocation(
    int locationId,
    Map<String, dynamic> payload,
  ) async {
    final res = await http.put(
      Uri.parse('$baseUrl/locations/$locationId'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    _decodeResponse(res);
  }

  Future<void> deleteLocation(int locationId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/locations/$locationId'),
      headers: _headers,
    );
    _decodeResponse(res);
  }

  Future<void> updateFloor(
    int floorId,
    Map<String, dynamic> payload,
  ) async {
    final res = await http.put(
      Uri.parse('$baseUrl/floors/$floorId'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    _decodeResponse(res);
  }

  Future<void> deleteFloor(int floorId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/floors/$floorId'),
      headers: _headers,
    );
    _decodeResponse(res);
  }

  Future<void> createRoom({
    required int floorId,
    required String name,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/rooms'),
      headers: _headers,
      body: jsonEncode({
        'floor_id': floorId,
        'name': name,
      }),
    );
    _decodeResponse(res);
  }

  Future<void> createAisle({
    required int roomId,
    required String code,
    required String name,
    required String aisleType,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/aisles'),
      headers: _headers,
      body: jsonEncode({
        'room_id': roomId,
        'code': code,
        'name': name,
        'aisle_type': aisleType,
      }),
    );
    _decodeResponse(res);
  }

  Future<int> createRack({
    required int roomId,
    int? aisleId,
    required String code,
    required String name,
    int totalUnits = 42,
    String manufacturer = 'Rittal',
    String responsiblePerson = 'Alex Geng',
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/racks'),
      headers: _headers,
      body: jsonEncode({
        'room_id': roomId,
        'aisle_id': aisleId,
        'code': code,
        'name': name,
        'total_units': totalUnits,
        'manufacturer': manufacturer,
        'responsible_person': responsiblePerson,
      }),
    );
    final data = _decodeResponse(res) as Map;
    return data['id'] as int;
  }

  Future<Map<String, dynamic>> createFloorDevice(
    int floorId,
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/floors/$floorId/floor-devices'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<void> updateFloorDevice(
    int deviceId,
    Map<String, dynamic> payload,
  ) async {
    final res = await http.put(
      Uri.parse('$baseUrl/floor-devices/$deviceId'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    _decodeResponse(res);
  }

  Future<void> deleteFloorDevice(int deviceId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/floor-devices/$deviceId'),
      headers: _headers,
    );
    _decodeResponse(res);
  }

  Future<List<Map<String, dynamic>>> fetchCustomFloorDeviceTypes() async {
    final res = await http.get(
      Uri.parse('$baseUrl/floor-device-types'),
      headers: _headers,
    );
    final data = _decodeResponse(res) as List;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> createCustomFloorDeviceType(
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/floor-device-types'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<void> deleteCustomFloorDeviceType(int typeId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/floor-device-types/$typeId'),
      headers: _headers,
    );
    _decodeResponse(res);
  }

  Future<List<DeviceTemplateModel>> getTemplates() async {
    final res = await http.get(Uri.parse('$baseUrl/templates'), headers: _headers);
    final data = _decodeResponse(res) as List;
    return data
        .map((e) => DeviceTemplateModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<DeviceTemplateModel> createTemplate(Map<String, dynamic> payload) async {
    final res = await http.post(
      Uri.parse('$baseUrl/templates'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    final data = _decodeResponse(res) as Map;
    return DeviceTemplateModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<DeviceTemplateModel> updateTemplate(
    int templateId,
    Map<String, dynamic> payload,
  ) async {
    final res = await http.put(
      Uri.parse('$baseUrl/templates/$templateId'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    final data = _decodeResponse(res) as Map;
    return DeviceTemplateModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<List<Map<String, dynamic>>> searchHardwarePhotos(String query) async {
    final uri = Uri.parse('$baseUrl/templates/search-photo').replace(
      queryParameters: {'q': query},
    );
    final res = await http.get(uri, headers: _headers);
    final data = _decodeResponse(res) as Map;
    final list = (data['results'] ?? []) as List;
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> getInterRackTargets(int rackId) async {
    final res = await http.get(
      Uri.parse('$baseUrl/racks/$rackId/inter-rack-targets'),
      headers: _headers,
    );
    final data = _decodeResponse(res) as List;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<RackDetailModel> getRackDetail(int rackId) async {
    final res = await http.get(Uri.parse('$baseUrl/racks/$rackId'), headers: _headers);
    final data = _decodeResponse(res) as Map;
    return RackDetailModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> updateRack(int rackId, Map<String, dynamic> payload) async {
    final res = await http.put(
      Uri.parse('$baseUrl/racks/$rackId'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    _decodeResponse(res);
  }

  Future<void> deleteRack(int rackId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/racks/$rackId'),
      headers: _headers,
    );
    _decodeResponse(res);
  }

  Future<RackDeviceModel> addDeviceToRack(
    int rackId,
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/racks/$rackId/devices'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    final data = _decodeResponse(res) as Map;
    return RackDeviceModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<RackDeviceModel> updateDevice(
    int deviceId,
    Map<String, dynamic> payload,
  ) async {
    final res = await http.put(
      Uri.parse('$baseUrl/devices/$deviceId'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    final data = _decodeResponse(res) as Map;
    return RackDeviceModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> deleteDevice(int deviceId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/devices/$deviceId'),
      headers: _headers,
    );
    _decodeResponse(res);
  }

  Future<Map<String, dynamic>> pingDevice(int deviceId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/devices/$deviceId/ping'),
      headers: _headers,
    );
    final data = _decodeResponse(res) as Map;
    return Map<String, dynamic>.from(data);
  }

  Future<Map<String, dynamic>> pingFloorDevice(int deviceId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/floor-devices/$deviceId/ping'),
      headers: _headers,
    );
    final data = _decodeResponse(res) as Map;
    return Map<String, dynamic>.from(data);
  }

  Future<Map<String, dynamic>> getMonitoringSettings() async {
    final res = await http.get(
      Uri.parse('$baseUrl/settings/monitoring'),
      headers: _headers,
    );
    final data = _decodeResponse(res) as Map;
    return Map<String, dynamic>.from(data);
  }

  Future<Map<String, dynamic>> updateMonitoringSettings(
    Map<String, dynamic> payload,
  ) async {
    final res = await http.put(
      Uri.parse('$baseUrl/settings/monitoring'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    final data = _decodeResponse(res) as Map;
    return Map<String, dynamic>.from(data);
  }

  Future<Map<String, dynamic>> runMonitoringNow() async {
    final res = await http.post(
      Uri.parse('$baseUrl/settings/monitoring/run-now'),
      headers: _headers,
    );
    final data = _decodeResponse(res) as Map;
    return Map<String, dynamic>.from(data);
  }

  Future<List<Map<String, dynamic>>> pingAllRackDevices(int rackId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/racks/$rackId/ping-all'),
      headers: _headers,
    );
    final data = _decodeResponse(res) as List;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> runDeviceRemoteConsole(
    int deviceId,
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/devices/$deviceId/remote-console'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    final data = _decodeResponse(res) as Map;
    return Map<String, dynamic>.from(data);
  }

  Future<ConnectionModel> createConnection(Map<String, dynamic> payload) async {
    final res = await http.post(
      Uri.parse('$baseUrl/connections'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    final data = _decodeResponse(res) as Map;
    return ConnectionModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<ConnectionModel> updateConnection(
    int connectionId,
    Map<String, dynamic> payload,
  ) async {
    final res = await http.put(
      Uri.parse('$baseUrl/connections/$connectionId'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    final data = _decodeResponse(res) as Map;
    return ConnectionModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> deleteConnection(int connectionId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/connections/$connectionId'),
      headers: _headers,
    );
    _decodeResponse(res);
  }

  Future<Map<String, dynamic>> fetchDashboardInventory({
    int? locationId,
    int? rackId,
  }) async {
    final params = <String, String>{};
    if (locationId != null) params['location_id'] = locationId.toString();
    if (rackId != null) params['rack_id'] = rackId.toString();
    final uri = Uri.parse('$baseUrl/reports/dashboard-inventory').replace(
      queryParameters: params.isEmpty ? null : params,
    );
    final res = await http.get(uri, headers: _headers);
    final data = _decodeResponse(res) as Map;
    return Map<String, dynamic>.from(data);
  }

  String getExcelExportUrl({int? locationId, int? rackId}) {
    final params = <String, String>{};
    if (locationId != null) params['location_id'] = locationId.toString();
    if (rackId != null) params['rack_id'] = rackId.toString();
    final uri = Uri.parse('$baseUrl/reports/excel').replace(
      queryParameters: params.isEmpty ? null : params,
    );
    return uri.toString();
  }

  String getExcelTemplateUrl() {
    return '$baseUrl/reports/excel/template';
  }

  Future<Map<String, dynamic>> importExcelFile({
    required String filename,
    required List<int> fileBytes,
  }) async {
    final uri = Uri.parse('$baseUrl/reports/excel/import');
    final req = http.MultipartRequest('POST', uri);
    req.files.add(
      http.MultipartFile.fromBytes(
        'file',
        fileBytes,
        filename: filename,
      ),
    );
    final streamed = await req.send();
    final res = await http.Response.fromStream(streamed);
    final data = _decodeResponse(res) as Map;
    return Map<String, dynamic>.from(data);
  }

  String resolvePlanImageUrl(String mapImageUrl) {
    if (mapImageUrl.isEmpty) return '';
    if (mapImageUrl.startsWith('http://') || mapImageUrl.startsWith('https://')) {
      return mapImageUrl;
    }
    if (mapImageUrl.startsWith('/api/')) {
      return '$rootOrigin$mapImageUrl';
    }
    return '$baseUrl$mapImageUrl';
  }

  Future<String> uploadCustomPlanImage({
    required String targetType, // 'location' | 'floor' | 'room'
    required int targetId,
    required String filename,
    required List<int> fileBytes,
  }) async {
    final uri = Uri.parse('$baseUrl/upload-plan');
    final req = http.MultipartRequest('POST', uri);
    req.fields['target_type'] = targetType;
    req.fields['target_id'] = targetId.toString();
    req.files.add(
      http.MultipartFile.fromBytes(
        'file',
        fileBytes,
        filename: filename,
      ),
    );
    final streamed = await req.send();
    final res = await http.Response.fromStream(streamed);
    final data = _decodeResponse(res) as Map;
    return (data['map_image_url'] ?? '') as String;
  }

  Future<void> deleteCustomPlanImage({
    required String targetType,
    required int targetId,
  }) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/upload-plan/$targetType/$targetId'),
      headers: _headers,
    );
    _decodeResponse(res);
  }

  /// Busca direcciones, calles, ciudades o edificios en OpenStreetMap (Nominatim)
  /// sin necesidad de API key.
  Future<List<Map<String, dynamic>>> searchOpenStreetMap(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final uri = Uri.parse(
      'https://nominatim.openstreetmap.org/search'
      '?format=jsonv2&addressdetails=1&limit=6&q=${Uri.encodeQueryComponent(q)}',
    );
    final res = await http.get(
      uri,
      headers: {'Accept': 'application/json'},
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Error consultando OpenStreetMap (${res.statusCode})');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes)) as List;
    return decoded.map((item) {
      final map = Map<String, dynamic>.from(item as Map);
      return {
        'display_name': (map['display_name'] ?? '').toString(),
        'name': (map['name'] ?? '').toString(),
        'lat': double.tryParse((map['lat'] ?? '0').toString()) ?? 0.0,
        'lon': double.tryParse((map['lon'] ?? '0').toString()) ?? 0.0,
      };
    }).toList();
  }

  // --- Librerías de Dispositivos (Import / Export) ---

  Future<Map<String, dynamic>> exportTemplates({String? libraryGroup}) async {
    final params = <String, String>{};
    if (libraryGroup != null && libraryGroup.isNotEmpty) {
      params['library_group'] = libraryGroup;
    }
    final uri = Uri.parse('$baseUrl/templates/export').replace(
      queryParameters: params.isEmpty ? null : params,
    );
    final res = await http.get(uri, headers: _headers);
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> importTemplates({
    String? libraryGroup,
    required List<Map<String, dynamic>> templates,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/templates/import'),
      headers: _headers,
      body: jsonEncode({
        'library_group': libraryGroup,
        'templates': templates,
      }),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<void> deleteTemplate(int templateId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/templates/$templateId'),
      headers: _headers,
    );
    _decodeResponse(res);
  }

  // --- Tomas / Enchufes Schuko Exteriores al Rack ---

  Future<RackDeviceModel> createExternalOutlet(
    int rackId,
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/racks/$rackId/external-outlets'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    final data = _decodeResponse(res) as Map;
    return RackDeviceModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<RackDeviceModel> updateExternalOutlet(
    int deviceId,
    Map<String, dynamic> payload,
  ) async {
    final res = await http.put(
      Uri.parse('$baseUrl/external-outlets/$deviceId'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    final data = _decodeResponse(res) as Map;
    return RackDeviceModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> deleteExternalOutlet(int deviceId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/external-outlets/$deviceId'),
      headers: _headers,
    );
    _decodeResponse(res);
  }

  // --- Autenticación, Usuarios (RBAC) y Active Directory (Multi-AD) ---

  Future<UserModel> login(String username, String password) async {
    final res = await http.post(
      Uri.parse('$baseUrl/auth/login'),
      headers: _headers,
      body: jsonEncode({
        'username': username,
        'password': password,
      }),
    );
    final data = _decodeResponse(res) as Map;
    return UserModel.fromJson(Map<String, dynamic>.from(data['user'] as Map));
  }

  Future<List<UserModel>> getUsers() async {
    final res = await http.get(Uri.parse('$baseUrl/users'), headers: _headers);
    final data = _decodeResponse(res) as List;
    return data
        .map((e) => UserModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<UserModel> createUser(Map<String, dynamic> payload) async {
    final res = await http.post(
      Uri.parse('$baseUrl/users'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    final data = _decodeResponse(res) as Map;
    return UserModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<UserModel> updateUser(int userId, Map<String, dynamic> payload) async {
    final res = await http.put(
      Uri.parse('$baseUrl/users/$userId'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    final data = _decodeResponse(res) as Map;
    return UserModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> deleteUser(int userId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/users/$userId'),
      headers: _headers,
    );
    _decodeResponse(res);
  }

  Future<List<ADServerModel>> getAdServers() async {
    final res =
        await http.get(Uri.parse('$baseUrl/ad-servers'), headers: _headers);
    final data = _decodeResponse(res) as List;
    return data
        .map((e) => ADServerModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<ADServerModel> createAdServer(Map<String, dynamic> payload) async {
    final res = await http.post(
      Uri.parse('$baseUrl/ad-servers'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    final data = _decodeResponse(res) as Map;
    return ADServerModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<ADServerModel> updateAdServer(
    int adId,
    Map<String, dynamic> payload,
  ) async {
    final res = await http.put(
      Uri.parse('$baseUrl/ad-servers/$adId'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    final data = _decodeResponse(res) as Map;
    return ADServerModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> deleteAdServer(int adId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/ad-servers/$adId'),
      headers: _headers,
    );
    _decodeResponse(res);
  }

  Future<Map<String, dynamic>> searchAdUsers(int adId, String query) async {
    final res = await http.post(
      Uri.parse('$baseUrl/ad-servers/$adId/search-users'),
      headers: _headers,
      body: jsonEncode({'query': query}),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> importAdUsers(
    int adId,
    List<Map<String, dynamic>> users,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/ad-servers/$adId/import-users'),
      headers: _headers,
      body: jsonEncode({'users': users}),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  // --- CMDB & IPAM + Verificador Manual Multi-Sonda de IPs ---

  Future<Map<String, dynamic>> fetchCmdbOverview() async {
    final res = await http.get(
      Uri.parse('$baseUrl/cmdb/overview'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> createCmdbAsset(
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/cmdb/assets'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> updateCmdbAsset(
    int assetId,
    Map<String, dynamic> payload,
  ) async {
    final res = await http.put(
      Uri.parse('$baseUrl/cmdb/assets/$assetId'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> deleteCmdbAsset(int assetId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/cmdb/assets/$assetId'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> addCmdbAssetIp(
    int assetId,
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/cmdb/assets/$assetId/ips'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> deleteCmdbIp(int ipId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/cmdb/ips/$ipId'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> runCmdbAssetHeartbeat(int assetId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/cmdb/assets/$assetId/heartbeat'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> createCmdbSubnet(
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/cmdb/subnets'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> updateCmdbSubnet(
    int subnetId,
    Map<String, dynamic> payload,
  ) async {
    final res = await http.put(
      Uri.parse('$baseUrl/cmdb/subnets/$subnetId'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> deleteCmdbSubnet(int subnetId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/cmdb/subnets/$subnetId'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> verifyCmdbIp({
    String targetIp = '',
    int? subnetId,
    List<int>? ports,
    double timeoutSec = 0.6,
    int countLimit = 254,
    bool onlySuggestFree = false,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/cmdb/verify-ip'),
      headers: _headers,
      body: jsonEncode({
        'target_ip': targetIp,
        'subnet_id': subnetId,
        'ports': ports ?? [22, 80, 443, 3389, 445, 8006, 902, 161],
        'timeout_sec': timeoutSec,
        'count_limit': countLimit,
        'only_suggest_free': onlySuggestFree,
      }),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> importDiscoveredCmdbHosts({
    String? registerSubnetCidr,
    String? subnetName,
    int? vlanId,
    required List<Map<String, dynamic>> items,
  }) async {
    final res = await http.post(
      Uri.parse('$baseUrl/cmdb/import-discovered'),
      headers: _headers,
      body: jsonEncode({
        'register_subnet_cidr': registerSubnetCidr,
        'subnet_name': subnetName,
        'vlan_id': vlanId,
        'items': items,
      }),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  // ---------------------------------------------------------------------------
  // 4. RED & HOST (TOPOLOGÍA LÓGICA, NAGIOS, SNMP, CONECTORES Y PROMETHEUS)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> getNetworkHostsOverview() async {
    final res = await http.get(
      Uri.parse('$baseUrl/network-hosts/overview'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> getNetworkHostTelemetry(
    int assetId, {
    int rangeHours = 6,
  }) async {
    final res = await http.get(
      Uri.parse(
        '$baseUrl/network-hosts/telemetry/$assetId?range_hours=$rangeHours',
      ),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> createNetworkServiceCheck(
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/network-hosts/service-checks'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> deleteNetworkServiceCheck(int checkId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/network-hosts/service-checks/$checkId'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> runSingleNetworkServiceCheck(int checkId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/network-hosts/service-checks/$checkId/run'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> runAllNetworkServiceChecks() async {
    final res = await http.post(
      Uri.parse('$baseUrl/network-hosts/run-all-checks'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> runSnmpSwitchDiscovery(
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/network-hosts/snmp-discover'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> createLogicalLink(
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/network-hosts/logical-links'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> deleteLogicalLink(int linkId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/network-hosts/logical-links/$linkId'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> createInfraConnector(
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/network-hosts/connectors'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> syncInfraConnector(int connectorId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/network-hosts/connectors/$connectorId/sync'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> deleteInfraConnector(int connectorId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/network-hosts/connectors/$connectorId'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> upsertHostGroup(
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/network-hosts/host-groups'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> deleteHostGroup(int groupId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/network-hosts/host-groups/$groupId'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> upsertAlertContact(
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/network-hosts/alert-contacts'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> deleteAlertContact(int contactId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/network-hosts/alert-contacts/$contactId'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> upsertAlertContactGroup(
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/network-hosts/alert-contact-groups'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> deleteAlertContactGroup(int groupId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/network-hosts/alert-contact-groups/$groupId'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> createNotificationRule(
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/network-hosts/notification-rules'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> deleteNotificationRule(int ruleId) async {
    final res = await http.delete(
      Uri.parse('$baseUrl/network-hosts/notification-rules/$ruleId'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> createMaintenanceWindow(
    Map<String, dynamic> payload,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/network-hosts/maintenance-windows'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> stopMaintenanceWindow(int windowId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/network-hosts/maintenance-windows/$windowId/stop'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> updateSmtpAlertConfig(
    Map<String, dynamic> payload,
  ) async {
    final res = await http.put(
      Uri.parse('$baseUrl/network-hosts/smtp-config'),
      headers: _headers,
      body: jsonEncode(payload),
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> triggerTestAlert({int? assetId}) async {
    final uri = assetId != null
        ? Uri.parse('$baseUrl/network-hosts/test-alert?asset_id=$assetId')
        : Uri.parse('$baseUrl/network-hosts/test-alert');
    final res = await http.post(uri, headers: _headers);
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }

  Future<Map<String, dynamic>> getAiAgentContextManifest() async {
    final res = await http.get(
      Uri.parse('$baseUrl/automation/ai-context'),
      headers: _headers,
    );
    return Map<String, dynamic>.from(_decodeResponse(res) as Map);
  }
}
