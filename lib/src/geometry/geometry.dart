import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart' as vm;

import 'package:flutter_scene/src/shaders.dart';
import 'package:flutter_scene_importer/constants.dart';
import 'package:flutter_scene_importer/flatbuffer.dart' as fb;

abstract class Geometry {
  gpu.BufferView? _vertices;
  int _vertexCount = 0;
  late Uint8List sourceVertices;
  late Uint8List sourceIndices;
  gpu.BufferView? _indices;
  gpu.IndexType _indexType = gpu.IndexType.int16;
  int _indexCount = 0;

  /// 缓存的包围盒
  vm.Aabb3? _cachedBounds;

  /// 缓存的包围球（中心点 + 半径）
  vm.Vector3? _boundingSphereCenter;
  double _boundingSphereRadius = 0.0;

  /// 获取几何体的包围盒
  vm.Aabb3? get bounds => _cachedBounds;

  /// 获取包围球中心（局部坐标系）
  vm.Vector3? get boundingSphereCenter => _boundingSphereCenter;

  /// 获取包围球半径
  double get boundingSphereRadius => _boundingSphereRadius;

  /// 每个顶点的字节数（子类需要设置）
  int get perVertexBytes;

  gpu.Shader? _vertexShader;
  gpu.Shader get vertexShader {
    if (_vertexShader == null) {
      throw Exception('Vertex shader has not been set');
    }
    return _vertexShader!;
  }

  static Geometry fromFlatbuffer(fb.MeshPrimitive fbPrimitive) {
    Uint8List vertices;
    bool isSkinned =
        fbPrimitive.vertices!.runtimeType == fb.SkinnedVertexBuffer;
    int perVertexBytes =
        isSkinned ? kSkinnedPerVertexSize : kUnskinnedPerVertexSize;

    switch (fbPrimitive.vertices!.runtimeType) {
      case const (fb.UnskinnedVertexBuffer):
        fb.UnskinnedVertexBuffer unskinned =
            (fbPrimitive.vertices as fb.UnskinnedVertexBuffer?)!;
        vertices = unskinned.vertices! as Uint8List;
      case const (fb.SkinnedVertexBuffer):
        fb.SkinnedVertexBuffer skinned =
            (fbPrimitive.vertices as fb.SkinnedVertexBuffer?)!;
        vertices = skinned.vertices! as Uint8List;
      default:
        throw Exception('Unknown vertex buffer type');
    }

    if (vertices.length % perVertexBytes != 0) {
      debugPrint(
        'OH NO: Encountered an vertex buffer of size '
        '${vertices.lengthInBytes} bytes, which doesn\'t match the '
        'expected multiple of $perVertexBytes bytes. Possible data corruption! '
        'Attempting to use a vertex count of ${vertices.length ~/ perVertexBytes}. '
        'The last ${vertices.length % perVertexBytes} bytes will be ignored.',
      );
    }
    int vertexCount = vertices.length ~/ perVertexBytes;

    gpu.IndexType indexType = fbPrimitive.indices!.type.toIndexType();
    Uint8List indices = fbPrimitive.indices!.data! as Uint8List;

    Geometry geometry;
    switch (fbPrimitive.vertices!.runtimeType) {
      case const (fb.UnskinnedVertexBuffer):
        geometry = UnskinnedGeometry();
      case const (fb.SkinnedVertexBuffer):
        geometry = SkinnedGeometry();
      default:
        throw Exception('Unknown vertex buffer type');
    }
    geometry.sourceIndices = indices;
    geometry.sourceVertices = vertices;
    geometry.uploadVertexData(
      ByteData.sublistView(vertices),
      vertexCount,
      ByteData.sublistView(indices),
      indexType: indexType,
    );

    // 计算包围盒（从顶点位置数据）
    geometry.buildBounds();

    return geometry;
  }

  /// 从顶点数据计算包围盒和包围球
  void buildBounds() {
    if (_vertexCount == 0) {
      _cachedBounds = null;
      _boundingSphereCenter = null;
      _boundingSphereRadius = 0.0;
      return;
    }

    // 顶点位置在每个顶点的前12字节（3个float）
    final floatView = ByteData.sublistView(
      sourceVertices,
      sourceVertices.offsetInBytes,
      sourceVertices.offsetInBytes + sourceVertices.lengthInBytes,
    );

    double minX = double.infinity;
    double minY = double.infinity;
    double minZ = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;
    double maxZ = double.negativeInfinity;

    for (int i = 0; i < _vertexCount; i++) {
      final offset = i * perVertexBytes;
      final x = floatView.getFloat32(offset, Endian.little);
      final y = floatView.getFloat32(offset + 4, Endian.little);
      final z = floatView.getFloat32(offset + 8, Endian.little);

      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (z < minZ) minZ = z;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
      if (z > maxZ) maxZ = z;
    }

    _cachedBounds = vm.Aabb3.minMax(
      vm.Vector3(minX, minY, minZ),
      vm.Vector3(maxX, maxY, maxZ),
    );

    // 计算包围球：中心为 AABB 中心，半径为中心到最远顶点的距离
    final centerX = (minX + maxX) * 0.5;
    final centerY = (minY + maxY) * 0.5;
    final centerZ = (minZ + maxZ) * 0.5;
    _boundingSphereCenter = vm.Vector3(centerX, centerY, centerZ);

    // 计算最大半径
    double maxRadiusSq = 0.0;
    for (int i = 0; i < _vertexCount; i++) {
      final offset = i * perVertexBytes;
      final x = floatView.getFloat32(offset, Endian.little) - centerX;
      final y = floatView.getFloat32(offset + 4, Endian.little) - centerY;
      final z = floatView.getFloat32(offset + 8, Endian.little) - centerZ;
      final distSq = x * x + y * y + z * z;
      if (distSq > maxRadiusSq) maxRadiusSq = distSq;
    }
    _boundingSphereRadius = maxRadiusSq > 0 ? math.sqrt(maxRadiusSq) : 0.0;
  }

  /// 手动设置自定义包围盒
  void buildCustomBounds(vm.Vector3 min, vm.Vector3 max) {
    _cachedBounds = vm.Aabb3.minMax(min, max);
  }

  void setVertices(gpu.BufferView vertices, int vertexCount) {
    _vertices = vertices;
    _vertexCount = vertexCount;
  }

  void setIndices(gpu.BufferView indices, gpu.IndexType indexType) {
    _indices = indices;
    _indexType = indexType;
    switch (indexType) {
      case gpu.IndexType.int16:
        _indexCount = indices.lengthInBytes ~/ 2;
      case gpu.IndexType.int32:
        _indexCount = indices.lengthInBytes ~/ 4;
    }
  }

  get indexCount => _indexCount;

  void uploadVertexData(
    ByteData vertices,
    int vertexCount,
    ByteData? indices, {
    gpu.IndexType indexType = gpu.IndexType.int16,
  }) {
    gpu.DeviceBuffer deviceBuffer = gpu.gpuContext.createDeviceBuffer(
      gpu.StorageMode.hostVisible,
      indices == null
          ? vertices.lengthInBytes
          : vertices.lengthInBytes + indices.lengthInBytes,
    );

    deviceBuffer.overwrite(vertices, destinationOffsetInBytes: 0);
    setVertices(
      gpu.BufferView(
        deviceBuffer,
        offsetInBytes: 0,
        lengthInBytes: vertices.lengthInBytes,
      ),
      vertexCount,
    );

    if (indices != null) {
      deviceBuffer.overwrite(
        indices,
        destinationOffsetInBytes: vertices.lengthInBytes,
      );
      setIndices(
        gpu.BufferView(
          deviceBuffer,
          offsetInBytes: vertices.lengthInBytes,
          lengthInBytes: indices.lengthInBytes,
        ),
        indexType,
      );
    }
  }

  void setVertexShader(gpu.Shader shader) {
    _vertexShader = shader;
  }

  void setJointsTexture(gpu.Texture? texture, int width) {}

  void bind(
    gpu.RenderPass pass,
    gpu.HostBuffer transientsBuffer,
    vm.Matrix4 modelTransform,
    vm.Matrix4 cameraTransform,
    vm.Vector3 cameraPosition,
  );
}

class UnskinnedGeometry extends Geometry {
  UnskinnedGeometry() {
    setVertexShader(baseShaderLibrary['UnskinnedVertex']!);
  }

  @override
  int get perVertexBytes => kUnskinnedPerVertexSize;

  /// 预分配的 UBO 缓冲区，避免每帧创建新数组
  /// Unskinned: 16 (model) + 16 (camera) + 3 (cameraPos) = 35 floats
  final Float32List _frameInfoFloats = Float32List(35);

  @override
  void bind(
    gpu.RenderPass pass,
    gpu.HostBuffer transientsBuffer,
    vm.Matrix4 modelTransform,
    vm.Matrix4 cameraTransform,
    vm.Vector3 cameraPosition,
  ) {
    if (_vertices == null) {
      throw Exception(
        'SetVertices must be called before GetBufferView for Geometry.',
      );
    }

    pass.bindVertexBuffer(_vertices!, _vertexCount);
    if (_indices != null) {
      pass.bindIndexBuffer(_indices!, _indexType, _indexCount);
    }

    // Unskinned vertex UBO - 直接写入预分配的缓冲区
    final floats = _frameInfoFloats;

    // Model transform (16 floats)
    floats[0] = modelTransform.storage[0];
    floats[1] = modelTransform.storage[1];
    floats[2] = modelTransform.storage[2];
    floats[3] = modelTransform.storage[3];
    floats[4] = modelTransform.storage[4];
    floats[5] = modelTransform.storage[5];
    floats[6] = modelTransform.storage[6];
    floats[7] = modelTransform.storage[7];
    floats[8] = modelTransform.storage[8];
    floats[9] = modelTransform.storage[9];
    floats[10] = modelTransform.storage[10];
    floats[11] = modelTransform.storage[11];
    floats[12] = modelTransform.storage[12];
    floats[13] = modelTransform.storage[13];
    floats[14] = modelTransform.storage[14];
    floats[15] = modelTransform.storage[15];

    // Camera transform (16 floats)
    floats[16] = cameraTransform.storage[0];
    floats[17] = cameraTransform.storage[1];
    floats[18] = cameraTransform.storage[2];
    floats[19] = cameraTransform.storage[3];
    floats[20] = cameraTransform.storage[4];
    floats[21] = cameraTransform.storage[5];
    floats[22] = cameraTransform.storage[6];
    floats[23] = cameraTransform.storage[7];
    floats[24] = cameraTransform.storage[8];
    floats[25] = cameraTransform.storage[9];
    floats[26] = cameraTransform.storage[10];
    floats[27] = cameraTransform.storage[11];
    floats[28] = cameraTransform.storage[12];
    floats[29] = cameraTransform.storage[13];
    floats[30] = cameraTransform.storage[14];
    floats[31] = cameraTransform.storage[15];

    // Camera position (3 floats)
    floats[32] = cameraPosition.x;
    floats[33] = cameraPosition.y;
    floats[34] = cameraPosition.z;

    final frameInfoSlot = vertexShader.getUniformSlot('FrameInfo');
    final frameInfoView = transientsBuffer.emplace(floats.buffer.asByteData());
    pass.bindUniform(frameInfoSlot, frameInfoView);
  }
}

class SkinnedGeometry extends Geometry {
  gpu.Texture? _jointsTexture;
  int _jointsTextureWidth = 0;

  /// 预分配的 UBO 缓冲区，避免每帧创建新数组
  /// Skinned: 16 (model) + 16 (camera) + 3 (cameraPos) + 2 (joints info) = 37 floats
  final Float32List _frameInfoFloats = Float32List(37);

  SkinnedGeometry() {
    setVertexShader(baseShaderLibrary['SkinnedVertex']!);
  }

  @override
  int get perVertexBytes => kSkinnedPerVertexSize;

  @override
  void setJointsTexture(gpu.Texture? texture, int width) {
    _jointsTexture = texture;
    _jointsTextureWidth = width;
  }

  @override
  void bind(
    gpu.RenderPass pass,
    gpu.HostBuffer transientsBuffer,
    vm.Matrix4 modelTransform,
    vm.Matrix4 cameraTransform,
    vm.Vector3 cameraPosition,
  ) {
    if (_jointsTexture == null) {
      throw Exception('Joints texture must be set for skinned geometry.');
    }

    pass.bindTexture(
      vertexShader.getUniformSlot('joints_texture'),
      _jointsTexture!,
      sampler: gpu.SamplerOptions(
        minFilter: gpu.MinMagFilter.nearest,
        magFilter: gpu.MinMagFilter.nearest,
        mipFilter: gpu.MipFilter.nearest,
        widthAddressMode: gpu.SamplerAddressMode.clampToEdge,
        heightAddressMode: gpu.SamplerAddressMode.clampToEdge,
      ),
    );

    if (_vertices == null) {
      throw Exception(
        'SetVertices must be called before GetBufferView for Geometry.',
      );
    }

    pass.bindVertexBuffer(_vertices!, _vertexCount);
    if (_indices != null) {
      pass.bindIndexBuffer(_indices!, _indexType, _indexCount);
    }

    // Skinned vertex UBO - 直接写入预分配的缓冲区
    final floats = _frameInfoFloats;

    // Model transform (16 floats)
    floats[0] = modelTransform.storage[0];
    floats[1] = modelTransform.storage[1];
    floats[2] = modelTransform.storage[2];
    floats[3] = modelTransform.storage[3];
    floats[4] = modelTransform.storage[4];
    floats[5] = modelTransform.storage[5];
    floats[6] = modelTransform.storage[6];
    floats[7] = modelTransform.storage[7];
    floats[8] = modelTransform.storage[8];
    floats[9] = modelTransform.storage[9];
    floats[10] = modelTransform.storage[10];
    floats[11] = modelTransform.storage[11];
    floats[12] = modelTransform.storage[12];
    floats[13] = modelTransform.storage[13];
    floats[14] = modelTransform.storage[14];
    floats[15] = modelTransform.storage[15];

    // Camera transform (16 floats)
    floats[16] = cameraTransform.storage[0];
    floats[17] = cameraTransform.storage[1];
    floats[18] = cameraTransform.storage[2];
    floats[19] = cameraTransform.storage[3];
    floats[20] = cameraTransform.storage[4];
    floats[21] = cameraTransform.storage[5];
    floats[22] = cameraTransform.storage[6];
    floats[23] = cameraTransform.storage[7];
    floats[24] = cameraTransform.storage[8];
    floats[25] = cameraTransform.storage[9];
    floats[26] = cameraTransform.storage[10];
    floats[27] = cameraTransform.storage[11];
    floats[28] = cameraTransform.storage[12];
    floats[29] = cameraTransform.storage[13];
    floats[30] = cameraTransform.storage[14];
    floats[31] = cameraTransform.storage[15];

    // Camera position (3 floats)
    floats[32] = cameraPosition.x;
    floats[33] = cameraPosition.y;
    floats[34] = cameraPosition.z;

    // Joints info (2 floats)
    floats[35] = _jointsTexture != null ? 1.0 : 0.0;
    floats[36] = _jointsTexture != null ? _jointsTextureWidth.toDouble() : 1.0;

    final frameInfoSlot = vertexShader.getUniformSlot('FrameInfo');
    final frameInfoView = transientsBuffer.emplace(floats.buffer.asByteData());
    pass.bindUniform(frameInfoSlot, frameInfoView);
  }
}

class CuboidGeometry extends UnskinnedGeometry {
  CuboidGeometry(vm.Vector3 extents) {
    final e = extents / 2;
    // Layout: Position, normal, uv, color
    final vertices = Float32List.fromList(<double>[
      -e.x, -e.y, -e.z, /* */ 0, 0, -1, /* */ 0, 0, /* */ 1, 0, 0, 1, //
      e.x, -e.y, -e.z, /*  */ 0, 0, -1, /* */ 1, 0, /* */ 0, 1, 0, 1, //
      e.x, e.y, -e.z, /*   */ 0, 0, -1, /* */ 1, 1, /* */ 0, 0, 1, 1, //
      -e.x, e.y, -e.z, /*  */ 0, 0, -1, /* */ 0, 1, /* */ 0, 0, 0, 1, //
      -e.x, -e.y, e.z, /*  */ 0, 0, -1, /* */ 0, 0, /* */ 0, 1, 1, 1, //
      e.x, -e.y, e.z, /*   */ 0, 0, -1, /* */ 1, 0, /* */ 1, 0, 1, 1, //
      e.x, e.y, e.z, /*    */ 0, 0, -1, /* */ 1, 1, /* */ 1, 1, 0, 1, //
      -e.x, e.y, e.z, /*   */ 0, 0, -1, /* */ 0, 1, /* */ 1, 1, 1, 1, //
    ]);

    final indices = Uint16List.fromList(<int>[
      0, 1, 3, 3, 1, 2, //
      1, 5, 2, 2, 5, 6, //
      5, 4, 6, 6, 4, 7, //
      4, 0, 7, 7, 0, 3, //
      3, 2, 7, 7, 2, 6, //
      4, 5, 0, 0, 5, 1, //
    ]);

    uploadVertexData(
      ByteData.sublistView(vertices),
      8,
      ByteData.sublistView(indices),
      indexType: gpu.IndexType.int16,
    );
  }
}
