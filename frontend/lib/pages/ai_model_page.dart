import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:dio/dio.dart';
import 'dart:math' as math;
import 'dart:io';
import 'package:exif/exif.dart';

class AiModelPage extends StatefulWidget {
  final List<Map<String, dynamic>>? initialMapData;
  final String? tifPath;
  final String? serverUrl;
  const AiModelPage({super.key, this.initialMapData, this.tifPath, this.serverUrl});

  @override
  State<AiModelPage> createState() => _AiModelPageState();
}

class ManualMarkerDef {
  final File file;
  final double rawLat;
  final double rawLon;
  final String name;
  final double physicalW;
  final double physicalH;
  final String stringId;
  ManualMarkerDef(this.file, this.rawLat, this.rawLon, this.name, this.physicalW, this.physicalH, this.stringId);
}

class StringTransform {
  double spacingScale = 1.0;
  double dLat = 0.0;
  double dLon = 0.0;
  double angleRad = 0.0;
}

class _AiModelPageState extends State<AiModelPage> {
  // 默认地图中心位置
  LatLng _mapCenter = const LatLng(39.9042, 116.4074);
  double _mapZoom = 13.0;
  final MapController _mapController = MapController();
  List<Marker> _markers = [];
  List<Polygon> _polygons = [];
  
  // 右侧面板状态
  bool _isPanelOpen = true;
  String? _currentTifPath;

  // 手动挂载点状态
  List<ManualMarkerDef> _manualDefs = [];
  final Map<String, StringTransform> _stringTransforms = {};
  String? _selectedStringId;

  // 新增功能状态
  bool _isSatellite = false;
  bool _isLocating = false;
  bool _isSearching = false;
  bool _isLoadingImages = false;
  int _loadingProgress = 0;
  int _loadingTotal = 0;
  Marker? _currentLocationMarker;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.initialMapData != null && widget.initialMapData!.isNotEmpty) {
      final List<Marker> allMarkers = [];
      
      for (var data in widget.initialMapData!) {
        final lat = data['lat'] as double;
        final lon = data['lon'] as double;
        final grade = data['grade'] as String;
        final color = grade == '待检测' ? Colors.grey : (grade == 'OK' ? Colors.green : (grade == 'A' ? Colors.amber : Colors.redAccent));
        
        // 中心基准位置（无人机位置）
        allMarkers.add(Marker(
          point: LatLng(lat, lon),
          width: 40,
          height: 40,
          child: GestureDetector(
            onTap: () {
              _showDefectDetails(data);
            },
            child: Icon(grade == '待检测' ? Icons.location_on : Icons.camera_alt, color: color, size: grade == '待检测' ? 40.0 : 28.0),
          ),
        ));
        
        // 将光伏组件（缺陷/标注框）展开成独立的物理标记点
        // 原有自动抽取 defectos 的大段逻辑依照要求被移除，不再进行自动拉伸贴图
      }
      _markers = allMarkers;
      
      // Auto-center map on the first point
      if (widget.initialMapData!.isNotEmpty) {
        _mapCenter = LatLng(
          widget.initialMapData![0]['lat'] as double,
          widget.initialMapData![0]['lon'] as double,
        );
        _mapZoom = 18.0; // 放大到组件级别
      }
    }
    _currentTifPath = _currentTifPath;
    if (_currentTifPath != null && widget.serverUrl != null) {
      _loadTifInfo();
    }
  }

  Future<void> _loadTifInfo() async {
    try {
      final dio = Dio(BaseOptions(baseUrl: widget.serverUrl!));
      final response = await dio.get('/api/map/info', queryParameters: {'path': _currentTifPath});
      if (response.data != null && response.data['success'] == true) {
        final center = response.data['center'];
        if (center != null && center.length == 2) {
          // rio-tiler usually returns center as (lon, lat)
          setState(() {
            _mapCenter = LatLng((center[1] as num).toDouble(), (center[0] as num).toDouble());
            _mapZoom = 18.0;
          });
          _mapController.move(_mapCenter, _mapZoom);
        }
      }
    } catch (e) {
      debugPrint('Failed to load tif info: ${e.toString()}');
    }
  }

    Future<void> _pickAndLoadTif() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['tif', 'tiff']);
    if (result != null && result.files.single.path != null) {
      setState(() { _currentTifPath = result.files.single.path; });
      _loadTifInfo();
    }
  }

  // 手动批量导入图片挂载点
  Future<void> _pickAndLoadDefects() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.image,
    );
    if (result != null && result.files.isNotEmpty) {
      final paths = result.files.where((f) => f.path != null).map((f) => f.path!).toList();
      if (paths.isNotEmpty) await _processImagePaths(paths);
    }
  }

  // 手动导入整个目录下的所有图片
  Future<void> _pickAndLoadFolder() async {
    String? dirPath = await FilePicker.platform.getDirectoryPath();
    if (dirPath == null) return;
    
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;
    
    List<String> imagePaths = [];
    final entities = dir.listSync(recursive: true);
    for (var entity in entities) {
      if (entity is File) {
        final pathLower = entity.path.toLowerCase();
        if (pathLower.endsWith('.jpg') || pathLower.endsWith('.jpeg') || pathLower.endsWith('.png')) {
          imagePaths.add(entity.path);
        }
      }
    }
    
    if (imagePaths.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('该目录下未发现任何图片')));
      return;
    }
    await _processImagePaths(imagePaths);
  }

  Future<void> _processImagePaths(List<String> paths) async {
    double? pWidth, pHeight;
    final bool confirmed = await showDialog(
      context: context,
      builder: (ctx) {
        final wc = TextEditingController(text: '1.0');
        final hc = TextEditingController(text: '2.0');
        return AlertDialog(
          title: const Text('设置物理组件尺寸', style: TextStyle(color: Colors.white)),
          backgroundColor: const Color(0xFF0F172A),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('请输入每张图片在真实世界中的长宽大小，图片会依照此长宽缩放并在地图层贴地渲染。', 
                style: TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 16),
              TextField(controller: wc, style: const TextStyle(color: Colors.white), 
                  decoration: const InputDecoration(labelText: '宽度 (米)', labelStyle: TextStyle(color: Colors.white54))),
              TextField(controller: hc, style: const TextStyle(color: Colors.white), 
                  decoration: const InputDecoration(labelText: '高度 (米)', labelStyle: TextStyle(color: Colors.white54))),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消', style: TextStyle(color: Colors.white54))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB)),
              onPressed: () {
                pWidth = double.tryParse(wc.text);
                pHeight = double.tryParse(hc.text);
                if (pWidth != null && pHeight != null) Navigator.pop(ctx, true);
              }, 
              child: const Text('确认', style: TextStyle(color: Colors.white))),
          ],
        );
      }
    ) ?? false;
    
    if (!confirmed || pWidth == null || pHeight == null) return;
    
    final List<ManualMarkerDef> newDefs = List.from(_manualDefs);
    bool didMoveCamera = false;
    
    setState(() {
      _isLoadingImages = true;
      _loadingTotal = paths.length;
      _loadingProgress = 0;
    });

    for (var i = 0; i < paths.length; i++) {
       var path = paths[i];
       
       // Update progress occasionally to avoid freezing the UI entirely
       if (i % 20 == 0) {
         setState(() { _loadingProgress = i; });
         await Future.delayed(const Duration(milliseconds: 1)); // Yield execution
       }

       final fileObj = File(path);
       final String fileName = fileObj.path.split(Platform.pathSeparator).last;
       try {
         final tags = await readExifFromFile(fileObj);
         
         if (!tags.containsKey('GPS GPSLatitude') || !tags.containsKey('GPS GPSLongitude')) {
             debugPrint('[Load] 跳过没有GPS信息的图片: $fileName');
             continue;
         }
         
         double? parseCoord(String printable) {
             try {
                 String clean = printable.replaceAll('[','').replaceAll(']','');
                 List<String> parts = clean.split(', ');
                 if (parts.length == 3) {
                     double parseP(String p) {
                         if (p.contains('/')) {
                             var spl = p.split('/');
                             return double.parse(spl[0]) / double.parse(spl[1]);
                         }
                         return double.parse(p);
                     }
                     double d = parseP(parts[0]);
                     double m = parseP(parts[1]);
                     double s = parseP(parts[2]);
                     return d + m/60.0 + s/3600.0;
                 }
             } catch (e) {}
             return null;
         }
         
         double? lat = parseCoord(tags['GPS GPSLatitude']!.printable);
         double? lon = parseCoord(tags['GPS GPSLongitude']!.printable);
         if (lat == null || lon == null) continue;
         
         if (tags['GPS GPSLatitudeRef']?.printable.contains('S') == true) lat = -lat;
         if (tags['GPS GPSLongitudeRef']?.printable.contains('W') == true) lon = -lon;
         
         final String parentDirName = fileObj.parent.path.split(Platform.pathSeparator).last;
         if (!_stringTransforms.containsKey(parentDirName)) {
             _stringTransforms[parentDirName] = StringTransform();
         }
         _selectedStringId = parentDirName; // Auto-select latest imported string
         
         newDefs.add(ManualMarkerDef(fileObj, lat, lon, fileName, pWidth!, pHeight!, parentDirName));
         
         if (!didMoveCamera) {
           didMoveCamera = true;
           _mapCenter = LatLng(lat, lon);
           _mapZoom = 21.0;
           _mapController.move(_mapCenter, _mapZoom);
         }
       } catch (e) {
           debugPrint('[Load] Error loading image $path: $e');
       }
    }
    setState(() { 
      _manualDefs = newDefs; 
      _isLoadingImages = false;
    });
    _rebuildMarkers();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('成功导入 ${newDefs.length - _manualDefs.length} 张组件图!')));
  }

  void _showStringDetails(String stringId, List<ManualMarkerDef> components) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          title: Text('组串详情: $stringId', style: const TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('组件数量: ${components.length}', style: const TextStyle(color: Color(0xFF94A3B8))),
              const SizedBox(height: 10),
              const Text('此为分组视图，提示: 双击组内任意单独组件可查看组件局部详情', style: TextStyle(color: Colors.white70)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭', style: TextStyle(color: Colors.white54)),
            ),
          ],
        );
      },
    );
  }

  void _rebuildMarkers() {
    List<Marker> newMarkers = [];
    List<Polygon> newPolygons = [];
    
    // 如果存在自动传入的中心点，先加入它
    if (widget.initialMapData != null && widget.initialMapData!.isNotEmpty) {
       final d0 = widget.initialMapData![0];
       newMarkers.add(Marker(
         point: LatLng(d0['lat'], d0['lon']),
         width: 40, height: 40,
         child: GestureDetector(
           onTap: () => _showDefectDetails(d0),
           child: const Icon(Icons.location_on, color: Colors.blueAccent, size: 40.0),
         ),
       ));
    }
    
    if (_manualDefs.isNotEmpty) {
      // 按照 StringId 分组聚合
      Map<String, List<ManualMarkerDef>> grouped = {};
      for (var def in _manualDefs) {
        grouped.putIfAbsent(def.stringId, () => []).add(def);
      }
      
      for (var entry in grouped.entries) {
        final String stringId = entry.key;
        final List<ManualMarkerDef> comps = entry.value;
        final StringTransform transform = _stringTransforms[stringId] ?? StringTransform();
        final bool isSelectedString = stringId == _selectedStringId;
        
        // 计算当前组的数学质心（旋转和平移的绝对锚点）
        double sumLat = 0, sumLon = 0;
        for (var d in comps) {
          sumLat += d.rawLat;
          sumLon += d.rawLon;
        }
        final double centroidLat = sumLat / comps.length;
        final double centroidLon = sumLon / comps.length;

        // 根据最新转换参数，生成每一个点的实际显示坐标
        List<LatLng> transformedPoints = [];

        for (var def in comps) {
          // 1. 根据重心缩放组件间距 (Spacing Scale)
          double scaledLat = centroidLat + (def.rawLat - centroidLat) * transform.spacingScale;
          double scaledLon = centroidLon + (def.rawLon - centroidLon) * transform.spacingScale;
          
          // 2. 根据重心进行二维方位角旋转变换 (Azimuth Rotation)
          // 计算当前点到重心的差值，经度因投影需要乘上纬度收缩系数
          double dy = scaledLat - centroidLat;
          double dx = (scaledLon - centroidLon) * math.cos(centroidLat * math.pi / 180.0);
          
          double rad = transform.angleRad;
          // 顺时针旋转公式 (屏幕坐标系通常 Y 下降 但在地图上北正南负。对于标准经纬度: dx和dy符合笛卡尔坐标)
          double rotX = dx * math.cos(rad) + dy * math.sin(rad);
          double rotY = -dx * math.sin(rad) + dy * math.cos(rad);
          
          // 还原因旋转修正的经纬度差值
          double rotatedLat = centroidLat + rotY;
          double rotatedLon = centroidLon + rotX / math.cos(centroidLat * math.pi / 180.0);
          
          // 3. 加上用户整体平移绝对位移 (Translation)
          double finalLat = rotatedLat + transform.dLat;
          double finalLon = rotatedLon + transform.dLon;
          
          LatLng finalPt = LatLng(finalLat, finalLon);
          transformedPoints.add(finalPt);
          
          newMarkers.add(Marker(
            point: finalPt,
            width: 1000, 
            height: 1000, 
            alignment: Alignment.center,
            child: Builder(builder: (ctx) {
              final camera = MapCamera.of(ctx);
              final double metersPerPx = 156543.03392 * math.cos(finalLat * math.pi / 180.0) / math.pow(2.0, camera.zoom);
              final double safeW = math.max(def.physicalW / metersPerPx, 8.0);
              final double safeH = math.max(def.physicalH / metersPerPx, 8.0);
              
              return Center(
                child: Transform.rotate(
                  angle: rad, // 修改为和轨道同向的正旋转，确保物理排列形成刚体旋转
                  child: GestureDetector(
                    onTap: () {
                        setState(() { _selectedStringId = stringId; });
                        _rebuildMarkers(); // <-- 立即重绘边框颜色和选区
                        _showStringDetails(stringId, comps);
                    },
                    onDoubleTap: () {
                        _showDefectDetails({'lat': def.rawLat, 'lon': def.rawLon, 'filename': def.name, 'grade': 'Loaded'});
                    },
                    child: Container(
                      width: safeW, height: safeH,
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        border: Border.all(color: isSelectedString ? Colors.amberAccent : Colors.tealAccent, width: isSelectedString ? 3 : 2),
                        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 4, offset: Offset(1, 1))],
                        image: DecorationImage(
                          image: ResizeImage(FileImage(def.file), width: 150), 
                          fit: BoxFit.fill
                        ),
                      )
                    ),
                  )
                )
              );
            })
          ));
        }

        // 绘制圈选组串边界轮廓
        if (transformedPoints.isNotEmpty && isSelectedString) {
          double minLat = transformedPoints[0].latitude, maxLat = transformedPoints[0].latitude;
          double minLon = transformedPoints[0].longitude, maxLon = transformedPoints[0].longitude;
          for (var p in transformedPoints) {
             if (p.latitude < minLat) minLat = p.latitude;
             if (p.latitude > maxLat) maxLat = p.latitude;
             if (p.longitude < minLon) minLon = p.longitude;
             if (p.longitude > maxLon) maxLon = p.longitude;
          }
          // 增加 10% 边界裕量
          final dLat = (maxLat - minLat).abs() * 0.1 + 0.000005;
          final dLon = (maxLon - minLon).abs() * 0.1 + 0.000005;
          
          newPolygons.add(Polygon(
            points: [
               LatLng(minLat - dLat, minLon - dLon),
               LatLng(minLat - dLat, maxLon + dLon),
               LatLng(maxLat + dLat, maxLon + dLon),
               LatLng(maxLat + dLat, minLon - dLon),
            ],
            color: Colors.amberAccent.withOpacity(0.1),
            borderColor: Colors.amberAccent,
            borderStrokeWidth: 2.0,
          ));
        }
      }
    }
    
    setState(() { 
      _markers = newMarkers; 
      _polygons = newPolygons;
    });
  }

  Future<void> _locateMe() async {
    setState(() => _isLocating = true);
    try {
      final dio = Dio();
      final response = await dio.get('http://ip-api.com/json/?lang=zh-CN');
      if (response.statusCode == 200 && response.data['status'] == 'success') {
        final lat = response.data['lat'] as double;
        final lon = response.data['lon'] as double;
        final city = response.data['city'] ?? '';
        final newCenter = LatLng(lat, lon);
        
        setState(() {
          _mapCenter = newCenter;
          _mapZoom = 14.0;
          _currentLocationMarker = Marker(
            point: newCenter,
            width: 40,
            height: 40,
            child: const Icon(Icons.my_location, color: Colors.blueAccent, size: 30),
          );
        });
        _mapController.move(newCenter, 14.0);
        
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已定位至: $city')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('网络定位失败，请检查网络')));
    } finally {
      if (mounted) setState(() => _isLocating = false);
    }
  }

  Future<void> _searchMap(String query) async {
    if (query.trim().isEmpty) return;
    setState(() => _isSearching = true);
    try {
      final parts = query.split(RegExp(r'[,，\s]+'));
      if (parts.length >= 2) {
        final p1 = double.tryParse(parts[0]);
        final p2 = double.tryParse(parts[1]);
        if (p1 != null && p2 != null) {
          // 假设是 经度,维度 (中国常见组合) 或 纬度,经度
          final lat = (p1 > 70 && p1 < 140) ? p2 : p1; // 如果前一个是经度，后一个是纬度
          final lon = (p1 > 70 && p1 < 140) ? p1 : p2;
          final newCenter = LatLng(lat, lon);
          setState(() { _mapCenter = newCenter; _mapZoom = 15.0; });
          _mapController.move(newCenter, 15.0);
          setState(() => _isSearching = false);
          return;
        }
      }
      
      final dio = Dio();
      final response = await dio.get('https://nominatim.openstreetmap.org/search', queryParameters: {
        'q': query, 'format': 'json', 'limit': 1,
      });
      
      if (response.statusCode == 200 && response.data is List && response.data.isNotEmpty) {
        final data = response.data[0];
        final lat = double.tryParse(data['lat'].toString()) ?? 0;
        final lon = double.tryParse(data['lon'].toString()) ?? 0;
        final name = data['display_name'] ?? query;
        
        final newCenter = LatLng(lat, lon);
        setState(() { _mapCenter = newCenter; _mapZoom = 14.0; });
        _mapController.move(newCenter, 14.0);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('找到位置: $name')));
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('未找到目标地址')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('搜索服务不可用')));
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  void _showDefectDetails(Map<String, dynamic> data) {
    showDialog(
      context: context,
      builder: (ctx) {
        final List defects = data['defects'] ?? [];
        return AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          title: Text(data['filename'] ?? '图片详情', style: const TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('经度: ${data['lon']}, 纬度: ${data['lat']}', style: const TextStyle(color: Color(0xFF94A3B8))),
              const SizedBox(height: 10),
              Text('等级: ${data['grade']}', style: TextStyle(color: data['grade'] == 'OK' ? Colors.green : Colors.redAccent, fontSize: 16, fontWeight: FontWeight.bold)),
              if (defects.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text('缺陷列表:', style: TextStyle(color: Colors.white)),
                ...defects.map((d) => Text('- ${d['className']} (${(d['score'] * 100).toStringAsFixed(1)}%)', style: const TextStyle(color: Color(0xFFF87171)))),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB)),
              onPressed: () {
                Navigator.pop(ctx);
                _showQrCodeDialog(data['lat'], data['lon'], data['filename'] ?? '异常光伏组件');
              },
              child: const Text('生成导航二维码', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showQrCodeDialog(double lat, double lon, String title) {
    // Generate an Amap Web URI that falls back to H5 or opens the app
    final String encodedTitle = Uri.encodeComponent(title);
    final String url = 'https://uri.amap.com/navigation?to=$lon,$lat,$encodedTitle&mode=walk&callnative=1';
    
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          title: const Text('巡检导航二维码', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                color: Colors.white,
                child: QrImageView(
                  data: url,
                  version: QrVersions.auto,
                  size: 200.0,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              const Text('使用手机浏览器或微信扫码\n直接拉起高德地图导航至异常组件位置', 
                  style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13, height: 1.5), textAlign: TextAlign.center),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('确认', style: TextStyle(color: Color(0xFF38BDF8))),
            ),
          ],
        );
      }
    );
  }

  Widget _buildStringControls() {
    if (_selectedStringId == null || !_stringTransforms.containsKey(_selectedStringId)) return const SizedBox();
    final transform = _stringTransforms[_selectedStringId]!;
    
    return Positioned(
      bottom: 24, left: 100, right: _isPanelOpen ? 340 : 100,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withOpacity(0.95), 
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFF334155)),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4))],
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 1. Spacing Control
                const Icon(Icons.compare_arrows_rounded, color: Colors.amber, size: 16),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => _showNumericInputDialog('设置聚拢间距', transform.spacingScale, (val) => setState(() { transform.spacingScale = val; _rebuildMarkers(); })),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(4)),
                    child: Text('${transform.spacingScale.toStringAsFixed(2)}x', style: const TextStyle(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.bold, decoration: TextDecoration.underline)),
                  ),
                ),
                SizedBox(
                  width: 100, height: 30,
                  child: Slider(
                    value: transform.spacingScale, min: 0.01, max: 3.0,
                    activeColor: Colors.amber,
                    onChanged: (val) { setState(() { transform.spacingScale = val; }); _rebuildMarkers(); }
                  )
                ),
                Container(height: 24, width: 1, color: Colors.white24, margin: const EdgeInsets.symmetric(horizontal: 8)),
                
                // 2. Rotation Control
                const Icon(Icons.rotate_right_rounded, color: Colors.greenAccent, size: 16),
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => _showNumericInputDialog('设置方位角 (度)', transform.angleRad * 180.0 / math.pi, (val) => setState(() { transform.angleRad = val * math.pi / 180.0; _rebuildMarkers(); })),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(4)),
                    child: Text('${(transform.angleRad * 180.0 / math.pi).toStringAsFixed(1)}°', style: const TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold, decoration: TextDecoration.underline)),
                  ),
                ),
                SizedBox(
                  width: 100, height: 30,
                  child: Slider(
                    value: transform.angleRad, min: -math.pi, max: math.pi,
                    activeColor: Colors.greenAccent,
                    onChanged: (val) { setState(() { transform.angleRad = val; }); _rebuildMarkers(); }
                  )
                ),
                Container(height: 24, width: 1, color: Colors.white24, margin: const EdgeInsets.symmetric(horizontal: 8)),
                
                // 3. Translation DPAD
                const Icon(Icons.open_with_rounded, color: Colors.lightBlueAccent, size: 16),
                const SizedBox(width: 6),
                const Text('微移矫正', style: TextStyle(color: Colors.white70, fontSize: 12)),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _dpadButton(Icons.arrow_left, () => _shiftSelected(0, -0.000003)),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _dpadButton(Icons.arrow_drop_up, () => _shiftSelected(0.000003, 0)),
                        _dpadButton(Icons.arrow_drop_down, () => _shiftSelected(-0.000003, 0)),
                      ],
                    ),
                    _dpadButton(Icons.arrow_right, () => _shiftSelected(0, 0.000003)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _dpadButton(IconData icon, VoidCallback onPressed) {
    return GestureDetector(
       onTap: onPressed,
       behavior: HitTestBehavior.opaque,
       child: Container(
         margin: const EdgeInsets.all(1),
         padding: const EdgeInsets.all(2),
         decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.white24)),
         child: Icon(icon, color: Colors.white, size: 24),
       )
    );
  }

  void _shiftSelected(double dLat, double dLon) {
    if (_selectedStringId == null || !_stringTransforms.containsKey(_selectedStringId)) return;
    setState(() {
      _stringTransforms[_selectedStringId!]!.dLat += dLat;
      _stringTransforms[_selectedStringId!]!.dLon += dLon;
    });
    _rebuildMarkers();
  }

  void _showNumericInputDialog(String title, double initialValue, Function(double) onConfirmed) {
    showDialog(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController(text: initialValue.toStringAsFixed(2));
        return AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          title: Text(title, style: const TextStyle(color: Colors.white)),
          content: TextField(
            controller: ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB)),
              onPressed: () {
                final double? parsed = double.tryParse(ctrl.text);
                if (parsed != null) {
                  onConfirmed(parsed);
                }
                Navigator.pop(ctx);
              },
              child: const Text('确认', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0A0F1D),
      child: Stack(
              children: [
                _buildMapLayer(),

                // 悬浮顶部功能栏
                Positioned(
                  top: 20, left: 20, right: _isPanelOpen ? 340 : 20,
                  child: _buildTopNav(),
                ),

                // 悬浮搜索栏
                Positioned(
                  top: 90, left: 20, width: 320,
                  child: _buildSearchBar(),
                ),

                // 悬浮地图控制箱 (左下角)
                Positioned(
                  bottom: 20, left: 20,
                  child: Column(
                    children: [
                      FloatingActionButton(
                        heroTag: 'btn_layer',
                        backgroundColor: const Color(0xFF1E293B),
                        mini: true,
                        onPressed: () => setState(() => _isSatellite = !_isSatellite),
                        child: Icon(_isSatellite ? Icons.map_rounded : Icons.satellite_alt_rounded, color: const Color(0xFF38BDF8)),
                      ),
                      const SizedBox(height: 12),
                      FloatingActionButton(
                        heroTag: 'btn_locate',
                        backgroundColor: const Color(0xFF1E293B),
                        mini: true,
                        onPressed: _isLocating ? null : _locateMe,
                        child: _isLocating 
                           ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Color(0xFF38BDF8), strokeWidth: 2))
                           : const Icon(Icons.my_location_rounded, color: Colors.white),
                      ),
                    ],
                  ),
                ),
                
                // 动态组串控制台 (平移, 旋转, 聚拢)
                _buildStringControls(),

                // 右侧参数控制台
                if (_isPanelOpen)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: _buildRightPanel(),
                  ),
                
                // 展开/收起右侧边栏按钮
                Positioned(
                  right: _isPanelOpen ? 320 : 0,
                  top: MediaQuery.of(context).size.height / 2 - 20,
                  child: GestureDetector(
                    onTap: () => setState(() => _isPanelOpen = !_isPanelOpen),
                    child: Container(
                      width: 24,
                      height: 48,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B).withOpacity(0.9),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(8),
                          bottomLeft: Radius.circular(8),
                        ),
                        border: Border.all(color: const Color(0xFF334155)),
                      ),
                      child: Icon(
                        _isPanelOpen ? Icons.chevron_right : Icons.chevron_left,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ),

                // 遮罩 Loading 页面
                if (_isLoadingImages)
                  Container(
                    color: Colors.black54,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 30),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF334155)),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 20, offset: const Offset(0, 10))
                          ]
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(color: Color(0xFF38BDF8)),
                            const SizedBox(height: 20),
                            const Text('正在解析组件图片 EXIF...', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 10),
                            Text('进度: $_loadingProgress / $_loadingTotal', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildMapLayer() {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _mapCenter,
        initialZoom: _mapZoom,
        maxZoom: 26,
      ),
      children: [
        // 比例尺及高度图层
        Builder(builder: (ctx) {
           final camera = MapCamera.of(ctx);
           final double metersPerPx = 156543.03392 * math.cos(camera.center.latitude * math.pi / 180.0) / math.pow(2.0, camera.zoom);
           final double widthPx = 100.0;
           final double meters = metersPerPx * widthPx;
           final double simulatedHeight = metersPerPx * 1000; // 粗略估算相对地面高度
           
           return Positioned(
             bottom: 110, left: 20,
             child: Container(
               padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
               decoration: BoxDecoration(color: const Color(0xFF0F172A).withOpacity(0.8), borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.white24)),
               child: Column(
                 crossAxisAlignment: CrossAxisAlignment.start,
                 mainAxisSize: MainAxisSize.min,
                 children: [
                    Row(
                      children: [
                        Container(width: widthPx, height: 4, decoration: const BoxDecoration(
                           border: Border(left: BorderSide(color: Colors.white, width: 2), right: BorderSide(color: Colors.white, width: 2), bottom: BorderSide(color: Colors.white, width: 2))
                        )),
                        const SizedBox(width: 8),
                        Text('${meters.toStringAsFixed(1)} m', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text('视觉GSD: ${(metersPerPx * 100).toStringAsFixed(1)} cm/pixel', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                    Text('模拟高度: ~${simulatedHeight.toStringAsFixed(1)} m', style: const TextStyle(color: Colors.amberAccent, fontSize: 11)),
                 ],
               ),
             ),
           );
        }),

        // 使用高德地图(Amap)国内公共瓦片服务
        TileLayer(
          urlTemplate: _isSatellite 
              ? 'https://webst01.is.autonavi.com/appmaptile?style=6&x={x}&y={y}&z={z}'
              : 'https://webrd01.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}',
          userAgentPackageName: 'com.qiyang.el_detect',
          maxNativeZoom: 18,
        ),
        
        // 动态加载用户的高清大图微服务
        if (_currentTifPath != null && widget.serverUrl != null)
          TileLayer(
             urlTemplate: '${widget.serverUrl!}/api/map/tile/{z}/{x}/{y}.png?path=${Uri.encodeComponent(_currentTifPath!)}&v=4',
             maxNativeZoom: 26,
             retinaMode: true,
          ),

        // 组串多边形轮廓图层
        PolygonLayer(polygons: _polygons),
        
        // 此处可添加基于 TIF 的 ImageLayer 或 MarkerLayer (显示缺陷打点)
        MarkerLayer(
          markers: [
            ...(_markers.isNotEmpty ? _markers : [
              Marker(
                point: _mapCenter,
                width: 40,
                height: 40,
                child: const Icon(Icons.location_on, color: Colors.blueAccent, size: 40.0),
              )
            ]),
            if (_currentLocationMarker != null) _currentLocationMarker!,
          ],
        )
      ],
    );
  }

  Widget _buildSearchBar() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withOpacity(0.9),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF334155), width: 1.5),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4))
        ]
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, color: Color(0xFF94A3B8), size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(
                hintText: '搜索地名 / 地址 / 经纬度 (如: 116.3,39.9)',
                hintStyle: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                border: InputBorder.none,
                isDense: true,
              ),
              onSubmitted: (val) => _searchMap(val),
            ),
          ),
          if (_isSearching)
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Color(0xFF38BDF8), strokeWidth: 2))
          else
            IconButton(
              icon: const Icon(Icons.arrow_forward_rounded, color: Color(0xFF38BDF8), size: 20),
              onPressed: () => _searchMap(_searchController.text),
              constraints: const BoxConstraints(),
              padding: EdgeInsets.zero,
            ),
        ],
      ),
    );
  }

  Widget _buildTopNav() {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withOpacity(0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155), width: 1.5),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 4))
        ]
      ),
      child: Row(
        children: [
          const Icon(Icons.satellite_alt_rounded, color: Color(0xFF38BDF8), size: 24),
          const SizedBox(width: 12),
          const Text('空间智能分析', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
          const Spacer(),
          _topNavItem(Icons.map_outlined, '地图视图', true, null),
          const SizedBox(width: 16),
          _topNavItem(Icons.picture_in_picture_alt_rounded, '导入选中组件', false, _pickAndLoadDefects),
          const SizedBox(width: 16),
          _topNavItem(Icons.drive_folder_upload_rounded, '导入整个目录', false, _pickAndLoadFolder),
          const SizedBox(width: 16),
          _topNavItem(Icons.add_photo_alternate_rounded, '正射大图', false, _pickAndLoadTif),
          const SizedBox(width: 16),
          _topNavItem(Icons.bolt, '极速分析', false, null),
          const SizedBox(width: 16),
          _topNavItem(Icons.history_rounded, '工程历史', false, null),
        ],
      ),
    );
  }

  Widget _topNavItem(IconData icon, String label, bool isActive, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFF38BDF8).withOpacity(0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: isActive ? const Color(0xFF38BDF8) : Colors.white70, size: 18),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: isActive ? Colors.white : Colors.white70, fontSize: 13, fontWeight: isActive ? FontWeight.bold : FontWeight.normal)),
          ],
        ),
      ),
    );
  }

  Widget _buildRightPanel() {
    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.95),
        border: const Border(left: BorderSide(color: Color(0xFF1E293B))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(20.0),
            child: Row(
              children: const [
                Icon(Icons.layers_rounded, color: Color(0xFF7DD3FC), size: 24),
                SizedBox(width: 12),
                Text('图层与数据控制', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const Divider(color: Color(0xFF1E293B), height: 1),
          
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [

                _buildAnalysisControlSection(),
              ],
            ),
          )
        ],
      ),
    );
  }



  Widget _buildAnalysisControlSection() {
    return Container(
       padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('智能拓扑与缺陷分析', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          _statusItem('阵列提取', '未执行'),
          const SizedBox(height: 12),
          _statusItem('组串编号', '未生成'),
          const SizedBox(height: 12),
          _statusItem('异常捕捉', '等待中'),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('即将调度 YOLO/Anomalib 分析引擎...')),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF059669),
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('全景一键执行扫描', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1.0)),
          ),
        ],
      )
    );
  }

  Widget _statusItem(String title, String status) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13)),
        Text(status, style: const TextStyle(color: Color(0xFF64748B), fontSize: 13, fontStyle: FontStyle.italic)),
      ],
    );
  }
}
