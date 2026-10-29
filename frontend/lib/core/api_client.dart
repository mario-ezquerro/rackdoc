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
      if (envUrl.startsWith('/') &&
          (Uri.base.scheme == 'http' || Uri.base.scheme == 'https')) {
        return '${Uri.base.origin}$envUrl';
      }
      return envUrl;
    }
    return 'http://127.0.0.1:8180/api';
  }

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

  Future<List<Map<String, dynamic>>> pingAllRackDevices(int rackId) async {
    final res = await http.post(
      Uri.parse('$baseUrl/racks/$rackId/ping-all'),
      headers: _headers,
    );
    final data = _decodeResponse(res) as List;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
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
    // mapImageUrl viene como '/api/uploads/...' y baseUrl termina en '/api'
    if (mapImageUrl.startsWith('/api/') && baseUrl.endsWith('/api')) {
      final rootOrigin = baseUrl.substring(0, baseUrl.length - 4);
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
}
