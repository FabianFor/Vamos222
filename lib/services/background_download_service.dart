import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:dio/dio.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class BackgroundDownloadService {
  static const String channelId = 'download_channel';
  static const String channelName = 'Descargas de Música';
  static FlutterLocalNotificationsPlugin notifications = FlutterLocalNotificationsPlugin();
  static Dio dio = Dio();

  // Stream para comunicar el progreso con la UI
  static final StreamController<DownloadProgress> _progressController =
      StreamController<DownloadProgress>.broadcast();
  static Stream<DownloadProgress> get progressStream => _progressController.stream;

  // Lista de descargas activas
  static final Map<String, CancelToken> _activeDownloads = {};

  static Future<void> initialize() async {
    print('🔧 Inicializando servicio de descargas...');

    // Configurar notificaciones
    await _initializeNotifications();

    // Configurar servicio de fondo
    await _initializeBackgroundService();

    print('✅ Servicio de descargas inicializado');
  }

  static Future<void> _initializeNotifications() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await notifications.initialize(initSettings);

    // Crear canal de notificaciones para Android
    const androidChannel = AndroidNotificationChannel(
      channelId,
      channelName,
      description: 'Notificaciones de progreso de descarga',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    );

    await notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);
  }

  static Future<void> _initializeBackgroundService() async {
    final service = FlutterBackgroundService();

    await service.configure(
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        autoStartOnBoot: false,
        notificationChannelId: channelId,
        initialNotificationTitle: 'Fabichelo',
        initialNotificationContent: 'Servicio de descargas activo',
        foregroundServiceNotificationId: 888,
      ),
    );
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();

    print('🚀 Servicio de fondo iniciado');

    // Escuchar comandos de descarga
    service.on('startDownload').listen((event) async {
      final data = event!['data'] as Map<String, dynamic>;
      await _performDownload(
        url: data['url'],
        filename: data['filename'],
        downloadUrl: data['downloadUrl'],
        savePath: data['savePath'],
        service: service,
      );
    });

    // Escuchar comandos de cancelación
    service.on('cancelDownload').listen((event) {
      final url = event!['url'] as String;
      _cancelDownload(url);
    });

    // Detener servicio cuando no hay descargas
    service.on('stopService').listen((event) {
      service.stopSelf();
    });
  }

  @pragma('vm:entry-point')
  static bool onIosBackground(ServiceInstance service) {
    WidgetsFlutterBinding.ensureInitialized();
    return true;
  }

  static Future<void> startDownload({
    required String url,
    required String filename,
    required String downloadUrl,
    required String savePath,
  }) async {
    print('⬇️ Iniciando descarga en segundo plano: $filename');

    // Verificar conectividad
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.none)) {
      _showNotification(
        'Sin conexión',
        'No hay conexión a internet para descargar $filename',
        isError: true,
      );
      return;
    }

    // Iniciar servicio de fondo
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();

    if (!isRunning) {
      await service.startService();
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // Enviar comando de descarga al servicio
    service.invoke('startDownload', {
      'data': {
        'url': url,
        'filename': filename,
        'downloadUrl': downloadUrl,
        'savePath': savePath,
      }
    });

    _showNotification(
      'Descarga iniciada',
      'Descargando $filename...',
    );
  }

  static Future<void> _performDownload({
    required String url,
    required String filename,
    required String downloadUrl,
    required String savePath,
    required ServiceInstance service,
  }) async {
    CancelToken cancelToken = CancelToken();
    _activeDownloads[url] = cancelToken;

    int lastNotificationTime = 0;

    try {
      print('📥 Descargando: $downloadUrl');

      await dio.download(
        downloadUrl,
        savePath,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total != -1) {
            final progress = (received / total * 100).round();
            final now = DateTime.now().millisecondsSinceEpoch;

            _progressController.add(DownloadProgress(
              url: url,
              filename: filename,
              progress: progress,
              isCompleted: false,
              isError: false,
            ));

            if (now - lastNotificationTime > 2000) {
              _updateProgressNotification(filename, progress);
              lastNotificationTime = now;
            }
          }
        },
      );

      final file = File(savePath);
      if (await file.exists() && await file.length() > 0) {
        print('✅ Descarga completada: $filename');

        _progressController.add(DownloadProgress(
          url: url,
          filename: filename,
          progress: 100,
          isCompleted: true,
          isError: false,
        ));

        _showNotification(
          'Descarga completada',
          '$filename se descargó correctamente',
          isCompleted: true,
        );
      } else {
        throw Exception('El archivo no se guardó correctamente');
      }
    } catch (e) {
      print('❌ Error en descarga: $e');

      _progressController.add(DownloadProgress(
        url: url,
        filename: filename,
        progress: 0,
        isCompleted: false,
        isError: true,
        errorMessage: e.toString(),
      ));

      if (!cancelToken.isCancelled) {
        _showNotification(
          'Error en descarga',
          'No se pudo descargar $filename: ${e.toString()}',
          isError: true,
        );
      }
    } finally {
      _activeDownloads.remove(url);

      if (_activeDownloads.isEmpty) {
        Future.delayed(const Duration(seconds: 3), () {
          if (_activeDownloads.isEmpty) {
            service.invoke('stopService');
          }
        });
      }
    }
  }

  static void _cancelDownload(String url) {
    final cancelToken = _activeDownloads[url];
    if (cancelToken != null && !cancelToken.isCancelled) {
      cancelToken.cancel('Descarga cancelada por el usuario');
      _activeDownloads.remove(url);

      _progressController.add(DownloadProgress(
        url: url,
        filename: 'Cancelado',
        progress: 0,
        isCompleted: false,
        isError: true,
        errorMessage: 'Descarga cancelada',
      ));

      print('❌ Descarga cancelada: $url');
    }
  }

  static void cancelDownload(String url) {
    final service = FlutterBackgroundService();
    service.invoke('cancelDownload', {'url': url});
  }

  static void _showNotification(
    String title,
    String body, {
    bool isCompleted = false,
    bool isError = false,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: 'Notificaciones de descarga',
      importance: Importance.low,
      priority: Priority.low,
      autoCancel: true,
      playSound: false,
      enableVibration: false,
    );

    final notificationDetails = NotificationDetails(android: androidDetails);

    await notifications.show(
      isError ? 999 : (isCompleted ? 888 : 777),
      title,
      body,
      notificationDetails,
    );
  }

  static void _updateProgressNotification(String filename, int progress) async {
    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: 'Progreso de descarga',
      importance: Importance.low,
      priority: Priority.low,
      autoCancel: false,
      ongoing: true,
      showProgress: true,
      maxProgress: 100,
      progress: progress,
      playSound: false,
      enableVibration: false,
    );

    final notificationDetails = NotificationDetails(android: androidDetails);

    await notifications.show(
      777,
      'Descargando música',
      '$filename - $progress%',
      notificationDetails,
    );
  }

  static List<String> getActiveDownloads() {
    return _activeDownloads.keys.toList();
  }

  static bool isDownloading(String url) {
    return _activeDownloads.containsKey(url);
  }

  static void dispose() {
    _progressController.close();
  }
}

class DownloadProgress {
  final String url;
  final String filename;
  final int progress;
  final bool isCompleted;
  final bool isError;
  final String? errorMessage;

  DownloadProgress({
    required this.url,
    required this.filename,
    required this.progress,
    required this.isCompleted,
    required this.isError,
    this.errorMessage,
  });

  @override
  String toString() {
    return 'DownloadProgress(url: $url, filename: $filename, progress: $progress%, completed: $isCompleted, error: $isError)';
  }
}
