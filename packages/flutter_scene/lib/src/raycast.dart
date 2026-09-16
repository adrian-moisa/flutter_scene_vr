/// Scene raycasting against render geometry.
///
/// Tests the actual rendered meshes (no colliders or physics setup), with
/// hit attributes interpolated from the vertex data, so a hit carries the
/// surface UV at the intersection. Used directly for picking and selection,
/// and by the widget-surface input layer to map pointer rays onto widget
/// textures.
///
/// Distinct from the physics queries (`PhysicsWorld.raycast`), which test
/// collision shapes: this answers "what visible surface did the ray touch",
/// physics answers "what does the collision world say".
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_scene/src/components/mesh_component.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_scene/src/importer/constants.dart';
import 'package:flutter_scene/src/mesh.dart';
import 'package:flutter_scene/src/node.dart';
import 'package:vector_math/vector_math.dart';

/// A render-geometry intersection from [raycastNode] (or `Scene.raycast`).
/// {@category Picking and input}
class SceneRaycastHit {
  /// Creates a hit record.
  SceneRaycastHit({
    required this.node,
    required this.distance,
    required this.worldPoint,
    required this.worldNormal,
    required this.uv,
    required this.barycentrics,
    required this.triangleIndex,
    required this.primitiveIndex,
  });

  /// The node whose mesh was hit.
  final Node node;

  /// Distance from the ray origin to [worldPoint], measured along the
  /// normalized ray direction.
  final double distance;

  /// The intersection point, world space.
  final Vector3 worldPoint;

  /// The geometric (triangle face) normal at the hit, world space, unit
  /// length, oriented to face the ray origin.
  final Vector3 worldNormal;

  /// The interpolated texture coordinate at the hit, or null when the mesh
  /// carries no UV data (never a silent zero).
  final Vector2? uv;

  /// Barycentric weights of the hit inside its triangle, ordered to match
  /// the triangle's vertex order.
  final Vector3 barycentrics;

  /// The index of the hit triangle within its primitive's index/vertex
  /// stream.
  final int triangleIndex;

  /// The index of the hit [MeshPrimitive] within the node's mesh.
  final int primitiveIndex;
}

/// Casts [ray] (direction need not be normalized) through [root]'s subtree
/// and returns the nearest hit, or null.
///
/// Only visible nodes participate unless [includeInvisible] is set, and a
/// primitive with `MeshPrimitive.visible` false is likewise skipped unless
/// [includeInvisible] is set. Nodes must intersect [layerMask] (against
/// [Node.layers]), have [Node.raycastable] set, and pass [where] when
/// provided. Skinned meshes are tested at rest pose. Geometry with
/// caller-managed vertex buffers (`setVertices`) or non-triangle topology is
/// skipped.
/// {@category Picking and input}
// TODO(raycast): test InstancedMesh components (one local-space test per
// instance transform).
// Dense meshes use a geometry-owned triangle BVH after the node-bounds
// early-out. The cache follows the retained CPU buffers by identity, so a
// replacement upload rebuilds it while repeated pointer rays reuse it.
SceneRaycastHit? raycastNode(
  Node root,
  Ray ray, {
  double maxDistance = double.infinity,
  int layerMask = 0xFFFFFFFF,
  bool Function(Node node)? where,
  bool includeInvisible = false,
}) {
  SceneRaycastHit? nearest;
  _walk(root, ray, maxDistance, layerMask, where, includeInvisible, true, (
    hit,
  ) {
    if (nearest == null || hit.distance < nearest!.distance) nearest = hit;
  });
  return nearest;
}

/// Casts [ray] through [root]'s subtree and returns every hit, sorted
/// nearest-first. Parameters as in [raycastNode].
/// {@category Picking and input}
List<SceneRaycastHit> raycastNodeAll(
  Node root,
  Ray ray, {
  double maxDistance = double.infinity,
  int layerMask = 0xFFFFFFFF,
  bool Function(Node node)? where,
  bool includeInvisible = false,
}) {
  final hits = <SceneRaycastHit>[];
  _walk(root, ray, maxDistance, layerMask, where, includeInvisible, true, (
    hit,
  ) {
    hits.add(hit);
  });
  hits.sort((a, b) => a.distance.compareTo(b.distance));
  return hits;
}

void _walk(
  Node node,
  Ray ray,
  double maxDistance,
  int layerMask,
  bool Function(Node)? where,
  bool includeInvisible,
  bool parentVisible,
  void Function(SceneRaycastHit) emit,
) {
  final visible = parentVisible && node.visible;
  if (!visible && !includeInvisible) return;

  if ((visible || includeInvisible) &&
      node.raycastable &&
      (node.layers & layerMask) != 0 &&
      (where == null || where(node))) {
    for (final component in node.getComponents<MeshComponent>()) {
      _testNodeMesh(
        node,
        component.mesh.primitives,
        ray,
        maxDistance,
        includeInvisible,
        emit,
      );
    }
  }
  for (final child in node.children) {
    _walk(
      child,
      ray,
      maxDistance,
      layerMask,
      where,
      includeInvisible,
      visible,
      emit,
    );
  }
}

void _testNodeMesh(
  Node node,
  List<MeshPrimitive> primitives,
  Ray ray,
  double maxDistance,
  bool includeInvisible,
  void Function(SceneRaycastHit) emit,
) {
  final worldTransform = node.globalTransform;
  final toLocal = Matrix4.zero();
  if (toLocal.copyInverse(worldTransform) == 0.0) return;

  // Transform the ray into node-local space by mapping a point pair, so the
  // direction picks up the transform's full linear part (including
  // non-uniform scale). The local direction is intentionally NOT
  // re-normalized: parameter t along the local ray then equals world-space
  // distance along the normalized world direction.
  final worldDirection = ray.direction.normalized();
  final localOrigin = toLocal.transform3(ray.origin.clone());
  final localTip = toLocal.transform3(ray.origin + worldDirection);
  final localRay = Ray.originDirection(localOrigin, localTip - localOrigin);

  for (var p = 0; p < primitives.length; p++) {
    final primitive = primitives[p];
    if (!primitive.visible && !includeInvisible) continue;
    final geometry = primitive.geometry;
    if (geometry.primitiveType != gpu.PrimitiveType.triangle) continue;
    final data = geometry.cpuMeshData;
    if (data.vertexCount == 0) continue;

    // De-interleaved geometry exposes structure-of-arrays attributes;
    // interleaved geometry exposes a single packed buffer. Either is
    // raycastable; a custom interleaved layout (unexpected stride) is not.
    final positions = data.positions;
    final vertices = data.vertices;
    int? stride;
    if (positions == null) {
      if (vertices == null) continue;
      stride = vertices.lengthInBytes ~/ data.vertexCount;
      if (stride != kUnskinnedPerVertexSize &&
          stride != kSkinnedPerVertexSize) {
        continue; // custom layout; not raycastable
      }
    }

    // Node-local bounds early-out.
    final bounds = geometry.localBounds;
    if (bounds != null && !_rayIntersectsAabb(localRay, bounds, maxDistance)) {
      continue;
    }

    _testTriangles(
      cacheOwner: geometry,
      cacheVersion: geometry.raycastDataVersion,
      node: node,
      primitiveIndex: p,
      vertices: vertices,
      stride: stride,
      positions: positions,
      texCoords: data.texCoords,
      indices: data.indices,
      indexType: data.indexType,
      indexCount: data.indexCount,
      vertexCount: data.vertexCount,
      localRay: localRay,
      worldTransform: worldTransform,
      worldOrigin: ray.origin,
      worldDirection: worldDirection,
      maxDistance: maxDistance,
      emit: emit,
    );
  }
}

// Byte offsets within the engine vertex layout (see importer/constants.dart):
// position is the first three floats and tex_coords floats 6..7 in both the
// unskinned and skinned layouts.
const int _positionOffset = 0;
const int _texCoordOffset = 6 * 4;

/// One local-space triangle intersection from [intersectPackedTriangles].
typedef PackedTriangleHit = ({
  double t,
  Vector3 barycentrics,
  int triangleIndex,
  Vector2 uv,
  Vector3 localNormal,
});

const int _triangleBvhThreshold = 64;
const int _triangleBvhLeafSize = 8;

final Expando<_TriangleBvhCacheEntry> _triangleBvhCache =
    Expando<_TriangleBvhCacheEntry>('flutter_scene_triangle_bvh');

class _TriangleBvhCacheEntry {
  _TriangleBvhCacheEntry({
    required this.vertices,
    required this.positions,
    required this.indices,
    required this.stride,
    required this.indexType,
    required this.indexCount,
    required this.vertexCount,
    required this.version,
    required this.bvh,
  });

  final ByteData? vertices;
  final Float32List? positions;
  final ByteData? indices;
  final int? stride;
  final gpu.IndexType indexType;
  final int indexCount;
  final int vertexCount;
  final int version;
  final _TriangleBvh bvh;

  bool matches({
    required ByteData? vertices,
    required Float32List? positions,
    required ByteData? indices,
    required int? stride,
    required gpu.IndexType indexType,
    required int indexCount,
    required int vertexCount,
    required int version,
  }) =>
      identical(this.vertices, vertices) &&
      identical(this.positions, positions) &&
      identical(this.indices, indices) &&
      this.stride == stride &&
      this.indexType == indexType &&
      this.indexCount == indexCount &&
      this.vertexCount == vertexCount &&
      this.version == version;
}

/// A compact, immutable local-space hierarchy over one triangle stream.
///
/// Triangles are Morton-sorted once, then stored in leaves of eight. Bounds
/// use doubles so acceleration never makes a valid edge hit disappear through
/// float rounding. The root is the last node because children are emitted
/// first.
class _TriangleBvh {
  _TriangleBvh._(
    this._bounds,
    this._children,
    this._triangles,
    this._nodeCount,
  );

  factory _TriangleBvh.build({
    required int triangleCount,
    required int Function(int indexOffset) vertexIndex,
    required double Function(int vertexIndex, int axis) coordinate,
  }) {
    final centroids = Float64List(triangleCount * 3);
    var minimumCentroidX = double.infinity;
    var minimumCentroidY = double.infinity;
    var minimumCentroidZ = double.infinity;
    var maximumCentroidX = double.negativeInfinity;
    var maximumCentroidY = double.negativeInfinity;
    var maximumCentroidZ = double.negativeInfinity;

    double safeCoordinate(int vertex, int axis) {
      final value = coordinate(vertex, axis);
      // Invalid triangles cannot produce a meaningful intersection. Keeping
      // their BVH bounds finite lets valid neighbors remain pickable instead
      // of letting one malformed coordinate poison the whole cache build.
      return value.isFinite ? value : 0;
    }

    for (var triangle = 0; triangle < triangleCount; triangle++) {
      final indexOffset = triangle * 3;
      final first = vertexIndex(indexOffset);
      final second = vertexIndex(indexOffset + 1);
      final third = vertexIndex(indexOffset + 2);
      final centroidOffset = triangle * 3;

      for (var axis = 0; axis < 3; axis++) {
        final centroid =
            (safeCoordinate(first, axis) +
                safeCoordinate(second, axis) +
                safeCoordinate(third, axis)) /
            3;
        centroids[centroidOffset + axis] = centroid;
      }

      final centroidX = centroids[centroidOffset];
      final centroidY = centroids[centroidOffset + 1];
      final centroidZ = centroids[centroidOffset + 2];
      if (centroidX < minimumCentroidX) minimumCentroidX = centroidX;
      if (centroidY < minimumCentroidY) minimumCentroidY = centroidY;
      if (centroidZ < minimumCentroidZ) minimumCentroidZ = centroidZ;
      if (centroidX > maximumCentroidX) maximumCentroidX = centroidX;
      if (centroidY > maximumCentroidY) maximumCentroidY = centroidY;
      if (centroidZ > maximumCentroidZ) maximumCentroidZ = centroidZ;
    }

    final spanX = maximumCentroidX - minimumCentroidX;
    final spanY = maximumCentroidY - minimumCentroidY;
    final spanZ = maximumCentroidZ - minimumCentroidZ;
    final scaleX = spanX > 0 ? 1023 / spanX : 0.0;
    final scaleY = spanY > 0 ? 1023 / spanY : 0.0;
    final scaleZ = spanZ > 0 ? 1023 / spanZ : 0.0;
    final keys = Uint32List(triangleCount);

    for (var triangle = 0; triangle < triangleCount; triangle++) {
      final centroidOffset = triangle * 3;
      final quantizedX =
          ((centroids[centroidOffset] - minimumCentroidX) * scaleX).toInt();
      final quantizedY =
          ((centroids[centroidOffset + 1] - minimumCentroidY) * scaleY).toInt();
      final quantizedZ =
          ((centroids[centroidOffset + 2] - minimumCentroidZ) * scaleZ).toInt();
      keys[triangle] =
          _spreadBits(quantizedX) |
          (_spreadBits(quantizedY) << 1) |
          (_spreadBits(quantizedZ) << 2);
    }

    var order = Uint32List(triangleCount);
    var scratch = Uint32List(triangleCount);
    for (var triangle = 0; triangle < triangleCount; triangle++) {
      order[triangle] = triangle;
    }

    final histogram = Uint32List(1024);
    for (var shift = 0; shift < 30; shift += 10) {
      histogram.fillRange(0, histogram.length, 0);
      for (var index = 0; index < triangleCount; index++) {
        histogram[(keys[order[index]] >> shift) & 1023]++;
      }
      var sum = 0;
      for (var bucket = 0; bucket < histogram.length; bucket++) {
        final count = histogram[bucket];
        histogram[bucket] = sum;
        sum += count;
      }
      for (var index = 0; index < triangleCount; index++) {
        final triangle = order[index];
        scratch[histogram[(keys[triangle] >> shift) & 1023]++] = triangle;
      }
      final swap = order;
      order = scratch;
      scratch = swap;
    }

    int nodeCountForTriangleRange(int count) {
      if (count <= _triangleBvhLeafSize) return 1;

      final leftCount = count ~/ 2;
      return 1 +
          nodeCountForTriangleRange(leftCount) +
          nodeCountForTriangleRange(count - leftCount);
    }

    // emitNode halves each range until both children fit the leaf limit. For
    // uneven triangle counts that can produce more leaves than ceil(count /
    // leafSize), so sizing from that quotient under-allocates the typed arrays
    // and makes dense-mesh picking throw while the hierarchy is being built.
    final nodeCapacity = nodeCountForTriangleRange(triangleCount);
    final bounds = Float64List(nodeCapacity * 6);
    final children = Int32List(nodeCapacity * 2);
    var nodeCount = 0;

    int emitNode(int start, int end) {
      if (end - start <= _triangleBvhLeafSize) {
        final node = nodeCount++;
        var minimumX = double.infinity;
        var minimumY = double.infinity;
        var minimumZ = double.infinity;
        var maximumX = double.negativeInfinity;
        var maximumY = double.negativeInfinity;
        var maximumZ = double.negativeInfinity;

        for (var orderedIndex = start; orderedIndex < end; orderedIndex++) {
          final triangle = order[orderedIndex];
          final indexOffset = triangle * 3;
          for (var corner = 0; corner < 3; corner++) {
            final vertex = vertexIndex(indexOffset + corner);
            final x = safeCoordinate(vertex, 0);
            final y = safeCoordinate(vertex, 1);
            final z = safeCoordinate(vertex, 2);
            if (x < minimumX) minimumX = x;
            if (y < minimumY) minimumY = y;
            if (z < minimumZ) minimumZ = z;
            if (x > maximumX) maximumX = x;
            if (y > maximumY) maximumY = y;
            if (z > maximumZ) maximumZ = z;
          }
        }

        final boundsOffset = node * 6;
        bounds[boundsOffset] = minimumX;
        bounds[boundsOffset + 1] = minimumY;
        bounds[boundsOffset + 2] = minimumZ;
        bounds[boundsOffset + 3] = maximumX;
        bounds[boundsOffset + 4] = maximumY;
        bounds[boundsOffset + 5] = maximumZ;
        children[node * 2] = ~start;
        children[node * 2 + 1] = end - start;
        return node;
      }

      final middle = (start + end) >> 1;
      final left = emitNode(start, middle);
      final right = emitNode(middle, end);
      final node = nodeCount++;
      final boundsOffset = node * 6;
      final leftBoundsOffset = left * 6;
      final rightBoundsOffset = right * 6;
      for (var axis = 0; axis < 3; axis++) {
        final leftMinimum = bounds[leftBoundsOffset + axis];
        final rightMinimum = bounds[rightBoundsOffset + axis];
        final leftMaximum = bounds[leftBoundsOffset + 3 + axis];
        final rightMaximum = bounds[rightBoundsOffset + 3 + axis];
        bounds[boundsOffset + axis] = leftMinimum < rightMinimum
            ? leftMinimum
            : rightMinimum;
        bounds[boundsOffset + 3 + axis] = leftMaximum > rightMaximum
            ? leftMaximum
            : rightMaximum;
      }
      children[node * 2] = left;
      children[node * 2 + 1] = right;
      return node;
    }

    emitNode(0, triangleCount);
    return _TriangleBvh._(bounds, children, order, nodeCount);
  }

  final Float64List _bounds;
  final Int32List _children;
  final Uint32List _triangles;
  final int _nodeCount;
  final Int32List _stack = Int32List(64);

  void visitRay(
    Ray ray,
    double maxDistance,
    void Function(int triangleIndex) visit,
  ) {
    if (_nodeCount == 0) return;
    final origin = ray.origin;
    final direction = ray.direction;
    var stackTop = 0;
    _stack[stackTop++] = _nodeCount - 1;

    while (stackTop > 0) {
      final node = _stack[--stackTop];
      if (!_rayIntersectsBounds(
        origin,
        direction,
        _bounds,
        node * 6,
        maxDistance,
      )) {
        continue;
      }

      final left = _children[node * 2];
      if (left < 0) {
        final start = ~left;
        final count = _children[node * 2 + 1];
        for (var index = start; index < start + count; index++) {
          visit(_triangles[index]);
        }
        continue;
      }

      _stack[stackTop++] = left;
      _stack[stackTop++] = _children[node * 2 + 1];
    }
  }

  static bool _rayIntersectsBounds(
    Vector3 origin,
    Vector3 direction,
    Float64List bounds,
    int boundsOffset,
    double maxDistance,
  ) {
    var near = 0.0;
    var far = maxDistance;
    for (var axis = 0; axis < 3; axis++) {
      final axisOrigin = origin[axis];
      final axisDirection = direction[axis];
      final minimum = bounds[boundsOffset + axis];
      final maximum = bounds[boundsOffset + 3 + axis];

      if (axisDirection.abs() < 1e-15) {
        if (axisOrigin < minimum || axisOrigin > maximum) return false;
        continue;
      }

      var first = (minimum - axisOrigin) / axisDirection;
      var second = (maximum - axisOrigin) / axisDirection;
      if (first > second) {
        final swap = first;
        first = second;
        second = swap;
      }
      if (first > near) near = first;
      if (second < far) far = second;
      if (far < near) return false;
    }
    return far >= 0;
  }

  static int _spreadBits(int value) {
    var bits = value & 0x3ff;
    bits = (bits | (bits << 16)) & 0x030000ff;
    bits = (bits | (bits << 8)) & 0x0300f00f;
    bits = (bits | (bits << 4)) & 0x030c30c3;
    bits = (bits | (bits << 2)) & 0x09249249;
    return bits;
  }
}

/// Intersects [localRay] with the triangles of an engine-layout interleaved
/// vertex buffer (and optional index buffer), emitting one record per hit
/// (both faces). Pure math over the packed bytes; exposed for testing.
@visibleForTesting
void intersectPackedTriangles({
  required ByteData vertices,
  required int stride,
  required ByteData? indices,
  required gpu.IndexType indexType,
  required int indexCount,
  required int vertexCount,
  required Ray localRay,
  required double maxDistance,
  required void Function(PackedTriangleHit) emit,
}) {
  _intersectTriangles(
    getPosition: (v) => Vector3(
      vertices.getFloat32(v * stride + _positionOffset, Endian.little),
      vertices.getFloat32(v * stride + _positionOffset + 4, Endian.little),
      vertices.getFloat32(v * stride + _positionOffset + 8, Endian.little),
    ),
    getTexCoord: (v) => Vector2(
      vertices.getFloat32(v * stride + _texCoordOffset, Endian.little),
      vertices.getFloat32(v * stride + _texCoordOffset + 4, Endian.little),
    ),
    indices: indices,
    indexType: indexType,
    indexCount: indexCount,
    vertexCount: vertexCount,
    localRay: localRay,
    maxDistance: maxDistance,
    emit: emit,
  );
}

/// Structure-of-arrays variant: position (3 floats/vertex) and optional
/// texture coordinates (2 floats/vertex) come from separate lists. Exposed
/// for testing.
@visibleForTesting
void intersectSoATriangles({
  required Float32List positions,
  Float32List? texCoords,
  required ByteData? indices,
  required gpu.IndexType indexType,
  required int indexCount,
  required int vertexCount,
  required Ray localRay,
  required double maxDistance,
  required void Function(PackedTriangleHit) emit,
}) {
  _intersectTriangles(
    getPosition: (v) =>
        Vector3(positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2]),
    getTexCoord: texCoords == null
        ? null
        : (v) => Vector2(texCoords[v * 2], texCoords[v * 2 + 1]),
    indices: indices,
    indexType: indexType,
    indexCount: indexCount,
    vertexCount: vertexCount,
    localRay: localRay,
    maxDistance: maxDistance,
    emit: emit,
  );
}

/// The layout-agnostic triangle intersection core. Reads position (and
/// optional texcoord) through accessors so it serves both the interleaved
/// and structure-of-arrays vertex layouts.
void _intersectTriangles({
  Object? cacheOwner,
  int cacheVersion = 0,
  ByteData? cacheVertices,
  Float32List? cachePositions,
  int? cacheStride,
  double Function(int vertexIndex, int axis)? cacheCoordinate,
  required Vector3 Function(int) getPosition,
  Vector2 Function(int)? getTexCoord,
  required ByteData? indices,
  required gpu.IndexType indexType,
  required int indexCount,
  required int vertexCount,
  required Ray localRay,
  required double maxDistance,
  required void Function(PackedTriangleHit) emit,
}) {
  final count = indices != null ? indexCount : vertexCount;
  int vertexIndex(int i) {
    if (indices == null) return i;
    return indexType == gpu.IndexType.int16
        ? indices.getUint16(i * 2, Endian.little)
        : indices.getUint32(i * 4, Endian.little);
  }

  final origin = localRay.origin;
  final direction = localRay.direction;

  void testTriangle(int t) {
    final i0 = vertexIndex(t * 3);
    final i1 = vertexIndex(t * 3 + 1);
    final i2 = vertexIndex(t * 3 + 2);
    final a = getPosition(i0);
    final b = getPosition(i1);
    final c = getPosition(i2);

    // Moller-Trumbore, both faces.
    final edge1 = b - a;
    final edge2 = c - a;
    final pvec = direction.cross(edge2);
    final det = edge1.dot(pvec);
    if (det.abs() < 1e-12) return;
    final invDet = 1.0 / det;
    final tvec = origin - a;
    final u = tvec.dot(pvec) * invDet;
    if (u < 0.0 || u > 1.0) return;
    final qvec = tvec.cross(edge1);
    final v = direction.dot(qvec) * invDet;
    if (v < 0.0 || u + v > 1.0) return;
    final rayT = edge2.dot(qvec) * invDet;
    if (rayT <= 0.0 || rayT > maxDistance) return;

    final w = 1.0 - u - v;
    // The engine's fixed vertex layouts always carry tex_coords; uv is zero
    // only for a custom layout that omits them.
    final uv = getTexCoord == null
        ? Vector2.zero()
        : getTexCoord(i0) * w + getTexCoord(i1) * u + getTexCoord(i2) * v;

    emit((
      t: rayT,
      barycentrics: Vector3(w, u, v),
      triangleIndex: t,
      uv: uv,
      localNormal: edge1.cross(edge2)..normalize(),
    ));
  }

  final triangleCount = count ~/ 3;
  final bvh = cacheOwner == null || triangleCount < _triangleBvhThreshold
      ? null
      : _triangleBvhFor(
          cacheOwner: cacheOwner,
          vertices: cacheVertices,
          positions: cachePositions,
          indices: indices,
          stride: cacheStride,
          indexType: indexType,
          indexCount: indexCount,
          vertexCount: vertexCount,
          version: cacheVersion,
          vertexIndex: vertexIndex,
          coordinate:
              cacheCoordinate ?? (vertex, axis) => getPosition(vertex)[axis],
        );

  if (bvh == null) {
    for (var triangle = 0; triangle < triangleCount; triangle++) {
      testTriangle(triangle);
    }
    return;
  }

  bvh.visitRay(localRay, maxDistance, testTriangle);
}

_TriangleBvh _triangleBvhFor({
  required Object cacheOwner,
  required ByteData? vertices,
  required Float32List? positions,
  required ByteData? indices,
  required int? stride,
  required gpu.IndexType indexType,
  required int indexCount,
  required int vertexCount,
  required int version,
  required int Function(int indexOffset) vertexIndex,
  required double Function(int vertexIndex, int axis) coordinate,
}) {
  final cached = _triangleBvhCache[cacheOwner];
  if (cached?.matches(
        vertices: vertices,
        positions: positions,
        indices: indices,
        stride: stride,
        indexType: indexType,
        indexCount: indexCount,
        vertexCount: vertexCount,
        version: version,
      ) ==
      true) {
    return cached!.bvh;
  }

  final triangleCount = (indices == null ? vertexCount : indexCount) ~/ 3;
  final bvh = _TriangleBvh.build(
    triangleCount: triangleCount,
    vertexIndex: vertexIndex,
    coordinate: coordinate,
  );
  _triangleBvhCache[cacheOwner] = _TriangleBvhCacheEntry(
    vertices: vertices,
    positions: positions,
    indices: indices,
    stride: stride,
    indexType: indexType,
    indexCount: indexCount,
    vertexCount: vertexCount,
    version: version,
    bvh: bvh,
  );
  return bvh;
}

void _testTriangles({
  required Object cacheOwner,
  required int cacheVersion,
  required Node node,
  required int primitiveIndex,
  ByteData? vertices,
  int? stride,
  Float32List? positions,
  Float32List? texCoords,
  required ByteData? indices,
  required gpu.IndexType indexType,
  required int indexCount,
  required int vertexCount,
  required Ray localRay,
  required Matrix4 worldTransform,
  required Vector3 worldOrigin,
  required Vector3 worldDirection,
  required double maxDistance,
  required void Function(SceneRaycastHit) emit,
}) {
  void onHit(PackedTriangleHit hit) {
    // hit.t is in world units because the local direction is the
    // transformed (unnormalized) world unit direction.
    final worldPoint = worldOrigin + worldDirection * hit.t;
    final worldNormal = _transformNormal(worldTransform, hit.localNormal);
    if (worldNormal.dot(worldDirection) > 0) worldNormal.negate();
    emit(
      SceneRaycastHit(
        node: node,
        distance: hit.t,
        worldPoint: worldPoint,
        worldNormal: worldNormal,
        uv: hit.uv,
        barycentrics: hit.barycentrics,
        triangleIndex: hit.triangleIndex,
        primitiveIndex: primitiveIndex,
      ),
    );
  }

  if (positions != null) {
    _intersectTriangles(
      cacheOwner: cacheOwner,
      cacheVersion: cacheVersion,
      cachePositions: positions,
      cacheCoordinate: (vertex, axis) => positions[vertex * 3 + axis],
      getPosition: (vertex) => Vector3(
        positions[vertex * 3],
        positions[vertex * 3 + 1],
        positions[vertex * 3 + 2],
      ),
      getTexCoord: texCoords == null
          ? null
          : (vertex) =>
                Vector2(texCoords[vertex * 2], texCoords[vertex * 2 + 1]),
      indices: indices,
      indexType: indexType,
      indexCount: indexCount,
      vertexCount: vertexCount,
      localRay: localRay,
      maxDistance: maxDistance,
      emit: onHit,
    );
  } else {
    final packedVertices = vertices!;
    final packedStride = stride!;
    _intersectTriangles(
      cacheOwner: cacheOwner,
      cacheVersion: cacheVersion,
      cacheVertices: packedVertices,
      cacheStride: packedStride,
      cacheCoordinate: (vertex, axis) => packedVertices.getFloat32(
        vertex * packedStride + _positionOffset + axis * 4,
        Endian.little,
      ),
      getPosition: (vertex) => Vector3(
        packedVertices.getFloat32(
          vertex * packedStride + _positionOffset,
          Endian.little,
        ),
        packedVertices.getFloat32(
          vertex * packedStride + _positionOffset + 4,
          Endian.little,
        ),
        packedVertices.getFloat32(
          vertex * packedStride + _positionOffset + 8,
          Endian.little,
        ),
      ),
      getTexCoord: (vertex) => Vector2(
        packedVertices.getFloat32(
          vertex * packedStride + _texCoordOffset,
          Endian.little,
        ),
        packedVertices.getFloat32(
          vertex * packedStride + _texCoordOffset + 4,
          Endian.little,
        ),
      ),
      indices: indices,
      indexType: indexType,
      indexCount: indexCount,
      vertexCount: vertexCount,
      localRay: localRay,
      maxDistance: maxDistance,
      emit: onHit,
    );
  }
}

/// Applies the linear part of [transform]'s inverse transpose to [normal],
/// the correct normal transform under non-uniform scale.
Vector3 _transformNormal(Matrix4 transform, Vector3 normal) {
  final inverseTranspose = Matrix4.copy(transform)
    ..invert()
    ..transpose();
  return Vector3(
    inverseTranspose.entry(0, 0) * normal.x +
        inverseTranspose.entry(0, 1) * normal.y +
        inverseTranspose.entry(0, 2) * normal.z,
    inverseTranspose.entry(1, 0) * normal.x +
        inverseTranspose.entry(1, 1) * normal.y +
        inverseTranspose.entry(1, 2) * normal.z,
    inverseTranspose.entry(2, 0) * normal.x +
        inverseTranspose.entry(2, 1) * normal.y +
        inverseTranspose.entry(2, 2) * normal.z,
  )..normalize();
}

bool _rayIntersectsAabb(Ray ray, Aabb3 aabb, double maxDistance) {
  var tMin = 0.0;
  var tMax = maxDistance;
  for (var axis = 0; axis < 3; axis++) {
    final originAxis = ray.origin[axis];
    final directionAxis = ray.direction[axis];
    final minAxis = aabb.min[axis];
    final maxAxis = aabb.max[axis];
    if (directionAxis.abs() < 1e-12) {
      if (originAxis < minAxis || originAxis > maxAxis) return false;
      continue;
    }
    var t1 = (minAxis - originAxis) / directionAxis;
    var t2 = (maxAxis - originAxis) / directionAxis;
    if (t1 > t2) {
      final swap = t1;
      t1 = t2;
      t2 = swap;
    }
    if (t1 > tMin) tMin = t1;
    if (t2 < tMax) tMax = t2;
    if (tMin > tMax) return false;
  }
  return true;
}
