import 'package:flutter_gpu/gpu.dart' as gpu;

/// 渲染管线缓存键
class _PipelineKey {
  _PipelineKey(this.vertexShaderName, this.fragmentShaderName);

  final String vertexShaderName;
  final String fragmentShaderName;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _PipelineKey &&
        other.vertexShaderName == vertexShaderName &&
        other.fragmentShaderName == fragmentShaderName;
  }

  @override
  int get hashCode => Object.hash(vertexShaderName, fragmentShaderName);
}

/// 渲染管线缓存
/// 避免每帧重复创建相同的渲染管线
class PipelineCache {
  PipelineCache._();

  static final PipelineCache _instance = PipelineCache._();
  static PipelineCache get instance => _instance;

  final Map<_PipelineKey, gpu.RenderPipeline> _cache = {};

  /// 统计信息
  int _cacheHits = 0;
  int _cacheMisses = 0;

  int get cacheHits => _cacheHits;
  int get cacheMisses => _cacheMisses;
  int get cacheSize => _cache.length;

  /// 获取或创建渲染管线
  gpu.RenderPipeline getOrCreate(
    gpu.Shader vertexShader,
    gpu.Shader fragmentShader,
  ) {
    // 使用 shader 名称作为 key（假设名称唯一）
    // 如果 shader 没有名称，使用 hashCode
    final key = _PipelineKey(
      vertexShader.hashCode.toString(),
      fragmentShader.hashCode.toString(),
    );

    final cached = _cache[key];
    if (cached != null) {
      _cacheHits++;
      return cached;
    }

    _cacheMisses++;
    final pipeline = gpu.gpuContext.createRenderPipeline(
      vertexShader,
      fragmentShader,
    );
    _cache[key] = pipeline;
    return pipeline;
  }

  /// 清空缓存
  void clear() {
    _cache.clear();
    _cacheHits = 0;
    _cacheMisses = 0;
  }

  /// 重置统计信息
  void resetStats() {
    _cacheHits = 0;
    _cacheMisses = 0;
  }
}
