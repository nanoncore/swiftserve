import Foundation

/// The JSON Schema (Draft 2020-12) for ``Report`` — the canonical output contract.
///
/// Published so agents and tools can validate/understand the output without
/// guessing. Kept beside the model so the two stay in sync (a test asserts the
/// mood/flag vocabularies match the Swift enums).
public enum ReportSchema {
    public static let json: String = """
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://swiftserve.dev/schemas/report-v1.json",
      "title": "SwiftServe Report",
      "description": "Canonical dependency-health report (a Scoop). Identical from the web POST /analyze and the swiftserve CLI.",
      "type": "object",
      "additionalProperties": false,
      "required": ["reportVersion", "generatedAt", "overall", "packages", "graph", "enrichment"],
      "properties": {
        "reportVersion": { "type": "integer", "const": 1 },
        "generatedAt": { "type": "string", "description": "ISO-8601 timestamp" },
        "overall": {
          "type": "object",
          "additionalProperties": false,
          "required": ["score", "mood", "voiceLine", "headline"],
          "properties": {
            "score": { "type": "integer", "minimum": 0, "maximum": 100 },
            "mood": { "type": "string", "enum": ["partyMode", "freshSwirl", "softSqueeze", "meltdown", "dayOld"] },
            "voiceLine": { "type": "string" },
            "headline": { "type": "string" }
          }
        },
        "packages": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["identity", "name", "kind", "location", "resolvedVersion", "latestVersion", "branch", "pinType", "score", "subScores", "reason", "flags"],
            "properties": {
              "identity": { "type": "string" },
              "name": { "type": "string" },
              "kind": { "type": "string", "enum": ["remoteSourceControl", "localSourceControl", "registry", "unknown"] },
              "location": { "type": "string" },
              "resolvedVersion": { "type": ["string", "null"] },
              "latestVersion": { "type": ["string", "null"] },
              "branch": { "type": ["string", "null"] },
              "pinType": { "type": "string", "enum": ["version", "branch", "revision", "unknown"] },
              "score": { "type": "integer", "minimum": 0, "maximum": 100 },
              "subScores": {
                "type": "object",
                "additionalProperties": false,
                "required": ["maintenance", "staleness", "busFactor", "swift6", "hygiene", "license"],
                "properties": {
                  "maintenance": { "type": "integer" },
                  "staleness": { "type": "integer" },
                  "busFactor": { "type": "integer" },
                  "swift6": { "type": "integer" },
                  "hygiene": { "type": "integer" },
                  "license": { "type": "integer" }
                }
              },
              "reason": { "type": "string" },
              "flags": {
                "type": "array",
                "items": {
                  "type": "string",
                  "enum": ["branchPin", "revisionPin", "preRelease", "nonCanonicalLocation", "localPath", "registry", "archived", "noLicense", "copyleftLicense"]
                }
              }
            }
          }
        },
        "graph": {
          "type": "object",
          "additionalProperties": false,
          "required": ["total", "direct", "transitive", "maxDepth", "duplicates", "conflicts"],
          "properties": {
            "total": { "type": "integer" },
            "direct": { "type": ["integer", "null"], "description": "null — needs the Package.swift manifest" },
            "transitive": { "type": ["integer", "null"], "description": "null — needs the manifest" },
            "maxDepth": { "type": ["integer", "null"], "description": "null — needs the manifest" },
            "duplicates": {
              "type": "array",
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["name", "locations"],
                "properties": {
                  "name": { "type": "string" },
                  "locations": { "type": "array", "items": { "type": "string" } }
                }
              }
            },
            "conflicts": { "type": "array", "items": { "type": "string" } }
          }
        },
        "enrichment": {
          "type": "object",
          "additionalProperties": false,
          "required": ["source", "networkUsed"],
          "properties": {
            "source": { "type": "string", "enum": ["fileOnly", "github"] },
            "networkUsed": { "type": "boolean" }
          }
        }
      }
    }
    """
}
