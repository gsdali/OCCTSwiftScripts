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

    public init(version: Int = 1, timestamp: Date = Date(), description: String?, bodies: [BodyDescriptor]) {
        self.version = version
        self.timestamp = timestamp
        self.description = description
        self.bodies = bodies
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
