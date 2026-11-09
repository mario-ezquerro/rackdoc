import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/datacenter_models.dart';

/// Error de autenticación/autorización devuelto por la API (401 / 403).
/// La UI lo distingue de un error de red para poder volver a la pantalla de login.
class RackDocAuthException implements Exception {
  final int statusCode;
  final String message;

  const RackDocAuthException(this.statusCode, this.message);

  /// 401: no hay sesión válida (hay que volver a identificarse).
  bool get requiresLogin => statusCode == 401;

  /// 403: la sesión es válida pero el rol no alcanza para esta operación.
  bool get isForbidden => statusCode == 403;

  @override
  String toString() => message;
}

class RackDocApiClient {
  final String baseUrl;

  /// JWT de la sesión en curso. Se rellena en [login] y se envía en cada
  /// petición mediante la cabecera Authorization.
  String? _accessToken;

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

  /// true si hay un token de sesión guardado.
  bool get hasSession => (_accessToken ?? '').isNotEmpty;

  /// Olvida el token (cierre de sesión o respuesta 401 del backend).
  void clearSession() => _accessToken = null;

  String getSwaggerDocsUrl() => '$rootOrigin/docs';
  String getRedocUrl() => '$rootOrigin/redoc';
  String getOpenApiSpecUrl() => '$rootOrigin/openapi.json';

  Map<String, String> get _headers => {
        'Content-Type': 'application/json; charset=UTF-8',
        'Accept': 'application/json',
        if (hasSession) 'Authorization': 'Bearer $_accessToken',
      };

  /// Construye la URL absoluta de una ruta de la API.
  Uri _url(String ruta, [Map<String, dynamic>? query]) {
    final uri = Uri.parse('$baseUrl$ruta');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(
      queryParameters: query.map((k, v) => MapEntry(k, '$v')),
    );
  }

  /// Punto único por el que pasan todas las llamadas a la API: pone las
  /// cabeceras (token incluido), serializa el cuerpo y decodifica la respuesta.
  /// Antes este mismo bloque estaba repetido en los 107 métodos del cliente.
  Future<dynamic> _enviar(String metodo, Uri uri, [Object? cuerpo]) async {
    final codificado = cuerpo == null ? null : jsonEncode(cuerpo);
    final http.Response respuesta;
    switch (metodo) {
      case 'GET':
        respuesta = await http.get(uri, headers: _headers);
        break;
      case 'POST':
        respuesta = await http.post(uri, headers: _headers, body: codificado);
        break;
      case 'PUT':
        respuesta = await http.put(uri, headers: _headers, body: codificado);
        break;
      case 'DELETE':
        respuesta = await http.delete(uri, headers: _headers, body: codificado);
        break;
      default:
        throw ArgumentError('Método HTTP no soportado: $metodo');
    }
    return _decodeResponse(respuesta);
  }

  Future<dynamic> _get(String ruta, [Map<String, dynamic>? query]) =>
      _enviar('GET', _url(ruta, query));

  Future<dynamic> _post(String ruta, [Object? cuerpo]) =>
      _enviar('POST', _url(ruta), cuerpo);

  Future<dynamic> _put(String ruta, [Object? cuerpo]) =>
      _enviar('PUT', _url(ruta), cuerpo);

  Future<dynamic> _delete(String ruta, [Object? cuerpo]) =>
      _enviar('DELETE', _url(ruta), cuerpo);

  dynamic _decodeResponse(http.Response response) {
    final bodyStr = utf8.decode(response.bodyBytes);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (bodyStr.isEmpty) return {};
      return jsonDecode(bodyStr);
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      String detail = response.statusCode == 401
          ? 'Sesión no válida o caducada. Vuelve a iniciar sesión.'
          : 'No tienes permisos para esta operación.';
      try {
        final err = jsonDecode(bodyStr);
        if (err is Map && err['detail'] is String) detail = err['detail'] as String;
      } catch (_) {}
      // Un 401 significa que el token ya no sirve: lo descartamos para no
      // seguir reintentando con credenciales muertas.
      if (response.statusCode == 401) clearSession();
      throw RackDocAuthException(response.statusCode, detail);
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
    final data = await _get('/locations') as List;
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
    return Map<String, dynamic>.from(await _post('/locations', {
        'code': code,
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'address': address,
      }) as Map);
  }

  Future<void> createFloor({
    required int locationId,
    required String name,
    required int levelNumber,
  }) async {
    await _post('/floors', {
        'location_id': locationId,
        'name': name,
        'level_number': levelNumber,
      });
  }

  Future<void> updateLocation(
    int locationId,
    Map<String, dynamic> payload,
  ) async {
    await _put('/locations/$locationId', payload);
  }

  Future<void> deleteLocation(int locationId) async {
    await _delete('/locations/$locationId');
  }

  Future<void> updateFloor(
    int floorId,
    Map<String, dynamic> payload,
  ) async {
    await _put('/floors/$floorId', payload);
  }

  Future<void> deleteFloor(int floorId) async {
    await _delete('/floors/$floorId');
  }

  Future<void> createRoom({
    required int floorId,
    required String name,
  }) async {
    await _post('/rooms', {
        'floor_id': floorId,
        'name': name,
      });
  }

  Future<void> createAisle({
    required int roomId,
    required String code,
    required String name,
    required String aisleType,
  }) async {
    await _post('/aisles', {
        'room_id': roomId,
        'code': code,
        'name': name,
        'aisle_type': aisleType,
      });
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
    final data = await _post('/racks', {
        'room_id': roomId,
        'aisle_id': aisleId,
        'code': code,
        'name': name,
        'total_units': totalUnits,
        'manufacturer': manufacturer,
        'responsible_person': responsiblePerson,
      }) as Map;
    return data['id'] as int;
  }

  Future<Map<String, dynamic>> createFloorDevice(
    int floorId,
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/floors/$floorId/floor-devices', payload) as Map);
  }

  Future<void> updateFloorDevice(
    int deviceId,
    Map<String, dynamic> payload,
  ) async {
    await _put('/floor-devices/$deviceId', payload);
  }

  Future<void> deleteFloorDevice(int deviceId) async {
    await _delete('/floor-devices/$deviceId');
  }

  Future<List<Map<String, dynamic>>> fetchCustomFloorDeviceTypes() async {
    final data = await _get('/floor-device-types') as List;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> createCustomFloorDeviceType(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/floor-device-types', payload) as Map);
  }

  Future<void> deleteCustomFloorDeviceType(int typeId) async {
    await _delete('/floor-device-types/$typeId');
  }

  Future<List<DeviceTemplateModel>> getTemplates() async {
    final data = await _get('/templates') as List;
    return data
        .map((e) => DeviceTemplateModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<DeviceTemplateModel> createTemplate(Map<String, dynamic> payload) async {
    final data = await _post('/templates', payload) as Map;
    return DeviceTemplateModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<DeviceTemplateModel> updateTemplate(
    int templateId,
    Map<String, dynamic> payload,
  ) async {
    final data = await _put('/templates/$templateId', payload) as Map;
    return DeviceTemplateModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<List<Map<String, dynamic>>> searchHardwarePhotos(String query) async {
    final uri = Uri.parse('$baseUrl/templates/search-photo').replace(
      queryParameters: {'q': query},
    );
    final data = await _enviar('GET', uri) as Map;
    final list = (data['results'] ?? []) as List;
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> getInterRackTargets(int rackId) async {
    final data = await _get('/racks/$rackId/inter-rack-targets') as List;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<RackDetailModel> getRackDetail(int rackId) async {
    final data = await _get('/racks/$rackId') as Map;
    return RackDetailModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> updateRack(int rackId, Map<String, dynamic> payload) async {
    await _put('/racks/$rackId', payload);
  }

  Future<void> deleteRack(int rackId) async {
    await _delete('/racks/$rackId');
  }

  Future<RackDeviceModel> addDeviceToRack(
    int rackId,
    Map<String, dynamic> payload,
  ) async {
    final data = await _post('/racks/$rackId/devices', payload) as Map;
    return RackDeviceModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<RackDeviceModel> updateDevice(
    int deviceId,
    Map<String, dynamic> payload,
  ) async {
    final data = await _put('/devices/$deviceId', payload) as Map;
    return RackDeviceModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> deleteDevice(int deviceId) async {
    await _delete('/devices/$deviceId');
  }

  Future<Map<String, dynamic>> pingDevice(int deviceId) async {
    final data = await _post('/devices/$deviceId/ping') as Map;
    return Map<String, dynamic>.from(data);
  }

  Future<Map<String, dynamic>> pingFloorDevice(int deviceId) async {
    final data = await _post('/floor-devices/$deviceId/ping') as Map;
    return Map<String, dynamic>.from(data);
  }

  Future<Map<String, dynamic>> getMonitoringSettings() async {
    final data = await _get('/settings/monitoring') as Map;
    return Map<String, dynamic>.from(data);
  }

  Future<Map<String, dynamic>> updateMonitoringSettings(
    Map<String, dynamic> payload,
  ) async {
    final data = await _put('/settings/monitoring', payload) as Map;
    return Map<String, dynamic>.from(data);
  }

  Future<Map<String, dynamic>> runMonitoringNow() async {
    final data = await _post('/settings/monitoring/run-now') as Map;
    return Map<String, dynamic>.from(data);
  }

  Future<List<Map<String, dynamic>>> pingAllRackDevices(int rackId) async {
    final data = await _post('/racks/$rackId/ping-all') as List;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> runDeviceRemoteConsole(
    int deviceId,
    Map<String, dynamic> payload,
  ) async {
    final data = await _post('/devices/$deviceId/remote-console', payload) as Map;
    return Map<String, dynamic>.from(data);
  }

  Future<ConnectionModel> createConnection(Map<String, dynamic> payload) async {
    final data = await _post('/connections', payload) as Map;
    return ConnectionModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<ConnectionModel> updateConnection(
    int connectionId,
    Map<String, dynamic> payload,
  ) async {
    final data = await _put('/connections/$connectionId', payload) as Map;
    return ConnectionModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> deleteConnection(int connectionId) async {
    await _delete('/connections/$connectionId');
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
    final data = await _enviar('GET', uri) as Map;
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
    await _delete('/upload-plan/$targetType/$targetId');
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
    return Map<String, dynamic>.from(await _enviar('GET', uri) as Map);
  }

  Future<Map<String, dynamic>> importTemplates({
    String? libraryGroup,
    required List<Map<String, dynamic>> templates,
  }) async {
    return Map<String, dynamic>.from(await _post('/templates/import', {
        'library_group': libraryGroup,
        'templates': templates,
      }) as Map);
  }

  Future<void> deleteTemplate(int templateId) async {
    await _delete('/templates/$templateId');
  }

  // --- Tomas / Enchufes Schuko Exteriores al Rack ---

  Future<RackDeviceModel> createExternalOutlet(
    int rackId,
    Map<String, dynamic> payload,
  ) async {
    final data = await _post('/racks/$rackId/external-outlets', payload) as Map;
    return RackDeviceModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<RackDeviceModel> updateExternalOutlet(
    int deviceId,
    Map<String, dynamic> payload,
  ) async {
    final data = await _put('/external-outlets/$deviceId', payload) as Map;
    return RackDeviceModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> deleteExternalOutlet(int deviceId) async {
    await _delete('/external-outlets/$deviceId');
  }

  // --- Autenticación, Usuarios (RBAC) y Active Directory (Multi-AD) ---

  Future<UserModel> login(String username, String password) async {
    final data = await _post('/auth/login', {
        'username': username,
        'password': password,
      }) as Map;
    final token = (data['token'] ?? '').toString();
    if (token.isEmpty) {
      throw Exception('El backend no devolvió un token de sesión.');
    }
    _accessToken = token;
    return UserModel.fromJson(Map<String, dynamic>.from(data['user'] as Map));
  }

  Future<List<UserModel>> getUsers() async {
    final data = await _get('/users') as List;
    return data
        .map((e) => UserModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<UserModel> createUser(Map<String, dynamic> payload) async {
    final data = await _post('/users', payload) as Map;
    return UserModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<UserModel> updateUser(int userId, Map<String, dynamic> payload) async {
    final data = await _put('/users/$userId', payload) as Map;
    return UserModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> deleteUser(int userId) async {
    await _delete('/users/$userId');
  }

  Future<List<ADServerModel>> getAdServers() async {
    final data = await _get('/ad-servers') as List;
    return data
        .map((e) => ADServerModel.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<ADServerModel> createAdServer(Map<String, dynamic> payload) async {
    final data = await _post('/ad-servers', payload) as Map;
    return ADServerModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<ADServerModel> updateAdServer(
    int adId,
    Map<String, dynamic> payload,
  ) async {
    final data = await _put('/ad-servers/$adId', payload) as Map;
    return ADServerModel.fromJson(Map<String, dynamic>.from(data));
  }

  Future<void> deleteAdServer(int adId) async {
    await _delete('/ad-servers/$adId');
  }

  Future<Map<String, dynamic>> searchAdUsers(int adId, String query) async {
    return Map<String, dynamic>.from(await _post('/ad-servers/$adId/search-users', {'query': query}) as Map);
  }

  Future<Map<String, dynamic>> importAdUsers(
    int adId,
    List<Map<String, dynamic>> users,
  ) async {
    return Map<String, dynamic>.from(await _post('/ad-servers/$adId/import-users', {'users': users}) as Map);
  }

  // --- CMDB & IPAM + Verificador Manual Multi-Sonda de IPs ---

  Future<Map<String, dynamic>> fetchCmdbOverview() async {
    return Map<String, dynamic>.from(await _get('/cmdb/overview') as Map);
  }

  Future<Map<String, dynamic>> createCmdbAsset(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/cmdb/assets', payload) as Map);
  }

  Future<Map<String, dynamic>> updateCmdbAsset(
    int assetId,
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _put('/cmdb/assets/$assetId', payload) as Map);
  }

  Future<Map<String, dynamic>> deleteCmdbAsset(int assetId) async {
    return Map<String, dynamic>.from(await _delete('/cmdb/assets/$assetId') as Map);
  }

  Future<Map<String, dynamic>> addCmdbAssetIp(
    int assetId,
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/cmdb/assets/$assetId/ips', payload) as Map);
  }

  Future<Map<String, dynamic>> deleteCmdbIp(int ipId) async {
    return Map<String, dynamic>.from(await _delete('/cmdb/ips/$ipId') as Map);
  }

  Future<Map<String, dynamic>> runCmdbAssetHeartbeat(int assetId) async {
    return Map<String, dynamic>.from(await _post('/cmdb/assets/$assetId/heartbeat') as Map);
  }

  Future<Map<String, dynamic>> createCmdbSubnet(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/cmdb/subnets', payload) as Map);
  }

  Future<Map<String, dynamic>> updateCmdbSubnet(
    int subnetId,
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _put('/cmdb/subnets/$subnetId', payload) as Map);
  }

  Future<Map<String, dynamic>> deleteCmdbSubnet(int subnetId) async {
    return Map<String, dynamic>.from(await _delete('/cmdb/subnets/$subnetId') as Map);
  }

  Future<Map<String, dynamic>> verifyCmdbIp({
    String targetIp = '',
    int? subnetId,
    List<int>? ports,
    double timeoutSec = 0.6,
    int countLimit = 254,
    bool onlySuggestFree = false,
  }) async {
    return Map<String, dynamic>.from(await _post('/cmdb/verify-ip', {
        'target_ip': targetIp,
        'subnet_id': subnetId,
        'ports': ports ?? [22, 80, 443, 3389, 445, 8006, 902, 161],
        'timeout_sec': timeoutSec,
        'count_limit': countLimit,
        'only_suggest_free': onlySuggestFree,
      }) as Map);
  }

  Future<Map<String, dynamic>> importDiscoveredCmdbHosts({
    String? registerSubnetCidr,
    String? subnetName,
    int? vlanId,
    int? locationId,
    required List<Map<String, dynamic>> items,
  }) async {
    return Map<String, dynamic>.from(await _post('/cmdb/import-discovered', {
        'register_subnet_cidr': registerSubnetCidr,
        'subnet_name': subnetName,
        'vlan_id': vlanId,
        'location_id': locationId,
        'items': items,
      }) as Map);
  }

  Future<Map<String, dynamic>> checkCmdbIpOwner({
    required String ip,
    int? excludeAssetId,
    int? excludeRackDeviceId,
    int? excludeFloorDeviceId,
  }) async {
    final params = <String, String>{'ip': ip.trim()};
    if (excludeAssetId != null) {
      params['exclude_asset_id'] = excludeAssetId.toString();
    }
    if (excludeRackDeviceId != null) {
      params['exclude_rack_device_id'] = excludeRackDeviceId.toString();
    }
    if (excludeFloorDeviceId != null) {
      params['exclude_floor_device_id'] = excludeFloorDeviceId.toString();
    }
    final uri = Uri.parse(
      '$baseUrl/cmdb/check-ip-owner',
    ).replace(queryParameters: params);
    return Map<String, dynamic>.from(await _enviar('GET', uri) as Map);
  }

  Future<Map<String, dynamic>> resolveCmdbIpCollision(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/cmdb/resolve-ip-collision', payload) as Map);
  }

  // ---------------------------------------------------------------------------
  // 4. RED & HOST (TOPOLOGÍA LÓGICA, NAGIOS, SNMP, CONECTORES Y PROMETHEUS)
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> getNetworkHostsOverview() async {
    return Map<String, dynamic>.from(await _get('/network-hosts/overview') as Map);
  }

  Future<Map<String, dynamic>> getNetworkHostTelemetry(
    int assetId, {
    int rangeHours = 6,
  }) async {
    return Map<String, dynamic>.from(
      await _get('/network-hosts/telemetry/$assetId',
              {'range_hours': rangeHours})
          as Map,
    );
  }

  Future<Map<String, dynamic>> createNetworkHostWithServices(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/hosts', payload) as Map);
  }

  Future<Map<String, dynamic>> createNetworkServiceCheck(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/service-checks', payload) as Map);
  }

  Future<Map<String, dynamic>> deleteNetworkServiceCheck(int checkId) async {
    return Map<String, dynamic>.from(await _delete('/network-hosts/service-checks/$checkId') as Map);
  }

  Future<Map<String, dynamic>> runSingleNetworkServiceCheck(int checkId) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/service-checks/$checkId/run') as Map);
  }

  Future<Map<String, dynamic>> runAllNetworkServiceChecks() async {
    return Map<String, dynamic>.from(await _post('/network-hosts/run-all-checks') as Map);
  }

  Future<Map<String, dynamic>> runSnmpSwitchDiscovery(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/snmp-discover', payload) as Map);
  }

  Future<Map<String, dynamic>> createLogicalLink(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/logical-links', payload) as Map);
  }

  Future<Map<String, dynamic>> deleteLogicalLink(int linkId) async {
    return Map<String, dynamic>.from(await _delete('/network-hosts/logical-links/$linkId') as Map);
  }

  Future<Map<String, dynamic>> createInfraConnector(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/connectors', payload) as Map);
  }

  Future<Map<String, dynamic>> syncInfraConnector(int connectorId) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/connectors/$connectorId/sync') as Map);
  }

  Future<Map<String, dynamic>> deleteInfraConnector(int connectorId) async {
    return Map<String, dynamic>.from(await _delete('/network-hosts/connectors/$connectorId') as Map);
  }

  Future<Map<String, dynamic>> upsertHostGroup(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/host-groups', payload) as Map);
  }

  Future<Map<String, dynamic>> deleteHostGroup(int groupId) async {
    return Map<String, dynamic>.from(await _delete('/network-hosts/host-groups/$groupId') as Map);
  }

  Future<Map<String, dynamic>> upsertAlertContact(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/alert-contacts', payload) as Map);
  }

  Future<Map<String, dynamic>> deleteAlertContact(int contactId) async {
    return Map<String, dynamic>.from(await _delete('/network-hosts/alert-contacts/$contactId') as Map);
  }

  Future<Map<String, dynamic>> upsertAlertContactGroup(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/alert-contact-groups', payload) as Map);
  }

  Future<Map<String, dynamic>> deleteAlertContactGroup(int groupId) async {
    return Map<String, dynamic>.from(await _delete('/network-hosts/alert-contact-groups/$groupId') as Map);
  }

  Future<Map<String, dynamic>> createNotificationRule(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/notification-rules', payload) as Map);
  }

  Future<Map<String, dynamic>> deleteNotificationRule(int ruleId) async {
    return Map<String, dynamic>.from(await _delete('/network-hosts/notification-rules/$ruleId') as Map);
  }

  Future<Map<String, dynamic>> createMaintenanceWindow(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/maintenance-windows', payload) as Map);
  }

  Future<Map<String, dynamic>> stopMaintenanceWindow(int windowId) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/maintenance-windows/$windowId/stop') as Map);
  }

  Future<Map<String, dynamic>> updateSmtpAlertConfig(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _put('/network-hosts/smtp-config', payload) as Map);
  }

  Future<Map<String, dynamic>> triggerTestAlert({int? assetId}) async {
    final uri = assetId != null
        ? Uri.parse('$baseUrl/network-hosts/test-alert?asset_id=$assetId')
        : Uri.parse('$baseUrl/network-hosts/test-alert');
    return Map<String, dynamic>.from(await _enviar('POST', uri) as Map);
  }

  Future<Map<String, dynamic>> getAiAgentContextManifest() async {
    return Map<String, dynamic>.from(await _get('/automation/ai-context') as Map);
  }

  Future<Map<String, dynamic>> upsertTechStackDiagram(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/tech-stacks', payload) as Map);
  }

  Future<Map<String, dynamic>> updateTechStackDiagram(
    int stackId,
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _put('/network-hosts/tech-stacks/$stackId', payload) as Map);
  }

  Future<Map<String, dynamic>> deleteTechStackDiagram(int stackId) async {
    return Map<String, dynamic>.from(await _delete('/network-hosts/tech-stacks/$stackId') as Map);
  }

  Future<Map<String, dynamic>> createTechStackNode(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/tech-stacks/nodes', payload) as Map);
  }

  Future<Map<String, dynamic>> moveTechStackNode(
    int nodeId,
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _put('/network-hosts/tech-stacks/nodes/$nodeId', payload) as Map);
  }

  Future<Map<String, dynamic>> deleteTechStackNode(int nodeId) async {
    return Map<String, dynamic>.from(await _delete('/network-hosts/tech-stacks/nodes/$nodeId') as Map);
  }

  Future<Map<String, dynamic>> createTechStackEdge(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/tech-stacks/edges', payload) as Map);
  }

  Future<Map<String, dynamic>> updateTechStackEdge(
    int edgeId,
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _put('/network-hosts/tech-stacks/edges/$edgeId', payload) as Map);
  }

  Future<Map<String, dynamic>> deleteTechStackEdge(int edgeId) async {
    return Map<String, dynamic>.from(await _delete('/network-hosts/tech-stacks/edges/$edgeId') as Map);
  }

  Future<Map<String, dynamic>> executeHostSshConsole(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/network-hosts/ssh-console', payload) as Map);
  }

  // ===========================================================================
  // 7. CERTSCOPE — AUDITORÍA Y CADUCIDAD DE CERTIFICADOS SSL/TLS & GUÍA API
  // ===========================================================================
  Future<Map<String, dynamic>> getCertScopeOverview() async {
    return Map<String, dynamic>.from(await _get('/certscope/overview') as Map);
  }

  Future<Map<String, dynamic>> getApiOnboardingGuide() async {
    return Map<String, dynamic>.from(await _get('/certscope/api-onboarding-guide') as Map);
  }

  Future<Map<String, dynamic>> probeCertificate(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/certscope/probe', payload) as Map);
  }

  Future<Map<String, dynamic>> createCertificate(
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/certscope/certificates', payload) as Map);
  }

  Future<Map<String, dynamic>> updateCertificate(
    int certId,
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _put('/certscope/certificates/$certId', payload) as Map);
  }

  Future<Map<String, dynamic>> deleteCertificate(int certId) async {
    return Map<String, dynamic>.from(await _delete('/certscope/certificates/$certId') as Map);
  }

  Future<Map<String, dynamic>> verifyCertificate(int certId) async {
    return Map<String, dynamic>.from(await _post('/certscope/certificates/$certId/verify') as Map);
  }

  Future<Map<String, dynamic>> verifyAllCertificates() async {
    return Map<String, dynamic>.from(await _post('/certscope/verify-all') as Map);
  }

  Future<Map<String, dynamic>> notifyCertificateContacts(
    int certId,
    Map<String, dynamic> payload,
  ) async {
    return Map<String, dynamic>.from(await _post('/certscope/certificates/$certId/notify', payload) as Map);
  }
}
