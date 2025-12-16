import 'dart:ui' hide Scene;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' hide Matrix4;
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene_importer/flatbuffer.dart' as fb;
import 'package:vector_math/vector_math.dart';

// ============================================================================
// Isolate 解析用的简化类型定义（使用 typedef 和 Records 简化）
// ============================================================================

/// 纹理数据: (uri, embeddedBytes, width, height)
typedef _TextureData =
    ({String? uri, Uint8List? bytes, int? width, int? height});

/// 材质数据 Map（使用 Map 而非类，键名与属性对应）
typedef _MaterialData = Map<String, dynamic>;

/// 骨骼数据: (jointIndices, inverseBindMatricesStorage)
typedef _SkinData = ({List<int> joints, List<Float64List> matrices});

/// 网格图元数据
typedef _MeshData =
    ({
      Uint8List vertices,
      Uint8List indices,
      int vertexCount,
      int indexType,
      bool isSkinned,
      _MaterialData? material,
    });

/// 动画通道数据
typedef _ChannelData =
    ({
      int nodeIndex,
      int property,
      List<double> timeline,
      List<List<double>> values,
    });

/// 动画数据
typedef _AnimData = ({String name, List<_ChannelData> channels});

/// 节点数据
typedef _NodeData =
    ({
      String name,
      Float64List transform,
      List<int> children,
      List<_MeshData>? meshes,
      _SkinData? skin,
    });

/// 完整场景数据
typedef _SceneData =
    ({
      Float64List rootTransform,
      List<_TextureData> textures,
      List<_NodeData> nodes,
      List<int> rootChildren,
      List<_AnimData> animations,
    });

/// 在 Isolate 中执行 Flatbuffer 解析的顶层函数
_SceneData _parseFlatbufferInIsolate(Uint8List bytes) {
  final fbScene = fb.Scene(bytes);

  // 解析根节点变换
  final rootTransform = fbScene.transform?.toMatrix4() ?? Matrix4.identity();

  // 解析纹理数据（只提取信息，不创建 GPU 资源）
  final List<_TextureData> textures = [];
  for (fb.Texture fbTexture in fbScene.textures ?? []) {
    if (fbTexture.embeddedImage != null) {
      final image = fbTexture.embeddedImage!;
      textures.add((
        uri: null,
        bytes: Uint8List.fromList(image.bytes as List<int>),
        width: image.width,
        height: image.height,
      ));
    } else {
      textures.add((
        uri: fbTexture.uri,
        bytes: null,
        width: null,
        height: null,
      ));
    }
  }

  // 解析节点数据
  final List<_NodeData> nodes = [];
  for (fb.Node fbNode in fbScene.nodes ?? []) {
    final localTransform = fbNode.transform?.toMatrix4() ?? Matrix4.identity();

    // 解析网格图元
    List<_MeshData>? meshes;
    if (fbNode.meshPrimitives != null) {
      meshes = [];
      for (fb.MeshPrimitive fbPrimitive in fbNode.meshPrimitives!) {
        final isSkinned =
            fbPrimitive.vertices!.runtimeType == fb.SkinnedVertexBuffer;
        Uint8List vertices;
        switch (fbPrimitive.vertices!.runtimeType) {
          case const (fb.UnskinnedVertexBuffer):
            vertices = Uint8List.fromList(
              (fbPrimitive.vertices as fb.UnskinnedVertexBuffer).vertices
                  as List<int>,
            );
          case const (fb.SkinnedVertexBuffer):
            vertices = Uint8List.fromList(
              (fbPrimitive.vertices as fb.SkinnedVertexBuffer).vertices
                  as List<int>,
            );
          default:
            throw Exception('Unknown vertex buffer type');
        }

        final indices = Uint8List.fromList(
          fbPrimitive.indices!.data as List<int>,
        );
        final indexType =
            fbPrimitive.indices!.type == fb.IndexType.k16Bit ? 0 : 1;
        final perVertexBytes =
            isSkinned
                ? 80
                : 48; // kSkinnedPerVertexSize : kUnskinnedPerVertexSize
        final vertexCount = vertices.length ~/ perVertexBytes;

        // 解析材质为 Map
        _MaterialData? material;
        if (fbPrimitive.material != null) {
          final fbMat = fbPrimitive.material!;
          material = {
            'type': fbMat.type == fb.MaterialType.kUnlit ? 0 : 1,
            if (fbMat.baseColorFactor != null)
              'baseColorFactor': [
                fbMat.baseColorFactor!.r,
                fbMat.baseColorFactor!.g,
                fbMat.baseColorFactor!.b,
                fbMat.baseColorFactor!.a,
              ],
            if (fbMat.baseColorTexture >= 0)
              'baseColorTexture': fbMat.baseColorTexture,
            'metallicFactor': fbMat.metallicFactor,
            'roughnessFactor': fbMat.roughnessFactor,
            if (fbMat.metallicRoughnessTexture >= 0)
              'metallicRoughnessTexture': fbMat.metallicRoughnessTexture,
            if (fbMat.normalTexture >= 0) 'normalTexture': fbMat.normalTexture,
            'normalScale': fbMat.normalScale,
            if (fbMat.emissiveFactor != null)
              'emissiveFactor': [
                fbMat.emissiveFactor!.x,
                fbMat.emissiveFactor!.y,
                fbMat.emissiveFactor!.z,
              ],
            if (fbMat.emissiveTexture >= 0)
              'emissiveTexture': fbMat.emissiveTexture,
            'occlusionStrength': fbMat.occlusionStrength,
            if (fbMat.occlusionTexture >= 0)
              'occlusionTexture': fbMat.occlusionTexture,
          };
        }

        meshes.add((
          vertices: vertices,
          indices: indices,
          vertexCount: vertexCount,
          indexType: indexType,
          isSkinned: isSkinned,
          material: material,
        ));
      }
    }

    // 解析骨骼数据
    _SkinData? skin;
    if (fbNode.skin != null) {
      final fbSkin = fbNode.skin!;
      final inverseBindMatrices = <Float64List>[];
      for (int i = 0; i < (fbSkin.inverseBindMatrices?.length ?? 0); i++) {
        final matrix = fbSkin.inverseBindMatrices![i].toMatrix4();
        inverseBindMatrices.add(Float64List.fromList(matrix.storage));
      }
      skin = (
        joints: List<int>.from(fbSkin.joints ?? []),
        matrices: inverseBindMatrices,
      );
    }

    nodes.add((
      name: fbNode.name ?? '',
      transform: Float64List.fromList(localTransform.storage),
      children: List<int>.from(fbNode.children ?? []),
      meshes: meshes,
      skin: skin,
    ));
  }

  // 解析动画数据
  final List<_AnimData> animations = [];
  for (fb.Animation fbAnimation in fbScene.animations ?? []) {
    if (fbAnimation.channels == null) continue;

    final channels = <_ChannelData>[];
    for (fb.Channel fbChannel in fbAnimation.channels!) {
      if (fbChannel.timeline == null) continue;

      int property;
      List<List<double>> values = [];

      switch (fbChannel.keyframesType) {
        case fb.KeyframesTypeId.TranslationKeyframes:
          property = 0;
          final keyframes = fbChannel.keyframes as fb.TranslationKeyframes?;
          if (keyframes?.values != null) {
            for (final v in keyframes!.values!) {
              values.add([v.x, v.y, v.z]);
            }
          }
        case fb.KeyframesTypeId.RotationKeyframes:
          property = 1;
          final keyframes = fbChannel.keyframes as fb.RotationKeyframes?;
          if (keyframes?.values != null) {
            for (final v in keyframes!.values!) {
              values.add([v.x, v.y, v.z, v.w]);
            }
          }
        case fb.KeyframesTypeId.ScaleKeyframes:
          property = 2;
          final keyframes = fbChannel.keyframes as fb.ScaleKeyframes?;
          if (keyframes?.values != null) {
            for (final v in keyframes!.values!) {
              values.add([v.x, v.y, v.z]);
            }
          }
        default:
          continue;
      }

      channels.add((
        nodeIndex: fbChannel.node,
        property: property,
        timeline: List<double>.from(fbChannel.timeline!),
        values: values,
      ));
    }

    if (channels.isNotEmpty) {
      animations.add((name: fbAnimation.name ?? '', channels: channels));
    }
  }

  return (
    rootTransform: Float64List.fromList(rootTransform.storage),
    textures: textures,
    nodes: nodes,
    rootChildren: List<int>.from(fbScene.children ?? []),
    animations: animations,
  );
}

/// A `Node` represents a single element in a 3D scene graph.
///
/// Each node can contain a transform (position, rotation, scale), a mesh (3D geometry and material),
/// and child nodes. Nodes are used to build complex scenes by establishing relationships
/// between different elements, allowing for transformations to propagate down the hierarchy.
base class Node implements SceneGraph {
  Node({this.name = '', Matrix4? localTransform, this.mesh})
    : localTransform = localTransform ?? Matrix4.identity();

  /// The name of this node, used for identification.
  String name;

  /// Whether this node is visible in the scene. If false, the node and its children will not be rendered.
  bool visible = true;

  /// The transformation matrix representing the node's position, rotation, and scale relative to the parent node.
  ///
  /// If the node does not have a parent, `localTransform` and [globalTransform] share the same transformation matrix instance.
  Matrix4 localTransform = Matrix4.identity();

  Skin? _skin;

  set globalTransform(Matrix4 transform) {
    final parent = _parent;
    if (parent == null) {
      localTransform = transform;
    } else {
      Matrix4 g = Matrix4.identity();
      parent.globalTransform.copyInverse(g);

      localTransform = transform * parent.globalTransform.invert();
    }
  }

  /// The transformation matrix representing the node's position, rotation, and scale in world space.
  ///
  /// If the node does not have a parent, `globalTransform` and [localTransform] share the same transformation matrix instance.
  Matrix4 get globalTransform {
    final parent = _parent;
    if (parent == null) {
      return localTransform;
    }
    return parent.globalTransform * localTransform;
  }

  Node? _parent;

  /// The parent node of this node in the scene graph.
  Node? get parent => _parent;
  bool _isSceneRoot = false;

  /// The collection of [MeshPrimitive] objects that represent the 3D geometry and material properties of this node.
  ///
  /// This property is `null` if this node does not have any associated geometry or material.
  Mesh? mesh;

  /// The skin for skeletal animation.
  Skin? get skin => _skin;

  bool get globalVisible => visible && (_parent?.globalVisible ?? true);

  /// Whether this node is a joint in a skeleton for animation.
  bool isJoint = false;

  final List<Animation> _animations = [];

  /// The list of animations parsed when this node was deserialized.
  ///
  /// To instantiate an animation on a node, use [createAnimationClip].
  /// To search for an animation by name, use [findAnimationByName].
  List<Animation> get parsedAnimations => _animations;

  AnimationPlayer? _animationPlayer;

  /// Updates the animation player for this node.
  void updateAnimation() {
    _animationPlayer?.update();
  }

  // Future<bool> isVisibleInScene(Scene scene, Camera camera) async {
  //   try {
  //     Vector3 worldGet = globalTransform.getTranslation();
  //     Vector3 screenGet = worldGet.clone();
  //     screenGet.applyProjection(camera.getViewTransform(scene.screenSize));
  //     ByteData? byteData = await scene.depthImage!.toByteData(
  //       format: ImageByteFormat.rawExtendedRgba128,
  //     );
  //     if (byteData == null) {
  //       return false;
  //     }
  //     int depth =
  //         byteData!.getInt32(
  //           (screenGet.y * scene.screenSize.width).toInt() +
  //               screenGet.x.toInt(),
  //         ) >>
  //         8;
  //     if (screenGet.z > depth) {
  //       return false;
  //     }
  //     return true;
  //   } catch (e) {
  //     debugPrint("isVisibleInScene error:$e");
  //     return false;
  //   }
  // }

  Node? getChildByName(String name, {bool excludeAnimationPlayers = false}) {
    for (var child in children) {
      if (excludeAnimationPlayers && child._animationPlayer != null) {
        continue;
      }
      if (child.name == name) {
        return child;
      }
      var result = child.getChildByName(name);
      if (result != null) {
        return result;
      }
    }
    return null;
  }

  /// Searches for an [Animation] by name.
  ///
  /// Returns `null` if no animation with the specified name is found.
  ///
  /// To enumerate all animations on this node, use [parsedAnimations].
  /// Animations can be instantiated on a nodes using [createAnimationClip].
  Animation? findAnimationByName(String name) {
    return _animations.firstWhereOrNull((element) => element.name == name);
  }

  AnimationClip createAnimationClip(Animation animation) {
    _animationPlayer ??= AnimationPlayer();
    return _animationPlayer!.createAnimationClip(animation, this);
  }

  /// The asset file should be in a format that can be converted to a scene graph node.
  ///
  /// Flutter Scene uses a specialized 3D model format (`.model`) internally.
  /// You can convert standard glTF binaries (`.glb` files) to this format using [Flutter Scene's offline importer tool](https://pub.dev/packages/flutter_scene_importer).
  ///
  /// Example:
  /// ```dart
  /// final node = await Node.fromAsset('path/to/asset.model');
  /// ```
  static Future<Node> fromAsset(String assetPath) async {
    final buffer = await rootBundle.load(assetPath);
    return fromFlatbuffer(buffer);
  }

  /// Deserialize a model from Flutter Scene's compact model format.
  ///
  /// If you're using [Flutter Scene's offline importer tool](https://pub.dev/packages/flutter_scene_importer),
  /// consider using [fromAsset] to load the model directly from the asset bundle instead.
  ///
  /// This method uses `compute` to parse the Flatbuffer data in a separate isolate,
  /// which prevents blocking the main thread during large model loading.
  static Future<Node> fromFlatbuffer(ByteData byteData) async {
    // 将 ByteData 转换为 Uint8List 以便在 Isolate 中传输
    final bytes = byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );

    // 在 Isolate 中解析 Flatbuffer（CPU 密集型操作）
    final data = await compute(_parseFlatbufferInIsolate, bytes);

    debugPrint(
      'Unpacking Scene (nodes: ${data.nodes.length}, '
      'textures: ${data.textures.length})',
    );

    // 在主线程上创建 GPU 纹理（必须在主线程执行）
    List<gpu.Texture> gpuTextures = [];
    for (final tex in data.textures) {
      if (tex.bytes != null) {
        gpu.Texture texture = gpu.gpuContext.createTexture(
          gpu.StorageMode.hostVisible,
          tex.width!,
          tex.height!,
        );
        texture.overwrite(ByteData.sublistView(tex.bytes!));
        gpuTextures.add(texture);
      } else if (tex.uri != null) {
        try {
          gpuTextures.add(await gpuTextureFromAsset(tex.uri!));
        } catch (e) {
          debugPrint(
            'Failed to load texture from asset URI: ${tex.uri}. '
            'A white placeholder will be used instead. (Error: $e)',
          );
          gpuTextures.add(Material.getWhitePlaceholderTexture());
        }
      } else {
        debugPrint(
          'Texture ${gpuTextures.length} has no embedded image or URI. A white placeholder will be used instead.',
        );
        gpuTextures.add(Material.getWhitePlaceholderTexture());
      }
    }

    // 创建根节点
    Node result = Node(
      name: 'root',
      localTransform: Matrix4.fromList(data.rootTransform.toList()),
    );

    if (data.nodes.isEmpty) {
      return result; // The scene is empty. ¯\_(ツ)_/¯
    }

    // 初始化场景节点
    List<Node> sceneNodes = List.generate(data.nodes.length, (_) => Node());

    // 连接根节点的子节点
    for (int childIndex in data.rootChildren) {
      if (childIndex < 0 || childIndex >= sceneNodes.length) {
        throw Exception('Scene child index out of range.');
      }
      result.add(sceneNodes[childIndex]);
    }

    // 从解析后的数据构建节点
    for (int nodeIndex = 0; nodeIndex < data.nodes.length; nodeIndex++) {
      sceneNodes[nodeIndex]._unpackFromData(
        data.nodes[nodeIndex],
        sceneNodes,
        gpuTextures,
      );
    }

    // 构建动画
    for (final anim in data.animations) {
      result._animations.add(_buildAnimation(anim, sceneNodes));
    }

    return result;
  }

  /// 从解析后的数据构建动画
  static Animation _buildAnimation(_AnimData anim, List<Node> sceneNodes) {
    List<AnimationChannel> channels = [];
    for (final ch in anim.channels) {
      if (ch.nodeIndex < 0 || ch.nodeIndex >= sceneNodes.length) {
        continue;
      }

      AnimationProperty property;
      PropertyResolver resolver;

      switch (ch.property) {
        case 0: // translation
          property = AnimationProperty.translation;
          final values =
              ch.values.map((v) => Vector3(v[0], v[1], v[2])).toList();
          resolver = PropertyResolver.makeTranslationTimeline(
            ch.timeline,
            values,
          );
        case 1: // rotation
          property = AnimationProperty.rotation;
          final values =
              ch.values.map((v) => Quaternion(v[0], v[1], v[2], v[3])).toList();
          resolver = PropertyResolver.makeRotationTimeline(ch.timeline, values);
        case 2: // scale
          property = AnimationProperty.scale;
          final values =
              ch.values.map((v) => Vector3(v[0], v[1], v[2])).toList();
          resolver = PropertyResolver.makeScaleTimeline(ch.timeline, values);
        default:
          continue;
      }

      channels.add(
        AnimationChannel(
          bindTarget: BindKey(
            nodeName: sceneNodes[ch.nodeIndex].name,
            property: property,
          ),
          resolver: resolver,
        ),
      );
    }

    return Animation(name: anim.name, channels: channels);
  }

  /// 从预解析的数据构建节点（主线程）
  void _unpackFromData(
    _NodeData node,
    List<Node> sceneNodes,
    List<gpu.Texture> textures,
  ) {
    name = node.name;
    localTransform = Matrix4.fromList(node.transform.toList());

    // 从解析后的数据构建网格
    if (node.meshes != null) {
      List<MeshPrimitive> primitives = [];
      for (final m in node.meshes!) {
        Geometry geometry = _buildGeometry(m);
        Material material = _buildMaterial(m.material, textures);
        primitives.add(MeshPrimitive(geometry, material));
      }
      mesh = Mesh.primitives(primitives: primitives);
    }

    // 连接子节点
    for (int childIndex in node.children) {
      if (childIndex < 0 || childIndex >= sceneNodes.length) {
        throw Exception('Node child index out of range.');
      }
      add(sceneNodes[childIndex]);
    }

    // 构建骨骼
    if (node.skin != null) {
      _skin = _buildSkin(node.skin!, sceneNodes);
    }
  }

  /// 从解析后的数据构建 Geometry
  static Geometry _buildGeometry(_MeshData m) {
    Geometry geometry = m.isSkinned ? SkinnedGeometry() : UnskinnedGeometry();
    geometry.sourceIndices = m.indices;
    geometry.sourceVertices = m.vertices;

    geometry.uploadVertexData(
      ByteData.sublistView(m.vertices),
      m.vertexCount,
      ByteData.sublistView(m.indices),
      indexType: m.indexType == 0 ? gpu.IndexType.int16 : gpu.IndexType.int32,
    );
    final start = DateTime.now();
    geometry.buildBounds();
    final end = DateTime.now();
    debugPrint(
      'Build geometry ${m.vertexCount} bounds time: ${end.difference(start).inMilliseconds} ms',
    );
    return geometry;
  }

  /// 从解析后的数据构建 Material
  static Material _buildMaterial(
    _MaterialData? mat,
    List<gpu.Texture> textures,
  ) {
    if (mat == null) {
      return UnlitMaterial();
    }

    final type = mat['type'] as int? ?? 1;
    final baseColorFactor = mat['baseColorFactor'] as List<double>?;
    final baseColorTexture = mat['baseColorTexture'] as int?;

    if (type == 0) {
      // Unlit material
      final material = UnlitMaterial();
      if (baseColorFactor != null) {
        material.baseColorFactor = Vector4(
          baseColorFactor[0],
          baseColorFactor[1],
          baseColorFactor[2],
          baseColorFactor[3],
        );
      }
      if (baseColorTexture != null && baseColorTexture < textures.length) {
        material.baseColorTexture = textures[baseColorTexture];
      }
      return material;
    } else {
      // Physically based material
      final material = PhysicallyBasedMaterial();
      if (baseColorFactor != null) {
        material.baseColorFactor = Vector4(
          baseColorFactor[0],
          baseColorFactor[1],
          baseColorFactor[2],
          baseColorFactor[3],
        );
      }
      if (baseColorTexture != null && baseColorTexture < textures.length) {
        material.baseColorTexture = textures[baseColorTexture];
      }

      material.metallicFactor = (mat['metallicFactor'] as double?) ?? 0;
      material.roughnessFactor = (mat['roughnessFactor'] as double?) ?? 1.0;

      final metallicRoughnessTexture = mat['metallicRoughnessTexture'] as int?;
      if (metallicRoughnessTexture != null &&
          metallicRoughnessTexture < textures.length) {
        material.metallicRoughnessTexture = textures[metallicRoughnessTexture];
      }

      final normalTexture = mat['normalTexture'] as int?;
      if (normalTexture != null && normalTexture < textures.length) {
        material.normalTexture = textures[normalTexture];
      }
      material.normalScale = (mat['normalScale'] as double?) ?? 1.0;

      final emissiveFactor = mat['emissiveFactor'] as List<double>?;
      if (emissiveFactor != null) {
        material.emissiveFactor = Vector4(
          emissiveFactor[0],
          emissiveFactor[1],
          emissiveFactor[2],
          1.0,
        );
      }

      final emissiveTexture = mat['emissiveTexture'] as int?;
      if (emissiveTexture != null && emissiveTexture < textures.length) {
        material.emissiveTexture = textures[emissiveTexture];
      }

      material.occlusionStrength = (mat['occlusionStrength'] as double?) ?? 1.0;

      final occlusionTexture = mat['occlusionTexture'] as int?;
      if (occlusionTexture != null && occlusionTexture < textures.length) {
        material.occlusionTexture = textures[occlusionTexture];
      }
      return material;
    }
  }

  /// 从解析后的数据构建 Skin
  static Skin _buildSkin(_SkinData skin, List<Node> sceneNodes) {
    Skin result = Skin();
    for (int jointIndex in skin.joints) {
      if (jointIndex >= 0 && jointIndex < sceneNodes.length) {
        sceneNodes[jointIndex].isJoint = true;
        result.joints.add(sceneNodes[jointIndex]);
      }
    }
    for (final matrixStorage in skin.matrices) {
      result.inverseBindMatrices.add(Matrix4.fromList(matrixStorage.toList()));
    }
    return result;
  }

  /// This list allows the node to act as a parent in the scene graph hierarchy. Transformations
  /// applied to this node, such as translation, rotation, and scaling, will also affect all child nodes.
  final List<Node> children = [];

  /// Registers this node as the root node of the scene graph.
  ///
  /// Throws an exception if the node is already a root or has a parent.
  void registerAsRoot(Scene scene) {
    name = 'root';
    if (_isSceneRoot) {
      throw Exception('Node is already a root');
    }
    if (_parent != null) {
      throw Exception('Node already has a parent');
    }
    _isSceneRoot = true;
  }

  @override
  void add(Node child) {
    if (child._parent != null) {
      throw Exception('Child already has a parent');
    }
    children.add(child);
    child._parent = this;
  }

  @override
  void addAll(Iterable<Node> children) {
    for (var child in children) {
      add(child);
    }
  }

  @override
  void addMesh(Mesh mesh) {
    final node = Node(mesh: mesh);
    add(node);
  }

  @override
  void remove(Node child) {
    if (child._parent != this) {
      throw Exception('Child is not attached to this node');
    }
    children.remove(child);
    child._parent = null;
  }

  @override
  void removeAll() {
    while (children.isNotEmpty) {
      remove(children.last);
    }
  }

  /// Returns the name lookup path from the ancestor node to the child node.
  static Iterable<String>? getNamePath(Node ancestor, Node child) {
    List<String> result = [];
    Node? current = child;
    while (current != null) {
      if (identical(current, ancestor)) {
        return result.reversed;
      }
      result.add(current.name);
      current = current._parent;
    }

    debugPrint(
      'Name path formation failed because the given ancestor was not an ancestor of the given child.',
    );
    return null;
  }

  /// Returns the index lookup path from the ancestor node to the child node.
  static Iterable<int>? getIndexPath(Node ancestor, Node child) {
    List<int> result = [];
    Node? current = child;
    while (current != null) {
      if (identical(current, ancestor)) {
        return result.reversed;
      }
      if (current._parent == null) {
        break;
      }
      result.add(current._parent!.children.indexOf(current));
      current = current._parent;
    }

    debugPrint(
      'Index path formation failed because the given ancestor was not an ancestor of the given child.',
    );
    return null;
  }

  /// Returns the child node at the specified name path.
  Node? getChildByNamePath(Iterable<String> namePath) {
    Node? current = this;
    for (var name in namePath) {
      current = current!.getChildByName(name);
      if (current == null) {
        return null;
      }
    }
    return current;
  }

  /// Returns the child node at the specified index path.
  Node? getChildByIndexPath(Iterable<int> indexPath) {
    Node? current = this;
    for (var index in indexPath) {
      if (index < 0 || index >= current!.children.length) {
        return null;
      }
      current = current.children[index];
    }
    return current;
  }

  /// Returns the root node of the graph that this node is a part of.
  Node getRoot() {
    Node? current = this;
    while (current!._parent != null) {
      current = current._parent;
    }
    return current;
  }

  /// Returns the depth of this node in the scene graph hierarchy.
  /// The root node has a depth of 0.
  int getDepth() {
    int depth = 0;
    Node? current = this;
    while (current!._parent != null) {
      current = current._parent;
      depth++;
    }
    return depth;
  }

  /// Prints the hierarchy of this node and all its children to the console.
  void debugPrintHierarchy({int depth = 0}) {
    String indent = '  ' * depth;
    debugPrint('$indent$name');
    for (var child in children) {
      child.debugPrintHierarchy(depth: depth + 1);
    }
  }

  /// Creates a copy of this node.
  ///
  /// If [recursive] is `true`, the copy will include all child nodes.
  Node clone({bool recursive = true}) {
    // First, clone the node tree and collect any skins that need to be re-bound.
    List<Skin> clonedSkins = [];
    Node result = _cloneAndCollectSkins(recursive, clonedSkins);

    // Then, re-bind the skins to the cloned node tree.

    // Each of the clonedSkins currently have joint references in the old tree.
    for (var clonedSkin in clonedSkins) {
      for (
        int jointIndex = 0;
        jointIndex < clonedSkin.joints.length;
        jointIndex++
      ) {
        Node? joint = clonedSkin.joints[jointIndex];
        if (joint == null) {
          clonedSkin.joints[jointIndex] = null;
          continue;
        }

        Node? newJoint;

        // Get the index path from this node to the joint.
        Iterable<int>? nodeIndexPath = Node.getIndexPath(this, joint);
        if (nodeIndexPath != null) {
          // Then, replay the path on the cloned node tree to find the cloned
          // joint reference.
          newJoint = result.getChildByIndexPath(nodeIndexPath);
        }

        // Inline replace the joint reference with the cloned joint.
        // If the joint isn't found, a null placeholder is added.
        clonedSkin.joints[jointIndex] = newJoint;
      }
    }

    return result;
  }

  Node _cloneAndCollectSkins(bool recursive, List<Skin> clonedSkins) {
    Node result = Node(name: name, localTransform: localTransform, mesh: mesh);
    result.isJoint = isJoint;
    result._animations.addAll(_animations);
    if (recursive) {
      for (var child in children) {
        result.add(child._cloneAndCollectSkins(recursive, clonedSkins));
      }
    }

    if (_skin != null) {
      result._skin = Skin();
      for (Matrix4 inverseBindMatrix in _skin!.inverseBindMatrices) {
        result._skin!.inverseBindMatrices.add(Matrix4.copy(inverseBindMatrix));
      }
      // Initially copy all the original joints. All of these will be replaced
      // with the cloned joints in Node.clone().
      result._skin!.joints.addAll(_skin!.joints);
      clonedSkins.add(result._skin!);
    }

    return result;
  }

  /// Detaches this node from its parent in the scene graph.
  ///
  /// Once detached, this node is removed from its parent's list of children, effectively
  /// disconnecting this node and its subtree (all child nodes) from the scene graph.
  /// This operation is useful for temporarily removing nodes from the scene without deleting them.
  ///
  /// Throws an exception if this is the root node of the scene graph.
  /// No action is taken if the node already has no parent.
  void detach() {
    if (_isSceneRoot) {
      throw Exception('Root node cannot be detached');
    }
    final parent = _parent;
    if (parent != null) {
      parent.remove(this);
    }
  }

  /// Recursively records [Mesh] draw operations for this node and all its children.
  ///
  /// To display this node in a `dart:ui` [Canvas], add this node to a [Scene] and call [Scene.render] instead.
  void render(SceneEncoder encoder, Matrix4 parentWorldTransform) {
    if (!visible) {
      return;
    }

    if (_animationPlayer != null) {
      _animationPlayer!.update();
    }

    final worldTransform = parentWorldTransform * localTransform;
    if (mesh != null) {
      mesh!.render(
        encoder,
        worldTransform,
        _skin?.getJointsTexture(),
        _skin?.getTextureWidth() ?? 0,
      );
    }
    for (var child in children) {
      child.render(encoder, worldTransform);
    }
  }
}
