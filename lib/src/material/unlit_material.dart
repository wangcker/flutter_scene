import 'dart:typed_data';

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/material/environment.dart';
import 'package:flutter_scene/src/material/material.dart';
import 'package:flutter_scene/src/shaders.dart';

import 'package:flutter_scene_importer/flatbuffer.dart' as fb;
import 'package:vector_math/vector_math.dart';

class UnlitMaterial extends Material {
  static UnlitMaterial fromFlatbuffer(
    fb.Material fbMaterial,
    List<gpu.Texture> textures,
  ) {
    if (fbMaterial.type != fb.MaterialType.kUnlit) {
      throw Exception('Cannot unpack unlit material from non-unlit material');
    }

    UnlitMaterial material = UnlitMaterial();

    if (fbMaterial.baseColorFactor != null) {
      material.baseColorFactor = Vector4(
        fbMaterial.baseColorFactor!.r,
        fbMaterial.baseColorFactor!.g,
        fbMaterial.baseColorFactor!.b,
        fbMaterial.baseColorFactor!.a,
      );
    }

    if (fbMaterial.baseColorTexture >= 0 &&
        fbMaterial.baseColorTexture < textures.length) {
      material.baseColorTexture = textures[fbMaterial.baseColorTexture];
    }

    return material;
  }

  UnlitMaterial({gpu.Texture? colorTexture}) {
    setFragmentShader(baseShaderLibrary['UnlitFragment']!);
    baseColorTexture = Material.whitePlaceholder(colorTexture);
  }

  /// 预分配的 UBO 缓冲区，避免每帧创建新数组
  final Float32List _fragInfoFloats = Float32List(5);

  late gpu.Texture baseColorTexture;
  Vector4 baseColorFactor = Colors.white;
  double vertexColorWeight = 1.0;

  @override
  void bind(
    gpu.RenderPass pass,
    gpu.HostBuffer transientsBuffer,
    Environment environment,
  ) {
    super.bind(pass, transientsBuffer, environment);

    // 直接写入预分配的缓冲区，避免每帧创建新数组
    final fragInfo = _fragInfoFloats;
    fragInfo[0] = baseColorFactor.r;
    fragInfo[1] = baseColorFactor.g;
    fragInfo[2] = baseColorFactor.b;
    fragInfo[3] = baseColorFactor.a;
    fragInfo[4] = vertexColorWeight;

    pass.bindUniform(
      fragmentShader.getUniformSlot("FragInfo"),
      transientsBuffer.emplace(fragInfo.buffer.asByteData()),
    );
    pass.bindTexture(
      fragmentShader.getUniformSlot('base_color_texture'),
      baseColorTexture,
      sampler: gpu.SamplerOptions(
        widthAddressMode: gpu.SamplerAddressMode.repeat,
        heightAddressMode: gpu.SamplerAddressMode.repeat,
      ),
    );
  }
}
