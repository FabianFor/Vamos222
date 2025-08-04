import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:ui';

// Configuración para notificaciones
const String notificationChannelId = 'download_channel';
const String notificationChannelName = 'Descargas de Música';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
  runApp(const MyApp());
}

// Inicializar el servicio de segundo plano
Future<void> initializeService() async {
  final service = FlutterBackgroundService();
  
  // Configurar notificaciones
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    notificationChannelId,
    notificationChannelName,
    description: 'Canal para notificaciones de descarga',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: notificationChannelId,
      initialNotificationTitle: 'Fabichelo',
      initialNotificationContent: 'Servicio de descarga iniciado',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // Escuchar comandos de descarga
  service.on('startDownload').listen((event) async {
    final url = event!['url'] as String;
    final downloadId = event['downloadId'] as String;
    
    print('🌐 Servicio: Iniciando descarga $downloadId');
    
    try {
      // Actualizar notificación
      flutterLocalNotificationsPlugin.show(
        downloadId.hashCode,
        'Descargando música',
        'Preparando descarga...',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            notificationChannelId,
            notificationChannelName,
            importance: Importance.low,
            priority: Priority.low,
            showProgress: true,
            maxProgress: 100,
            progress: 0,
          ),
        ),
      );

      // Hacer la descarga
      await _performDownload(url, downloadId, service, flutterLocalNotificationsPlugin);
      
    } catch (e) {
      print('❌ Servicio: Error en descarga $downloadId: $e');
      
      // Notificar error
      service.invoke('downloadError', {
        'downloadId': downloadId,
        'error': e.toString(),
      });
      
      flutterLocalNotificationsPlugin.show(
        downloadId.hashCode,
        'Error en descarga',
        'No se pudo completar la descarga',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            notificationChannelId,
            notificationChannelName,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    }
  });

  service.on('stopService').listen((event) {
    service.stopSelf();
  });
}

Future<void> _performDownload(
  String url, 
  String downloadId, 
  ServiceInstance service,
  FlutterLocalNotificationsPlugin notificationsPlugin,
) async {
  try {
    // Notificar que está obteniendo información
    service.invoke('downloadProgress', {
      'downloadId': downloadId,
      'progress': 0,
      'status': 'preparing',
      'filename': 'Obteniendo información...',
    });

    // Obtener información del video con timeout más largo
    final response = await http.post(
      Uri.parse('https://servermusica-1.onrender.com/download'),
      headers: {
        'Content-Type': 'application/json',
        'Connection': 'keep-alive',
      },
      body: jsonEncode({'url': url}),
    ).timeout(const Duration(minutes: 5)); // Timeout más largo

    if (response.statusCode != 200) {
      final error = jsonDecode(response.body)['error'] ?? 'Error del servidor';
      throw Exception(error);
    }

    final data = jsonDecode(response.body);
    final filename = data['file'] as String;
    final downloadUrl = 'https://servermusica-1.onrender.com/downloads/$filename';

    // Actualizar con el nombre del archivo
    service.invoke('downloadProgress', {
      'downloadId': downloadId,
      'progress': 10,
      'status': 'downloading',
      'filename': filename,
    });

    // Obtener directorio de música
    final Directory musicDir = await _getMusicDirectory();
    final String savePath = '${musicDir.path}/$filename';

    print('📥 Servicio: Descargando desde $downloadUrl');
    
    // Descargar archivo con progreso
    final request = http.Request('GET', Uri.parse(downloadUrl));
    request.headers['Connection'] = 'keep-alive';
    
    final streamedResponse = await http.Client().send(request);
    
    if (streamedResponse.statusCode != 200) {
      throw Exception('Error al descargar el archivo: ${streamedResponse.statusCode}');
    }

    final List<int> bytes = [];
    int downloaded = 0;
    final int total = streamedResponse.contentLength ?? 0;

    await for (final chunk in streamedResponse.stream) {
      bytes.addAll(chunk);
      downloaded += chunk.length;
      
      if (total > 0) {
        final progress = (downloaded / total * 90).round() + 10; // 10-100%
        
        // Actualizar progreso cada 5%
        if (progress % 5 == 0) {
          service.invoke('downloadProgress', {
            'downloadId': downloadId,
            'progress': progress,
            'status': 'downloading',
            'filename': filename,
          });

          // Actualizar notificación
          notificationsPlugin.show(
            downloadId.hashCode,
            'Descargando: $filename',
            '$progress% completado',
            NotificationDetails(
              android: AndroidNotificationDetails(
                notificationChannelId,
                notificationChannelName,
                importance: Importance.low,
                priority: Priority.low,
                showProgress: true,
                maxProgress: 100,
                progress: progress,
              ),
            ),
          );
        }
      }
    }

    // Guardar archivo
    final file = File(savePath);
    await file.writeAsBytes(bytes);

    if (await file.exists() && await file.length() > 0) {
      // Descarga completada
      service.invoke('downloadCompleted', {
        'downloadId': downloadId,
        'filename': filename,
        'path': savePath,
      });

      // Notificación de éxito
      notificationsPlugin.show(
        downloadId.hashCode,
        'Descarga completada',
        filename,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            notificationChannelId,
            notificationChannelName,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );

      print('✅ Servicio: Descarga completada - $filename');
    } else {
      throw Exception('El archivo no se guardó correctamente');
    }

  } catch (e) {
    print('❌ Servicio: Error detallado - $e');
    rethrow;
  }
}

Future<Directory> _getMusicDirectory() async {
  Directory? directory;
  if (Platform.isAndroid) {
    try {
      directory = Directory('/storage/emulated/0/Download/Fabichelo');
      await directory.create(recursive: true);
    } catch (e) {
      final appDir = await getApplicationDocumentsDirectory();
      directory = Directory('${appDir.path}/Fabichelo');
      await directory.create(recursive: true);
    }
  } else {
    final appDir = await getApplicationDocumentsDirectory();
    directory = Directory('${appDir.path}/Fabichelo');
    await directory.create(recursive: true);
  }

  // Crear archivo .nomedia
  final nomediaFile = File('${directory.path}/.nomedia');
  if (!await nomediaFile.exists()) {
    await nomediaFile.create();
  }

  return directory;
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return true;
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fabichelo',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF161B22),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        cardColor: const Color(0xFF21262D),
      ),
      home: const MainPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// Singleton para el servicio de música - OPTIMIZACIÓN CLAVE
class MusicService {
  static final MusicService _instance = MusicService._internal();
  factory MusicService() => _instance;
  MusicService._internal();

  final AudioPlayer _audioPlayer = AudioPlayer();
  List<File> _songs = [];
  File? _currentSong;
  int _currentIndex = 0;
  bool _isInitialized = false;
  
  // StreamControllers optimizados con valores iniciales
  final _songsController = StreamController<List<File>>.broadcast();
  final _currentSongController = StreamController<File?>.broadcast();
  
  Stream<List<File>> get songsStream => _songsController.stream;
  Stream<File?> get currentSongStream => _currentSongController.stream;
  
  // Métodos para obtener el estado actual inmediatamente
  List<File> getCurrentSongs() => _songs;
  File? getCurrentSong() => _currentSong;
  
  List<File> get songs => _songs;
  File? get currentSong => _currentSong;
  AudioPlayer get audioPlayer => _audioPlayer;

  Future<void> initialize() async {
    if (_isInitialized) return;
    
    print('🎵 Inicializando MusicService...');
    await _requestPermissions();
    await loadSongs();
    _setupAudioPlayer();
    _isInitialized = true;
    print('✅ MusicService inicializado');
  }

  void _setupAudioPlayer() {
    _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        playNext();
      }
    });
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.storage,
        Permission.manageExternalStorage,
        Permission.notification,
      ].request();
    }
  }

  Future<Directory> getMusicDirectory() async {
    return await _getMusicDirectory();
  }

  Future<void> loadSongs() async {
    try {
      final musicDir = await getMusicDirectory();
      
      if (!await musicDir.exists()) {
        _songs = [];
        _songsController.add(_songs);
        return;
      }
      
      final allFiles = await musicDir.list().toList();
      final audioFiles = allFiles
          .where((file) => file is File && _isAudioFile(file.path))
          .map((file) => File(file.path))
          .toList();
      
      audioFiles.sort((a, b) => a.path.split('/').last.compareTo(b.path.split('/').last));
      
      _songs = audioFiles;
      _songsController.add(_songs);
      
      // Actualizar índice si la canción actual ya no existe
      if (_currentSong != null && !_songs.contains(_currentSong)) {
        _currentSong = null;
        _currentSongController.add(null);
        _currentIndex = 0;
      }
      
      print('🎶 Canciones cargadas: ${_songs.length}');
      
    } catch (e) {
      print('❌ Error cargando canciones: $e');
      _songs = [];
      _songsController.add(_songs);
    }
  }

  bool _isAudioFile(String path) {
    final lowerPath = path.toLowerCase();
    return lowerPath.endsWith('.mp3') ||
           lowerPath.endsWith('.webm') ||
           lowerPath.endsWith('.m4a') ||
           lowerPath.endsWith('.wav') ||
           lowerPath.endsWith('.aac') ||
           lowerPath.endsWith('.ogg');
  }

  Future<void> playSong(File song) async {
    try {
      if (!await song.exists()) {
        print('❌ El archivo no existe: ${song.path}');
        return;
      }
      
      print('🎵 Reproduciendo: ${getSongName(song)}');
      
      // SIEMPRE establecer la canción actual PRIMERO
      _currentSong = song;
      _currentIndex = _songs.indexOf(song);
      
      // Notificar INMEDIATAMENTE el cambio
      _currentSongController.add(_currentSong);
      print('✅ Canción establecida como actual: ${getSongName(song)}');
      
      // Si es la misma canción que ya está cargada, solo cambiar play/pause
      if (_audioPlayer.audioSource != null) {
        final currentPath = (_audioPlayer.audioSource as UriAudioSource?)?.uri.toFilePath();
        if (currentPath == song.path) {
          if (_audioPlayer.playing) {
            await _audioPlayer.pause();
            print('⏸️ Pausando canción actual');
          } else {
            await _audioPlayer.play();
            print('▶️ Reanudando canción actual');
          }
          return;
        }
      }
      
      // Cargar y reproducir nueva canción
      await _audioPlayer.stop();
      await _audioPlayer.setFilePath(song.path);
      await _audioPlayer.play();
      
      print('🎶 Reproduciendo nueva canción: ${getSongName(song)}');
      
    } catch (e) {
      print('❌ Error reproduciendo canción: $e');
      // En caso de error, mantener la canción como actual para que aparezca el mini player
      if (_currentSong == null) {
        _currentSong = song;
        _currentSongController.add(_currentSong);
      }
    }
  }

  String getSongName(File song) {
    return song.path.split('/').last
        .replaceAll(RegExp(r'\.(mp3|webm|m4a|wav|aac|ogg)$', caseSensitive: false), '');
  }

  Future<void> pauseResume() async {
    try {
      if (_audioPlayer.playing) {
        await _audioPlayer.pause();
      } else {
        await _audioPlayer.play();
      }
    } catch (e) {
      print('❌ Error en pauseResume: $e');
    }
  }

  Future<void> playNext() async {
    if (_songs.isNotEmpty) {
      _currentIndex = (_currentIndex + 1) % _songs.length;
      await playSong(_songs[_currentIndex]);
    }
  }

  Future<void> playPrevious() async {
    if (_songs.isNotEmpty) {
      _currentIndex = _currentIndex > 0 ? _currentIndex - 1 : _songs.length - 1;
      await playSong(_songs[_currentIndex]);
    }
  }

  Future<void> deleteSong(File song) async {
    try {
      if (_currentSong == song) {
        await _audioPlayer.stop();
        _currentSong = null;
        _currentSongController.add(null);
      }
      
      await song.delete();
      await loadSongs();
      
    } catch (e) {
      print('❌ Error eliminando canción: $e');
    }
  }

  void dispose() {
    _audioPlayer.dispose();
    _songsController.close();
    _currentSongController.close();
    _isInitialized = false;
  }
}

// Servicio de descarga mejorado con segundo plano
class DownloadService {
  static final Map<String, DownloadItem> _downloads = {};
  static final StreamController<Map<String, DownloadItem>> _downloadsController = 
      StreamController<Map<String, DownloadItem>>.broadcast();
  
  static Stream<Map<String, DownloadItem>> get downloadsStream => _downloadsController.stream;
  static Map<String, DownloadItem> get downloads => _downloads;
  static List<DownloadItem> get downloadsList => _downloads.values.toList();

  static FlutterBackgroundService? _service;
  static bool _isInitialized = false;

  static Future<void> initialize() async {
    if (_isInitialized) return;

    _service = FlutterBackgroundService();
    if (await _service!.isRunning()) {
      _setupServiceListeners();
      _isInitialized = true;
      print('✅ DownloadService inicializado');
    }
  }

  static void _setupServiceListeners() {
    _service!.on('downloadProgress').listen((event) {
      final downloadId = event!['downloadId'] as String;
      final progress = event['progress'] as int;
      final status = event['status'] as String;
      final filename = event['filename'] as String;

      _updateDownload(downloadId, 
        filename: filename,
        progress: progress,
        status: _stringToStatus(status)
      );
    });

    _service!.on('downloadCompleted').listen((event) {
      final downloadId = event!['downloadId'] as String;
      final filename = event['filename'] as String;

      _updateDownload(downloadId,
        filename: filename,
        progress: 100,
        status: DownloadStatus.completed
      );

      // Actualizar lista de música
      MusicService().loadSongs();
    });

    _service!.on('downloadError').listen((event) {
      final downloadId = event!['downloadId'] as String;
      final error = event['error'] as String;

      _updateDownload(downloadId,
        status: DownloadStatus.error,
        errorMessage: error
      );
    });
  }

  static DownloadStatus _stringToStatus(String status) {
    switch (status) {
      case 'preparing': return DownloadStatus.preparing;
      case 'downloading': return DownloadStatus.downloading;
      case 'completed': return DownloadStatus.completed;
      case 'error': return DownloadStatus.error;
      default: return DownloadStatus.preparing;
    }
  }

  static Future<void> addDownload(String url) async {
    await initialize();

    final downloadId = DateTime.now().millisecondsSinceEpoch.toString();
    
    if (_downloads.values.any((item) => item.url == url && 
        (item.status == DownloadStatus.preparing || item.status == DownloadStatus.downloading))) {
      throw Exception('Esta URL ya se está descargando');
    }

    final item = DownloadItem(
      id: downloadId,
      url: url,
      filename: 'Preparando descarga...',
      progress: 0,
      status: DownloadStatus.preparing,
    );

    _downloads[downloadId] = item;
    _downloadsController.add(_downloads);

    // Enviar al servicio de segundo plano
    _service!.invoke('startDownload', {
      'url': url,
      'downloadId': downloadId,
    });

    print('🌐 Descarga iniciada en segundo plano: $downloadId');
  }

  static void _updateDownload(String downloadId, {
    String? filename,
    int? progress,
    DownloadStatus? status,
    String? errorMessage,
  }) {
    if (_downloads.containsKey(downloadId)) {
      _downloads[downloadId] = _downloads[downloadId]!.copyWith(
        filename: filename,
        progress: progress,
        status: status,
        errorMessage: errorMessage,
      );
      _downloadsController.add(_downloads);
    }
  }

  static void removeDownload(String downloadId) {
    _downloads.remove(downloadId);
    _downloadsController.add(_downloads);
  }

  static void clearCompleted() {
    _downloads.removeWhere((key, item) => 
      item.status == DownloadStatus.completed || 
      item.status == DownloadStatus.error
    );
    _downloadsController.add(_downloads);
  }

  static void dispose() {
    _downloadsController.close();
  }
}

enum DownloadStatus { preparing, downloading, completed, error }

class DownloadItem {
  final String id;
  final String url;
  final String filename;
  final int progress;
  final DownloadStatus status;
  final String? errorMessage;

  DownloadItem({
    required this.id,
    required this.url,
    required this.filename,
    required this.progress,
    required this.status,
    this.errorMessage,
  });

  DownloadItem copyWith({
    String? filename,
    int? progress,
    DownloadStatus? status,
    String? errorMessage,
  }) {
    return DownloadItem(
      id: id,
      url: url,
      filename: filename ?? this.filename,
      progress: progress ?? this.progress,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({Key? key}) : super(key: key);

  @override
  _MainPageState createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> with TickerProviderStateMixin {
  late TabController _tabController;
  final MusicService _musicService = MusicService();
  
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _musicService.initialize();
    DownloadService.initialize();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                MusicPage(musicService: _musicService),
                const DownloadsPage(),
                const TtsPage(),
              ],
            ),
          ),
          // Mini Player
          StreamBuilder<File?>(
            stream: _musicService.currentSongStream,
            initialData: _musicService.getCurrentSong(), // Datos inmediatos
            builder: (context, snapshot) {
              final currentSong = snapshot.data ?? _musicService.getCurrentSong();
              print('🎵 MainPage - MiniPlayer - Canción: ${currentSong?.path}');
              
              if (currentSong != null) {
                return MiniPlayer(
                  musicService: _musicService,
                  onTap: () => _navigateToFullPlayer(),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          _buildTabBar(),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        boxShadow: [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 8,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: TabBar(
        controller: _tabController,
        tabs: [
          const Tab(icon: Icon(Icons.music_note), text: 'Música'),
          Tab(
            icon: Stack(
              children: [
                const Icon(Icons.download),
                StreamBuilder<Map<String, DownloadItem>>(
                  stream: DownloadService.downloadsStream,
                  builder: (context, snapshot) {
                    final downloads = snapshot.data ?? {};
                    final activeDownloads = downloads.values.where(
                      (item) => item.status == DownloadStatus.downloading || 
                               item.status == DownloadStatus.preparing
                    ).length;
                    
                    if (activeDownloads > 0) {
                      return Positioned(
                        right: 0,
                        top: 0,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            activeDownloads.toString(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
            text: 'Descargas',
          ),
          const Tab(icon: Icon(Icons.record_voice_over), text: 'TTS'),
        ],
        labelColor: Colors.green,
        unselectedLabelColor: Colors.grey,
        indicatorColor: Colors.green,
      ),
    );
  }

  void _navigateToFullPlayer() {
    final currentSong = _musicService.getCurrentSong();
    print('🎵 Navegando a FullPlayer con canción: ${currentSong?.path}');
    
    if (currentSong != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => FullPlayerPage(musicService: _musicService),
        ),
      );
    } else {
      print('⚠️ No hay canción actual para mostrar');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay canción reproduciéndose'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }
}

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({Key? key}) : super(key: key);

  @override
  _DownloadsPageState createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  final TextEditingController _urlController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Gestor de Descargas'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () => DownloadService.clearCompleted(),
            tooltip: 'Limpiar completadas',
          ),
        ],
      ),
      body: Column(
        children: [
          // Sección de agregar descarga
          Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    TextField(
                      controller: _urlController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Pega el link de YouTube',
                        labelStyle: const TextStyle(color: Colors.grey),
                        prefixIcon: const Icon(Icons.link, color: Colors.grey),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Colors.grey),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Colors.green),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _addDownload,
                      icon: const Icon(Icons.add_to_queue),
                      label: const Text('Descargar en Segundo Plano'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'La descarga continuará aunque cierres la app',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Lista de descargas
          Expanded(
            child: StreamBuilder<Map<String, DownloadItem>>(
              stream: DownloadService.downloadsStream,
              builder: (context, snapshot) {
                final downloads = snapshot.data ?? {};
                final downloadsList = downloads.values.toList();
                
                if (downloadsList.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.download_outlined, size: 64, color: Colors.grey),
                        SizedBox(height: 16),
                        Text(
                          'No hay descargas',
                          style: TextStyle(color: Colors.grey, fontSize: 18),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Agrega un enlace de YouTube para empezar',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: downloadsList.length,
                  itemBuilder: (context, index) {
                    final item = downloadsList[index];
                    return DownloadItemWidget(
                      item: item,
                      onRemove: () => DownloadService.removeDownload(item.id),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addDownload() async {
    final url = _urlController.text.trim();
    if (!url.contains('youtube.com') && !url.contains('youtu.be')) {
      _showMessage('URL no válida. Debe ser un enlace de YouTube', isError: true);
      return;
    }

    try {
      await DownloadService.addDownload(url);
      _urlController.clear();
      _showMessage('Descarga iniciada en segundo plano');
    } catch (e) {
      _showMessage(e.toString(), isError: true);
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }
}

class DownloadItemWidget extends StatelessWidget {
  final DownloadItem item;
  final VoidCallback onRemove;

  const DownloadItemWidget({
    Key? key,
    required this.item,
    required this.onRemove,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.filename,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _buildStatusIcon(),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  onPressed: onRemove,
                  tooltip: 'Eliminar',
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildProgressIndicator(),
            if (item.status == DownloadStatus.downloading ||
                item.status == DownloadStatus.preparing) ...[
              const SizedBox(height: 4),
              const Text(
                'Descarga en segundo plano activa',
                style: TextStyle(color: Colors.blue, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIcon() {
    switch (item.status) {
      case DownloadStatus.completed:
        return const Icon(Icons.check_circle, color: Colors.green);
      case DownloadStatus.error:
        return const Icon(Icons.error, color: Colors.red);
      case DownloadStatus.downloading:
        return const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
          ),
        );
      case DownloadStatus.preparing:
        return const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
          ),
        );
    }
  }

  Widget _buildProgressIndicator() {
    switch (item.status) {
      case DownloadStatus.downloading:
        return Column(
          children: [
            LinearProgressIndicator(
              value: item.progress / 100,
              backgroundColor: Colors.grey[700],
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.green),
            ),
            const SizedBox(height: 4),
            Text(
              '${item.progress}% - Descargando en segundo plano',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        );
      case DownloadStatus.error:
        return Text(
          'Error: ${item.errorMessage ?? "Error desconocido"}',
          style: const TextStyle(color: Colors.red, fontSize: 12),
        );
      case DownloadStatus.completed:
        return const Text(
          'Descarga completada ✓',
          style: TextStyle(color: Colors.green, fontSize: 12),
        );
      case DownloadStatus.preparing:
        return const Text(
          'Preparando descarga en segundo plano...',
          style: TextStyle(color: Colors.orange, fontSize: 12),
        );
    }
  }
}

class MiniPlayer extends StatelessWidget {
  final MusicService musicService;
  final VoidCallback onTap;

  const MiniPlayer({
    Key? key,
    required this.musicService,
    required this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 70,
        decoration: const BoxDecoration(
          color: Color(0xFF161B22),
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 8,
              offset: Offset(0, -2),
            ),
          ],
        ),
        child: StreamBuilder<File?>(
          stream: musicService.currentSongStream,
          initialData: musicService.getCurrentSong(), // Datos inmediatos
          builder: (context, snapshot) {
            final currentSong = snapshot.data ?? musicService.getCurrentSong();
            
            print('🎵 MiniPlayer - Canción actual: ${currentSong?.path}');
            
            if (currentSong == null) return const SizedBox.shrink();
            
            return Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  margin: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.green,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Icon(Icons.music_note, color: Colors.white),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        musicService.getSongName(currentSong),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const Text(
                        'Fabichelo',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                StreamBuilder<bool>(
                  stream: musicService.audioPlayer.playingStream,
                  builder: (context, snapshot) {
                    final isPlaying = snapshot.data ?? false;
                    return IconButton(
                      onPressed: musicService.pauseResume,
                      icon: Icon(
                        isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                      ),
                    );
                  },
                ),
                const SizedBox(width: 8),
              ],
            );
          },
        ),
      ),
    );
  }
}

class MusicPage extends StatelessWidget {
  final MusicService musicService;

  const MusicPage({Key? key, required this.musicService}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Mi Música'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => musicService.loadSongs(),
            tooltip: 'Actualizar lista',
          ),
        ],
      ),
      body: StreamBuilder<List<File>>(
        stream: musicService.songsStream,
        initialData: musicService.getCurrentSongs(), // Datos iniciales inmediatos
        builder: (context, snapshot) {
          final songs = snapshot.data ?? musicService.getCurrentSongs();
          
          print('🎵 MusicPage - Canciones mostradas: ${songs.length}');
          
          if (songs.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.music_off, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'No hay canciones',
                    style: TextStyle(color: Colors.grey, fontSize: 18),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Ve a la pestaña "Descargas" para\nagregar música desde YouTube',
                    style: TextStyle(color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: songs.length,
            itemBuilder: (context, index) {
              final song = songs[index];
              return StreamBuilder<File?>(
                stream: musicService.currentSongStream,
                initialData: musicService.getCurrentSong(), // Datos iniciales inmediatos
                builder: (context, currentSnapshot) {
                  final currentSong = currentSnapshot.data ?? musicService.getCurrentSong();
                  final isCurrent = currentSong?.path == song.path;
                  final songName = musicService.getSongName(song);

                  return ListTile(
                    tileColor: isCurrent ? Colors.green.withOpacity(0.1) : null,
                    leading: Icon(
                      isCurrent ? Icons.volume_up : Icons.music_note,
                      color: isCurrent ? Colors.green : Colors.white,
                    ),
                    title: Text(
                      songName,
                      style: TextStyle(
                        color: isCurrent ? Colors.green : Colors.white,
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    subtitle: Text(
                      '${(song.lengthSync() / (1024 * 1024)).toStringAsFixed(1)} MB',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    onTap: () {
                      print('🎵 Tocando canción desde lista: $songName');
                      musicService.playSong(song);
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () => _showDeleteDialog(context, song),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  void _showDeleteDialog(BuildContext context, File song) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF21262D),
        title: const Text('Eliminar canción', style: TextStyle(color: Colors.white)),
        content: Text(
          '¿Estás seguro de que quieres eliminar "${musicService.getSongName(song)}"?',
          style: const TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await musicService.deleteSong(song);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Canción eliminada'),
                  backgroundColor: Colors.green,
                ),
              );
            },
            child: const Text('Eliminar', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

class FullPlayerPage extends StatefulWidget {
  final MusicService musicService;

  const FullPlayerPage({Key? key, required this.musicService}) : super(key: key);

  @override
  _FullPlayerPageState createState() => _FullPlayerPageState();
}

class _FullPlayerPageState extends State<FullPlayerPage> {
  @override
  void initState() {
    super.initState();
    // Verificar que hay una canción al inicializar
    final currentSong = widget.musicService.getCurrentSong();
    print('🎵 FullPlayer iniciado - Canción actual: ${currentSong?.path}');
    
    if (currentSong == null) {
      // Si no hay canción, cerrar después de mostrar el frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.pop(context);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down, size: 28),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Reproduciendo'),
        centerTitle: true,
      ),
      body: StreamBuilder<File?>(
        stream: widget.musicService.currentSongStream,
        initialData: widget.musicService.getCurrentSong(), // ¡CLAVE! Datos inmediatos
        builder: (context, snapshot) {
          final currentSong = snapshot.data ?? widget.musicService.getCurrentSong();
          
          print('🎵 FullPlayer StreamBuilder - Canción: ${currentSong?.path}');
          print('🎵 FullPlayer - snapshot.hasData: ${snapshot.hasData}');
          print('🎵 FullPlayer - connectionState: ${snapshot.connectionState}');
          
          if (currentSong == null) {
            print('⚠️ FullPlayer - No hay canción actual');
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.music_off, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text(
                    'No hay canción seleccionada',
                    style: TextStyle(color: Colors.grey, fontSize: 18),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                    child: const Text('Volver a la lista'),
                  ),
                ],
              ),
            );
          }

          print('✅ FullPlayer - Mostrando reproductor para: ${widget.musicService.getSongName(currentSong)}');

          return Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              children: [
                const Spacer(),
                // Artwork
                Container(
                  width: 300,
                  height: 300,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    gradient: const LinearGradient(
                      colors: [Colors.green, Colors.teal],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.green.withOpacity(0.3),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.music_note,
                    size: 100,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 40),
                // Song title
                Text(
                  widget.musicService.getSongName(currentSong),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Fabichelo',
                  style: TextStyle(
                    color: Colors.grey,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 40),
                // Progress bar
                StreamBuilder<Duration>(
                  stream: widget.musicService.audioPlayer.positionStream,
                  builder: (context, positionSnapshot) {
                    return StreamBuilder<Duration?>(
                      stream: widget.musicService.audioPlayer.durationStream,
                      builder: (context, durationSnapshot) {
                        final position = positionSnapshot.data ?? Duration.zero;
                        final duration = durationSnapshot.data ?? Duration.zero;
                        
                        return Column(
                          children: [
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 4,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                              ),
                              child: Slider(
                                value: duration.inSeconds > 0
                                    ? position.inSeconds / duration.inSeconds
                                    : 0.0,
                                onChanged: (value) {
                                  final newPosition = Duration(
                                    seconds: (duration.inSeconds * value).round(),
                                  );
                                  widget.musicService.audioPlayer.seek(newPosition);
                                },
                                activeColor: Colors.green,
                                inactiveColor: Colors.grey[700],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    _formatDuration(position),
                                    style: const TextStyle(color: Colors.grey),
                                  ),
                                  Text(
                                    _formatDuration(duration),
                                    style: const TextStyle(color: Colors.grey),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 40),
                // Controls
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        onPressed: widget.musicService.playPrevious,
                        icon: const Icon(Icons.skip_previous, size: 30),
                        color: Colors.white,
                      ),
                    ),
                    StreamBuilder<bool>(
                      stream: widget.musicService.audioPlayer.playingStream,
                      builder: (context, snapshot) {
                        final isPlaying = snapshot.data ?? false;
                        return Container(
                          width: 80,
                          height: 80,
                          decoration: const BoxDecoration(
                            color: Colors.green,
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            onPressed: widget.musicService.pauseResume,
                            icon: Icon(
                              isPlaying ? Icons.pause : Icons.play_arrow,
                              size: 40,
                              color: Colors.white,
                            ),
                          ),
                        );
                      },
                    ),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        onPressed: widget.musicService.playNext,
                        icon: const Icon(Icons.skip_next, size: 30),
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                // Volume control
                StreamBuilder<double>(
                  stream: widget.musicService.audioPlayer.volumeStream,
                  builder: (context, snapshot) {
                    final volume = snapshot.data ?? 1.0;
                    return Row(
                      children: [
                        const Icon(Icons.volume_down, color: Colors.grey),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                            ),
                            child: Slider(
                              value: volume,
                              onChanged: (value) {
                                widget.musicService.audioPlayer.setVolume(value);
                              },
                              activeColor: Colors.green,
                              inactiveColor: Colors.grey[700],
                            ),
                          ),
                        ),
                        const Icon(Icons.volume_up, color: Colors.grey),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 20),
              ],
            ),
          );
        },
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }
}

class TtsPage extends StatefulWidget {
  const TtsPage({Key? key}) : super(key: key);

  @override
  _TtsPageState createState() => _TtsPageState();
}

class _TtsPageState extends State<TtsPage> {
  final FlutterTts _tts = FlutterTts();
  final TextEditingController _controller = TextEditingController();
  double _rate = 0.5;
  double _pitch = 1.0;
  double _volume = 1.0;
  bool _isSpeaking = false;

  @override
  void initState() {
    super.initState();
    _initTts();
  }

  void _initTts() {
    _tts.setStartHandler(() => setState(() => _isSpeaking = true));
    _tts.setCompletionHandler(() => setState(() => _isSpeaking = false));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Texto a Voz')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _controller,
              maxLines: 5,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Escribe algo...',
                hintStyle: const TextStyle(color: Colors.grey),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.grey),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.green),
                ),
              ),
            ),
            const SizedBox(height: 20),
            _buildSlider('Velocidad', Icons.speed, _rate, 0.1, 1.0, (v) => setState(() => _rate = v)),
            _buildSlider('Tono', Icons.graphic_eq, _pitch, 0.5, 2.0, (v) => setState(() => _pitch = v)),
            _buildSlider('Volumen', Icons.volume_up, _volume, 0.0, 1.0, (v) => setState(() => _volume = v)),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _toggleSpeech,
              icon: Icon(_isSpeaking ? Icons.stop : Icons.play_arrow),
              label: Text(_isSpeaking ? 'Detener' : 'Reproducir'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSlider(String label, IconData icon, double value, double min, double max, Function(double) onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 12),
          SizedBox(
            width: 80,
            child: Text(label, style: const TextStyle(color: Colors.white)),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: value,
                min: min,
                max: max,
                divisions: 20,
                activeColor: Colors.green,
                inactiveColor: Colors.grey[700],
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              value.toStringAsFixed(1),
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleSpeech() async {
    if (_controller.text.trim().isEmpty) return;

    if (_isSpeaking) {
      await _tts.stop();
      setState(() => _isSpeaking = false);
    } else {
      await _tts.setLanguage('es-ES');
      await _tts.setSpeechRate(_rate);
      await _tts.setPitch(_pitch);
      await _tts.setVolume(_volume);
      await _tts.speak(_controller.text.trim());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _tts.stop();
    super.dispose();
  }
}