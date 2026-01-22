import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  late CameraController cameraController;

  bool isCameraInitialized = false;

  void permissionCheck() async {
    try {
      final permissionStatus = await Permission.camera.status;
      if (permissionStatus.isGranted) {
        await _initCamera();
      } else {
        await Permission.camera.request();
        if (await Permission.camera.status.isGranted) {
          await _initCamera();
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Camera permission denied')),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Camera plugin error: $e\nPlease rebuild the app.'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  void _disposeCamera() {
    cameraController.dispose();
    setState(() {
      isCameraInitialized = false;
    });
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    final camera = cameras.first;
    cameraController = CameraController(camera, ResolutionPreset.high);
    await cameraController.initialize();
    setState(() {
      isCameraInitialized = true;
    });
  }

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  @override
  void dispose() {
    _disposeCamera();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          if (isCameraInitialized)
            Positioned.fill(child: CameraPreview(cameraController)),
          Align(alignment: Alignment.bottomCenter, child: _buildButtonScan()),
        ],
      ),
    );
  }

  Widget _buildButtonScan() {
    return ElevatedButton(
      onPressed: () {
        cameraController.takePicture();
      },
      child: const Icon(Icons.camera_alt),
    );
  }
}
