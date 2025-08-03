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
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fabichelo',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Color(0xFF0D1117),
        appBarTheme: AppBarTheme(
          backgroundColor: Color(0xFF161B22),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        bottomNavigationBarTheme: BottomNavigationBarThemeData(
          backgroundColor: Color(0xFF161B22),
          selectedItemColor: Colors.green,
          unselectedItemColor: Colors.grey,
        ),
        cardColor: Color(0xFF21262D),
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
  final AudioPlayer _audioPlayer = AudioPlayer();
  List<File> _songs = [];
  File? _currentSong;
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  double _volume = 1.0;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _playingSubscription;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _requestPermissions();
    _loadSongs();
    _setupAudioPlayer();
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.storage,
      Permission.manageExternalStorage,
      Permission.notification,
    ].request();
  }

  void _setupAudioPlayer() {
    _positionSubscription = _audioPlayer.positionStream.listen((position) {
      if (mounted) setState(() => _position = position);
    });

    _durationSubscription = _audioPlayer.durationStream.listen((duration) {
      if (mounted) setState(() => _duration = duration ?? Duration.zero);
    });

    _playingSubscription = _audioPlayer.playingStream.listen((playing) {
      if (mounted) setState(() => _isPlaying = playing);
    });

    _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _playNext();
      }
    });
  }

  Future<Directory> _getMusicDirectory() async {
    Directory? directory;
    if (Platform.isAndroid) {
      directory = Directory('/storage/emulated/0/Download/Fabichelo');
    } else {
      final appDir = await getApplicationDocumentsDirectory();
      directory = Directory('${appDir.path}/Fabichelo');
    }

    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    final nomediaFile = File('${directory.path}/.nomedia');
    if (!await nomediaFile.exists()) {
      await nomediaFile.create();
    }

    return directory;
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
      if (mounted) setState(() => _songs = files);
    } catch (e) {
      _showMessage('Error cargando canciones: $e');
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

  void _showMessage(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.green,
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

  void _seekTo(double seconds) {
    _audioPlayer.seek(Duration(seconds: seconds.toInt()));
  }

  void _setVolume(double volume) {
    setState(() => _volume = volume);
    _audioPlayer.setVolume(volume);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _audioPlayer.dispose();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playingSubscription?.cancel();
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
                _buildMusicPage(),
                _buildTtsPage(),
              ],
            ),
          ),
          if (_currentSong != null) _buildFullPlayer(),
          Container(
            decoration: BoxDecoration(
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
                Tab(icon: Icon(Icons.music_note), text: 'Música'),
                Tab(icon: Icon(Icons.record_voice_over), text: 'TTS'),
              ],
              labelColor: Colors.green,
              unselectedLabelColor: Colors.grey,
              indicatorColor: Colors.green,
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildFullPlayer() {
    return Container(
      height: 90,
      decoration: BoxDecoration(
        color: Color(0xFF161B22),
        boxShadow: [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 8,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            height: 2,
            child: LinearProgressIndicator(
              value: _duration.inSeconds > 0
                  ? _position.inSeconds / _duration.inSeconds
                  : 0.0,
              backgroundColor: Colors.grey[800],
              valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Container(
                  width: 60,
                  height: 60,
                  margin: EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.green,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Icon(Icons.music_note, color: Colors.white, size: 24),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _currentSong!.path.split('/').last.replaceAll('.mp3', '').replaceAll('.webm', ''),
                          style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        SizedBox(height: 2),
                        Text(
                          '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _playPrevious,
                  icon: Icon(Icons.skip_previous, color: Colors.white),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    onPressed: _pauseResume,
                    icon: Icon(
                      _isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _playNext,
                  icon: Icon(Icons.skip_next, color: Colors.white),
                ),
                Container(
                  width: 80,
                  child: Row(
                    children: [
                      Icon(Icons.volume_down, color: Colors.grey, size: 16),
                      Expanded(
                        child: Slider(
                          value: _volume,
                          onChanged: _setVolume,
                          activeColor: Colors.green,
                          inactiveColor: Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildMusicPage() {
    final TextEditingController urlController = TextEditingController();
    bool isDownloading = false;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text('Fabichelo Musica'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(Icons.folder),
            onPressed: () async {
              final dir = await _getMusicDirectory();
              _showMessage('Ruta: ${dir.path}');
            },
          ),
        ],
      ),
      body: StatefulBuilder(
        builder: (context, setState) {
          return Column(
            children: [
              Padding(
                padding: EdgeInsets.all(16),
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      children: [
                        TextField(
                          controller: urlController,
                          style: TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'Pega el link de YouTube',
                            labelStyle: TextStyle(color: Colors.grey),
                            prefixIcon: Icon(Icons.link, color: Colors.grey),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: Colors.grey),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: Colors.green),
                            ),
                          ),
                        ),
                        SizedBox(height: 12),
                        ElevatedButton.icon(
                          onPressed: isDownloading ? null : () async {
                            final url = urlController.text.trim();
                            if (!url.contains('youtube.com') && !url.contains('youtu.be')) {
                              _showMessage('URL no válida');
                              return;
                            }

                            setState(() => isDownloading = true);

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
                                final dir = await _getMusicDirectory();
                                final file = File('${dir.path}/$filename');
                                await file.writeAsBytes(audioResponse.bodyBytes);

                                _showMessage('Descargado: $filename');
                                urlController.clear();
                                await _loadSongs();
                              } else {
                                final error = jsonDecode(response.body)['error'] ?? 'Error desconocido';
                                _showMessage('Error: $error');
                              }
                            } catch (e) {
                              _showMessage('Error: $e');
                            } finally {
                              setState(() => isDownloading = false);
                            }
                          },
                          icon: isDownloading
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Icon(Icons.download),
                          label: Text(isDownloading ? 'Descargando...' : 'Descargar'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            padding: EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(child: _buildSongsList()),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSongsList() {
    if (_songs.isEmpty) {
      return Center(
        child: Text('No hay canciones', style: TextStyle(color: Colors.grey)),
      );
    }

    return ListView.builder(
      itemCount: _songs.length,
      itemBuilder: (context, index) {
        final song = _songs[index];
        final isCurrent = _currentSong == song;
        final songName = song.path.split('/').last;

        return ListTile(
          tileColor: isCurrent ? Colors.green.withOpacity(0.1) : null,
          leading: Icon(Icons.music_note, color: isCurrent ? Colors.green : Colors.white),
          title: Text(songName, style: TextStyle(color: Colors.white)),
          onTap: () => _playSong(song),
          trailing: IconButton(
            icon: Icon(Icons.delete, color: Colors.red),
            onPressed: () async {
              if (isCurrent) await _audioPlayer.stop();
              await song.delete();
              await _loadSongs();
              _showMessage('Eliminado');
            },
          ),
        );
      },
    );
  }

  Widget _buildTtsPage() {
    final FlutterTts tts = FlutterTts();
    final controller = TextEditingController();
    double rate = 0.5;
    double pitch = 1.0;
    double vol = 1.0;
    bool isSpeaking = false;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: Text('Texto a Voz')),
      body: StatefulBuilder(
        builder: (context, setState) {
          return Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(
                  controller: controller,
                  maxLines: 5,
                  style: TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Escribe algo...',
                    hintStyle: TextStyle(color: Colors.grey),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                SizedBox(height: 12),
                _buildSlider('Velocidad', Icons.speed, rate, 0.1, 1.0, (v) => setState(() => rate = v)),
                _buildSlider('Tono', Icons.graphic_eq, pitch, 0.5, 2.0, (v) => setState(() => pitch = v)),
                _buildSlider('Volumen', Icons.volume_up, vol, 0.0, 1.0, (v) => setState(() => vol = v)),
                SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: () async {
                    if (controller.text.trim().isEmpty) return;
                    if (isSpeaking) {
                      await tts.stop();
                      setState(() => isSpeaking = false);
                    } else {
                      await tts.setLanguage('es-ES');
                      await tts.setSpeechRate(rate);
                      await tts.setPitch(pitch);
                      await tts.setVolume(vol);
                      tts.setStartHandler(() => setState(() => isSpeaking = true));
                      tts.setCompletionHandler(() => setState(() => isSpeaking = false));
                      await tts.speak(controller.text.trim());
                    }
                  },
                  icon: Icon(isSpeaking ? Icons.stop : Icons.play_arrow),
                  label: Text(isSpeaking ? 'Detener' : 'Reproducir'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSlider(String label, IconData icon, double value, double min, double max, Function(double) onChanged) {
    return Row(
      children: [
        Icon(icon, color: Colors.white),
        SizedBox(width: 8),
        Text(label, style: TextStyle(color: Colors.white)),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: 20,
            activeColor: Colors.green,
            inactiveColor: Colors.grey,
            onChanged: onChanged,
          ),
        ),
        Text(value.toStringAsFixed(1), style: TextStyle(color: Colors.white)),
      ],
    );
  }
}

 
