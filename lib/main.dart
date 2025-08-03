import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'dart:async';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
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
    _tabController = TabController(length: 2, vsync: this);
    _musicService.initialize();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _musicService.dispose();
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
                const TtsPage(),
              ],
            ),
          ),
          // Mini Player - SIEMPRE escucha el stream
          StreamBuilder<File?>(
            stream: _musicService.currentSongStream,
            builder: (context, snapshot) {
              final currentSong = snapshot.data;
              print('🎵 Mini Player - Current song: ${currentSong?.path}'); // Debug
              
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
        tabs: const [
          Tab(icon: Icon(Icons.music_note), text: 'Música'),
          Tab(icon: Icon(Icons.record_voice_over), text: 'TTS'),
        ],
        labelColor: Colors.green,
        unselectedLabelColor: Colors.grey,
        indicatorColor: Colors.green,
      ),
    );
  }

  void _navigateToFullPlayer() {
    // Verificar que hay una canción actual antes de navegar
    if (_musicService.currentSong != null) {
      print('🎵 Navegando a reproductor completo con: ${_musicService.currentSong!.path}');
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => FullPlayerPage(musicService: _musicService),
        ),
      );
    } else {
      print('⚠️ No hay canción actual para mostrar en reproductor completo');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay canción reproduciéndose'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }
}

// Servicio de música corregido
class MusicService {
  final AudioPlayer _audioPlayer = AudioPlayer();
  List<File> _songs = [];
  File? _currentSong;
  int _currentIndex = 0;
  
  // StreamControllers con mejor manejo
  final _songsController = StreamController<List<File>>.broadcast();
  final _currentSongController = StreamController<File?>.broadcast();
  
  Stream<List<File>> get songsStream => _songsController.stream;
  Stream<File?> get currentSongStream => _currentSongController.stream;
  
  // Getter sincronizado para hasCurrentSong
  Stream<bool> get hasCurrentSongStream => 
      _currentSongController.stream.map((song) => song != null);
  
  List<File> get songs => _songs;
  File? get currentSong => _currentSong;
  AudioPlayer get audioPlayer => _audioPlayer;

  void initialize() {
    _requestPermissions();
    loadSongs();
    _setupAudioPlayer();
  }

  void _setupAudioPlayer() {
    _audioPlayer.playerStateStream.listen((state) {
      print('🎵 Estado del reproductor: ${state.processingState}');
      if (state.processingState == ProcessingState.completed) {
        playNext();
      }
    });
    
    // Escuchar cuando el audio se carga exitosamente
    _audioPlayer.durationStream.listen((duration) {
      if (duration != null && _currentSong != null) {
        print('🎶 Audio cargado correctamente: ${getSongName(_currentSong!)}');
        // Re-notificar que tenemos una canción actual
        _currentSongController.add(_currentSong);
      }
    });
  }

  Future<void> _requestPermissions() async {
    print('🔐 Solicitando permisos...');
    
    if (Platform.isAndroid) {
      // Para Android 13+ (API 33+)
      Map<Permission, PermissionStatus> statuses = await [
        Permission.storage,
        Permission.manageExternalStorage,
        Permission.notification,
      ].request();
      
      print('📱 Estado de permisos:');
      statuses.forEach((permission, status) {
        print('   ${permission.toString()}: ${status.toString()}');
      });
      
      // Si no tenemos permisos, mostrar mensaje al usuario
      if (statuses[Permission.storage] != PermissionStatus.granted &&
          statuses[Permission.manageExternalStorage] != PermissionStatus.granted) {
        print('❌ Sin permisos de almacenamiento');
      } else {
        print('✅ Permisos de almacenamiento concedidos');
      }
    }
  }

  Future<Directory> getMusicDirectory() async {
    print('📁 Obteniendo directorio de música...');
    
    Directory? directory;
    if (Platform.isAndroid) {
      // Intentar múltiples rutas
      List<String> possiblePaths = [
        '/storage/emulated/0/Download/Fabichelo',
        '/storage/emulated/0/Music/Fabichelo',
        '/storage/emulated/0/Documents/Fabichelo',
      ];
      
      for (String path in possiblePaths) {
        try {
          directory = Directory(path);
          await directory.create(recursive: true);
          print('✅ Directorio creado en: $path');
          break;
        } catch (e) {
          print('❌ No se pudo crear directorio en: $path - Error: $e');
          continue;
        }
      }
      
      // Si ninguna ruta funciona, usar el directorio de la app
      if (directory == null || !await directory.exists()) {
        final appDir = await getApplicationDocumentsDirectory();
        directory = Directory('${appDir.path}/Fabichelo');
        print('📱 Usando directorio de la app: ${directory.path}');
      }
    } else {
      final appDir = await getApplicationDocumentsDirectory();
      directory = Directory('${appDir.path}/Fabichelo');
    }

    // Crear el directorio si no existe
    if (!await directory.exists()) {
      await directory.create(recursive: true);
      print('📁 Directorio creado: ${directory.path}');
    }

    // Crear archivo .nomedia para evitar que aparezca en la galería
    final nomediaFile = File('${directory.path}/.nomedia');
    if (!await nomediaFile.exists()) {
      await nomediaFile.create();
      print('🚫 Archivo .nomedia creado');
    }

    print('📂 Directorio final: ${directory.path}');
    return directory;
  }

  Future<void> loadSongs() async {
    print('🎵 Cargando canciones...');
    try {
      final musicDir = await getMusicDirectory();
      print('📁 Buscando archivos en: ${musicDir.path}');
      
      // Verificar si el directorio existe
      if (!await musicDir.exists()) {
        print('❌ El directorio no existe');
        _songs = [];
        _songsController.add(_songs);
        return;
      }
      
      // Listar todos los archivos
      final allFiles = await musicDir.list().toList();
      print('📂 Total de archivos encontrados: ${allFiles.length}');
      
      // Filtrar solo archivos de audio
      final audioFiles = allFiles
          .where((file) => file is File && _isAudioFile(file.path))
          .map((file) => File(file.path))
          .toList();
      
      // Ordenar por nombre
      audioFiles.sort((a, b) => a.path.split('/').last.compareTo(b.path.split('/').last));
      
      print('🎶 Archivos de audio encontrados: ${audioFiles.length}');
      audioFiles.forEach((file) {
        print('   - ${file.path.split('/').last}');
      });
      
      _songs = audioFiles;
      _songsController.add(_songs);
      
      // Actualizar índice si la canción actual ya no existe
      if (_currentSong != null && !_songs.contains(_currentSong)) {
        print('⚠️ Canción actual eliminada, limpiando...');
        _currentSong = null;
        _currentSongController.add(null);
        _currentIndex = 0;
      }
      
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
           lowerPath.endsWith('.ogg') ||
           lowerPath.endsWith('.flac');
  }

  Future<void> playSong(File song) async {
    try {
      print('🎵 Intentando reproducir: ${song.path}');
      
      // Verificar que el archivo existe
      if (!await song.exists()) {
        print('❌ El archivo no existe: ${song.path}');
        return;
      }
      
      // Si es la misma canción y está reproduciendo, pausar/reanudar
      if (_currentSong?.path == song.path && _audioPlayer.playing) {
        await _audioPlayer.pause();
        print('⏸️ Pausando canción actual');
        return;
      }
      
      // Si es la misma canción pero está pausada, reanudar
      if (_currentSong?.path == song.path && !_audioPlayer.playing) {
        await _audioPlayer.play();
        print('▶️ Reanudando canción actual');
        return;
      }
      
      // DETENER cualquier reproducción actual
      await _audioPlayer.stop();
      
      // Establecer nueva canción ANTES de cualquier operación
      _currentSong = song;
      _currentIndex = _songs.indexOf(song);
      
      // Notificar INMEDIATAMENTE el cambio
      _currentSongController.add(_currentSong);
      print('✅ Canción actual establecida: ${getSongName(song)}');
      
      // Configurar y reproducir audio
      await _audioPlayer.setFilePath(song.path);
      await _audioPlayer.play();
      
      print('🎶 Reproduciendo: ${getSongName(song)}');
      
    } catch (e) {
      print('❌ Error reproduciendo canción: $e');
      // En caso de error, limpiar estado
      _currentSong = null;
      _currentSongController.add(null);
    }
  }

  String getSongName(File song) {
    return song.path.split('/').last
        .replaceAll(RegExp(r'\.(mp3|webm|m4a|wav|aac|ogg|flac)$', caseSensitive: false), '');
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
      final nextSong = _songs[_currentIndex];
      
      print('🎵 Cambiando a siguiente canción: ${getSongName(nextSong)}');
      
      try {
        // Verificar que el archivo existe
        if (!await nextSong.exists()) {
          print('❌ El archivo no existe: ${nextSong.path}');
          return;
        }
        
        // DETENER música actual
        await _audioPlayer.stop();
        
        // Establecer nueva canción INMEDIATAMENTE
        _currentSong = nextSong;
        _currentSongController.add(_currentSong);
        
        // Configurar y reproducir SIN pausa
        await _audioPlayer.setFilePath(nextSong.path);
        await _audioPlayer.play();
        
        print('✅ Reproduciendo siguiente: ${getSongName(nextSong)}');
        
      } catch (e) {
        print('❌ Error cambiando a siguiente canción: $e');
      }
    }
  }

  Future<void> playPrevious() async {
    if (_songs.isNotEmpty) {
      _currentIndex = _currentIndex > 0 ? _currentIndex - 1 : _songs.length - 1;
      final previousSong = _songs[_currentIndex];
      
      print('🎵 Cambiando a canción anterior: ${getSongName(previousSong)}');
      
      try {
        // Verificar que el archivo existe
        if (!await previousSong.exists()) {
          print('❌ El archivo no existe: ${previousSong.path}');
          return;
        }
        
        // DETENER música actual
        await _audioPlayer.stop();
        
        // Establecer nueva canción INMEDIATAMENTE
        _currentSong = previousSong;
        _currentSongController.add(_currentSong);
        
        // Configurar y reproducir SIN pausa
        await _audioPlayer.setFilePath(previousSong.path);
        await _audioPlayer.play();
        
        print('✅ Reproduciendo anterior: ${getSongName(previousSong)}');
        
      } catch (e) {
        print('❌ Error cambiando a canción anterior: $e');
      }
    }
  }

  Future<void> deleteSong(File song) async {
    try {
      // Si es la canción actual, detener reproducción
      if (_currentSong == song) {
        await _audioPlayer.stop();
        _currentSong = null;
        _currentSongController.add(null);
      }
      
      // Eliminar archivo
      await song.delete();
      print('🗑️ Archivo eliminado: ${song.path}');
      
      // Recargar lista
      await loadSongs();
      
    } catch (e) {
      print('❌ Error eliminando canción: $e');
    }
  }

  void dispose() {
    _audioPlayer.dispose();
    _songsController.close();
    _currentSongController.close();
  }
}

// Mini reproductor con mejor detección
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
    return StreamBuilder<File?>(
      stream: musicService.currentSongStream,
      builder: (context, snapshot) {
        final currentSong = snapshot.data;
        print('🎵 MiniPlayer render - Current song: ${currentSong?.path}'); // Debug
        
        // Si no hay canción, no mostrar nada
        if (currentSong == null) {
          print('🎵 MiniPlayer - No hay canción, ocultando');
          return const SizedBox.shrink();
        }
        
        return GestureDetector(
          onTap: () {
            print('🎵 MiniPlayer tocado - navegando a reproductor completo');
            onTap();
          },
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
            child: Row(
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
                      onPressed: () {
                        print('🎵 MiniPlayer - botón play/pause presionado');
                        musicService.pauseResume();
                      },
                      icon: Icon(
                        isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                      ),
                    );
                  },
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        );
      },
    );
  }
}

// Página de música mejorada
class MusicPage extends StatelessWidget {
  final MusicService musicService;

  const MusicPage({Key? key, required this.musicService}) : super(key: key);

  void _showPermissionsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF21262D),
        title: const Text('Información de Permisos', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Para descargar música necesitas:',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            const Text(
              '• Acceso a almacenamiento\n• Permisos de escritura\n• Conexión a internet',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 15),
            const Text(
              'Si las descargas no funcionan:',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 5),
            const Text(
              '1. Ve a Configuración > Aplicaciones > Fabichelo\n2. Permite "Administrar archivos"\n3. Reinicia la app',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await musicService._requestPermissions();
              await musicService.getMusicDirectory();
            },
            child: const Text('Verificar Permisos', style: TextStyle(color: Colors.green)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Fabichelo Musica'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => musicService.loadSongs(),
            tooltip: 'Actualizar lista',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => _showPermissionsDialog(context),
          ),
          IconButton(
            icon: const Icon(Icons.folder),
            onPressed: () async {
              final dir = await musicService.getMusicDirectory();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Ruta: ${dir.path}'),
                  backgroundColor: Colors.green,
                  duration: const Duration(seconds: 4),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          DownloadSection(musicService: musicService),
          Expanded(child: SongsList(musicService: musicService)),
        ],
      ),
    );
  }
}

// Sección de descarga optimizada
class DownloadSection extends StatefulWidget {
  final MusicService musicService;

  const DownloadSection({Key? key, required this.musicService}) : super(key: key);

  @override
  _DownloadSectionState createState() => _DownloadSectionState();
}

class _DownloadSectionState extends State<DownloadSection> {
  final TextEditingController _urlController = TextEditingController();
  bool _isDownloading = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
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
                onPressed: _isDownloading ? null : _downloadSong,
                icon: _isDownloading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.download),
                label: Text(_isDownloading ? 'Descargando...' : 'Descargar'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _downloadSong() async {
    final url = _urlController.text.trim();
    if (!url.contains('youtube.com') && !url.contains('youtu.be')) {
      _showMessage('URL no válida');
      return;
    }

    setState(() => _isDownloading = true);
    print('⬇️ Iniciando descarga para: $url');

    try {
      print('🌐 Enviando solicitud al servidor...');
      final response = await http.post(
        Uri.parse('https://servermusica-1.onrender.com/download'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'url': url}),
      ).timeout(const Duration(minutes: 5));

      print('📡 Respuesta del servidor: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final filename = data['file'];
        final downloadUrl = 'https://servermusica-1.onrender.com/downloads/$filename';

        print('📥 Descargando archivo: $filename');
        print('🔗 URL de descarga: $downloadUrl');

        final audioResponse = await http.get(Uri.parse(downloadUrl));
        print('📦 Tamaño del archivo: ${audioResponse.bodyBytes.length} bytes');

        final dir = await widget.musicService.getMusicDirectory();
        final file = File('${dir.path}/$filename');
        
        print('💾 Guardando archivo en: ${file.path}');
        await file.writeAsBytes(audioResponse.bodyBytes);
        
        // Verificar que el archivo se guardó correctamente
        if (await file.exists()) {
          final fileSize = await file.length();
          print('✅ Archivo guardado exitosamente. Tamaño: $fileSize bytes');
          _showMessage('Descargado: $filename');
        } else {
          print('❌ Error: El archivo no se guardó correctamente');
          _showMessage('Error: No se pudo guardar el archivo');
        }

        _urlController.clear();
        await widget.musicService.loadSongs();
      } else {
        final error = jsonDecode(response.body)['error'] ?? 'Error desconocido';
        print('❌ Error del servidor: $error');
        _showMessage('Error: $error');
      }
    } catch (e) {
      print('❌ Error durante la descarga: $e');
      _showMessage('Error: $e');
    } finally {
      setState(() => _isDownloading = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
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

// Lista de canciones corregida
class SongsList extends StatelessWidget {
  final MusicService musicService;

  const SongsList({Key? key, required this.musicService}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<File>>(
      stream: musicService.songsStream,
      builder: (context, snapshot) {
        final songs = snapshot.data ?? [];
        
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
                  'Descarga música o coloca archivos\nen la carpeta Fabichelo',
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
              builder: (context, currentSnapshot) {
                final isCurrent = currentSnapshot.data?.path == song.path;
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
                    print('🎵 Tocando canción: $songName');
                    print('🎵 Archivo existe: ${song.existsSync()}');
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

// Reproductor completo con inicialización mejorada
class FullPlayerPage extends StatefulWidget {
  final MusicService musicService;

  const FullPlayerPage({Key? key, required this.musicService}) : super(key: key);

  @override
  _FullPlayerPageState createState() => _FullPlayerPageState();
}

class _FullPlayerPageState extends State<FullPlayerPage> {
  File? _initialSong;

  @override
  void initState() {
    super.initState();
    // Capturar la canción actual al inicializar
    _initialSong = widget.musicService.currentSong;
    print('🎵 FullPlayer inicializado con canción: ${_initialSong?.path}');
    
    // Si no hay canción inicial, cerrar la pantalla
    if (_initialSong == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pop(context);
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
        initialData: _initialSong, // Usar la canción inicial como dato inicial
        builder: (context, snapshot) {
          final currentSong = snapshot.data ?? _initialSong; // Fallback a la canción inicial
          print('🎵 FullPlayer - Current song: ${currentSong?.path}');
          print('🎵 FullPlayer - Initial song: ${_initialSong?.path}');
          print('🎵 FullPlayer - Snapshot connectionState: ${snapshot.connectionState}');
          print('🎵 FullPlayer - Snapshot hasData: ${snapshot.hasData}');
          
          if (currentSong == null) {
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
                  const SizedBox(height: 8),
                  const Text(
                    'Selecciona una canción para reproducir',
                    style: TextStyle(color: Colors.grey),
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

// Página TTS optimizada
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