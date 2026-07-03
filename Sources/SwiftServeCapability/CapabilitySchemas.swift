import Foundation

/// JSON Schemas (Draft 2020-12) for the capability pillar's contracts — the
/// record (what curators/labelers produce) and the surface (what extraction
/// emits). Published via `swiftserve schema` so agents never guess. Kept
/// beside the models; sync tests assert the enum vocabularies match.
public enum CapabilitySchemas {

    public static let platformEnum = Platform.allCases.map(\.rawValue)
    public static let statusEnum = ["supported", "unsupported", "conditional", "unknown"]
    public static let evidenceKindEnum = ["symbol", "guard", "availability", "manifestPlatforms", "readme"]

    public static let recordJSON: String = """
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://swiftserve.dev/schemas/capability-record-v1.json",
      "title": "SwiftServe Capability Record",
      "description": "One package × one capability × every platform. Every supported/unsupported claim is anchored to the package's extracted surface; the validator (V01–V07) is the only gate.",
      "type": "object",
      "additionalProperties": false,
      "required": ["recordVersion", "package", "capability", "platforms", "requiresCompanion", "notes", "labeledBy", "labeledAt"],
      "properties": {
        "recordVersion": { "type": "integer", "const": 1 },
        "package": {
          "type": "object",
          "additionalProperties": false,
          "required": ["canonicalURL", "name", "aliases", "version", "commit", "surfaceDigest"],
          "properties": {
            "canonicalURL": { "type": "string", "description": "https://github.com/owner/repo, lowercase, no .git" },
            "name": { "type": "string" },
            "aliases": { "type": "array", "items": { "type": "string" } },
            "version": { "type": "string", "description": "the tag the surface was extracted at" },
            "commit": { "type": "string" },
            "surfaceDigest": { "type": "string", "description": "fnv1a64:… digest of the surface JSON — drift detector" }
          }
        },
        "capability": {
          "type": "object",
          "additionalProperties": false,
          "required": ["id", "label"],
          "properties": {
            "id": { "type": "string", "description": "taxonomy id, e.g. audio.noise-cancellation" },
            "label": { "type": "string" }
          }
        },
        "platforms": {
          "type": "object",
          "description": "Platform → claim. Missing platforms draw a coverage warning; ‘unknown’ is an honest, welcome answer.",
          "additionalProperties": false,
          "patternProperties": {
            "^(iOS|macOS|watchOS|tvOS|visionOS|macCatalyst|linux)$": {
              "type": "object",
              "additionalProperties": false,
              "required": ["status", "confidence", "evidence"],
              "properties": {
                "status": { "type": "string", "enum": ["supported", "unsupported", "conditional", "unknown"] },
                "confidence": { "type": "number", "minimum": 0, "maximum": 0.95, "description": "capped by evidence strength: 0.6 all-conditional, 0.3 readme/manifest-only, 0.7 macro-flagged, 0.8 binary targets" },
                "evidence": {
                  "type": "array",
                  "items": {
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["kind", "symbol", "file", "line", "condition", "availability", "package", "note"],
                    "properties": {
                      "kind": { "type": "string", "enum": ["symbol", "guard", "availability", "manifestPlatforms", "readme"] },
                      "symbol": { "type": ["string", "null"], "description": "EXACT qualified name from the surface (required for symbol/guard/availability)" },
                      "file": { "type": ["string", "null"], "description": "repo-relative path, must match the surface decl" },
                      "line": { "type": ["integer", "null"] },
                      "condition": { "type": ["string", "null"], "description": "the #if guard text, e.g. os(iOS)" },
                      "availability": { "type": ["string", "null"] },
                      "package": { "type": ["string", "null"], "description": "canonical URL when citing a companion package's surface" },
                      "note": { "type": ["string", "null"] }
                    }
                  }
                }
              }
            }
          }
        },
        "requiresCompanion": { "type": "array", "items": { "type": "string" }, "description": "canonical URLs of companion packages" },
        "notes": { "type": ["string", "null"] },
        "labeledBy": { "type": "string", "description": "claude-code-session | api | human — audit only; the validator is the gate" },
        "labeledAt": { "type": "string", "description": "ISO-8601" }
      }
    }
    """

    public static let surfaceJSON: String = """
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://swiftserve.dev/schemas/package-surface-v1.json",
      "title": "SwiftServe Package Surface",
      "description": "A package's public API surface × platform conditionals, extracted by parsing at a pinned commit. Deterministic: same commit, same bytes. No wall-clock timestamp by design.",
      "type": "object",
      "additionalProperties": false,
      "required": ["surfaceVersion", "package", "manifestPlatforms", "decls", "stats"],
      "properties": {
        "surfaceVersion": { "type": "integer", "const": 1 },
        "package": {
          "type": "object",
          "additionalProperties": false,
          "required": ["canonicalURL", "name", "tag", "commit"],
          "properties": {
            "canonicalURL": { "type": ["string", "null"] },
            "name": { "type": "string" },
            "tag": { "type": ["string", "null"] },
            "commit": { "type": ["string", "null"] }
          }
        },
        "manifestPlatforms": {
          "type": "array",
          "description": "Package.swift platforms: — version FLOORS only, never exclusions (SPM semantics).",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["platform", "minVersion"],
            "properties": {
              "platform": { "type": "string" },
              "minVersion": { "type": ["string", "null"] }
            }
          }
        },
        "decls": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["name", "kind", "signature", "location", "condition", "rawCondition", "availability", "resolvedPlatforms", "docSummary", "hasMacroAttributes"],
            "properties": {
              "name": { "type": "string", "description": "qualified: RoomOptions.noiseCancellationFilter" },
              "kind": { "type": "string", "enum": ["function", "property", "initializer", "subscript", "enumCase", "class", "struct", "enum", "protocol", "actor", "typealias"] },
              "signature": { "type": ["string", "null"] },
              "location": {
                "type": "object",
                "additionalProperties": false,
                "required": ["file", "line"],
                "properties": { "file": { "type": "string" }, "line": { "type": "integer" } }
              },
              "condition": { "description": "structured #if condition tree (kind/value/operand/operands), null when unconditional" },
              "rawCondition": { "type": ["string", "null"], "description": "rendered condition text — the explainability channel" },
              "availability": { "type": "array", "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["platform", "introduced", "deprecated", "obsoleted", "unavailable", "message"],
                "properties": {
                  "platform": { "type": "string" },
                  "introduced": { "type": ["string", "null"] },
                  "deprecated": { "type": ["string", "null"] },
                  "obsoleted": { "type": ["string", "null"] },
                  "unavailable": { "type": "boolean" },
                  "message": { "type": ["string", "null"] }
                }
              }},
              "resolvedPlatforms": {
                "type": ["object", "null"],
                "description": "Platform → three-valued presence. ‘conditional’ carries the undecidable condition text — never a guess.",
                "additionalProperties": false,
                "patternProperties": {
                  "^(iOS|macOS|watchOS|tvOS|visionOS|macCatalyst|linux)$": {
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["state"],
                    "properties": {
                      "state": { "type": "string", "enum": ["present", "absent", "conditional"] },
                      "condition": { "type": "string" }
                    }
                  }
                }
              },
              "docSummary": { "type": ["string", "null"] },
              "hasMacroAttributes": { "type": "boolean" }
            }
          }
        },
        "stats": {
          "type": "object",
          "additionalProperties": false,
          "required": ["swiftFiles", "objcFiles", "declCount", "parseFailures", "manifestUnparsed", "hasBinaryTargets"],
          "properties": {
            "swiftFiles": { "type": "integer" },
            "objcFiles": { "type": "integer", "description": "ObjC files NOT parsed (implementations, private headers) — an honest blind spot" },
            "objcHeadersParsed": { "type": "integer", "description": "public ObjC headers turned into decls; absent/0 on pre-ObjC-pass surfaces" },
            "declCount": { "type": "integer" },
            "parseFailures": { "type": "integer" },
            "manifestUnparsed": { "type": "boolean" },
            "hasBinaryTargets": { "type": "boolean", "description": "the real fence may live in a binary — confidence cap" }
          }
        }
      }
    }
    """
}
