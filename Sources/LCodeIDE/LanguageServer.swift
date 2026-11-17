import Foundation
import LCodeKit

/// A completion item.
struct CompletionItem {
    enum Kind { case type, function, property, keyword, variable, other }
    let label: String
    let detail: String
    let insertText: String
    let kind: Kind
    let filterText: String
    /// Explicit replacement start column (UTF-16) on the cursor line, if provided.
    let replaceStart: Int?
    let sortText: String
}

/// sourcekit-lsp client, run on the project's preview copy (built against LSim's SwiftUI API), used for completion.
final class LanguageServer {
    private let build: PreviewBuild
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: ([String: Any]?) -> Void] = [:]
    private var versions: [String: Int] = [:]
    private var initialized = false
    private var queued: [() -> Void] = []
    private let lock = NSLock()

    init(build: PreviewBuild) {
        self.build = build
    }

    // MARK: - Startup

    func start() {
        guard process == nil else { return }
        _ = try? build.prepare()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["sourcekit-lsp"]
        p.currentDirectoryURL = build.directory
        p.environment = Runner.environment
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.receive(data)
        }
        do { try p.run() } catch { return }
        process = p
        input = inPipe.fileHandleForWriting
        let params: [String: Any] = [
            "processId": Int(getpid()),
            "rootUri": build.directory.absoluteString,
            "capabilities": [
                "textDocument": ["completion": ["completionItem": ["snippetSupport": false]]],
            ],
        ]
        request("initialize", params) { [weak self] _ in
            guard let self else { return }
            self.notify("initialized", [:])
            self.initialized = true
            let q = self.queued
            self.queued = []
            q.forEach { $0() }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    // MARK: - Documents

    /// URI of a source file's copy (the one the server compiles).
    private func uri(for url: URL) -> String? { build.copyURL(for: url)?.absoluteString }

    /// Sends the current text, rewritten like the copy (previews, @main), to the server.
    func update(_ url: URL, text: String) {
        guard let uri = uri(for: url) else { return }
        let transformed = PreviewTransform.transform(text, removeMain: build.isAppFile(url), firstIndex: 0).text
        let send = { [weak self] in
            guard let self else { return }
            if let v = self.versions[uri] {
                self.versions[uri] = v + 1
                self.notify("textDocument/didChange", [
                    "textDocument": ["uri": uri, "version": v + 1],
                    "contentChanges": [["text": transformed]],
                ])
            } else {
                self.versions[uri] = 1
                self.notify("textDocument/didOpen", [
                    "textDocument": ["uri": uri, "languageId": "swift", "version": 1, "text": transformed],
                ])
            }
        }
        if initialized { send() } else { queued.append(send) }
    }

    /// Completions at a 0-based line and UTF-16 column.
    func complete(_ url: URL, text: String, line: Int, character: Int, completion: @escaping ([CompletionItem]) -> Void) {
        guard let uri = uri(for: url) else { completion([]); return }
        update(url, text: text)
        let ask: () -> Void = { [weak self] in
            self?.request("textDocument/completion", [
                "textDocument": ["uri": uri],
                "position": ["line": line, "character": character],
            ]) { result in
                // Server ranking (sortText), minus duplicates (same inherited signature).
                var seen = Set<String>()
                let items = ((result?["items"] as? [[String: Any]]) ?? []).map(Self.item)
                    .sorted { $0.sortText < $1.sortText }
                    .filter { seen.insert($0.label).inserted }
                completion(Array(items.prefix(100)))
            }
        }
        if initialized { ask() } else { queued.append(ask) }
    }

    private static func item(_ d: [String: Any]) -> CompletionItem {
        let label = (d["label"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        var insert = d["insertText"] as? String ?? label
        var start: Int?
        if let edit = d["textEdit"] as? [String: Any], let newText = edit["newText"] as? String {
            insert = newText
            start = ((edit["range"] as? [String: Any])?["start"] as? [String: Any])?["character"] as? Int
        }
        // Strip placeholders like `${1:value}` or `<#value#>`.
        insert = insert.replacingOccurrences(of: #"\$\{\d+:([^}]*)\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<#[^#]*#>"#, with: "", options: .regularExpression)
        let kind: CompletionItem.Kind
        switch d["kind"] as? Int ?? 0 {
        case 7, 22, 13, 8, 25: kind = .type          // class, struct, enum, interface, typeParameter
        case 2, 3, 4: kind = .function               // method, function, constructor
        case 5, 10: kind = .property                 // field, property
        case 14: kind = .keyword
        case 6, 21: kind = .variable                 // variable, constant
        default: kind = .other
        }
        return CompletionItem(label: label, detail: d["detail"] as? String ?? "", insertText: insert, kind: kind,
                              filterText: d["filterText"] as? String ?? label, replaceStart: start,
                              sortText: d["sortText"] as? String ?? label)
    }

    // MARK: - JSON-RPC

    private func request(_ method: String, _ params: [String: Any], _ handler: @escaping ([String: Any]?) -> Void) {
        lock.lock()
        let id = nextID
        nextID += 1
        pending[id] = handler
        lock.unlock()
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private static let debug = ProcessInfo.processInfo.environment["LCODE_DEBUG"] != nil
    private func log(_ s: @autoclosure () -> String) { if Self.debug { FileHandle.standardError.write(Data(("[lsp] " + s() + "\n").utf8)) } }

    private func send(_ message: [String: Any]) {
        log("→ \(message["method"] ?? "response") \(message["id"] ?? "")")
        guard let input, let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? input.write(contentsOf: Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while true {
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            guard let lengthLine = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length") }),
                  let length = Int(lengthLine.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") else {
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                continue
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return }
            let body = buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)]
            buffer.removeSubrange(buffer.startIndex..<buffer.index(bodyStart, offsetBy: length))
            guard let message = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] else { continue }
            if let id = message["id"] as? Int, message["method"] == nil {
                lock.lock()
                let handler = pending.removeValue(forKey: id)
                lock.unlock()
                log("← \(id) \((message["result"] as? [String: Any])?["items"].map { "\(($0 as? [Any])?.count ?? 0) items" } ?? String(describing: message["error"] ?? ""))")
                let result = message["result"] as? [String: Any]
                    ?? (message["result"] as? [[String: Any]]).map { ["items": $0] }
                onMain { handler?(result) }
            } else if let id = message["id"], message["method"] != nil {
                // Server request (capability registration…): reply with an empty result.
                send(["jsonrpc": "2.0", "id": id, "result": NSNull()])
            }
        }
    }
}
