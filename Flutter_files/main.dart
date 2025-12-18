import 'dart:io';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tflite/flutter_tflite.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path_package;
import 'package:sqflite/sqflite.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';

import 'dart:developer' as devtools;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
   runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Dog Identifier',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color.fromARGB(194, 11, 154, 49)),
        textTheme: GoogleFonts.poppinsTextTheme(),
      ),
      home: const MyHomePage(),
    );
  }
}

enum AppSection { home, scan, graph, history }

class DogInfo {
  const DogInfo({
    required this.name,
    required this.description,
    required this.assetPath,
  });

  final String name;
  final String description;
  final String assetPath;
}

const List<DogInfo> dogCatalog = [
  DogInfo(
    name: 'Golden Retriever',
    description: 'Friendly, intelligent, and devoted family dog.',
    assetPath: 'assets/Golden-Retriever.jpg',
  ),
  DogInfo(
    name: 'Poodle',
    description: 'Elegant and smart with hypoallergenic coat.',
    assetPath: 'assets/Poodle.jpg',
  ),
  DogInfo(
    name: 'Dalmatian',
    description: 'Athletic dog famed for its iconic spots.',
    assetPath: 'assets/Dalmatian.png',
  ),
  DogInfo(
    name: 'Bulldog',
    description: 'Calm companion with a courageous heart.',
    assetPath: 'assets/bulldog.jpg',
  ),
  DogInfo(
    name: 'Pomeranian',
    description: 'Fluffy extrovert packed with personality.',
    assetPath: 'assets/pomeranian.jpg',
  ),
  DogInfo(
    name: 'Siberian Husky',
    description: 'Energetic adventurer with striking eyes.',
    assetPath: 'assets/siberian.jpg',
  ),
  DogInfo(
    name: 'German Shepherd',
    description: 'Confident working dog and loyal guardian.',
    assetPath: 'assets/german.jpg',
  ),
  DogInfo(
    name: 'Labrador Retriever',
    description: 'Playful companion that loves the outdoors.',
    assetPath: 'assets/labrador.jpg',
  ),
  DogInfo(
    name: 'Shih Tzu',
    description: 'Gentle lap dog with a royal background.',
    assetPath: 'assets/shihtzu.jpg',
  ),
  DogInfo(
    name: 'Aspin',
    description: 'Resilient Filipino dog—smart and adaptable.',
    assetPath: 'assets/aspin.jpg',
  ),
];

// Database Helper Class
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('scan_history.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = path_package.join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE scan_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        label TEXT NOT NULL,
        confidence REAL NOT NULL,
        image_path TEXT NOT NULL,
        date_time TEXT NOT NULL
      )
    ''');
  }

  Future<int> insertScan(Map<String, dynamic> row) async {
    final db = await instance.database;
    return await db.insert('scan_history', row);
  }

  Future<List<Map<String, dynamic>>> getAllScans() async {
    final db = await instance.database;
    return await db.query('scan_history', orderBy: 'id DESC');
  }

  Future<int> deleteScan(int id) async {
    final db = await instance.database;
    return await db.delete('scan_history', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteAllScans() async {
    final db = await instance.database;
    return await db.delete('scan_history');
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyWidgetState();
}

class _MyWidgetState extends State<MyHomePage> {
  File? filePath;
  String label = "";
  double confidence = 0.0;
  bool _isScanning = false;
  AppSection _currentSection = AppSection.home;
  List<Map<String, dynamic>> _history = [];
  List<dynamic> _allRecognitions = [];

  Future<void> _tfiteInit() async {
    final res = await Tflite.loadModel(
      model: "assets/model_unquant.tflite",
      labels: "assets/labels.txt",
      numThreads: 1,
      isAsset: true,
      useGpuDelegate: false,
    );
    devtools.log('TFLite model load result: ${res ?? 'unknown'}');
  }

  Future<void> _loadHistory() async {
    final data = await DatabaseHelper.instance.getAllScans();
    setState(() {
      _history = data;
    });
  }

  Future<void> _saveToHistory() async {
    if (filePath != null && label.isNotEmpty) {
      final scanData = {
        'label': label,
        'confidence': confidence,
        'image_path': filePath!.path,
        'date_time': DateTime.now().toIso8601String(),
      };

      // Save locally (SQLite) for offline history & graphs
      await DatabaseHelper.instance.insertScan(scanData);

      // Also save to Firestore with the new field names
      try {
        final now = DateTime.now();
        // Format: "October 29, 2025 at 11:03:24 AM UTC+8"
        final formattedDate = DateFormat("MMMM dd, yyyy 'at' hh:mm:ss a").format(now);
        final timezoneOffset = now.timeZoneOffset;
        final totalMinutes = timezoneOffset.inMinutes;
        final hours = totalMinutes ~/ 60;
        final timezoneString = hours >= 0 ? 'UTC+$hours' : 'UTC$hours';
        final dateTimeString = '$formattedDate $timezoneString';
        
        final firestoreData = {
          'Class_type': label,
          'Accuracy_rate': confidence,
          'date_time': dateTimeString,
        };
        await FirebaseFirestore.instance
            .collection('Azumbrado_DogBreeds')
            .add(firestoreData);
        devtools.log('Saved scan to Firestore: $firestoreData');
      } catch (e, st) {
        devtools.log('Failed to save scan to Firestore: $e', stackTrace: st);
      }

      await _loadHistory();
    }
  }

  Map<String, int> get _frequencyMap {
    final Map<String, int> frequency = {
      for (final dog in dogCatalog) dog.name: 0,
    };

    for (final entry in _history) {
      final rawLabel = entry['label']?.toString();
      if (rawLabel == null) continue;
      final cleanedLabel = rawLabel.replaceAll(RegExp(r'^\d+\s*'), '').trim();
      
      // Try exact match first
      String? match = frequency.keys.firstWhere(
        (name) => name.toLowerCase() == cleanedLabel.toLowerCase(),
        orElse: () => '',
      );
      
      // If no exact match, try partial match (for backward compatibility with truncated labels)
      if (match.isEmpty) {
        match = frequency.keys.firstWhere(
          (name) {
            final nameLower = name.toLowerCase();
            final labelLower = cleanedLabel.toLowerCase();
            // Check if label is a prefix of name, or name is a prefix of label
            return nameLower.startsWith(labelLower) || labelLower.startsWith(nameLower);
          },
          orElse: () => '',
        );
      }
      
      if (match.isNotEmpty) {
        frequency[match] = frequency[match]! + 1;
      }
    }
    return frequency;
  }

  void _setSection(AppSection section) {
    setState(() {
      _currentSection = section;
    });
  }

  Future<void> pickImageGallery() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);

    if (image == null) return;

    var imageMap = File(image.path);

    setState(() {
      filePath = imageMap;
      _isScanning = true;
    });

    var recognitions = await Tflite.runModelOnImage(
      path: image.path,
      imageMean: 0.0,
      imageStd: 255.0,
      numResults: 10,
      threshold: 0.0,
      asynch: true,
    );

    if (recognitions == null) {
      devtools.log("recognitions is Null");
      setState(() {
        _isScanning = false;
        _allRecognitions = [];
      });
      return;
    }
    devtools.log(recognitions.toString());
    final rawLabel = recognitions[0]['label'].toString();
    final cleanedLabel = rawLabel.replaceAll(RegExp(r'^\d+\s*'), '').trim();
    setState(() {
      confidence = (recognitions[0]['confidence'] * 100);
      label = cleanedLabel;
      _allRecognitions = recognitions;
      _isScanning = false;
    });

    // Save to history
    await _saveToHistory();
  }

  Future<void> pickImageCamera() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.camera);

    if (image == null) return;

    var imageMap = File(image.path);

    setState(() {
      filePath = imageMap;
      _isScanning = true;
    });

    var recognitions = await Tflite.runModelOnImage(
      path: image.path,
      imageMean: 0.0,
      imageStd: 255.0,
      numResults: 10,
      threshold: 0.0,
      asynch: true,
    );

    if (recognitions == null) {
      devtools.log("recognitions is Null");
      setState(() {
        _isScanning = false;
        _allRecognitions = [];
      });
      return;
    }
    devtools.log(recognitions.toString());
    final rawLabel = recognitions[0]['label'].toString();
    final cleanedLabel = rawLabel.replaceAll(RegExp(r'^\d+\s*'), '').trim();
    setState(() {
      confidence = (recognitions[0]['confidence'] * 100);
      label = cleanedLabel;
      _allRecognitions = recognitions;
      _isScanning = false;
    });

    // Save to history
    await _saveToHistory();
  }

  Future<void> _deleteItem(int id) async {
    await DatabaseHelper.instance.deleteScan(id);
    await _loadHistory();
  }

  Future<void> _clearAll() async {
    if (_history.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All History'),
        content: const Text('Are you sure you want to delete all scan history?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await DatabaseHelper.instance.deleteAllScans();
      await _loadHistory();
    }
  }

  @override
  void dispose() {
    super.dispose();
    Tflite.close();
  }

  @override
  void initState() {
    super.initState();
    _tfiteInit();
    _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F4EF),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color(0xFF8B5E3C),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            bottom: Radius.circular(23),
          ),
        ),
        centerTitle: true,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: const [
            Text(
              "Dog Identifier",
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 2),
            Text(
              "Identify Dog Breeds in Seconds",
              style: TextStyle(fontSize: 13, color: Color(0xFFDFCBB8)),
            ),
          ],
        ),
        toolbarHeight: 60,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _NavigationRow(
              currentSection: _currentSection,
              onSectionSelected: _setSection,
            ),
            const SizedBox(height: 24),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              child: _buildSection(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection() {
    switch (_currentSection) {
      case AppSection.home:
        return HomeSection(
          key: const ValueKey('home'),
          onScanTap: () => _setSection(AppSection.scan),
          dogs: dogCatalog,
        );
      case AppSection.scan:
        return ScanSection(
          key: const ValueKey('scan'),
          filePath: filePath,
          confidence: confidence,
          label: label,
          isScanning: _isScanning,
          allRecognitions: _allRecognitions,
          onCameraTap: pickImageCamera,
          onGalleryTap: pickImageGallery,
        );
      case AppSection.graph:
        return GraphSection(
          key: const ValueKey('graph'),
          frequencyMap: _frequencyMap,
        );
      case AppSection.history:
        return HistorySection(
          key: const ValueKey('history'),
          history: _history,
          onDelete: _deleteItem,
          onClearAll: _clearAll,
        );
    }
  }
}

class _NavigationRow extends StatelessWidget {
  const _NavigationRow({
    required this.currentSection,
    required this.onSectionSelected,
  });

  final AppSection currentSection;
  final void Function(AppSection) onSectionSelected;

  @override
  Widget build(BuildContext context) {
    const tabs = [
      (AppSection.home, Icons.home, 'Home'),
      (AppSection.scan, Icons.camera_alt, 'Scan'),
      (AppSection.graph, Icons.show_chart, 'Graph'),
      (AppSection.history, Icons.history, 'History'),
    ];

    return Row(
      children: [
        for (final tab in tabs)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => onSectionSelected(tab.$1),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
                  decoration: BoxDecoration(
                    color: currentSection == tab.$1 ? const Color(0xFF8B5E3C) : const Color(0xFFE9DACB),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        tab.$2,
                        size: 26,
                        color: currentSection == tab.$1 ? Colors.white : const Color(0xFF5A341A),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        tab.$3,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: currentSection == tab.$1 ? Colors.white : const Color(0xFF5A341A),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class HomeSection extends StatelessWidget {
  const HomeSection({
    super.key,
    required this.onScanTap,
    required this.dogs,
  });

  final VoidCallback onScanTap;
  final List<DogInfo> dogs;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: const LinearGradient(
              colors: [Color(0xFF6E3E21), Color(0xFFB4784E)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          'Your Daily Dog Guide',
                          style: TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Discover Breeds,\nScan Instantly',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Image.asset(
                      'assets/dog_ui.png',
                      width: 120,
                      height: 120,
                      fit: BoxFit.cover,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              ElevatedButton(
                onPressed: onScanTap,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF6E3E21),
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                ),
                child: const Text(
                  'Scan now!',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'Popular Breeds',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: const Color(0xFF5A341A),
              ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 220,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: dogs.length,
            separatorBuilder: (context, _) => const SizedBox(width: 16),
            itemBuilder: (context, index) {
              final dog = dogs[index];
              return _DogCard(dog: dog);
            },
          ),
        ),
        const SizedBox(height: 32),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.brown.shade100.withValues(alpha: 0.4),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF8B5E3C).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.info_outline,
                      color: Color(0xFF8B5E3C),
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'About Dog Identifier',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF5A341A),
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text(
                'Your intelligent companion for identifying dog breeds instantly! Simply capture or upload a photo of any dog, and our advanced AI technology will recognize the breed with remarkable accuracy.',
                style: TextStyle(
                  fontSize: 15,
                  height: 1.6,
                  color: Color(0xFF5A341A),
                ),
              ),
              const SizedBox(height: 24),
              _InfoFeature(
                icon: Icons.camera_alt,
                title: 'Quick Scanning',
                description: 'Capture photos with your camera or choose from your gallery',
              ),
              const SizedBox(height: 16),
              _InfoFeature(
                icon: Icons.analytics,
                title: 'Accurate Results',
                description: 'Get detailed breed identification with confidence percentages',
              ),
              const SizedBox(height: 16),
              _InfoFeature(
                icon: Icons.history,
                title: 'History Tracking',
                description: 'Keep a record of all your scans and view statistics',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoFeature extends StatelessWidget {
  const _InfoFeature({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFFE9DACB),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            icon,
            color: const Color(0xFF8B5E3C),
            size: 20,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: Color(0xFF5A341A),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF8C6A54),
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DogCard extends StatelessWidget {
  const _DogCard({required this.dog});

  final DogInfo dog;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 180,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.brown.shade100.withValues(alpha: 0.4),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Image.asset(
              dog.assetPath,
              height: 100,
              width: double.infinity,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            dog.name,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: Color(0xFF5A341A),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Text(
              dog.description,
              style: const TextStyle(fontSize: 12, color: Color(0xFF8C6A54)),
            ),
          ),
        ],
      ),
    );
  }
}

class ScanSection extends StatelessWidget {
  const ScanSection({
    super.key,
    required this.filePath,
    required this.confidence,
    required this.label,
    required this.isScanning,
    required this.allRecognitions,
    required this.onCameraTap,
    required this.onGalleryTap,
  });

  final File? filePath;
  final double confidence;
  final String label;
  final bool isScanning;
  final List<dynamic> allRecognitions;
  final VoidCallback onCameraTap;
  final VoidCallback onGalleryTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.brown.shade100.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 280,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: const Color(0xFFE9DACB),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.brown.shade200.withValues(alpha: 0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                      spreadRadius: 1,
                    ),
                  ],
                  color: const Color(0xFFF5ECE3),
                ),
                child: filePath != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Image.file(
                          filePath!,
                          fit: BoxFit.cover,
                        ),
                      )
                    : const Center(
                        child: Icon(
                          Icons.pets,
                          size: 64,
                          color: Color(0xFF8C6A54),
                        ),
                      ),
              ),
              const SizedBox(height: 28),
              Text(
                label.isEmpty ? 'Ready to scan a dog?' : label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                  color: Color(0xFF5A341A),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                label.isEmpty
                    ? 'Capture or import a photo to start'
                    : 'Accuracy: ${confidence.toStringAsFixed(2)}%',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF8C6A54)),
              ),
              const SizedBox(height: 28),
              if (isScanning)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: LinearProgressIndicator(
                    color: Color(0xFF8B5E3C),
                    backgroundColor: Color(0xFFE9DACB),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: onCameraTap,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        backgroundColor: const Color(0xFF8B5E3C),
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.camera_alt, color: Colors.white70),
                      label: const Text(
                        'Take Photo',
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: onGalleryTap,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        backgroundColor: const Color(0xFFE9DACB),
                        foregroundColor: const Color(0xFF5A341A),
                      ),
                      icon: const Icon(Icons.photo_library),
                      label: const Text(
                        'Import',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (allRecognitions.isNotEmpty && label.isNotEmpty) ...[
          const SizedBox(height: 20),
          _PredictionBarChart(recognitions: allRecognitions),
        ],
      ],
    );
  }
}

class _PredictionBarChart extends StatelessWidget {
  const _PredictionBarChart({required this.recognitions});

  final List<dynamic> recognitions;

  String _formatConfidence(double conf) {
    if (conf == 0.0) {
      return '0.00%';
    } else if (conf >= 0.01) {
      return '${conf.toStringAsFixed(2)}%';
    } else if (conf >= 0.0001) {
      return '${conf.toStringAsFixed(4)}%';
    } else if (conf >= 0.00001) {
      return '${conf.toStringAsFixed(5)}%';
    } else if (conf >= 0.000001) {
      return '${conf.toStringAsFixed(6)}%';
    } else {
      // For extremely small values (> 0 but < 0.000001), show up to 8 decimal places
      // and remove trailing zeros
      final formatted = conf.toStringAsFixed(8);
      final trimmed = formatted.replaceAll(RegExp(r'0+$'), '');
      return '${trimmed.endsWith('.') ? trimmed + '0' : trimmed}%';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (recognitions.isEmpty) return const SizedBox.shrink();

    // Convert and sort recognitions by confidence (highest first)
    final sortedRecognitions = recognitions
        .map((recognition) => {
              'label': recognition['label']?.toString() ?? '',
              'confidence': (recognition['confidence'] as num?)?.toDouble() ?? 0.0,
            })
        .toList()
      ..sort((a, b) => (b['confidence'] as double).compareTo(a['confidence'] as double));

    // Get the top prediction (first one) - this will be excluded
    if (sortedRecognitions.isEmpty) return const SizedBox.shrink();
    
    final topConfidence = sortedRecognitions[0]['confidence'] as double;
    final topConfidencePercent = topConfidence * 100;
    
    // Hide remaining predictions if top confidence is 100% (accounting for floating point precision and rounding)
    // If displayed as 100.00%, actual value could be 99.995% or higher, so we check >= 99.995
    if (topConfidencePercent >= 99.995) return const SizedBox.shrink();
    
    // Get remaining predictions (skip the first one)
    final remainingRecognitions = sortedRecognitions.skip(1).toList();
    
    if (remainingRecognitions.isEmpty) return const SizedBox.shrink();

    // Use actual confidence values from the model (convert to percentages)
    // Filter out predictions with zero or negative confidence
    final actualPredictions = remainingRecognitions
        .map((rec) {
          final originalConf = rec['confidence'] as double;
          // Convert to percentage (0.0-1.0 range to 0-100%)
          final confPercentage = originalConf * 100;
          return {
            'label': rec['label'],
            'confidence': confPercentage,
          };
        })
        .where((pred) => (pred['confidence'] as double) > 0.0)
        .toList();

    if (actualPredictions.isEmpty) return const SizedBox.shrink();

    // Take top 5 remaining predictions for better visualization
    final topRemainingPredictions = actualPredictions.take(5).toList();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.brown.shade100.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Remaining Predictions',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
              color: Color(0xFF5A341A),
            ),
          ),
          const SizedBox(height: 16),
          ...topRemainingPredictions.asMap().entries.map((entry) {
            final recognition = entry.value;
            final breedLabel = recognition['label']?.toString() ?? '';
            final conf = recognition['confidence'] as double;
            final cleanedLabel = breedLabel.replaceAll(RegExp(r'^\d+\s*'), '').trim();
            
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          cleanedLabel,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF5A341A),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        _formatConfidence(conf),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF8C6A54),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: conf / 100.0, // Show as percentage of 100%
                      minHeight: 8,
                      backgroundColor: const Color(0xFFE9DACB),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        const Color(0xFFB4784E).withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

class GraphSection extends StatelessWidget {
  const GraphSection({
    super.key,
    required this.frequencyMap,
  });

  final Map<String, int> frequencyMap;

  @override
  Widget build(BuildContext context) {
    final spots = <FlSpot>[];
    for (var i = 0; i < dogCatalog.length; i++) {
      final value = frequencyMap[dogCatalog[i].name]?.toDouble() ?? 0;
      spots.add(FlSpot(i.toDouble(), value));
    }

    final hasData = spots.any((spot) => spot.y > 0);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.brown.shade100.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Scan Frequency',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF5A341A),
                ),
          ),
          const SizedBox(height: 18),
          AspectRatio(
            aspectRatio: 1.0,
            child: hasData
                ? LineChart(
                    LineChartData(
                      borderData: FlBorderData(show: false),
                      gridData: FlGridData(
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (value) => FlLine(
                          color: Colors.brown.shade100,
                          strokeWidth: 1,
                        ),
                      ),
                      titlesData: FlTitlesData(
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 40,
                            interval: 5,
                            getTitlesWidget: (value, meta) {
                              if (value < 0 || value % 5 != 0) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Text(
                                  value.toInt().toString(),
                                  style: const TextStyle(fontSize: 11),
                                ),
                              );
                            },
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 70,
                            getTitlesWidget: (value, meta) {
                              final index = value.toInt();
                              if (index < 0 || index >= dogCatalog.length) {
                                return const SizedBox.shrink();
                              }
                              return Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Transform.rotate(
                                  angle: -math.pi / 6,
                                  child: Text(
                                    dogCatalog[index].name,
                                    style: const TextStyle(fontSize: 10),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      minY: 0,
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipColor: (_) => const Color.fromARGB(255, 241, 208, 185),
                          getTooltipItems: (touchedSpots) {
                            return touchedSpots.map((spot) {
                              final dogName = dogCatalog[spot.x.toInt()].name;
                              return LineTooltipItem(
                                '$dogName\n${spot.y.toInt()} scans',
                                const TextStyle(
                                  color: Color.fromARGB(255, 127, 74, 35),
                                  fontWeight: FontWeight.bold,
                                ),
                              );
                            }).toList();
                          },
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: true,
                          color: const Color(0xFF8B5E3C),
                          barWidth: 4,
                          dotData: const FlDotData(show: true),
                          belowBarData: BarAreaData(
                            show: true,
                            color: const Color(0xFF8B5E3C).withValues(alpha: 0.2),
                          ),
                        ),
                      ],
                    ),
                  )
                : const Center(
                    child: Text(
                      'No scans yet. Start identifying breeds!',
                      style: TextStyle(color: Color(0xFF8C6A54)),
                    ),
                  ),
          ),
          const SizedBox(height: 18),
          _FrequencyList(frequencyMap: frequencyMap),
        ],
      ),
    );
  }
}

class _FrequencyList extends StatelessWidget {
  const _FrequencyList({required this.frequencyMap});

  final Map<String, int> frequencyMap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Scans by Breed',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Color(0xFF5A341A),
          ),
        ),
        const SizedBox(height: 12),
        ...dogCatalog.map((dog) {
          final count = frequencyMap[dog.name] ?? 0;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    dog.name,
                    style: const TextStyle(
                      color: Color(0xFF5A341A),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE9DACB),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '$count',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF8B5E3C),
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class HistorySection extends StatefulWidget {
  const HistorySection({
    super.key,
    required this.history,
    required this.onDelete,
    required this.onClearAll,
  });

  final List<Map<String, dynamic>> history;
  final Future<void> Function(int id) onDelete;
  final Future<void> Function() onClearAll;

  @override
  State<HistorySection> createState() => _HistorySectionState();
}

class _HistorySectionState extends State<HistorySection> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _filteredHistory {
    if (_searchQuery.isEmpty) {
      return widget.history;
    }
    final query = _searchQuery.toLowerCase().trim();
    
    return widget.history.where((item) {
      // Search by breed name
      final label = (item['label']?.toString() ?? '')
          .replaceAll(RegExp(r'^\d+\s*'), '')
          .trim()
          .toLowerCase();
      if (label.contains(query)) return true;
      
      // Search by accuracy percentage
      final confidence = (item['confidence'] as num?)?.toDouble() ?? 0.0;
      final accuracyText = confidence.toStringAsFixed(2);
      if (accuracyText.contains(query) || query.contains(accuracyText)) return true;
      
      // Search by date/time
      try {
        final dateTime = DateTime.parse(item['date_time']);
        final formattedDate = DateFormat('MMM dd, yyyy • hh:mm a').format(dateTime).toLowerCase();
        if (formattedDate.contains(query)) return true;
        
        // Also search by individual date components
        final month = DateFormat('MMMM').format(dateTime).toLowerCase();
        final day = DateFormat('dd').format(dateTime);
        final year = DateFormat('yyyy').format(dateTime);
        final time = DateFormat('hh:mm a').format(dateTime).toLowerCase();
        
        if (month.contains(query) || 
            day.contains(query) || 
            year.contains(query) || 
            time.contains(query)) {
          return true;
        }
      } catch (e) {
        // If date parsing fails, skip date search
      }
      
      return false;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filteredHistory = _filteredHistory;

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenHeight = MediaQuery.of(context).size.height;
        // Calculate available height: screen height minus header, nav, title, search bar, and padding
        final availableHeight = screenHeight - 350; // Account for all fixed elements
        final maxListHeight = availableHeight.clamp(300.0, screenHeight * 0.6);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'History',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF5A341A),
                  ),
            ),
            if (widget.history.isNotEmpty)
              TextButton.icon(
                onPressed: widget.onClearAll,
                icon: const Icon(Icons.delete_sweep, color: Color(0xFFB5483E)),
                label: const Text(
                  'Clear All',
                  style: TextStyle(color: Color(0xFFB5483E)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        // Search bar
        if (widget.history.isNotEmpty)
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.brown.shade100.withValues(alpha: 0.2),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: TextField(
              controller: _searchController,
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
              },
              decoration: InputDecoration(
                hintText: 'Search by breed, accuracy, or date...',
                hintStyle: const TextStyle(color: Color(0xFFB79D8C)),
                prefixIcon: const Icon(Icons.search, color: Color(0xFF8C6A54)),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Color(0xFF8C6A54)),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                          });
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ),
        const SizedBox(height: 16),
        if (widget.history.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Text(
              'No scan history yet. Your results will appear here.',
              style: TextStyle(color: Color(0xFF8C6A54)),
            ),
          )
        else if (filteredHistory.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              children: [
                const Icon(
                  Icons.search_off,
                  size: 48,
                  color: Color(0xFF8C6A54),
                ),
                const SizedBox(height: 12),
                Text(
                  'No dogs found matching "$_searchQuery"',
                  style: const TextStyle(
                    color: Color(0xFF8C6A54),
                    fontSize: 16,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          )
        else
          SizedBox(
            height: maxListHeight,
            child: Builder(
              builder: (context) {
                // Estimate item height: 70 (image) + 14*2 (padding) + text height (~40) ≈ 98px
                // Plus 12px separator between items
                final itemHeight = 98.0;
                final separatorHeight = 12.0;
                final estimatedTotalHeight = (filteredHistory.length * itemHeight) + 
                                            ((filteredHistory.length - 1) * separatorHeight);
                
                // Always use maxListHeight to fill the available space
                // Enable scrolling only when content exceeds the available height
                final shouldScroll = estimatedTotalHeight > maxListHeight;
                
                return ListView.separated(
                  physics: shouldScroll 
                      ? const AlwaysScrollableScrollPhysics() 
                      : const NeverScrollableScrollPhysics(),
                  itemCount: filteredHistory.length,
                  separatorBuilder: (context, _) => const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    final item = filteredHistory[index];
                    final dateTime = DateTime.parse(item['date_time']);
                    final formattedDate = DateFormat('MMM dd, yyyy • hh:mm a').format(dateTime);

                    return Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.brown.shade100.withValues(alpha: 0.3),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: item['image_path'] != null
                                ? Image.file(
                                    File(item['image_path']),
                                    width: 70,
                                    height: 70,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) {
                                      return Container(
                                        width: 70,
                                        height: 70,
                                        color: const Color(0xFFE9DACB),
                                        child: const Icon(Icons.broken_image),
                                      );
                                    },
                                  )
                                : Container(
                                    width: 70,
                                    height: 70,
                                    color: const Color(0xFFE9DACB),
                                    child: const Icon(Icons.image_not_supported),
                                  ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  (item['label']?.toString() ?? '').replaceAll(RegExp(r'^\d+\s*'), '').trim(),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: Color(0xFF5A341A),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Accuracy: ${(item['confidence'] as num).toStringAsFixed(2)}%',
                                  style: const TextStyle(color: Color(0xFF8C6A54)),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  formattedDate,
                                  style: const TextStyle(fontSize: 12, color: Color(0xFFB79D8C)),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => widget.onDelete(item['id'] as int),
                            icon: const Icon(Icons.close, color: Color(0xFFB5483E)),
                          ),
                        ],
                      ),
                    );
                  }, 
                );
              },
            ),
          ),
          ],
        );
      },
    );
  }
}