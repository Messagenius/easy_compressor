import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:easy_compressor/easy_compressor.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Easy Compressor Demo',
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const CompressorPage(),
    );
  }
}

class CompressorPage extends StatefulWidget {
  const CompressorPage({super.key});

  @override
  State<CompressorPage> createState() => _CompressorPageState();
}

class _CompressorPageState extends State<CompressorPage> {
  final _compressor = EasyCompressor();

  String? _inputPath;
  MediaInfo? _mediaInfo;
  Uint8List? _thumbnail;
  CompressionResult? _result;

  double _quality = 70;
  String _selectedPreset = 'Custom';
  int? _maxHeight;
  int? _frameRate;
  bool _includeAudio = true;
  bool _showAdvanced = false;

  double _progress = 0;
  bool _isCompressing = false;
  String? _error;

  final Map<String, int?> _resolutionOptions = {
    'Original': null,
    '480p': 480,
    '720p': 720,
    '1080p': 1080,
  };

  final Map<String, int?> _fpsOptions = {
    'Original': null,
    '24': 24,
    '30': 30,
    '60': 60,
  };

  Future<void> _pickVideo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );

    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;

    setState(() {
      _inputPath = path;
      _mediaInfo = null;
      _thumbnail = null;
      _result = null;
      _error = null;
    });

    try {
      final info = await _compressor.getMediaInfo(path);
      final thumb = await _compressor.getThumbnail(path, maxHeight: 200);
      setState(() {
        _mediaInfo = info;
        _thumbnail = thumb;
      });
    } catch (e) {
      setState(() => _error = 'Failed to read video info: $e');
    }
  }

  void _applyPreset(String preset) {
    setState(() {
      _selectedPreset = preset;
      switch (preset) {
        case 'WhatsApp':
          _quality = 65;
          _maxHeight = 720;
          _frameRate = 30;
          _includeAudio = true;
        case 'Social':
          _quality = 70;
          _maxHeight = 1080;
          _frameRate = 30;
          _includeAudio = true;
        case 'Light':
          _quality = 90;
          _maxHeight = null;
          _frameRate = null;
          _includeAudio = true;
        case 'Maximum':
          _quality = 30;
          _maxHeight = 480;
          _frameRate = 24;
          _includeAudio = true;
      }
    });
  }

  Future<void> _compress() async {
    if (_inputPath == null) return;

    setState(() {
      _isCompressing = true;
      _progress = 0;
      _result = null;
      _error = null;
    });

    try {
      final result = await _compressor.compressVideo(
        _inputPath!,
        config: CompressionConfig(
          quality: _quality.round(),
          maxHeight: _maxHeight,
          frameRate: _frameRate,
          includeAudio: _includeAudio,
        ),
        onProgress: (progress) {
          setState(() => _progress = progress);
        },
      );

      setState(() {
        _result = result;
        _isCompressing = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isCompressing = false;
      });
    }
  }

  Future<void> _cancel() async {
    await _compressor.cancelCompression();
    setState(() => _isCompressing = false);
  }

  void _playVideo(String path, String title) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VideoPlayerPage(path: path, title: title),
      ),
    );
  }

  void _compareVideos() {
    if (_inputPath != null && _result != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ComparePlayerPage(
            originalPath: _inputPath!,
            compressedPath: _result!.outputPath,
          ),
        ),
      );
    }
  }

  Future<void> _saveVideo() async {
    if (_result == null) return;

    try {
      if (Platform.isAndroid || Platform.isIOS) {
        final hasAccess = await Gal.hasAccess();
        if (!hasAccess) {
          final granted = await Gal.requestAccess();
          if (!granted) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Permission denied to gallery')),
              );
            }
            return;
          }
        }
        await Gal.putVideo(_result!.outputPath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Video saved to gallery!')),
          );
        }
      } else {
        // Desktop (macOS, Windows)
        String? selectedPath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save Compressed Video',
          fileName: p.basename(_result!.outputPath),
          type: FileType.video,
        );

        if (selectedPath != null) {
          await File(_result!.outputPath).copy(selectedPath);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Saved to $selectedPath')),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving video: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Easy Compressor'),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: _isCompressing ? null : _pickVideo,
              icon: const Icon(Icons.video_library),
              label: const Text('Pick Video'),
            ),
            const SizedBox(height: 16),

            if (_thumbnail != null || _mediaInfo != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Original Video',
                              style: Theme.of(context).textTheme.titleMedium),
                          if (_inputPath != null)
                            IconButton.filledTonal(
                              onPressed: () => _playVideo(_inputPath!, 'Original Video'),
                              icon: const Icon(Icons.play_arrow),
                              tooltip: 'Play Original',
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_thumbnail != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            _thumbnail!,
                            height: 180,
                            width: double.infinity,
                            fit: BoxFit.cover,
                          ),
                        ),
                      if (_mediaInfo != null) ...[
                        const SizedBox(height: 12),
                        _InfoRow('Size', _mediaInfo!.fileSizeFormatted),
                        _InfoRow('Resolution', _mediaInfo!.resolution),
                        _InfoRow('Duration', '${_mediaInfo!.duration.inSeconds}s'),
                        _InfoRow('Frame Rate', '${_mediaInfo!.frameRate.toStringAsFixed(1)} fps'),
                      ],
                    ],
                  ),
                ),
              ),

            if (_inputPath != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Quality', style: Theme.of(context).textTheme.titleMedium),
                      Slider(
                        value: _quality,
                        min: 0,
                        max: 100,
                        divisions: 100,
                        label: '${_quality.round()}',
                        onChanged: _isCompressing ? null : (v) => setState(() {
                          _quality = v;
                          _selectedPreset = 'Custom';
                        }),
                      ),
                      Center(child: Text('Quality: ${_quality.round()}')),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: ['WhatsApp', 'Social', 'Light', 'Maximum'].map((p) {
                  return ChoiceChip(
                    label: Text(p),
                    selected: _selectedPreset == p,
                    onSelected: _isCompressing ? null : (_) => _applyPreset(p),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      title: const Text('Advanced Settings'),
                      trailing: Icon(_showAdvanced ? Icons.expand_less : Icons.expand_more),
                      onTap: () => setState(() => _showAdvanced = !_showAdvanced),
                    ),
                    if (_showAdvanced)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Column(
                          children: [
                            DropdownButtonFormField<int?>(
                              value: _maxHeight,
                              decoration: const InputDecoration(
                                labelText: 'Max Resolution',
                                border: OutlineInputBorder(),
                              ),
                              items: _resolutionOptions.entries
                                  .map((e) => DropdownMenuItem(value: e.value, child: Text(e.key)))
                                  .toList(),
                              onChanged: _isCompressing ? null : (v) => setState(() {
                                _maxHeight = v;
                                _selectedPreset = 'Custom';
                              }),
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<int?>(
                              value: _frameRate,
                              decoration: const InputDecoration(
                                labelText: 'Frame Rate',
                                border: OutlineInputBorder(),
                              ),
                              items: _fpsOptions.entries
                                  .map((e) => DropdownMenuItem(value: e.value, child: Text(e.key)))
                                  .toList(),
                              onChanged: _isCompressing ? null : (v) => setState(() {
                                _frameRate = v;
                                _selectedPreset = 'Custom';
                              }),
                            ),
                            const SizedBox(height: 12),
                            SwitchListTile(
                              title: const Text('Include Audio'),
                              value: _includeAudio,
                              onChanged: _isCompressing ? null : (v) => setState(() {
                                _includeAudio = v;
                                _selectedPreset = 'Custom';
                              }),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (_isCompressing) ...[
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 8),
                Text('${(_progress * 100).toStringAsFixed(1)}%', textAlign: TextAlign.center),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _cancel,
                  icon: const Icon(Icons.cancel),
                  label: const Text('Cancel'),
                ),
              ] else
                FilledButton.icon(
                  onPressed: _compress,
                  icon: const Icon(Icons.compress),
                  label: const Text('Compress Video'),
                ),
            ],

            if (_result != null) ...[
              const SizedBox(height: 24),
              Card(
                color: colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Compression Results',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: colorScheme.onPrimaryContainer)),
                      const SizedBox(height: 12),
                      _InfoRow('Compressed Size', _result!.compressedSizeFormatted),
                      _InfoRow('Saved', _result!.spaceSavedFormatted),
                      _InfoRow('Reduction', '${_result!.spaceSavedPercent.toStringAsFixed(1)}%'),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _playVideo(_result!.outputPath, 'Compressed Video'),
                              icon: const Icon(Icons.play_circle_filled),
                              label: const Text('Play'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _compareVideos,
                              icon: const Icon(Icons.compare),
                              label: const Text('Compare'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: _saveVideo,
                        icon: const Icon(Icons.download),
                        label: const Text('Save / Download'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(double.infinity, 48),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class VideoPlayerPage extends StatefulWidget {
  final String path;
  final String title;
  const VideoPlayerPage({super.key, required this.path, required this.title});
  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late VideoPlayerController _videoPlayerController;
  ChewieController? _chewieController;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    _videoPlayerController = VideoPlayerController.file(File(widget.path));
    await _videoPlayerController.initialize();
    _chewieController = ChewieController(
      videoPlayerController: _videoPlayerController,
      autoPlay: true,
      looping: false,
      aspectRatio: _videoPlayerController.value.aspectRatio,
    );
    setState(() {});
  }

  @override
  void dispose() {
    _videoPlayerController.dispose();
    _chewieController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Center(
        child: _chewieController != null &&
                _chewieController!.videoPlayerController.value.isInitialized
            ? Chewie(controller: _chewieController!)
            : const CircularProgressIndicator(),
      ),
    );
  }
}

class ComparePlayerPage extends StatefulWidget {
  final String originalPath;
  final String compressedPath;
  const ComparePlayerPage({super.key, required this.originalPath, required this.compressedPath});
  @override
  State<ComparePlayerPage> createState() => _ComparePlayerPageState();
}

class _ComparePlayerPageState extends State<ComparePlayerPage> {
  late VideoPlayerController _origController;
  late VideoPlayerController _compController;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _origController = VideoPlayerController.file(File(widget.originalPath));
    _compController = VideoPlayerController.file(File(widget.compressedPath));
    await Future.wait([_origController.initialize(), _compController.initialize()]);
    
    // Listeners for UI updates (like play/pause state)
    _origController.addListener(() => setState(() {}));
    _compController.addListener(() => setState(() {}));

    setState(() => _isInitialized = true);
  }

  @override
  void dispose() {
    _origController.dispose();
    _compController.dispose();
    super.dispose();
  }

  void _togglePlay() {
    setState(() {
      if (_origController.value.isPlaying) {
        _origController.pause();
        _compController.pause();
      } else {
        // Sync positions before playing to ensure they are at the exact same spot
        final targetPosition = _origController.value.position;
        _compController.seekTo(targetPosition);
        
        _origController.play();
        _compController.play();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Compare Videos')),
      body: _isInitialized
          ? Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            const Padding(
                              padding: EdgeInsets.all(8.0),
                              child: Text('Original', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                            Expanded(child: Center(child: AspectRatio(aspectRatio: _origController.value.aspectRatio, child: VideoPlayer(_origController)))),
                          ],
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: Column(
                          children: [
                            const Padding(
                              padding: EdgeInsets.all(8.0),
                              child: Text('Compressed', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                            Expanded(child: Center(child: AspectRatio(aspectRatio: _compController.value.aspectRatio, child: VideoPlayer(_compController)))),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    children: [
                      VideoProgressIndicator(
                        _origController,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                          playedColor: Colors.deepPurple,
                          bufferedColor: Colors.grey,
                          backgroundColor: Colors.black12,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton.filled(
                            iconSize: 48,
                            onPressed: _togglePlay,
                            icon: Icon(_origController.value.isPlaying ? Icons.pause : Icons.play_arrow),
                          ),
                          const SizedBox(width: 16),
                          IconButton.outlined(
                            onPressed: () {
                              _origController.seekTo(Duration.zero);
                              _compController.seekTo(Duration.zero);
                              _origController.pause();
                              _compController.pause();
                            },
                            icon: const Icon(Icons.replay),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          Text(value),
        ],
      ),
    );
  }
}
