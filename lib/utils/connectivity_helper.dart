import 'package:connectivity_plus/connectivity_plus.dart';

class ConnectivityHelper {
  static final Connectivity _connectivity = Connectivity();

  /// Verifica si hay conexión a internet disponible
  static Future<bool> hasInternetConnection() async {
    try {
      final connectivityResults = await _connectivity.checkConnectivity();
      
      // Si no hay conexión, retornar false inmediatamente
      if (connectivityResults.contains(ConnectivityResult.none)) {
        return false;
      }
      
      // Si hay conexión (wifi, móvil, ethernet, etc.), asumir que hay internet
      // En casos específicos donde necesites verificar conectividad real a internet,
      // podrías hacer una petición de prueba a un servidor confiable
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Verifica si hay conexión específica a un tipo de red
  static Future<bool> hasSpecificConnection(ConnectivityResult type) async {
    try {
      final connectivityResults = await _connectivity.checkConnectivity();
      return connectivityResults.contains(type);
    } catch (e) {
      return false;
    }
  }

  /// Verifica si hay conexión WiFi
  static Future<bool> hasWifiConnection() async {
    return await hasSpecificConnection(ConnectivityResult.wifi);
  }

  /// Verifica si hay conexión móvil
  static Future<bool> hasMobileConnection() async {
    return await hasSpecificConnection(ConnectivityResult.mobile);
  }

  /// Verifica si hay conexión Ethernet
  static Future<bool> hasEthernetConnection() async {
    return await hasSpecificConnection(ConnectivityResult.ethernet);
  }

  /// Obtiene el tipo de conexión actual
  static Future<List<ConnectivityResult>> getCurrentConnectionTypes() async {
    try {
      return await _connectivity.checkConnectivity();
    } catch (e) {
      return [ConnectivityResult.none];
    }
  }

  /// Escucha cambios en la conectividad
  static Stream<List<ConnectivityResult>> get connectivityStream {
    return _connectivity.onConnectivityChanged;
  }

  /// Verifica conectividad con un timeout personalizado
  static Future<bool> hasInternetConnectionWithTimeout({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      return await hasInternetConnection().timeout(timeout);
    } catch (e) {
      return false;
    }
  }
}
