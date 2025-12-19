import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart';

import 'package:flutter_scene/src/camera.dart';

import 'package:flutter_scene/src/geometry/geometry.dart';
import 'package:flutter_scene/src/material/environment.dart';
import 'package:flutter_scene/src/material/material.dart';
import 'package:flutter_scene/src/pipeline_cache.dart';

/// 可复用的透明物体记录
base class _TranslucentRecord {
  /// 存储变换矩阵的副本，避免引用问题
  final Matrix4 worldTransform = Matrix4.identity();
  late Geometry geometry;
  late Material material;

  /// 用于排序的距离平方（避免每次比较都计算平方根）
  double distanceSquared = 0.0;

  void set(Matrix4 transform, Geometry geo, Material mat) {
    worldTransform.setFrom(transform);
    geometry = geo;
    material = mat;
  }
}

/// 对象池，用于复用 _TranslucentRecord 对象
class _RecordPool {
  final List<_TranslucentRecord> _pool = [];
  int _activeCount = 0;

  _TranslucentRecord acquire(
    Matrix4 worldTransform,
    Geometry geometry,
    Material material,
  ) {
    _TranslucentRecord record;
    if (_activeCount < _pool.length) {
      record = _pool[_activeCount];
    } else {
      record = _TranslucentRecord();
      _pool.add(record);
    }
    _activeCount++;
    record.set(worldTransform, geometry, material);
    return record;
  }

  void reset() {
    _activeCount = 0;
  }

  int get length => _activeCount;
}

/// 可复用的渲染资源
class _ReusableRenderResources {
  static _ReusableRenderResources? _instance;
  static _ReusableRenderResources get instance {
    _instance ??= _ReusableRenderResources._();
    return _instance!;
  }

  _ReusableRenderResources._();

  /// 可复用的 HostBuffer
  gpu.HostBuffer? _transientsBuffer;

  gpu.HostBuffer get transientsBuffer {
    _transientsBuffer ??= gpu.gpuContext.createHostBuffer();
    return _transientsBuffer!;
  }

  /// 对象池，避免每帧创建新对象
  final _RecordPool translucentPool = _RecordPool();
  final _RecordPool highlightPool = _RecordPool();
  final _RecordPool lastRenderPool = _RecordPool();

  void reset() {
    _transientsBuffer?.reset();
    translucentPool.reset();
    highlightPool.reset();
    lastRenderPool.reset();
  }
}

base class SceneEncoder {
  SceneEncoder(
    gpu.RenderTarget renderTarget,
    this._camera,
    ui.Size dimensions,
    this._environment,
  ) {
    _cameraTransform = _camera.getViewTransform(dimensions);
    _frustum = Frustum.matrix(_cameraTransform);
    _commandBuffer = gpu.gpuContext.createCommandBuffer();

    // Begin the opaque render pass.
    _renderPass = _commandBuffer.createRenderPass(renderTarget);
    _renderPass.setDepthWriteEnable(true);
    _renderPass.setColorBlendEnable(true);
    _renderPass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
  }

  final Camera _camera;
  final Environment _environment;
  late final Matrix4 _cameraTransform;
  late final Frustum _frustum;
  late final gpu.CommandBuffer _commandBuffer;
  late final gpu.RenderPass _renderPass;

  /// 使用共享的可复用资源
  _ReusableRenderResources get _resources => _ReusableRenderResources.instance;
  gpu.HostBuffer get _transientsBuffer => _resources.transientsBuffer;

  final List<_TranslucentRecord> _translucentRecords = [];
  final List<_TranslucentRecord> _highlightRecords = [];
  final List<_TranslucentRecord> _lastRenderRecords = [];

  /// 剔除统计
  int _culledCount = 0;
  int _renderedCount = 0;

  int get culledCount => _culledCount;
  int get renderedCount => _renderedCount;

  /// 获取视锥体用于外部剔除检测
  Frustum get frustum => _frustum;

  /// 带包围盒的编码方法，支持视锥剔除
  void encodeWithBounds(
    Matrix4 worldTransform,
    Geometry geometry,
    Material material,
    Aabb3? bounds,
  ) {
    // 视锥剔除
    if (bounds != null) {
      final worldBounds = bounds.transformed(worldTransform, Aabb3());
      if (!_frustum.intersectsWithAabb3(worldBounds)) {
        _culledCount++;
        return;
      }
    }

    encode(worldTransform, geometry, material);
  }

  void encode(Matrix4 worldTransform, Geometry geometry, Material material) {
    _renderedCount++;
    if (material.isOpaque()) {
      if (material.lastRender) {
        _lastRenderRecords.add(
          _resources.lastRenderPool.acquire(worldTransform, geometry, material),
        );
      } else if (!material.highlight) {
        _encode(worldTransform, geometry, material);
        return;
      } else {
        _highlightRecords.add(
          _resources.highlightPool.acquire(worldTransform, geometry, material),
        );
      }
    }

    _translucentRecords.add(
      _resources.translucentPool.acquire(worldTransform, geometry, material),
    );
  }

  void _encode(Matrix4 worldTransform, Geometry geometry, Material material) {
    _renderPass.clearBindings();
    // 使用管线缓存，避免每帧重建管线
    var pipeline = PipelineCache.instance.getOrCreate(
      geometry.vertexShader,
      material.fragmentShader,
    );
    _renderPass.bindPipeline(pipeline);

    geometry.bind(
      _renderPass,
      _transientsBuffer,
      worldTransform,
      _cameraTransform,
      _camera.position,
    );
    material.bind(_renderPass, _transientsBuffer, _environment);
    _renderPass.draw();
  }

  void finish() {
    // 使用距离平方进行排序，避免平方根计算
    final cameraPos = _camera.position;
    for (var record in _translucentRecords) {
      final translation = record.worldTransform.getTranslation();
      final dx = translation.x - cameraPos.x;
      final dy = translation.y - cameraPos.y;
      final dz = translation.z - cameraPos.z;
      record.distanceSquared = dx * dx + dy * dy + dz * dz;
    }
    _translucentRecords.sort(
      (a, b) => b.distanceSquared.compareTo(a.distanceSquared),
    );

    _renderPass.setDepthWriteEnable(false);
    _renderPass.setColorBlendEnable(true);
    // Additive source-over blending.
    // Note: Expects premultiplied alpha output from the fragment stage!
    _renderPass.setColorBlendEquation(
      gpu.ColorBlendEquation(
        colorBlendOperation: gpu.BlendOperation.add,
        sourceColorBlendFactor: gpu.BlendFactor.sourceAlpha,
        destinationColorBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
        alphaBlendOperation: gpu.BlendOperation.add,
        sourceAlphaBlendFactor: gpu.BlendFactor.one,
        destinationAlphaBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
      ),
    );
    for (var record in _translucentRecords) {
      _encode(record.worldTransform, record.geometry, record.material);
    }
    _renderPass.setDepthWriteEnable(false);
    _renderPass.setDepthCompareOperation(gpu.CompareFunction.greater);
    _renderPass.setColorBlendEquation(
      gpu.ColorBlendEquation(
        colorBlendOperation: gpu.BlendOperation.add,
        sourceColorBlendFactor: gpu.BlendFactor.one,
        destinationColorBlendFactor: gpu.BlendFactor.one,
        alphaBlendOperation: gpu.BlendOperation.add,
        sourceAlphaBlendFactor: gpu.BlendFactor.one,
        destinationAlphaBlendFactor: gpu.BlendFactor.one,
      ),
    );
    for (var record in _highlightRecords) {
      _encode(record.worldTransform, record.geometry, record.material);
    }
    _renderPass.setDepthWriteEnable(false);
    _renderPass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
    _renderPass.setColorBlendEquation(
      gpu.ColorBlendEquation(
        colorBlendOperation: gpu.BlendOperation.add,
        sourceColorBlendFactor: gpu.BlendFactor.sourceAlpha,
        destinationColorBlendFactor: gpu.BlendFactor.oneMinusSourceAlpha,
        alphaBlendOperation: gpu.BlendOperation.add,
        sourceAlphaBlendFactor: gpu.BlendFactor.zero,
        destinationAlphaBlendFactor: gpu.BlendFactor.one,
      ),
    );
    for (var record in _lastRenderRecords) {
      _encode(record.worldTransform, record.geometry, record.material);
    }

    _lastRenderRecords.clear();
    _highlightRecords.clear();
    _translucentRecords.clear();

    // 重置共享资源
    _resources.reset();

    _commandBuffer.submit();
  }
}
