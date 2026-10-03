import Foundation

// MARK: - Shared diagnostic log helpers

/// Escapes ASCII control characters so log lines can't inject terminal sequences.
func escapedForLog(_ s: String) -> String {
    s.unicodeScalars.map { sc -> String in
        let v = sc.value
        return (v < 0x20 || v == 0x7F) ? "\\u\(String(format: "%04X", v))" : String(sc)
    }.joined()
}

/// Log writes happen off the main thread, one at a time, in call order.
private let logQueue = DispatchQueue(label: "compagnon.log", qos: .utility)

/// Appends one timestamped line to `~/Library/Logs/Kumo/<fileName>`, in the background.
/// - Log directory is created at mode 0700.
/// - Log file is set to mode 0600 on first creation and after each rotation.
/// - File is rotated (truncated) when it reaches 1 MB.
func appendAppLog(_ fileName: String, _ message: String,
                  timestampFormat: String = "yyyy-MM-dd HH:mm:ss") {
    let now = Date()
    logQueue.async { writeLogLine(fileName, message, now, timestampFormat) }
}

private func writeLogLine(_ fileName: String, _ message: String, _ date: Date, _ timestampFormat: String) {
    let fm = FileManager.default
    let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Kumo")
    let logFile = logsDir.appendingPathComponent(fileName)
    let f = DateFormatter(); f.dateFormat = timestampFormat
    let line = "\(f.string(from: date)) \(escapedForLog(message))\n"
    guard let data = line.data(using: .utf8) else { return }
    let maxLogBytes = 1_048_576 // 1 MB
    if let size = (try? fm.attributesOfItem(atPath: logFile.path)[.size]) as? Int {
        // Rotate when the file reaches the limit
        if size >= maxLogBytes {
            try? fm.removeItem(at: logFile)
            try? data.write(to: logFile, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600 as NSNumber], ofItemAtPath: logFile.path)
            return
        }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    } else {
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: logsDir.path)
        try? data.write(to: logFile, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600 as NSNumber], ofItemAtPath: logFile.path)
    }
}
