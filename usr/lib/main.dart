import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';

List<CameraDescription> _cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _cameras = await availableCameras();
  } on CameraException catch (e) {
    debugPrint('Kamera hatası: $e');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kişi Sayar & Röle',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const FaceCounterScreen(),
    );
  }
}

class FaceCounterScreen extends StatefulWidget {
  const FaceCounterScreen({super.key});

  @override
  State<FaceCounterScreen> createState() => _FaceCounterScreenState();
}

class _FaceCounterScreenState extends State<FaceCounterScreen> {
  CameraController? _controller;
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: false,
      enableClassification: false,
      performanceMode: FaceDetectorMode.fast,
    ),
  );
  
  bool _isBusy = false;
  int _personCount = 0;
  bool _relay1State = false; // 1. Tole (Röle) durumu
  String _statusMessage = "Sistem Başlatılıyor...";
  bool _isSimulationMode = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb || _cameras.isEmpty) {
      // Web ortamında veya kamera yoksa simülasyon moduna geç
      setState(() {
        _isSimulationMode = true;
        _statusMessage = "Simülasyon Modu (Kamera Bulunamadı)";
      });
    } else {
      _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    var status = await Permission.camera.request();
    if (status.isDenied) {
      setState(() => _statusMessage = "Kamera izni reddedildi.");
      return;
    }

    // Ön kamerayı bulmaya çalış, yoksa ilk kamerayı al
    CameraDescription? camera = _cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => _cameras.first,
    );

    _controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    try {
      await _controller!.initialize();
      if (!mounted) return;
      
      setState(() => _statusMessage = "Kamera Aktif");
      
      _controller!.startImageStream((CameraImage image) {
        _processCameraImage(image);
      });
    } catch (e) {
      setState(() {
        _statusMessage = "Kamera başlatılamadı: $e";
        _isSimulationMode = true;
      });
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isBusy) return;
    _isBusy = true;

    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) {
        _isBusy = false;
        return;
      }

      final faces = await _faceDetector.processImage(inputImage);
      
      if (mounted) {
        setState(() {
          _personCount = faces.length;
          _updateRelayState();
        });
      }
    } catch (e) {
      debugPrint("Yüz tanıma hatası: $e");
    } finally {
      _isBusy = false;
    }
  }

  void _updateRelayState() {
    // MANTIK: 1'den fazla kişi varsa 1. toleyi aç
    bool shouldOpenRelay = _personCount > 1;
    
    if (_relay1State != shouldOpenRelay) {
      setState(() {
        _relay1State = shouldOpenRelay;
      });
    }
  }

  // Kamera görüntüsünü ML Kit formatına çeviren yardımcı fonksiyon
  InputImage? _inputImageFromCameraImage(CameraImage image) {
    if (_controller == null) return null;

    final camera = _controller!.description;
    final sensorOrientation = camera.sensorOrientation;
    
    // InputImageRotation hesaplama
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation = _orientations[_controller!.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation = (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) return null;

    // Format kontrolü
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null || (Platform.isAndroid && format != InputImageFormat.nv21) || (Platform.isIOS && format != InputImageFormat.bgra8888)) {
       // Basitlik için sadece desteklenen formatları işliyoruz
       // Demo amaçlı olduğu için burayı esnek tutuyoruz
       if (format == null) return null; 
    }

    // Plane verilerini birleştirme (Basitleştirilmiş)
    // Not: Tam prodüksiyon kodu için daha karmaşık byte birleştirme gerekebilir
    // Ancak ML Kit son sürümleri bazı formatları otomatik tanır.
    
    // Bu örnekte metadata oluşturup dönüyoruz
    // Not: Web veya emülatörde bu kısım çalışmayabilir, bu yüzden simülasyon modu ekledik.
    
    // Gerçek cihazda çalışması için temel metadata:
    return InputImage.fromBytes(
      bytes: _concatenatePlanes(image.planes),
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format ?? InputImageFormat.nv21,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  Uint8List _concatenatePlanes(List<Plane> planes) {
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in planes) {
      allBytes.putUint8List(plane.bytes);
    }
    return allBytes.done().buffer.asUint8List();
  }

  final _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  @override
  void dispose() {
    _controller?.dispose();
    _faceDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kişi Sayar & Röle Kontrol'),
        backgroundColor: _relay1State ? Colors.green : Colors.red,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // Kamera Alanı veya Simülasyon Alanı
          Expanded(
            flex: 3,
            child: Container(
              color: Colors.black,
              child: Center(
                child: _isSimulationMode
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.videocam_off, color: Colors.white54, size: 64),
                          const SizedBox(height: 16),
                          const Text(
                            "Simülasyon Modu",
                            style: TextStyle(color: Colors.white, fontSize: 20),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            "Web'de veya kamerasız ortamda test için\naşağıdaki butonları kullanın.",
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white70),
                          ),
                        ],
                      )
                    : (_controller != null && _controller!.value.isInitialized)
                        ? CameraPreview(_controller!)
                        : const CircularProgressIndicator(),
              ),
            ),
          ),

          // Kontrol Paneli
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  // Kişi Sayısı Göstergesi
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.people, size: 32, color: Colors.blueGrey),
                      const SizedBox(width: 12),
                      Text(
                        "Kişi Sayısı: $_personCount",
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),

                  const Divider(),

                  // Röle Durumu Göstergesi
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    decoration: BoxDecoration(
                      color: _relay1State ? Colors.green.shade100 : Colors.red.shade100,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: _relay1State ? Colors.green : Colors.red,
                        width: 2,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "1. TOLE (RÖLE)",
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Colors.black54,
                              ),
                            ),
                            Text(
                              _relay1State ? "AÇIK" : "KAPALI",
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: _relay1State ? Colors.green[700] : Colors.red[700],
                              ),
                            ),
                          ],
                        ),
                        Icon(
                          _relay1State ? Icons.lightbulb : Icons.lightbulb_outline,
                          size: 48,
                          color: _relay1State ? Colors.green : Colors.grey,
                        ),
                      ],
                    ),
                  ),

                  // Simülasyon Kontrolleri (Sadece simülasyon modunda görünür)
                  if (_isSimulationMode)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () {
                            if (_personCount > 0) {
                              setState(() {
                                _personCount--;
                                _updateRelayState();
                              });
                            }
                          },
                          icon: const Icon(Icons.remove),
                          label: const Text("Azalt"),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                        ),
                        const SizedBox(width: 20),
                        ElevatedButton.icon(
                          onPressed: () {
                            setState(() {
                              _personCount++;
                              _updateRelayState();
                            });
                          },
                          icon: const Icon(Icons.add),
                          label: const Text("Arttır"),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
