import 'dart:async';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:permission_handler/permission_handler.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class ScanStrip {
  final ui.Image image;
  final double top;
  final double height;

  ScanStrip({required this.image, required this.top, required this.height});
}

class _FrozenStripsPainter extends CustomPainter {
  final List<ScanStrip> strips;

  const _FrozenStripsPainter({required this.strips});

  @override
  void paint(Canvas canvas, Size size) {
    for (final strip in strips) {
      canvas.drawImage(strip.image, Offset(0, strip.top), Paint());
    }
  }

  @override
  bool shouldRepaint(covariant _FrozenStripsPainter oldDelegate) {
    return oldDelegate.strips != strips;
  }
}

class _CameraScreenState extends State<CameraScreen>
    with TickerProviderStateMixin {
  CameraController? _cameraController;

  bool _isCameraInitialized = false;
  bool _isScanning = false;
  bool _isCapturing = false;

  final GlobalKey _previewKey = GlobalKey();
  Size? _previewSize;

  final List<ScanStrip> _strips = <ScanStrip>[];

  late final AnimationController _scanController;
  double _lastCapturedY = 0;

  // Bigger step = fewer captures = better performance.
  static const double _stripStepPx = 24.0;

  @override
  void initState() {
    super.initState();

    _scanController =
        AnimationController(vsync: this, duration: const Duration(seconds: 2))
          ..addListener(_onScanTick)
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) {
              _onScanCompleted();
            }
          });

    _checkPermissionAndInitCamera();
  }

  @override
  void dispose() {
    _scanController.dispose();

    for (final strip in _strips) {
      strip.image.dispose();
    }
    _strips.clear();

    _cameraController?.dispose();
    super.dispose();
  }

  Future<void> _checkPermissionAndInitCamera() async {
    try {
      final status = await Permission.camera.status;
      if (!status.isGranted) {
        await Permission.camera.request();
      }

      if (!(await Permission.camera.status.isGranted)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Camera permission denied')),
          );
        }
        return;
      }

      await _initCamera();
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

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    final camera = cameras.first;

    final controller = CameraController(camera, ResolutionPreset.high);
    await controller.initialize();

    _cameraController?.dispose();
    _cameraController = controller;

    if (!mounted) return;
    setState(() {
      _isCameraInitialized = true;
    });
  }

  Future<void> _startScan() async {
    if (!_isCameraInitialized || _cameraController == null) return;
    if (_isScanning) return;

    // Ensure we have the actual rendered preview size.
    await Future<void>.delayed(Duration.zero);
    final renderObject = _previewKey.currentContext?.findRenderObject();
    if (renderObject is RenderBox) {
      _previewSize = renderObject.size;
    }

    if (_previewSize == null || _previewSize!.height <= 0) return;

    // Clear previous frozen strips.
    for (final strip in _strips) {
      strip.image.dispose();
    }
    _strips.clear();

    setState(() {
      _isScanning = true;
    });

    _lastCapturedY = 0;
    _scanController.forward(from: 0);
  }

  Future<void> _onScanCompleted() async {
    // Show full frozen result briefly, then reset.
    await Future<void>.delayed(const Duration(seconds: 2));

    if (!mounted) return;

    for (final strip in _strips) {
      strip.image.dispose();
    }
    _strips.clear();

    setState(() {
      _isScanning = false;
      _lastCapturedY = 0;
    });
  }

  void _onScanTick() {
    if (!_isScanning) return;
    final previewHeight = _previewSize?.height;
    if (previewHeight == null || previewHeight <= 0) return;

    final currentY =
        (_scanController.value * previewHeight)
            .clamp(0.0, previewHeight)
            .toDouble();

    // Capture strips only when we advanced enough (performance).
    if (currentY - _lastCapturedY >= _stripStepPx && !_isCapturing) {
      final fromY = _lastCapturedY;
      final toY = currentY;
      _lastCapturedY = currentY;
      unawaited(_captureStrip(fromY: fromY, toY: toY));
    }

    // Always repaint scan line.
    setState(() {});
  }

  Future<void> _captureStrip({
    required double fromY,
    required double toY,
  }) async {
    if (!_isScanning) return;

    final boundaryContext = _previewKey.currentContext;
    if (boundaryContext == null) return;

    final boundary =
        boundaryContext.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return;

    final stripHeight = (toY - fromY).clamp(0.0, double.infinity).toDouble();
    if (stripHeight <= 0) return;

    _isCapturing = true;
    try {
      // Capture at pixelRatio 1.0 so image pixels align with logical pixels.
      final fullImage = await boundary.toImage(pixelRatio: 1.0);

      final imageWidth = fullImage.width;
      final imageHeight = fullImage.height;

      final clampedFromY = fromY.clamp(0.0, imageHeight.toDouble()).toDouble();
      final clampedStripHeight =
          stripHeight
              .clamp(0.0, (imageHeight.toDouble() - clampedFromY))
              .toDouble();

      if (clampedStripHeight <= 0) {
        fullImage.dispose();
        return;
      }

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      final srcRect = Rect.fromLTWH(
        0,
        clampedFromY,
        imageWidth.toDouble(),
        clampedStripHeight,
      );
      final dstRect = Rect.fromLTWH(
        0,
        0,
        imageWidth.toDouble(),
        clampedStripHeight,
      );

      canvas.drawImageRect(fullImage, srcRect, dstRect, Paint());

      final picture = recorder.endRecording();
      final stripImage = await picture.toImage(
        imageWidth,
        clampedStripHeight.ceil(),
      );

      picture.dispose();
      fullImage.dispose();

      if (!mounted) {
        stripImage.dispose();
        return;
      }

      setState(() {
        _strips.add(
          ScanStrip(
            image: stripImage,
            top: clampedFromY,
            height: clampedStripHeight,
          ),
        );
      });
    } catch (_) {
      // Ignore capture failures (can happen if widget tree changes mid-capture).
    } finally {
      _isCapturing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final previewHeight =
        _previewSize?.height ?? MediaQuery.of(context).size.height;
    final scanY =
        (_scanController.value * previewHeight)
            .clamp(0.0, previewHeight)
            .toDouble();

    return Scaffold(
      body: Stack(
        children: [
          if (_isCameraInitialized && _cameraController != null)
            Positioned.fill(
              child: RepaintBoundary(
                key: _previewKey,
                child: CameraPreview(_cameraController!),
              ),
            ),

          // Frozen (top) region built from captured strips.
          if (_strips.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _FrozenStripsPainter(
                    strips: List<ScanStrip>.unmodifiable(_strips),
                  ),
                ),
              ),
            ),

          // Scan line overlay.
          if (_isScanning)
            Positioned(
              left: 0,
              right: 0,
              top: scanY - 1,
              child: Container(height: 2, color: Colors.red),
            ),

          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 32),
              child: _buildButtonScan(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildButtonScan() {
    final enabled = _isCameraInitialized && !_isScanning;

    return ElevatedButton(
      onPressed: enabled ? _startScan : null,
      child: Icon(_isScanning ? Icons.stop : Icons.play_arrow),
    );
  }
}
