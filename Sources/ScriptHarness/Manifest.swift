// Manifest.swift
// ScriptHarness
//
// JSON manifest types for script output.

import Foundation

/// Manifest written by ScriptContext, read by the demo app's ScriptWatcher.
public struct ScriptManifest: Codable, Sendable {
    public let version: Int
    public let timestamp: Date
    public let description: String?
    public let bodies: [BodyDescriptor]
    public let graphs: [GraphDescriptor]?
    public let metadata: ManifestMetadata?

    public init(
        version: Int = 1,
        timestamp: Date = Date(),
        description: String?,
        bodies: [BodyDescriptor],
        graphs: [GraphDescriptor]? = nil,
        metadata: ManifestMetadata? = nil
    ) {
        self.version = version
        self.timestamp = timestamp
        self.description = description
        self.bodies = bodies
        self.graphs = graphs
        self.metadata = metadata
    }
}

/// Project/part metadata carried through the manifest.
public struct ManifestMetadata: Codable, Sendable {
    public let name: String
    public let revision: String?
    public let dateCreated: Date?
    public let dateModified: Date?
    public let source: String?
    public let tags: [String]?
    public let notes: String?

    public init(
        name: String,
        revision: String? = nil,
        dateCreated: Date? = nil,
        dateModified: Date? = nil,
        source: String? = nil,
        tags: [String]? = nil,
        notes: String? = nil
    ) {
        self.name = name
        self.revision = revision
        self.dateCreated = dateCreated
        self.dateModified = dateModified
        self.source = source
        self.tags = tags
        self.notes = notes
    }
}

/// Summary statistics for a topology graph.
public struct GraphStats: Codable, Sendable {
    public let faces: Int
    public let edges: Int
    public let vertices: Int
    public let shells: Int
    public let solids: Int

    public init(faces: Int, edges: Int, vertices: Int, shells: Int, solids: Int) {
        self.faces = faces
        self.edges = edges
        self.vertices = vertices
        self.shells = shells
        self.solids = solids
    }
}

/// Describes a topology graph in the manifest.
public struct GraphDescriptor: Codable, Sendable {
    public let id: String
    public let file: String
    public let sourceBodyId: String?
    public let stats: GraphStats?

    public init(
        id: String,
        file: String,
        sourceBodyId: String? = nil,
        stats: GraphStats? = nil
    ) {
        self.id = id
        self.file = file
        self.sourceBodyId = sourceBodyId
        self.stats = stats
    }
}

/// Describes a single body in the manifest.
public struct BodyDescriptor: Codable, Sendable {
    public let id: String?
    public let file: String
    public let format: String
    public let name: String?
    public let roughness: Float?
    public let metallic: Float?

    /// Color as [r, g, b, a] array.
    public let color: [Float]?

    public init(
        id: String?,
        file: String,
        format: String = "brep",
        name: String? = nil,
        color: [Float]? = nil,
        roughness: Float? = nil,
        metallic: Float? = nil
    ) {
        self.id = id
        self.file = file
        self.format = format
        self.name = name
        self.color = color
        self.roughness = roughness
        self.metallic = metallic
    }
}
