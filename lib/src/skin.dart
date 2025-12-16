import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/src/node.dart';
import 'package:vector_math/vector_math.dart';
import 'package:flutter_scene_importer/flatbuffer.dart' as fb;
import 'package:flutter_gpu/gpu.dart' as gpu;

int _getNextPowerOfTwoSize(int x) {
  if (x == 0) {
    return 1;
  }

  --x;

  x |= x >> 1;
  x |= x >> 2;
  x |= x >> 4;
  x |= x >> 8;
  x |= x >> 16;

  return x + 1;
}

base class Skin {
  final List<Node?> joints = [];
  final List<Matrix4> inverseBindMatrices = [];

  /// 缓存的 GPU 纹理
  gpu.Texture? _cachedTexture;
  int _cachedTextureSize = 0;

  /// 缓存的 Float32List，避免每帧分配
  Float32List? _jointMatrixFloats;

  /// 复用的临时 Matrix4，避免每次计算时分配
  final Matrix4 _tempMatrix = Matrix4.identity();
  final Matrix4 _resultMatrix = Matrix4.identity();

  static Skin fromFlatbuffer(fb.Skin skin, List<Node> sceneNodes) {
    if (skin.joints == null ||
        skin.inverseBindMatrices == null ||
        skin.joints!.length != skin.inverseBindMatrices!.length) {
      throw Exception('Skin data is missing joints or bind matrices.');
    }

    Skin result = Skin();
    for (int jointIndex in skin.joints!) {
      if (jointIndex < 0 || jointIndex > sceneNodes.length) {
        throw Exception('Skin join index out of range');
      }
      sceneNodes[jointIndex].isJoint = true;
      result.joints.add(sceneNodes[jointIndex]);
    }

    for (
      int matrixIndex = 0;
      matrixIndex < skin.inverseBindMatrices!.length;
      matrixIndex++
    ) {
      final matrix = skin.inverseBindMatrices![matrixIndex].toMatrix4();

      result.inverseBindMatrices.add(matrix);
    }

    return result;
  }

  gpu.Texture getJointsTexture() {
    // Each joint has a matrix. 1 matrix = 16 floats. 1 pixel = 4 floats.
    // Therefore, each joint needs 4 pixels.
    int requiredPixels = joints.length * 4;
    int dimensionSize = max(
      2,
      _getNextPowerOfTwoSize(sqrt(requiredPixels).ceil()),
    );

    // 如果纹理不存在或尺寸变化，重新创建
    if (_cachedTexture == null || _cachedTextureSize != dimensionSize) {
      _cachedTexture = gpu.gpuContext.createTexture(
        gpu.StorageMode.hostVisible,
        dimensionSize,
        dimensionSize,
        format: gpu.PixelFormat.r32g32b32a32Float,
      );
      _cachedTextureSize = dimensionSize;
      // 同时重新分配 Float32List
      _jointMatrixFloats = Float32List(dimensionSize * dimensionSize * 4);
    }

    final jointMatrixFloats = _jointMatrixFloats!;

    // Initialize with identity matrices.
    for (int i = 0; i < jointMatrixFloats.length; i += 16) {
      jointMatrixFloats[i] = 1.0;
      jointMatrixFloats[i + 1] = 0.0;
      jointMatrixFloats[i + 2] = 0.0;
      jointMatrixFloats[i + 3] = 0.0;
      jointMatrixFloats[i + 4] = 0.0;
      jointMatrixFloats[i + 5] = 1.0;
      jointMatrixFloats[i + 6] = 0.0;
      jointMatrixFloats[i + 7] = 0.0;
      jointMatrixFloats[i + 8] = 0.0;
      jointMatrixFloats[i + 9] = 0.0;
      jointMatrixFloats[i + 10] = 1.0;
      jointMatrixFloats[i + 11] = 0.0;
      jointMatrixFloats[i + 12] = 0.0;
      jointMatrixFloats[i + 13] = 0.0;
      jointMatrixFloats[i + 14] = 0.0;
      jointMatrixFloats[i + 15] = 1.0;
    }

    for (int jointIndex = 0; jointIndex < joints.length; jointIndex++) {
      Node? joint = joints[jointIndex];

      // Compute a model space matrix for the joint by walking up the bones to the
      // skeleton root.
      final floatOffset = jointIndex * 16;
      while (joint != null && joint.isJoint) {
        // 从 float 数组直接读取到复用的临时 Matrix4，避免创建新对象
        _tempMatrix.storage[0] = jointMatrixFloats[floatOffset];
        _tempMatrix.storage[1] = jointMatrixFloats[floatOffset + 1];
        _tempMatrix.storage[2] = jointMatrixFloats[floatOffset + 2];
        _tempMatrix.storage[3] = jointMatrixFloats[floatOffset + 3];
        _tempMatrix.storage[4] = jointMatrixFloats[floatOffset + 4];
        _tempMatrix.storage[5] = jointMatrixFloats[floatOffset + 5];
        _tempMatrix.storage[6] = jointMatrixFloats[floatOffset + 6];
        _tempMatrix.storage[7] = jointMatrixFloats[floatOffset + 7];
        _tempMatrix.storage[8] = jointMatrixFloats[floatOffset + 8];
        _tempMatrix.storage[9] = jointMatrixFloats[floatOffset + 9];
        _tempMatrix.storage[10] = jointMatrixFloats[floatOffset + 10];
        _tempMatrix.storage[11] = jointMatrixFloats[floatOffset + 11];
        _tempMatrix.storage[12] = jointMatrixFloats[floatOffset + 12];
        _tempMatrix.storage[13] = jointMatrixFloats[floatOffset + 13];
        _tempMatrix.storage[14] = jointMatrixFloats[floatOffset + 14];
        _tempMatrix.storage[15] = jointMatrixFloats[floatOffset + 15];

        // 直接相乘到结果矩阵
        _resultMatrix.setFrom(joint.localTransform);
        _resultMatrix.multiply(_tempMatrix);

        // 写回到 float 数组
        jointMatrixFloats[floatOffset] = _resultMatrix.storage[0];
        jointMatrixFloats[floatOffset + 1] = _resultMatrix.storage[1];
        jointMatrixFloats[floatOffset + 2] = _resultMatrix.storage[2];
        jointMatrixFloats[floatOffset + 3] = _resultMatrix.storage[3];
        jointMatrixFloats[floatOffset + 4] = _resultMatrix.storage[4];
        jointMatrixFloats[floatOffset + 5] = _resultMatrix.storage[5];
        jointMatrixFloats[floatOffset + 6] = _resultMatrix.storage[6];
        jointMatrixFloats[floatOffset + 7] = _resultMatrix.storage[7];
        jointMatrixFloats[floatOffset + 8] = _resultMatrix.storage[8];
        jointMatrixFloats[floatOffset + 9] = _resultMatrix.storage[9];
        jointMatrixFloats[floatOffset + 10] = _resultMatrix.storage[10];
        jointMatrixFloats[floatOffset + 11] = _resultMatrix.storage[11];
        jointMatrixFloats[floatOffset + 12] = _resultMatrix.storage[12];
        jointMatrixFloats[floatOffset + 13] = _resultMatrix.storage[13];
        jointMatrixFloats[floatOffset + 14] = _resultMatrix.storage[14];
        jointMatrixFloats[floatOffset + 15] = _resultMatrix.storage[15];

        joint = joint.parent;
      }

      // Get the joint transform relative to the default pose of the bone by
      // incorporating the joint's inverse bind matrix.
      // 从 float 数组读取当前矩阵
      _tempMatrix.storage[0] = jointMatrixFloats[floatOffset];
      _tempMatrix.storage[1] = jointMatrixFloats[floatOffset + 1];
      _tempMatrix.storage[2] = jointMatrixFloats[floatOffset + 2];
      _tempMatrix.storage[3] = jointMatrixFloats[floatOffset + 3];
      _tempMatrix.storage[4] = jointMatrixFloats[floatOffset + 4];
      _tempMatrix.storage[5] = jointMatrixFloats[floatOffset + 5];
      _tempMatrix.storage[6] = jointMatrixFloats[floatOffset + 6];
      _tempMatrix.storage[7] = jointMatrixFloats[floatOffset + 7];
      _tempMatrix.storage[8] = jointMatrixFloats[floatOffset + 8];
      _tempMatrix.storage[9] = jointMatrixFloats[floatOffset + 9];
      _tempMatrix.storage[10] = jointMatrixFloats[floatOffset + 10];
      _tempMatrix.storage[11] = jointMatrixFloats[floatOffset + 11];
      _tempMatrix.storage[12] = jointMatrixFloats[floatOffset + 12];
      _tempMatrix.storage[13] = jointMatrixFloats[floatOffset + 13];
      _tempMatrix.storage[14] = jointMatrixFloats[floatOffset + 14];
      _tempMatrix.storage[15] = jointMatrixFloats[floatOffset + 15];

      // 乘以逆绑定矩阵
      _tempMatrix.multiply(inverseBindMatrices[jointIndex]);

      // 写回结果
      jointMatrixFloats[floatOffset] = _tempMatrix.storage[0];
      jointMatrixFloats[floatOffset + 1] = _tempMatrix.storage[1];
      jointMatrixFloats[floatOffset + 2] = _tempMatrix.storage[2];
      jointMatrixFloats[floatOffset + 3] = _tempMatrix.storage[3];
      jointMatrixFloats[floatOffset + 4] = _tempMatrix.storage[4];
      jointMatrixFloats[floatOffset + 5] = _tempMatrix.storage[5];
      jointMatrixFloats[floatOffset + 6] = _tempMatrix.storage[6];
      jointMatrixFloats[floatOffset + 7] = _tempMatrix.storage[7];
      jointMatrixFloats[floatOffset + 8] = _tempMatrix.storage[8];
      jointMatrixFloats[floatOffset + 9] = _tempMatrix.storage[9];
      jointMatrixFloats[floatOffset + 10] = _tempMatrix.storage[10];
      jointMatrixFloats[floatOffset + 11] = _tempMatrix.storage[11];
      jointMatrixFloats[floatOffset + 12] = _tempMatrix.storage[12];
      jointMatrixFloats[floatOffset + 13] = _tempMatrix.storage[13];
      jointMatrixFloats[floatOffset + 14] = _tempMatrix.storage[14];
      jointMatrixFloats[floatOffset + 15] = _tempMatrix.storage[15];
    }

    // 只更新数据，不重新创建纹理
    _cachedTexture!.overwrite(jointMatrixFloats.buffer.asByteData());
    return _cachedTexture!;
  }

  int getTextureWidth() {
    return _getNextPowerOfTwoSize(sqrt(joints.length * 4).ceil());
  }

  /// 释放缓存的资源
  void dispose() {
    _cachedTexture = null;
    _jointMatrixFloats = null;
  }
}
