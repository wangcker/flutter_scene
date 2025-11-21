import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart';

import 'package:flutter_scene/src/camera.dart';
import 'package:flutter_scene/src/geometry/geometry.dart';
import 'package:flutter_scene/src/material/environment.dart';
import 'package:flutter_scene/src/material/material.dart';

base class _TranslucentRecord {
  _TranslucentRecord(this.worldTransform, this.geometry, this.material);
  final Matrix4 worldTransform;
  final Geometry geometry;
  final Material material;
}

base class SceneEncoder {
  SceneEncoder(
    gpu.RenderTarget renderTarget,
    this._camera,
    ui.Size dimensions,
    this._environment,
  ) {
    _cameraTransform = _camera.getViewTransform(dimensions);
    _commandBuffer = gpu.gpuContext.createCommandBuffer();
    _transientsBuffer = gpu.gpuContext.createHostBuffer();

    // Begin the opaque render pass.
    _renderPass = _commandBuffer.createRenderPass(renderTarget);
    _renderPass.setDepthWriteEnable(true);
    _renderPass.setColorBlendEnable(true);
    _renderPass.setDepthCompareOperation(gpu.CompareFunction.lessEqual);
  }

  final Camera _camera;
  final Environment _environment;
  late final Matrix4 _cameraTransform;
  late final gpu.CommandBuffer _commandBuffer;
  late final gpu.HostBuffer _transientsBuffer;
  late final gpu.RenderPass _renderPass;
  final List<_TranslucentRecord> _translucentRecords = [];
  final List<_TranslucentRecord> _highlightRecords = [];
  final List<_TranslucentRecord> _lastRenderRecords = [];

  void encode(Matrix4 worldTransform, Geometry geometry, Material material) {
    if (material.isOpaque()) {
      if (material.lastRender) {
        _lastRenderRecords.add(
          _TranslucentRecord(worldTransform, geometry, material),
        );
      } else if (!material.highlight) {
        _encode(worldTransform, geometry, material);
        return;
      } else {
        _highlightRecords.add(
          _TranslucentRecord(worldTransform, geometry, material),
        );
      }
    }

    _translucentRecords.add(
      _TranslucentRecord(worldTransform, geometry, material),
    );
  }

  void _encode(Matrix4 worldTransform, Geometry geometry, Material material) {
    _renderPass.clearBindings();
    var pipeline = gpu.gpuContext.createRenderPipeline(
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
    _translucentRecords.sort((a, b) {
      var aDistance = a.worldTransform.getTranslation().distanceTo(
        _camera.position,
      );
      var bDistance = b.worldTransform.getTranslation().distanceTo(
        _camera.position,
      );
      return bDistance.compareTo(aDistance);
    });
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
    _commandBuffer.submit();
    _transientsBuffer.reset();
  }
}
