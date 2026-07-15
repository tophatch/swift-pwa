import Foundation
import SwiftPWACore

/// Generates a typed TypeScript client from a set of ``CommandDescriptor``s (the
/// `__bridge.describe` catalog). The output wraps `__SWIFT_PWA__` so call sites
/// get typed command names, payloads, and results across all three call shapes
/// (unary / stream / session), replacing the stringly-typed envelope.
///
/// Pure: descriptors in, one `.ts` module string out — no I/O, so it's unit-
/// testable without a headless app run. The CLI (`swift-pwa codegen`) supplies
/// the descriptors (via the `SWIFT_PWA_DESCRIBE` dump) and writes the file.
public enum TypeScriptClientGenerator {
    public static func generate(_ descriptors: [CommandDescriptor]) -> String {
        let sorted = descriptors.sorted { $0.name < $1.name }

        // Collect every named object / enum reachable from any descriptor, so
        // each becomes one emitted declaration (dedup by name).
        var named: [String: BridgeSchema] = [:]
        for d in sorted {
            collectNamed(d.args, into: &named)
            collectNamed(d.result, into: &named)
            if let inbound = d.inbound { collectNamed(inbound, into: &named) }
        }

        var out = header()
        out += preamble()
        for name in named.keys.sorted() {
            out += declaration(for: named[name]!)
            out += "\n"
        }
        out += clientFactory(sorted)
        return out
    }

    // MARK: - Named type collection

    private static func collectNamed(_ schema: BridgeSchema, into named: inout [String: BridgeSchema]) {
        switch schema {
        case let .optional(inner), let .array(inner), let .dictionary(inner):
            collectNamed(inner, into: &named)
        case let .object(name, fields):
            if named[name] == nil {
                named[name] = schema
                for f in fields { collectNamed(f.schema, into: &named) }
            }
        case let .stringEnum(name, _):
            named[name] = schema
        case .unknown, .void, .bool, .int, .double, .string:
            break
        }
    }

    // MARK: - Type expressions

    /// The TS type expression for a schema (a reference, not a declaration).
    private static func tsType(_ schema: BridgeSchema) -> String {
        switch schema {
        case .unknown: "unknown"
        case .void: "void"
        case .bool: "boolean"
        case .int, .double: "number"
        case .string: "string"
        case let .optional(inner): "\(tsType(inner)) | null"
        case let .array(inner): "Array<\(tsType(inner))>"
        case let .dictionary(value): "Record<string, \(tsType(value))>"
        case let .object(name, _): name
        case let .stringEnum(name, _): name
        }
    }

    private static func declaration(for schema: BridgeSchema) -> String {
        switch schema {
        case let .object(name, fields):
            var s = "export interface \(name) {\n"
            for f in fields {
                // A `.optional` field becomes `name?: T` (idiomatic TS) rather
                // than `name: T | null`.
                if case let .optional(inner) = f.schema {
                    s += "  \(f.name)?: \(tsType(inner));\n"
                } else {
                    s += "  \(f.name): \(tsType(f.schema));\n"
                }
            }
            s += "}\n"
            return s
        case let .stringEnum(name, cases):
            let union = cases.isEmpty ? "never" : cases.map { "\"\($0)\"" }.joined(separator: " | ")
            return "export type \(name) = \(union);\n"
        default:
            return ""
        }
    }

    // MARK: - Client factory

    /// One node of the dotted-command-name tree (`window.setTitle` →
    /// `window` node → `setTitle` leaf).
    private final class Node {
        var command: CommandDescriptor?
        var children: [String: Node] = [:]
        func child(_ key: String) -> Node {
            if let existing = children[key] { return existing }
            let node = Node()
            children[key] = node
            return node
        }
    }

    private static func clientFactory(_ descriptors: [CommandDescriptor]) -> String {
        let root = Node()
        for d in descriptors {
            var node = root
            for segment in d.name.split(separator: ".").map(String.init) {
                node = node.child(segment)
            }
            node.command = d
        }
        var out = "export function createBridge(raw: RawBridge) {\n  return "
        out += emitNode(root, indent: "  ")
        out += ";\n}\n"
        return out
    }

    private static func emitNode(_ node: Node, indent: String) -> String {
        var out = "{\n"
        let inner = indent + "  "
        for key in node.children.keys.sorted() {
            let child = node.children[key]!
            let prop = tsPropertyName(key)
            if let command = child.command, child.children.isEmpty {
                out += "\(inner)\(prop): \(method(command)),\n"
            } else {
                out += "\(inner)\(prop): \(emitNode(child, indent: inner)),\n"
            }
        }
        out += "\(indent)}"
        return out
    }

    /// The typed method expression for one command.
    private static func method(_ d: CommandDescriptor) -> String {
        let quotedName = "\"\(d.name)\""
        switch d.kind {
        case .unary:
            let ret = d.result == .void ? "void" : tsType(d.result)
            let (params, callArgs) = argParam(d.args)
            return "(\(params)): Promise<\(ret)> => raw.invoke(\(quotedName)\(callArgs))"
        case .stream:
            let chunk = tsType(d.result)
            let (params, callArgs) = argParam(d.args)
            let sep = params.isEmpty ? "" : ", "
            return "(\(params)\(sep)onChunk: (chunk: \(chunk)) => void, onError?: (e: BridgeError) => void, "
                + "onEnd?: () => void): Unsubscribe => "
                + "raw.subscribe(\(quotedName)\(callArgs), onChunk, onError, onEnd)"
        case .session:
            let event = tsType(d.result)
            let frame = d.inbound.map(tsType) ?? "unknown"
            let (params, callArgs) = argParam(d.args, label: "open")
            let sep = params.isEmpty ? "" : ", "
            return "(\(params)\(sep)handlers: SessionHandlers<\(event)>): BridgeSession<\(frame)> => "
                + "raw.session(\(quotedName)\(callArgs), handlers)"
        }
    }

    /// Returns the parameter declaration and the trailing call-argument fragment
    /// for a command's args schema. `.void` → no parameter; else a typed one.
    private static func argParam(_ schema: BridgeSchema, label: String = "args") -> (params: String, call: String) {
        switch schema {
        case .void: ("", "")
        case .unknown: ("\(label)?: unknown", ", \(label)")
        default: ("\(label): \(tsType(schema))", ", \(label)")
        }
    }

    private static func tsPropertyName(_ key: String) -> String {
        let ok = !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
            && !(key.first?.isNumber ?? true)
        return ok ? key : "\"\(key)\""
    }

    // MARK: - Boilerplate

    private static func header() -> String {
        """
        // Generated by `swift-pwa codegen` — DO NOT EDIT BY HAND.
        //
        // Typed client over the __SWIFT_PWA__ bridge. Regenerate whenever the
        // registered command set changes.
        /* eslint-disable */

        """
    }

    private static func preamble() -> String {
        """

        export type Unsubscribe = () => void;
        export interface BridgeError { code: string; message: string; }
        export interface BridgeSession<Frame> { push: (frame: Frame) => void; close: () => void; }
        export interface SessionHandlers<Event> {
          onChunk?: (event: Event) => void;
          onError?: (e: BridgeError) => void;
          onEnd?: () => void;
        }

        /** The raw, untyped __SWIFT_PWA__ surface this client wraps. */
        export interface RawBridge {
          invoke: (cmd: string, args?: unknown) => Promise<any>;
          subscribe: (
            cmd: string,
            args: unknown,
            onChunk: (chunk: any) => void,
            onError?: (e: BridgeError) => void,
            onEnd?: () => void,
          ) => Unsubscribe;
          session: (
            cmd: string,
            openArgs: unknown,
            handlers: SessionHandlers<any>,
          ) => BridgeSession<any>;
        }

        """
    }
}
