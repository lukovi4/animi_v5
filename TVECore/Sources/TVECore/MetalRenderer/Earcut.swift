import Foundation

// MARK: - Earcut Triangulator

/// Ear-clipping triangulation algorithm for simple polygons.
/// Based on the earcut.js algorithm by Mapbox.
/// Converts a polygon (with optional holes) into triangles for GPU rendering.
public enum Earcut {

    /// Triangulates a simple polygon defined by its vertices.
    /// - Parameters:
    ///   - vertices: Flat array of coordinates [x0, y0, x1, y1, ...]
    ///   - holeIndices: Array of indices where holes start (empty for no holes)
    /// - Returns: Array of triangle indices into the vertices array
    public static func triangulate(vertices: [Double], holeIndices: [Int] = []) -> [Int] {
        let vertexCount = vertices.count / 2
        guard vertexCount >= 3 else { return [] }

        let hasHoles = !holeIndices.isEmpty
        let outerLen = hasHoles ? holeIndices[0] : vertexCount

        var outerNode = linkedList(vertices: vertices, start: 0, end: outerLen, clockwise: true)
        guard var node = outerNode else { return [] }

        var triangles: [Int] = []

        if hasHoles {
            outerNode = eliminateHoles(vertices: vertices, holeIndices: holeIndices, outerNode: node)
            node = outerNode!
        }

        // For simple polygons, use fast ear-clipping
        if vertexCount <= 80 {
            earcutLinked(&node, &triangles, pass: 0)
        } else {
            // For complex polygons, use z-order curve hashing
            let (minX, minY, maxX, maxY) = computeBounds(vertices: vertices, start: 0, end: outerLen)
            let invSize = max(maxX - minX, maxY - minY)
            indexCurve(node, minX: minX, minY: minY, invSize: invSize == 0 ? 1 : 1 / invSize)
            earcutLinked(&node, &triangles, pass: 0)
        }

        return triangles
    }

    /// Triangulates a BezierPath by flattening curves and triangulating the result.
    /// - Parameters:
    ///   - path: BezierPath to triangulate
    ///   - flatness: Maximum distance from curve to line segment (default: 1.0)
    /// - Returns: Array of triangle indices
    public static func triangulate(path: BezierPath, flatness: Double = 1.0) -> [Int] {
        let flattenedVertices = flattenPath(path, flatness: flatness)
        return triangulate(vertices: flattenedVertices)
    }

    /// Flattens a BezierPath into a polyline.
    /// - Parameters:
    ///   - path: BezierPath to flatten
    ///   - flatness: Maximum distance from curve to line segment
    /// - Returns: Flat array of coordinates [x0, y0, x1, y1, ...]
    public static func flattenPath(_ path: BezierPath, flatness: Double = 1.0) -> [Double] {
        guard path.vertexCount >= 2 else { return [] }

        var result: [Double] = []
        let count = path.vertices.count

        for index in 0..<count {
            let vertex = path.vertices[index]
            let outTangent = path.outTangents[index]

            let nextIndex = (index + 1) % count
            let nextVertex = path.vertices[nextIndex]
            let nextInTangent = path.inTangents[nextIndex]

            // Skip last segment for open paths
            if !path.closed && index == count - 1 {
                result.append(vertex.x)
                result.append(vertex.y)
                break
            }

            // Check if this segment is a straight line (both tangents are zero)
            let isLine = outTangent.x == 0 && outTangent.y == 0 &&
                        nextInTangent.x == 0 && nextInTangent.y == 0

            if isLine {
                result.append(vertex.x)
                result.append(vertex.y)
            } else {
                // Flatten bezier curve
                let controlPoint1 = Vec2D(x: vertex.x + outTangent.x, y: vertex.y + outTangent.y)
                let controlPoint2 = Vec2D(x: nextVertex.x + nextInTangent.x, y: nextVertex.y + nextInTangent.y)
                flattenBezier(
                    p0: vertex, p1: controlPoint1, p2: controlPoint2, p3: nextVertex,
                    flatness: flatness, result: &result, includeStart: true
                )
            }
        }

        return result
    }

    // MARK: - Private Implementation

    /// Linked list node for ear-clipping algorithm
    private final class Node {
        let index: Int
        var x: Double
        var y: Double
        var prev: Node!
        var next: Node!
        var z: Int = 0
        var prevZ: Node?
        var nextZ: Node?
        var steiner: Bool = false

        init(index: Int, x: Double, y: Double) {
            self.index = index
            self.x = x
            self.y = y
        }
    }

    /// Creates a circular doubly linked list from polygon vertices
    private static func linkedList(
        vertices: [Double],
        start: Int,
        end: Int,
        clockwise: Bool
    ) -> Node? {
        var last: Node?

        if clockwise == (signedArea(vertices: vertices, start: start, end: end) > 0) {
            for idx in stride(from: start, to: end, by: 1) {
                last = insertNode(idx, x: vertices[idx * 2], y: vertices[idx * 2 + 1], last: last)
            }
        } else {
            for idx in stride(from: end - 1, through: start, by: -1) {
                last = insertNode(idx, x: vertices[idx * 2], y: vertices[idx * 2 + 1], last: last)
            }
        }

        if let last = last, equals(last, last.next) {
            removeNode(last)
            return last.next
        }

        last?.next.prev = last
        last?.prev.next = last

        return last
    }

    /// Inserts a node after the given node
    private static func insertNode(_ index: Int, x: Double, y: Double, last: Node?) -> Node {
        let node = Node(index: index, x: x, y: y)

        if let last = last {
            node.next = last.next
            node.prev = last
            last.next.prev = node
            last.next = node
        } else {
            node.prev = node
            node.next = node
        }

        return node
    }

    /// Removes a node from the linked list
    private static func removeNode(_ node: Node) {
        node.next.prev = node.prev
        node.prev.next = node.next

        if let prevZ = node.prevZ {
            prevZ.nextZ = node.nextZ
        }
        if let nextZ = node.nextZ {
            nextZ.prevZ = node.prevZ
        }
    }

    /// Checks if two nodes are equal
    private static func equals(_ a: Node, _ b: Node) -> Bool {
        a.x == b.x && a.y == b.y
    }

    /// Computes signed area of a polygon
    private static func signedArea(vertices: [Double], start: Int, end: Int) -> Double {
        var sum: Double = 0
        var j = end - 1
        for idx in start..<end {
            sum += (vertices[j * 2] - vertices[idx * 2]) * (vertices[idx * 2 + 1] + vertices[j * 2 + 1])
            j = idx
        }
        return sum
    }

    /// Main ear-clipping loop
    private static func earcutLinked(_ ear: inout Node, _ triangles: inout [Int], pass: Int) {
        guard ear.next !== ear.prev else { return }

        var stop = ear
        var current: Node? = ear

        while current?.prev !== current?.next {
            guard let node = current else { break }

            let prev = node.prev!
            let next = node.next!

            if isEar(node) {
                triangles.append(prev.index)
                triangles.append(node.index)
                triangles.append(next.index)

                removeNode(node)

                current = next.next
                stop = next.next

                continue
            }

            current = next

            if current === stop {
                // No more ears found
                if pass == 0 {
                    // Try filtering out degenerate edges
                    filterPoints(ear, nil)
                    earcutLinked(&ear, &triangles, pass: 1)
                } else if pass == 1 {
                    let filtered = filterPoints(ear, nil)
                    if var f = filtered {
                        earcutLinked(&f, &triangles, pass: 2)
                    }
                } else if pass == 2 {
                    splitEarcut(ear, &triangles)
                }
                break
            }
        }
    }

    /// Checks if a node is an ear (can be clipped)
    private static func isEar(_ ear: Node) -> Bool {
        let a = ear.prev!
        let b = ear
        let c = ear.next!

        // Reflex vertex (concave angle)
        if area(a, b, c) >= 0 { return false }

        // Check if any point is inside the triangle
        var node = c.next!
        while node !== a {
            if pointInTriangle(a.x, a.y, b.x, b.y, c.x, c.y, node.x, node.y) &&
               area(node.prev, node, node.next) >= 0 {
                return false
            }
            node = node.next
        }

        return true
    }

    /// Signed area of a triangle
    private static func area(_ p: Node, _ q: Node, _ r: Node) -> Double {
        (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
    }

    /// Checks if point (px, py) is inside triangle (ax, ay), (bx, by), (cx, cy)
    private static func pointInTriangle(
        _ ax: Double, _ ay: Double,
        _ bx: Double, _ by: Double,
        _ cx: Double, _ cy: Double,
        _ px: Double, _ py: Double
    ) -> Bool {
        (cx - px) * (ay - py) - (ax - px) * (cy - py) >= 0 &&
        (ax - px) * (by - py) - (bx - px) * (ay - py) >= 0 &&
        (bx - px) * (cy - py) - (cx - px) * (by - py) >= 0
    }

    /// Filters out colinear or duplicate points
    @discardableResult
    private static func filterPoints(_ start: Node, _ end: Node?) -> Node? {
        let endNode = end ?? start
        var node = start
        var again: Bool

        repeat {
            again = false

            if !node.steiner && (equals(node, node.next) || area(node.prev, node, node.next) == 0) {
                removeNode(node)
                node = node.prev
                if node === node.next { break }
                again = true
            } else {
                node = node.next
            }
        } while again || node !== endNode

        return node
    }

    /// Splits remaining polygon when no ears can be found
    private static func splitEarcut(_ start: Node, _ triangles: inout [Int]) {
        var a = start
        repeat {
            var b = a.next.next!
            while b !== a.prev {
                if a.index != b.index && isValidDiagonal(a, b) {
                    var c = splitPolygon(a, b)

                    a = filterPoints(a, a.next) ?? a
                    c = filterPoints(c, c.next) ?? c

                    earcutLinked(&a, &triangles, pass: 0)
                    earcutLinked(&c, &triangles, pass: 0)
                    return
                }
                b = b.next
            }
            a = a.next
        } while a !== start
    }

    /// Checks if diagonal from a to b is valid
    private static func isValidDiagonal(_ a: Node, _ b: Node) -> Bool {
        a.next.index != b.index && a.prev.index != b.index &&
        !intersectsPolygon(a, b) &&
        locallyInside(a, b) && locallyInside(b, a) &&
        middleInside(a, b)
    }

    /// Checks if a diagonal locally lies inside the polygon
    private static func locallyInside(_ a: Node, _ b: Node) -> Bool {
        if area(a.prev, a, a.next) < 0 {
            return area(a, b, a.next) >= 0 && area(a, a.prev, b) >= 0
        }
        return area(a, b, a.prev) < 0 || area(a, a.next, b) < 0
    }

    /// Checks if the middle point of a diagonal is inside the polygon
    private static func middleInside(_ a: Node, _ b: Node) -> Bool {
        var node = a
        var inside = false
        let px = (a.x + b.x) / 2
        let py = (a.y + b.y) / 2
        repeat {
            if ((node.y > py) != (node.next.y > py)) &&
               node.next.y != node.y &&
               (px < (node.next.x - node.x) * (py - node.y) / (node.next.y - node.y) + node.x) {
                inside = !inside
            }
            node = node.next
        } while node !== a

        return inside
    }

    /// Checks if diagonal intersects any polygon edge
    private static func intersectsPolygon(_ a: Node, _ b: Node) -> Bool {
        var node = a
        repeat {
            if node.index != a.index && node.next.index != a.index &&
               node.index != b.index && node.next.index != b.index &&
               intersects(node, node.next, a, b) {
                return true
            }
            node = node.next
        } while node !== a

        return false
    }

    /// Checks if two segments intersect
    private static func intersects(_ p1: Node, _ q1: Node, _ p2: Node, _ q2: Node) -> Bool {
        let o1 = sign(area(p1, q1, p2))
        let o2 = sign(area(p1, q1, q2))
        let o3 = sign(area(p2, q2, p1))
        let o4 = sign(area(p2, q2, q1))

        if o1 != o2 && o3 != o4 { return true }

        if o1 == 0 && onSegment(p1, p2, q1) { return true }
        if o2 == 0 && onSegment(p1, q2, q1) { return true }
        if o3 == 0 && onSegment(p2, p1, q2) { return true }
        if o4 == 0 && onSegment(p2, q1, q2) { return true }

        return false
    }

    /// Returns sign of a number
    private static func sign(_ value: Double) -> Int {
        if value > 0 { return 1 }
        if value < 0 { return -1 }
        return 0
    }

    /// Checks if point q lies on segment pr
    private static func onSegment(_ p: Node, _ q: Node, _ r: Node) -> Bool {
        q.x <= max(p.x, r.x) && q.x >= min(p.x, r.x) &&
        q.y <= max(p.y, r.y) && q.y >= min(p.y, r.y)
    }

    /// Links two polygon vertices with a bridge
    private static func splitPolygon(_ a: Node, _ b: Node) -> Node {
        let a2 = Node(index: a.index, x: a.x, y: a.y)
        let b2 = Node(index: b.index, x: b.x, y: b.y)
        let an = a.next!
        let bp = b.prev!

        a.next = b
        b.prev = a

        a2.next = an
        an.prev = a2

        b2.next = a2
        a2.prev = b2

        bp.next = b2
        b2.prev = bp

        return b2
    }

    /// Eliminates holes by finding bridge to outer polygon
    private static func eliminateHoles(
        vertices: [Double],
        holeIndices: [Int],
        outerNode: Node
    ) -> Node? {
        var queue: [Node] = []

        for idx in 0..<holeIndices.count {
            let start = holeIndices[idx]
            let end = idx < holeIndices.count - 1 ? holeIndices[idx + 1] : vertices.count / 2
            if let list = linkedList(vertices: vertices, start: start, end: end, clockwise: false) {
                if list === list.next { list.steiner = true }
                queue.append(getLeftmost(list))
            }
        }

        queue.sort { $0.x < $1.x }

        var outer: Node? = outerNode
        for hole in queue {
            outer = eliminateHole(hole, outer)
        }

        return outer
    }

    /// Finds leftmost node of a polygon ring
    private static func getLeftmost(_ start: Node) -> Node {
        var node = start
        var leftmost = start
        repeat {
            if node.x < leftmost.x || (node.x == leftmost.x && node.y < leftmost.y) {
                leftmost = node
            }
            node = node.next
        } while node !== start

        return leftmost
    }

    /// Bridges a hole to the outer polygon
    private static func eliminateHole(_ hole: Node, _ outerNode: Node?) -> Node? {
        guard let outer = outerNode else { return nil }
        guard let bridge = findHoleBridge(hole, outer) else { return outer }

        let bridgeReverse = splitPolygon(bridge, hole)

        filterPoints(bridgeReverse, bridgeReverse.next)
        return filterPoints(bridge, bridge.next)
    }

    /// Finds a bridge between hole and outer polygon
    private static func findHoleBridge(_ hole: Node, _ outerNode: Node) -> Node? {
        var node = outerNode
        let hx = hole.x
        let hy = hole.y
        var qx = Double.leastNonzeroMagnitude * -1
        var bridge: Node?

        repeat {
            if hy <= node.y && hy >= node.next.y && node.next.y != node.y {
                let x = node.x + (hy - node.y) * (node.next.x - node.x) / (node.next.y - node.y)
                if x <= hx && x > qx {
                    qx = x
                    bridge = node.x < node.next.x ? node : node.next
                    if x == hx { return bridge }
                }
            }
            node = node.next
        } while node !== outerNode

        guard var m = bridge else { return nil }

        let stop = m
        let mx = m.x
        let my = m.y
        var tanMin = Double.infinity
        node = m

        repeat {
            if hx >= node.x && node.x >= mx && hx != node.x &&
               pointInTriangle(hy < my ? hx : qx, hy, mx, my, hy < my ? qx : hx, hy, node.x, node.y) {
                let tan = abs(hy - node.y) / (hx - node.x)
                if locallyInside(node, hole) && (tan < tanMin || (tan == tanMin && (node.x > m.x || sectorContainsSector(m, node)))) {
                    m = node
                    tanMin = tan
                }
            }
            node = node.next
        } while node !== stop

        return m
    }

    /// Checks if sector in node m contains sector in node p
    private static func sectorContainsSector(_ m: Node, _ p: Node) -> Bool {
        area(m.prev, m, p.prev) < 0 && area(p.next, m, m.next) < 0
    }

    /// Computes bounds of polygon
    private static func computeBounds(
        vertices: [Double],
        start: Int,
        end: Int
    ) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity

        for idx in start..<end {
            let x = vertices[idx * 2]
            let y = vertices[idx * 2 + 1]
            if x < minX { minX = x }
            if y < minY { minY = y }
            if x > maxX { maxX = x }
            if y > maxY { maxY = y }
        }

        return (minX, minY, maxX, maxY)
    }

    /// Indexes nodes by z-order curve for faster intersection checks
    private static func indexCurve(_ start: Node, minX: Double, minY: Double, invSize: Double) {
        var node: Node? = start
        repeat {
            if node!.z == 0 {
                node!.z = zOrder(x: node!.x, y: node!.y, minX: minX, minY: minY, invSize: invSize)
            }
            node!.prevZ = node!.prev
            node!.nextZ = node!.next
            node = node!.next
        } while node !== start

        node!.prevZ?.nextZ = nil
        node!.prevZ = nil

        sortLinked(node!)
    }

    /// z-order of a point
    private static func zOrder(x: Double, y: Double, minX: Double, minY: Double, invSize: Double) -> Int {
        var lx = Int((x - minX) * invSize) | 0
        var ly = Int((y - minY) * invSize) | 0

        lx = (lx | (lx << 8)) & 0x00FF00FF
        lx = (lx | (lx << 4)) & 0x0F0F0F0F
        lx = (lx | (lx << 2)) & 0x33333333
        lx = (lx | (lx << 1)) & 0x55555555

        ly = (ly | (ly << 8)) & 0x00FF00FF
        ly = (ly | (ly << 4)) & 0x0F0F0F0F
        ly = (ly | (ly << 2)) & 0x33333333
        ly = (ly | (ly << 1)) & 0x55555555

        return lx | (ly << 1)
    }

    /// Simon Tatham's linked list merge sort
    private static func sortLinked(_ list: Node) {
        var inSize = 1
        var listOpt: Node? = list

        while true {
            var p = listOpt
            listOpt = nil
            var tail: Node?
            var numMerges = 0

            while p != nil {
                numMerges += 1
                var q = p
                var pSize = 0
                for _ in 0..<inSize {
                    pSize += 1
                    q = q?.nextZ
                    if q == nil { break }
                }
                var qSize = inSize

                while pSize > 0 || (qSize > 0 && q != nil) {
                    var e: Node?
                    if pSize != 0 && (qSize == 0 || q == nil || p!.z <= q!.z) {
                        e = p
                        p = p?.nextZ
                        pSize -= 1
                    } else {
                        e = q
                        q = q?.nextZ
                        qSize -= 1
                    }

                    if let t = tail {
                        t.nextZ = e
                    } else {
                        listOpt = e
                    }

                    e?.prevZ = tail
                    tail = e
                }

                p = q
            }

            tail?.nextZ = nil
            if numMerges <= 1 { return }

            inSize *= 2
        }
    }

    /// Flattens a cubic bezier curve to line segments
    private static func flattenBezier(
        p0: Vec2D, p1: Vec2D, p2: Vec2D, p3: Vec2D,
        flatness: Double,
        result: inout [Double],
        includeStart: Bool
    ) {
        // Check if curve is flat enough
        let dx = p3.x - p0.x
        let dy = p3.y - p0.y

        let d1 = abs((p1.x - p3.x) * dy - (p1.y - p3.y) * dx)
        let d2 = abs((p2.x - p3.x) * dy - (p2.y - p3.y) * dx)

        let tolerance = flatness * flatness * (dx * dx + dy * dy)

        if (d1 + d2) * (d1 + d2) < tolerance {
            // Flat enough - add start point
            if includeStart {
                result.append(p0.x)
                result.append(p0.y)
            }
            return
        }

        // Subdivide curve
        let p01 = Vec2D(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
        let p12 = Vec2D(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
        let p23 = Vec2D(x: (p2.x + p3.x) / 2, y: (p2.y + p3.y) / 2)
        let p012 = Vec2D(x: (p01.x + p12.x) / 2, y: (p01.y + p12.y) / 2)
        let p123 = Vec2D(x: (p12.x + p23.x) / 2, y: (p12.y + p23.y) / 2)
        let p0123 = Vec2D(x: (p012.x + p123.x) / 2, y: (p012.y + p123.y) / 2)

        flattenBezier(p0: p0, p1: p01, p2: p012, p3: p0123, flatness: flatness, result: &result, includeStart: includeStart)
        flattenBezier(p0: p0123, p1: p123, p2: p23, p3: p3, flatness: flatness, result: &result, includeStart: false)
    }
}
