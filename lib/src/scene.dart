import 'dart:developer';
import 'dart:ui' as ui;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'camera.dart';
import 'culling/bvh.dart';
import 'material/environment.dart';
import 'material/material.dart';
import 'mesh.dart';
import 'node.dart';
import 'scene_encoder.dart';
import 'surface.dart';
import 'package:vector_math/vector_math.dart';

/// Defines a common interface for managing a scene graph, allowing the addition and removal of [Nodes].
///
/// `SceneGraph` provides a set of methods that can be implemented by a class
/// to manage a hierarchy of nodes within a 3D scene.
mixin SceneGraph {
  /// Add a child node.
  void add(Node child);

  /// Add a list of child nodes.
  void addAll(Iterable<Node> children);

  /// Add a mesh as a child node.
  void addMesh(Mesh mesh);

  /// Remove a child node.
  void remove(Node child);

  /// Remove all children nodes.
  void removeAll();
}

enum AntiAliasingMode { none, msaa }

/// Represents a 3D scene, which is a collection of nodes that can be rendered onto the screen.
///
/// `Scene` manages the scene graph and handles rendering operations.
/// It contains a root [Node] that serves as the entry point for all nodes in this `Scene`, and
/// it provides methods for adding and removing nodes from the scene graph.
base class Scene implements SceneGraph {
  Scene({AntiAliasingMode antiAliasingMode = AntiAliasingMode.msaa}) {
    initializeStaticResources();
    root.registerAsRoot(this);
    this.antiAliasingMode = antiAliasingMode;
  }

  static Future<void>? _initializeStaticResources;
  static bool _readyToRender = false;

  AntiAliasingMode _antiAliasingMode = AntiAliasingMode.none;
  //Image? depthImage;
  PerspectiveCamera? camera;
  Size screenSize = Size.zero;

  /// BVH 空间加速结构，用于快速空间查询
  Bvh<Node>? _bvh;

  /// BVH 是否需要重建
  bool _bvhDirty = true;

  /// 标记 BVH 需要重建
  void invalidateBvh() {
    _bvhDirty = true;
  }

  void buildBvh() {
    _rebuildBvh();
  }

  /// 获取或重建 BVH
  Bvh<Node> get bvh {
    if (_bvhDirty || _bvh == null) {
      _rebuildBvh();
    }
    return _bvh!;
  }

  /// 重建 BVH
  void _rebuildBvh() {
    final items = <BvhItem<Node>>[];
    _collectBvhItems(root, Matrix4.identity(), items);
    _bvh = Bvh.build(items);
    _bvhDirty = false;
  }

  /// 递归收集所有有包围盒的节点
  void _collectBvhItems(
    Node node,
    Matrix4 parentTransform,
    List<BvhItem<Node>> items,
  ) {
    //if (!node.visible) return;

    final worldTransform = parentTransform * node.localTransform;

    // 如果节点有 mesh，计算其世界空间包围盒
    if (node.mesh != null) {
      final bounds = _computeMeshBounds(node.mesh!);
      if (bounds != null) {
        // 变换包围盒到世界空间
        final worldBounds = bounds.transformed(worldTransform, Aabb3());
        items.add(BvhItem(worldBounds, node));
      }
    }

    // 递归处理子节点
    for (final child in node.children) {
      _collectBvhItems(child, worldTransform, items);
    }
  }

  /// 计算 Mesh 的局部包围盒
  Aabb3? _computeMeshBounds(Mesh mesh) {
    if (mesh.primitives.isEmpty) return null;

    Aabb3? bounds;
    for (final primitive in mesh.primitives) {
      final geoBounds = _computeGeometryBounds(primitive.geometry);
      if (geoBounds != null) {
        if (bounds == null) {
          bounds = Aabb3.copy(geoBounds);
        } else {
          bounds.hull(geoBounds);
        }
      }
    }
    return bounds;
  }

  /// 计算 Geometry 的包围盒（从顶点数据）
  Aabb3? _computeGeometryBounds(dynamic geometry) {
    return geometry.bounds;
  }

  /// 使用视锥体查询可见节点（已过滤 visible=false 的节点）
  List<Node> queryVisibleNodes(Frustum frustum) {
    final nodes = bvh.queryFrustum(frustum);
    return nodes.toList();
  }

  /// 使用包围盒查询节点
  List<Node> queryNodesInBounds(Aabb3 bounds) {
    return bvh.queryAabb(bounds);
  }

  /// 射线拾取 - 返回射线击中的最近节点
  Node? raycast(Ray ray, {double maxDistance = double.infinity}) {
    return bvh.raycast(ray, maxDistance: maxDistance);
  }

  /// 从屏幕坐标进行射线拾取
  Node? raycastFromScreen(
    Offset screenPosition,
    Camera camera,
    Size viewportSize,
  ) {
    final ray = camera.screenPointToRay(screenPosition, viewportSize);
    return raycast(ray);
  }

  set antiAliasingMode(AntiAliasingMode value) {
    switch (value) {
      case AntiAliasingMode.none:
        break;
      case AntiAliasingMode.msaa:
        if (!gpu.gpuContext.doesSupportOffscreenMSAA) {
          debugPrint("MSAA is not currently supported on this backend.");
          return;
        }
        break;
    }

    _antiAliasingMode = value;
  }

  AntiAliasingMode get antiAliasingMode {
    return _antiAliasingMode;
  }

  /// Prepares the rendering resources, such as textures and shaders,
  /// that are used to display models in this [Scene].
  ///
  /// This method ensures all necessary resources are loaded and ready to be used in the rendering pipeline.
  /// If the initialization fails, the resources are reset, and the scene
  /// will not be marked as ready to render.
  ///
  /// Returns a [Future] that completes when the initialization is finished.
  static Future<void> initializeStaticResources() {
    if (_initializeStaticResources != null) {
      return _initializeStaticResources!;
    }
    _initializeStaticResources = Material.initializeStaticResources()
        .onError((e, stacktrace) {
          log(
            'Failed to initialize static Flutter Scene resources',
            error: e,
            stackTrace: stacktrace,
          );
          _initializeStaticResources = null;
        })
        .then((_) {
          _readyToRender = true;
        });
    return _initializeStaticResources!;
  }

  /// The root [Node] of the scene graph.
  ///
  /// All [Node] objects in the scene are connected to this node, either directly or indirectly.
  /// Transformations applied to this [Node] affect all child [Node] objects.
  final Node root = Node();

  /// Handles the creation and management of render targets for this [Scene].
  final Surface surface = Surface();

  /// Manages the lighting for this [Scene].
  final Environment environment = Environment();

  @override
  void add(Node child) {
    root.add(child);
    invalidateBvh();
  }

  @override
  void addAll(Iterable<Node> children) {
    root.addAll(children);
    invalidateBvh();
  }

  @override
  void addMesh(Mesh mesh) {
    final node = Node(mesh: mesh);
    add(node);
  }

  @override
  void remove(Node child) {
    root.remove(child);
    invalidateBvh();
  }

  @override
  void removeAll() {
    root.removeAll();
    invalidateBvh();
  }

  /// Renders the current state of this [Scene] onto the given [ui.Canvas] using the specified [Camera].
  ///
  /// The [Camera] provides the perspective from which the scene is viewed, and the [ui.Canvas]
  /// is the drawing surface onto which this [Scene] will be rendered.
  ///
  /// Optionally, a [ui.Rect] can be provided to define a viewport, limiting the rendering area on the canvas.
  /// If no [ui.Rect] is specified, the entire canvas will be rendered.
  ///
  /// Set [useFrustumCulling] to true to enable BVH-based frustum culling (default: true).
  void render(
    Camera camera,
    ui.Canvas canvas, {
    ui.Rect? viewport,
    bool useFrustumCulling = true,
  }) {
    if (!_readyToRender) {
      debugPrint('Flutter Scene is not ready to render. Skipping frame.');
      debugPrint(
        'You may wait on the Future returned by Scene.initializeStaticResources() before rendering.',
      );
      return;
    }

    final drawArea = viewport ?? canvas.getLocalClipBounds();
    if (drawArea.isEmpty) {
      return;
    }
    final enableMsaa = _antiAliasingMode == AntiAliasingMode.msaa;
    final gpu.RenderTarget renderTarget = surface.getNextRenderTarget(
      drawArea.size,
      enableMsaa,
    );

    final env =
        environment.environmentMap.isEmpty()
            ? environment.withNewEnvironmentMap(
              Material.getDefaultEnvironmentMap(),
            )
            : environment;

    final encoder = SceneEncoder(renderTarget, camera, drawArea.size, env);

    if (useFrustumCulling && bvh.root != null) {
      // 使用 BVH 视锥剔除，只渲染可见节点
      final visibleNodes = queryVisibleNodes(encoder.frustum);
      _lastVisibleCount = visibleNodes.length;
      _lastTotalCount = _countTotalNodes();

      if (visibleNodes.isEmpty && _lastTotalCount > 0) {
        // 如果没有可见节点但有总节点，可能是 BVH 或视锥有问题
        // 回退到传统渲染
        debugPrint(
          'Warning: BVH frustum culling returned 0 visible nodes out of $_lastTotalCount. '
          'Falling back to traditional rendering.',
        );
        root.render(encoder, Matrix4.identity());
      } else {
        for (final node in visibleNodes) {
          // 计算节点的世界变换
          final worldTransform = _computeWorldTransform(node);
          _renderNodeOnly(node, encoder, worldTransform);
        }
      }
    } else {
      // 传统方式：渲染所有节点
      _lastVisibleCount = 0;
      _lastTotalCount = 0;
      root.render(encoder, Matrix4.identity());
    }

    encoder.finish();

    final gpu.Texture texture =
        enableMsaa
            ? renderTarget.colorAttachments[0].resolveTexture!
            : renderTarget.colorAttachments[0].texture;
    final image = texture.asImage();
    canvas.drawImage(image, drawArea.topLeft, ui.Paint());
  }

  /// 剔除统计：上一帧可见节点数
  int _lastVisibleCount = 0;
  int get lastVisibleCount => _lastVisibleCount;

  /// 剔除统计：上一帧总节点数
  int _lastTotalCount = 0;
  int get lastTotalCount => _lastTotalCount;

  /// 计算节点的世界变换矩阵
  Matrix4 _computeWorldTransform(Node node) {
    // 直接使用节点的 globalTransform，它已经计算好了从根到节点的变换
    return node.globalTransform;
  }

  /// 只渲染单个节点（不递归子节点，因为 BVH 已经展平）
  void _renderNodeOnly(
    Node node,
    SceneEncoder encoder,
    Matrix4 worldTransform,
  ) {
    if (!node.visible) return;

    // 更新动画
    node.updateAnimation();

    // 渲染 mesh
    if (node.mesh != null) {
      node.mesh!.render(
        encoder,
        worldTransform,
        node.skin?.getJointsTexture(),
        node.skin?.getTextureWidth() ?? 0,
      );
    }
  }

  /// 统计总节点数
  int _countTotalNodes() {
    int count = 0;
    _countNodesRecursive(root, (node) {
      if (node.mesh != null) count++;
    });
    return count;
  }

  void _countNodesRecursive(Node node, void Function(Node) callback) {
    callback(node);
    for (final child in node.children) {
      _countNodesRecursive(child, callback);
    }
  }
}
