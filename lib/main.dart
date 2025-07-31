import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'dart:async';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mi Música Pro',
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.indigo,
          foregroundColor: Colors.white,
          elevation: 4,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.indigo,
            foregroundColor: Colors.white,
            elevation: 3,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      ),
      home: MainPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainPage extends StatefulWidget {
  @override
  _MainPageState createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> with TickerProviderStateMixin {
  int _currentIndex = 0;
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: TabBarView(
        controller: _tabController,
        children: [
          MusicPage(),
          TtsPage(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 4,
              offset: Offset(0, -2),
            ),
          ],
        ),
        child: TabBar(
          controller: _tabController,
          tabs: [
            Tab(icon: Icon(Icons.music_note), text: 'Música'),
            Tab(icon: Icon(Icons.record_voice_over), text: 'Texto a Voz'),
          ],
          labelColor: Colors.indigo,
          unselectedLabelColor: Colors.grey,
          indicatorColor: Colors.indigo,
        ),
      ),
    );
  }
}

class MusicPage extends StatefulWidget {
  @override
  _MusicPageState createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> {
  final TextEditingController _urlController = TextEditingController();
  final AudioPlayer _audioPlayer = AudioPlayer();
  List<File> _songs = [];
  bool _isDownloading = false;
  bool _isPlaying = false;
  File? _currentSong;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  double _volume = 1.0;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _playingSubscription;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _loadSongs();
    _setupAudioPlayer();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.storage,
      Permission.manageExternalStorage,
    ].request();
  }

  void _setupAudioPlayer() {
    _positionSubscription = _audioPlayer.positionStream.listen((position) {
      if (mounted) {
        setState(() => _position = position);
      }
    });

    _durationSubscription = _audioPlayer.durationStream.listen((duration) {
      if (mounted) {
        setState(() => _duration = duration ?? Duration.zero);
      }
    });

    _playingSubscription = _audioPlayer.playingStream.listen((playing) {
      if (mounted) {
        setState(() => _isPlaying = playing);
      }
    });

    _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _playNext();
      }
    });
  }

  Future<Directory> _getMusicDirectory() async {
    final directory = await getApplicationDocumentsDirectory();
    final musicDir = Directory('${directory.path}/musica');
    if (!await musicDir.exists()) {
      await musicDir.create(recursive: true);
    }
    return musicDir;
  }

  Future<void> _loadSongs() async {
    try {
      final musicDir = await _getMusicDirectory();
      final files = musicDir
          .listSync()
          .where((file) => 
              file.path.endsWith('.mp3') ||
              file.path.endsWith('.webm') ||
              file.path.endsWith('.m4a') ||
              file.path.endsWith('.wav'))
          .map((file) => File(file.path))
          .toList();
      
      if (mounted) {
        setState(() => _songs = files);
      }
    } catch (e) {
      _showMessage('Error cargando canciones: $e');
    }
  }

  bool _isValidYouTubeUrl(String url) {
    final regex = RegExp(r'(https?\:\/\/)?(www\.)?(youtube\.com|youtu\.?be)\/.+');
    return regex.hasMatch(url);
  }

  Future<void> _downloadSong() async {
    final url = _urlController.text.trim();
    if (!_isValidYouTubeUrl(url)) {
      _showMessage('URL de YouTube no válida');
      return;
    }

    setState(() => _isDownloading = true);

    try {
      final response = await http.post(
        Uri.parse('https://servermusica-1.onrender.com/download'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'url': url}),
      ).timeout(Duration(minutes: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final filename = data['file'];
        final downloadUrl = 'https://servermusica-1.onrender.com/downloads/$filename';
        
        final audioResponse = await http.get(Uri.parse(downloadUrl));
        final musicDir = await _getMusicDirectory();
        final file = File('${musicDir.path}/$filename');
        
        await file.writeAsBytes(audioResponse.bodyBytes);
        _showMessage('Descargado: $filename');
        _urlController.clear();
        await _loadSongs();
      } else {
        final error = jsonDecode(response.body)['error'] ?? 'Error desconocido';
        _showMessage('Error: $error');
      }
    } catch (e) {
      _showMessage('Error de descarga: $e');
    } finally {
      if (mounted) {
        setState(() => _isDownloading = false);
      }
    }
  }

  Future<void> _playSong(File song) async {
    try {
      if (_currentSong == song && _isPlaying) {
        await _audioPlayer.pause();
      } else {
        setState(() => _currentSong = song);
        await _audioPlayer.setFilePath(song.path);
        await _audioPlayer.play();
      }
    } catch (e) {
      _showMessage('Error reproduciendo: $e');
    }
  }

  Future<void> _pauseResume() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.play();
    }
  }

  Future<void> _stop() async {
    await _audioPlayer.stop();
    if (mounted) {
      setState(() {
        _currentSong = null;
        _position = Duration.zero;
      });
    }
  }

  Future<void> _playNext() async {
    if (_currentSong != null && _songs.isNotEmpty) {
      final currentIndex = _songs.indexOf(_currentSong!);
      final nextIndex = (currentIndex + 1) % _songs.length;
      await _playSong(_songs[nextIndex]);
    }
  }

  Future<void> _playPrevious() async {
    if (_currentSong != null && _songs.isNotEmpty) {
      final currentIndex = _songs.indexOf(_currentSong!);
      final previousIndex = currentIndex > 0 ? currentIndex - 1 : _songs.length - 1;
      await _playSong(_songs[previousIndex]);
    }
  }

  void _seekTo(double seconds) {
    _audioPlayer.seek(Duration(seconds: seconds.toInt()));
  }

  void _setVolume(double volume) {
    setState(() => _volume = volume);
    _audioPlayer.setVolume(volume);
  }

  void _showMessage(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.indigo,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  Future<void> _deleteSong(File song) async {
    try {
      if (_currentSong == song) {
        await _stop();
      }
      await song.delete();
      await _loadSongs();
      _showMessage('Canción eliminada');
    } catch (e) {
      _showMessage('Error eliminando canción: $e');
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _audioPlayer.dispose();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Mi Música Pro'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Download Section
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey[50],
              border: Border(
                bottom: BorderSide(color: Colors.grey[300]!),
              ),
            ),
            child: Column(
              children: [
                TextField(
                  controller: _urlController,
                  decoration: InputDecoration(
                    labelText: 'Pega el link de YouTube',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    prefixIcon: Icon(Icons.link),
                  ),
                ),
                SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isDownloading ? null : _downloadSong,
                    icon: _isDownloading
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(Icons.download),
                    label: Text(_isDownloading ? 'Descargando...' : 'Descargar música'),
                  ),
                ),
              ],
            ),
          ),

          // Current Song Player
          if (_currentSong != null)
            Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.indigo[50],
                border: Border(
                  bottom: BorderSide(color: Colors.grey[300]!),
                ),
              ),
              child: Column(
                children: [
                  Text(
                    _currentSong!.path.split('/').last,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 8),
                  Row(
                    children: [
                      Text(_formatDuration(_position)),
                      Expanded(
                        child: Slider(
                          value: _position.inSeconds.toDouble(),
                          max: _duration.inSeconds.toDouble(),
                          onChanged: _seekTo,
                          activeColor: Colors.indigo,
                        ),
                      ),
                      Text(_formatDuration(_duration)),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        onPressed: _playPrevious,
                        icon: Icon(Icons.skip_previous, size: 30),
                        color: Colors.indigo,
                      ),
                      IconButton(
                        onPressed: _pauseResume,
                        icon: Icon(
                          _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                          size: 50,
                        ),
                        color: Colors.indigo,
                      ),
                      IconButton(
                        onPressed: _playNext,
                        icon: Icon(Icons.skip_next, size: 30),
                        color: Colors.indigo,
                      ),
                      IconButton(
                        onPressed: _stop,
                        icon: Icon(Icons.stop, size: 30),
                        color: Colors.red,
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Icon(Icons.volume_down),
                      Expanded(
                        child: Slider(
                          value: _volume,
                          onChanged: _setVolume,
                          activeColor: Colors.indigo,
                        ),
                      ),
                      Icon(Icons.volume_up),
                    ],
                  ),
                ],
              ),
            ),

          // Songs List
          Expanded(
            child: _songs.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.music_off, size: 64, color: Colors.grey),
                        SizedBox(height: 16),
                        Text(
                          'No hay canciones aún',
                          style: TextStyle(fontSize: 18, color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _songs.length,
                    itemBuilder: (context, index) {
                      final song = _songs[index];
                      final isCurrentSong = _currentSong == song;
                      
                      return Container(
                        margin: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: isCurrentSong ? Colors.indigo[50] : null,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ListTile(
                          leading: Container(
                            padding: EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: isCurrentSong ? Colors.indigo : Colors.grey[300],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(
                              isCurrentSong && _isPlaying ? Icons.music_note : Icons.music_note_outlined,
                              color: isCurrentSong ? Colors.white : Colors.grey[600],
                            ),
                          ),
                          title: Text(
                            song.path.split('/').last,
                            style: TextStyle(
                              fontWeight: isCurrentSong ? FontWeight.bold : FontWeight.normal,
                              color: isCurrentSong ? Colors.indigo : null,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                onPressed: () => _playSong(song),
                                icon: Icon(
                                  isCurrentSong && _isPlaying ? Icons.pause : Icons.play_arrow,
                                  color: Colors.indigo,
                                ),
                              ),
                              PopupMenuButton(
                                itemBuilder: (context) => [
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Row(
                                      children: [
                                        Icon(Icons.delete, color: Colors.red),
                                        SizedBox(width: 8),
                                        Text('Eliminar'),
                                      ],
                                    ),
                                  ),
                                ],
                                onSelected: (value) {
                                  if (value == 'delete') {
                                    showDialog(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: Text('Eliminar canción'),
                                        content: Text('¿Estás seguro de que quieres eliminar esta canción?'),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(context),
                                            child: Text('Cancelar'),
                                          ),
                                          TextButton(
                                            onPressed: () {
                                              Navigator.pop(context);
                                              _deleteSong(song);
                                            },
                                            child: Text('Eliminar', style: TextStyle(color: Colors.red)),
                                          ),
                                        ],
                                      ),
                                    );
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class TtsPage extends StatefulWidget {
  @override
  _TtsPageState createState() => _TtsPageState();
}

class _TtsPageState extends State<TtsPage> {
  final FlutterTts _flutterTts = FlutterTts();
  final TextEditingController _textController = TextEditingController();
  double _speechRate = 0.5;
  double _pitch = 1.0;
  double _volume = 1.0;
  bool _isSpeaking = false;
  List<String> _languages = [];
  String _selectedLanguage = "es-ES";

  @override
  void initState() {
    super.initState();
    _initTts();
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage(_selectedLanguage);
    await _flutterTts.setSpeechRate(_speechRate);
    await _flutterTts.setPitch(_pitch);
    await _flutterTts.setVolume(_volume);

    _flutterTts.setStartHandler(() {
      if (mounted) {
        setState(() => _isSpeaking = true);
      }
    });

    _flutterTts.setCompletionHandler(() {
      if (mounted) {
        setState(() => _isSpeaking = false);
      }
    });

    _flutterTts.setErrorHandler((msg) {
      if (mounted) {
        setState(() => _isSpeaking = false);
        _showMessage('Error: $msg');
      }
    });

    // Obtener idiomas disponibles
    final languages = await _flutterTts.getLanguages;
    if (languages != null && mounted) {
      setState(() {
        _languages = List<String>.from(languages);
      });
    }
  }

  Future<void> _speak() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      _showMessage('Ingresa texto para leer');
      return;
    }

    if (_isSpeaking) {
      await _flutterTts.stop();
    } else {
      await _flutterTts.setLanguage(_selectedLanguage);
      await _flutterTts.setSpeechRate(_speechRate);
      await _flutterTts.setPitch(_pitch);
      await _flutterTts.setVolume(_volume);
      await _flutterTts.speak(text);
    }
  }

  Future<void> _stop() async {
    await _flutterTts.stop();
    if (mounted) {
      setState(() => _isSpeaking = false);
    }
  }

  void _showMessage(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.deepPurple,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  void dispose() {
    _flutterTts.stop();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Texto a Voz'),
        centerTitle: true,
        backgroundColor: Colors.deepPurple,
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Text Input
            Card(
              elevation: 4,
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Texto a leer:',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.deepPurple,
                      ),
                    ),
                    SizedBox(height: 8),
                    TextField(
                      controller: _textController,
                      maxLines: 5,
                      decoration: InputDecoration(
                        hintText: 'Escribe aquí el texto que quieres que lea...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(color: Colors.deepPurple),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            SizedBox(height: 16),

            // Language Selection
            if (_languages.isNotEmpty)
              Card(
                elevation: 4,
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Idioma:',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.deepPurple,
                        ),
                      ),
                      SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        value: _selectedLanguage,
                        decoration: InputDecoration(
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        items: _languages.map((language) {
                          return DropdownMenuItem(
                            value: language,
                            child: Text(language),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _selectedLanguage = value);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),

            SizedBox(height: 16),

            // Controls
            Card(
              elevation: 4,
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Configuración:',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.deepPurple,
                      ),
                    ),
                    SizedBox(height: 16),

                    // Speech Rate
                    Row(
                      children: [
                        Icon(Icons.speed, color: Colors.deepPurple),
                        SizedBox(width: 8),
                        Text('Velocidad:'),
                        Expanded(
                          child: Slider(
                            value: _speechRate,
                            min: 0.1,
                            max: 1.0,
                            divisions: 9,
                            label: _speechRate.toStringAsFixed(1),
                            activeColor: Colors.deepPurple,
                            onChanged: (value) => setState(() => _speechRate = value),
                          ),
                        ),
                        Text(_speechRate.toStringAsFixed(1)),
                      ],
                    ),

                    // Pitch
                    Row(
                      children: [
                        Icon(Icons.graphic_eq, color: Colors.deepPurple),
                        SizedBox(width: 8),
                        Text('Tono:'),
                        Expanded(
                          child: Slider(
                            value: _pitch,
                            min: 0.5,
                            max: 2.0,
                            divisions: 15,
                            label: _pitch.toStringAsFixed(1),
                            activeColor: Colors.deepPurple,
                            onChanged: (value) => setState(() => _pitch = value),
                          ),
                        ),
                        Text(_pitch.toStringAsFixed(1)),
                      ],
                    ),

                    // Volume
                    Row(
                      children: [
                        Icon(Icons.volume_up, color: Colors.deepPurple),
                        SizedBox(width: 8),
                        Text('Volumen:'),
                        Expanded(
                          child: Slider(
                            value: _volume,
                            min: 0.0,
                            max: 1.0,
                            divisions: 10,
                            label: _volume.toStringAsFixed(1),
                            activeColor: Colors.deepPurple,
                            onChanged: (value) => setState(() => _volume = value),
                          ),
                        ),
                        Text(_volume.toStringAsFixed(1)),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            SizedBox(height: 24),

            // Action Buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _speak,
                    icon: Icon(_isSpeaking ? Icons.stop : Icons.play_arrow),
                    label: Text(_isSpeaking ? 'Detener' : 'Reproducir'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepPurple,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                if (_isSpeaking) ...[
                  SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _stop,
                      icon: Icon(Icons.stop),
                      label: Text('Parar'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),

            SizedBox(height: 16),

            // Clear Text Button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  _textController.clear();
                  _stop();
                },
                icon: Icon(Icons.clear),
                label: Text('Limpiar texto'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.deepPurple,
                  side: BorderSide(color: Colors.deepPurple),
                  padding: EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}