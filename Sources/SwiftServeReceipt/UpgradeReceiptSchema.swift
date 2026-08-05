import Foundation

public enum UpgradeReceiptSchema {
    public static let json = """
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://swiftserve.dev/schemas/upgrade-receipt-v1.json",
      "title": "SwiftServe Upgrade Receipt",
      "description": "Versioned dependency-change decision artifact. pass means no configured policy was violated, not universal safety.",
      "type": "object",
      "additionalProperties": false,
      "required": ["receiptVersion", "generatedAt", "verdict", "headline", "base", "head", "counts", "changes", "policy", "enrichment"],
      "properties": {
        "receiptVersion": { "type": "integer", "const": 1 },
        "generatedAt": { "type": "string" },
        "verdict": { "$ref": "#/$defs/verdict" },
        "headline": { "type": "string" },
        "base": { "$ref": "#/$defs/input" },
        "head": { "$ref": "#/$defs/input" },
        "counts": { "$ref": "#/$defs/counts" },
        "changes": { "type": "array", "items": { "$ref": "#/$defs/change" } },
        "policy": { "$ref": "#/$defs/policy" },
        "enrichment": { "$ref": "#/$defs/enrichment" }
      },
      "$defs": {
        "verdict": { "type": "string", "enum": ["pass", "review", "block"] },
        "severity": { "type": "string", "enum": ["info", "review", "block"] },
        "input": {
          "type": "object", "additionalProperties": false,
          "required": ["packageCount", "duplicateIdentities", "conflictingIdentities"],
          "properties": {
            "packageCount": { "type": "integer", "minimum": 0 },
            "duplicateIdentities": { "type": "array", "items": { "type": "string" } },
            "conflictingIdentities": { "type": "array", "items": { "type": "string" } }
          }
        },
        "counts": {
          "type": "object", "additionalProperties": false,
          "required": ["total", "byChangeType", "bySeverity"],
          "properties": {
            "total": { "type": "integer", "minimum": 0 },
            "byChangeType": {
              "type": "object", "additionalProperties": false,
              "required": ["added", "removed", "upgraded", "downgraded", "modified", "unknown"],
              "properties": {
                "added": { "type": "integer" }, "removed": { "type": "integer" },
                "upgraded": { "type": "integer" }, "downgraded": { "type": "integer" },
                "modified": { "type": "integer" }, "unknown": { "type": "integer" }
              }
            },
            "bySeverity": {
              "type": "object", "additionalProperties": false,
              "required": ["info", "review", "block"],
              "properties": { "info": { "type": "integer" }, "review": { "type": "integer" }, "block": { "type": "integer" } }
            }
          }
        },
        "pin": {
          "type": "object", "additionalProperties": false,
          "required": ["identity", "kind", "location", "pinType", "version", "branch", "revision"],
          "properties": {
            "identity": { "type": "string" },
            "kind": { "type": "string", "enum": ["remoteSourceControl", "localSourceControl", "registry", "unknown"] },
            "location": { "type": "string" },
            "pinType": { "type": "string", "enum": ["version", "branch", "revision", "unknown"] },
            "version": { "type": ["string", "null"] },
            "branch": { "type": ["string", "null"] },
            "revision": { "type": ["string", "null"] }
          }
        },
        "finding": {
          "type": "object", "additionalProperties": false,
          "required": ["code", "severity", "message"],
          "properties": {
            "code": { "type": "string", "enum": [\(findingCodes)] },
            "severity": { "$ref": "#/$defs/severity" },
            "message": { "type": "string" }
          }
        },
        "evidence": {
          "type": "object", "additionalProperties": false,
          "required": ["kind", "symbol", "file", "line", "condition", "permalink"],
          "properties": {
            "kind": { "type": "string" }, "symbol": { "type": ["string", "null"] },
            "file": { "type": ["string", "null"] }, "line": { "type": ["integer", "null"] },
            "condition": { "type": ["string", "null"] }, "permalink": { "type": ["string", "null"] }
          }
        },
        "capability": {
          "type": "object", "additionalProperties": false,
          "required": ["capability", "platform", "outcome", "baseStatus", "headStatus", "evidenceVersion", "detail", "evidence"],
          "properties": {
            "capability": { "type": ["string", "null"] }, "platform": { "type": ["string", "null"] },
            "outcome": { "type": "string", "enum": [\(capabilityOutcomes)] },
            "baseStatus": { "type": ["string", "null"], "enum": ["supported", "unsupported", "conditional", "unknown", null] },
            "headStatus": { "type": ["string", "null"], "enum": ["supported", "unsupported", "conditional", "unknown", null] },
            "evidenceVersion": { "type": ["string", "null"] }, "detail": { "type": "string" },
            "evidence": { "type": "array", "items": { "$ref": "#/$defs/evidence" } }
          }
        },
        "healthDelta": {
          "type": "object", "additionalProperties": false,
          "required": ["baseScore", "headScore", "delta", "latestVersion"],
          "properties": {
            "baseScore": { "type": "integer" }, "headScore": { "type": "integer" },
            "delta": { "type": "integer" }, "latestVersion": { "type": ["string", "null"] }
          }
        },
        "change": {
          "type": "object", "additionalProperties": false,
          "required": ["identity", "changeType", "classification", "severity", "findings", "oldPin", "newPin", "healthDelta", "capabilityChecks"],
          "properties": {
            "identity": { "type": "string" },
            "changeType": { "type": "string", "enum": ["added", "removed", "upgraded", "downgraded", "modified", "unknown"] },
            "classification": { "type": "string", "enum": [\(classifications)] },
            "severity": { "$ref": "#/$defs/severity" },
            "findings": { "type": "array", "items": { "$ref": "#/$defs/finding" } },
            "oldPin": { "anyOf": [{ "$ref": "#/$defs/pin" }, { "type": "null" }] },
            "newPin": { "anyOf": [{ "$ref": "#/$defs/pin" }, { "type": "null" }] },
            "healthDelta": { "anyOf": [{ "$ref": "#/$defs/healthDelta" }, { "type": "null" }] },
            "capabilityChecks": { "type": "array", "items": { "$ref": "#/$defs/capability" } }
          }
        },
        "policy": {
          "type": "object", "additionalProperties": false,
          "required": ["source", "version", "passed", "violations"],
          "properties": {
            "source": { "type": "string" }, "version": { "type": "integer", "const": 1 },
            "passed": { "type": "boolean" }, "violations": { "type": "array", "items": { "type": "string" } }
          }
        },
        "enrichment": {
          "type": "object", "additionalProperties": false,
          "required": ["source", "networkUsed", "capabilityRecheckRequested", "capabilityRecheckExecuted", "unavailablePackages"],
          "properties": {
            "source": { "type": "string" }, "networkUsed": { "type": "boolean" },
            "capabilityRecheckRequested": { "type": "boolean" }, "capabilityRecheckExecuted": { "type": "boolean" },
            "unavailablePackages": { "type": "array", "items": { "type": "string" } }
          }
        }
      }
    }
    """

    private static let findingCodes = FindingCode.allCases
        .map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
    private static let capabilityOutcomes = CapabilityImpactOutcome.allCases
        .map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
    private static let classifications = UpdateClassification.allCases
        .map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
}
