import 'package:vector_math/vector_math.dart';

import '../node.dart';

/// BVH 节点
class BvhNode<T> {
  BvhNode({required this.bounds, this.data, this.left, this.right});

  /// 节点的包围盒
  final Aabb3 bounds;

  /// 叶子节点存储的数据
  final T? data;

  /// 左子节点
  final BvhNode<T>? left;

  /// 右子节点
  final BvhNode<T>? right;

  /// 是否是叶子节点
  bool get isLeaf => left == null && right == null;
}

/// 用于构建 BVH 的项
class BvhItem<T> {
  BvhItem(this.bounds, this.data);

  final Aabb3 bounds;
  final T data;

  /// 包围盒中心点
  Vector3 get center => bounds.center;
}

/// Bounding Volume Hierarchy (层次包围盒)
/// 用于加速空间查询和剔除
class Bvh<T> {
  Bvh._(this.root);

  final BvhNode<T>? root;

  /// 从项列表构建 BVH
  factory Bvh.build(List<BvhItem<T>> items) {
    if (items.isEmpty) {
      return Bvh._(null);
    }

    final root = _buildRecursive(items, 0);
    return Bvh._(root);
  }

  /// 递归构建 BVH
  static BvhNode<T> _buildRecursive<T>(List<BvhItem<T>> items, int depth) {
    if (items.length == 1) {
      // 叶子节点
      return BvhNode(bounds: items[0].bounds, data: items[0].data);
    }

    // 计算所有项的总包围盒
    final totalBounds = Aabb3.copy(items[0].bounds);
    for (int i = 1; i < items.length; i++) {
      totalBounds.hull(items[i].bounds);
    }

    if (items.length == 2) {
      // 两个项直接创建内部节点
      return BvhNode(
        bounds: totalBounds,
        left: BvhNode(bounds: items[0].bounds, data: items[0].data),
        right: BvhNode(bounds: items[1].bounds, data: items[1].data),
      );
    }

    // 选择最长的轴进行分割
    final extent = totalBounds.max - totalBounds.min;
    int axis;
    if (extent.x >= extent.y && extent.x >= extent.z) {
      axis = 0; // X轴
    } else if (extent.y >= extent.z) {
      axis = 1; // Y轴
    } else {
      axis = 2; // Z轴
    }

    // 按选定轴的中心点排序
    items.sort((a, b) {
      double aValue, bValue;
      switch (axis) {
        case 0:
          aValue = a.center.x;
          bValue = b.center.x;
        case 1:
          aValue = a.center.y;
          bValue = b.center.y;
        default:
          aValue = a.center.z;
          bValue = b.center.z;
      }
      return aValue.compareTo(bValue);
    });

    // 从中间分割
    final mid = items.length ~/ 2;
    final leftItems = items.sublist(0, mid);
    final rightItems = items.sublist(mid);

    return BvhNode(
      bounds: totalBounds,
      left: _buildRecursive(leftItems, depth + 1),
      right: _buildRecursive(rightItems, depth + 1),
    );
  }

  /// 查询与视锥体相交的所有项
  /// 使用 vector_math 的 Frustum 类
  List<T> queryFrustum(Frustum frustum) {
    final results = <T>[];
    if (root != null) {
      _queryFrustumRecursive(root!, frustum, results);
    }
    return results;
  }

  void _queryFrustumRecursive(
    BvhNode<T> node,
    Frustum frustum,
    List<T> results,
  ) {
    // 首先测试节点的包围盒
    // vector_math 的 Frustum.intersectsWithAabb3 返回 true 表示相交
    if (!frustum.intersectsWithAabb3(node.bounds)) {
      return; // 完全在视锥体外，跳过整个子树
    }
    if (node.data is Node && !(node.data as Node).globalVisible) {
      return; // 数据不可见，跳过
    }

    if (node.isLeaf) {
      // 叶子节点，添加数据
      if (node.data != null) {
        results.add(node.data as T);
      }
    } else {
      // 内部节点，递归查询子节点
      if (node.left != null) {
        _queryFrustumRecursive(node.left!, frustum, results);
      }
      if (node.right != null) {
        _queryFrustumRecursive(node.right!, frustum, results);
      }
    }
  }

  /// 查询与包围盒相交的所有项
  /// 使用 vector_math 的 Aabb3 类
  List<T> queryAabb(Aabb3 queryBounds) {
    final results = <T>[];
    if (root != null) {
      _queryAabbRecursive(root!, queryBounds, results);
    }
    return results;
  }

  void _queryAabbRecursive(
    BvhNode<T> node,
    Aabb3 queryBounds,
    List<T> results,
  ) {
    // 使用 vector_math 的 Aabb3.intersectsWithAabb3 检查包围盒是否相交
    if (!node.bounds.intersectsWithAabb3(queryBounds)) {
      return;
    }

    if (node.isLeaf) {
      if (node.data != null) {
        results.add(node.data as T);
      }
    } else {
      if (node.left != null) {
        _queryAabbRecursive(node.left!, queryBounds, results);
      }
      if (node.right != null) {
        _queryAabbRecursive(node.right!, queryBounds, results);
      }
    }
  }

  /// 射线查询 - 返回与射线相交的最近项
  /// 使用 vector_math 的 Ray 类
  T? raycast(Ray ray, {double maxDistance = double.infinity}) {
    if (root == null) return null;

    T? closestHit;
    double closestDistance = maxDistance;

    _raycastRecursive(root!, ray, (item, distance) {
      if (distance < closestDistance) {
        closestDistance = distance;
        closestHit = item;
      }
    });

    return closestHit;
  }

  void _raycastRecursive(
    BvhNode<T> node,
    Ray ray,
    void Function(T item, double distance) onHit,
  ) {
    // 使用 vector_math 的 Ray.intersectsWithAabb3 检查射线是否与节点的包围盒相交
    final hitDistance = ray.intersectsWithAabb3(node.bounds);
    if (hitDistance == null) {
      return;
    }

    if (node.isLeaf) {
      if (node.data != null) {
        onHit(node.data as T, hitDistance);
      }
    } else {
      // 递归检查子节点
      if (node.left != null) {
        _raycastRecursive(node.left!, ray, onHit);
      }
      if (node.right != null) {
        _raycastRecursive(node.right!, ray, onHit);
      }
    }
  }
}

/// 遮挡查询结果
class OcclusionResult {
  OcclusionResult({
    required this.visibleCount,
    required this.occludedCount,
    required this.totalCount,
  });

  final int visibleCount;
  final int occludedCount;
  final int totalCount;

  double get visibilityRatio =>
      totalCount > 0 ? visibleCount / totalCount : 1.0;
}
