import Foundation

// Round 22: the one shape of a 3D scene that SceneKit has no ready-made geometry for, the hemisphere,
// built here as plain numbers (positions, normals and triangles) so it can be checked without SceneKit.
// The app turns the mesh into an `SCNGeometry` with geometry sources and one triangle element.

/// A triangle mesh in plain numbers. Every three entries of `triangleIndices` are one triangle, wound
/// counter-clockwise seen from outside (the front face SceneKit draws), and each index is a place in
/// `positions` and `normals`, which have the same count.
nonisolated struct EzraSceneMesh: Equatable {
    let positions: [EzraSceneVector]
    /// One unit normal per position, pointing out of the surface.
    let normals: [EzraSceneVector]
    let triangleIndices: [Int]

    var triangleCount: Int {
        triangleIndices.count / 3
    }
}

nonisolated enum EzraSceneMeshBuilder {
    /// The hemisphere's flat sides: as many as a sphere of a scene has round its middle.
    static let hemisphereRadialSegmentCount = 24
    /// The bands of the dome from its rim to its top.
    static let hemisphereRingCount = 8

    /// A dome of this radius, its flat side down, centred on its own bounds like every other part of a
    /// scene: the flat side is half a radius below the centre and the top half a radius above it.
    ///
    /// The dome has `rings` bands from the rim to the top. Every band but the top one is a strip of two
    /// triangles per side; the top band is a fan round the single top vertex, so no triangle is
    /// degenerate. The flat side is a fan round its centre, with vertices of its own whose normal points
    /// straight down, so its edge stays sharp. That makes radialSegments x (2 x rings - 1) triangles for
    /// the dome and radialSegments for the flat side: radialSegments x 2 x rings in all.
    static func hemisphere(radius: Double, radialSegments: Int = hemisphereRadialSegmentCount, rings: Int = hemisphereRingCount) -> EzraSceneMesh {
        let radialSegmentCount = max(3, radialSegments)
        let ringCount = max(1, rings)
        // The bounds of a dome run from its flat side (0) to its top (radius); this moves them so the
        // middle is at 0.
        let verticalShift = -radius / 2

        var positions: [EzraSceneVector] = []
        var normals: [EzraSceneVector] = []
        var triangleIndices: [Int] = []

        // The dome's rings, from the rim (latitude 0) up to one band below the top.
        for ringIndex in 0..<ringCount {
            let latitudeInRadians = Double(ringIndex) / Double(ringCount) * Double.pi / 2
            for segmentIndex in 0..<radialSegmentCount {
                let longitudeInRadians = Double(segmentIndex) / Double(radialSegmentCount) * 2 * Double.pi
                let unitDirection = EzraSceneVector(
                    x: cos(latitudeInRadians) * sin(longitudeInRadians),
                    y: sin(latitudeInRadians),
                    z: cos(latitudeInRadians) * cos(longitudeInRadians)
                )
                positions.append(EzraSceneVector(x: radius * unitDirection.x, y: radius * unitDirection.y + verticalShift, z: radius * unitDirection.z))
                normals.append(unitDirection)
            }
        }
        // The top, one vertex.
        let topVertexIndex = positions.count
        positions.append(EzraSceneVector(x: 0, y: radius + verticalShift, z: 0))
        normals.append(EzraSceneVector(x: 0, y: 1, z: 0))

        func domeVertexIndex(ringIndex: Int, segmentIndex: Int) -> Int {
            ringIndex * radialSegmentCount + (segmentIndex % radialSegmentCount)
        }
        // The strips. Going round, the longitude grows from +z towards +x; seen from outside that is
        // to the right, so "lower left, lower right, upper right" is counter-clockwise.
        for ringIndex in 0..<(ringCount - 1) {
            for segmentIndex in 0..<radialSegmentCount {
                let lowerLeft = domeVertexIndex(ringIndex: ringIndex, segmentIndex: segmentIndex)
                let lowerRight = domeVertexIndex(ringIndex: ringIndex, segmentIndex: segmentIndex + 1)
                let upperLeft = domeVertexIndex(ringIndex: ringIndex + 1, segmentIndex: segmentIndex)
                let upperRight = domeVertexIndex(ringIndex: ringIndex + 1, segmentIndex: segmentIndex + 1)
                triangleIndices += [lowerLeft, lowerRight, upperRight]
                triangleIndices += [lowerLeft, upperRight, upperLeft]
            }
        }
        // The fan round the top.
        for segmentIndex in 0..<radialSegmentCount {
            triangleIndices += [
                domeVertexIndex(ringIndex: ringCount - 1, segmentIndex: segmentIndex),
                domeVertexIndex(ringIndex: ringCount - 1, segmentIndex: segmentIndex + 1),
                topVertexIndex,
            ]
        }

        // The flat side: its centre and its own copy of the rim, all facing down.
        let flatSideCentreIndex = positions.count
        positions.append(EzraSceneVector(x: 0, y: verticalShift, z: 0))
        normals.append(EzraSceneVector(x: 0, y: -1, z: 0))
        let flatSideRimStartIndex = positions.count
        for segmentIndex in 0..<radialSegmentCount {
            let longitudeInRadians = Double(segmentIndex) / Double(radialSegmentCount) * 2 * Double.pi
            positions.append(EzraSceneVector(x: radius * sin(longitudeInRadians), y: verticalShift, z: radius * cos(longitudeInRadians)))
            normals.append(EzraSceneVector(x: 0, y: -1, z: 0))
        }
        // Seen from below, the longitude runs the other way round, so the fan goes centre, next, this.
        for segmentIndex in 0..<radialSegmentCount {
            triangleIndices += [
                flatSideCentreIndex,
                flatSideRimStartIndex + (segmentIndex + 1) % radialSegmentCount,
                flatSideRimStartIndex + segmentIndex,
            ]
        }

        return EzraSceneMesh(positions: positions, normals: normals, triangleIndices: triangleIndices)
    }
}
