import AppKit
// 用于验收界面流程的最小应用：每 2 秒用 URLSession（Network.framework）和 HTTP3 取出口地址，写日志。
let log = "/tmp/guardprobe.log"
func write(_ s: String) { let h = FileHandle(forWritingAtPath: log) ?? { FileManager.default.createFile(atPath: log, contents: nil); return FileHandle(forWritingAtPath: log)! }(); h.seekToEndOfFile(); h.write(Data((s+"\n").utf8)) }
let d = ISO8601DateFormatter()
final class A: NSObject, NSApplicationDelegate {
  var w: NSWindow!
  func applicationDidFinishLaunching(_ n: Notification) {
    w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 120), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    w.title = "Guard Probe"; w.makeKeyAndOrderFront(nil)
    write("\(d.string(from: Date())) START pid=\(getpid()) gid=\(getegid())")
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
      for (k, u, h3) in [("h1","https://1.1.1.1/cdn-cgi/trace",false),("h3","https://cloudflare-quic.com/cdn-cgi/trace",true)] {
        var r = URLRequest(url: URL(string: u)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5); r.assumesHTTP3Capable = h3
        let c = URLSessionConfiguration.ephemeral; let s = URLSession(configuration: c)
        s.dataTask(with: r) { data, _, e in
          let t = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
          write("\(d.string(from: Date())) \(k) " + (t.split(separator: "\n").filter { $0.hasPrefix("ip=") || $0.hasPrefix("http=") }.joined(separator: " ").isEmpty ? "ERR \((e as NSError?)?.code ?? 0)" : t.split(separator: "\n").filter { $0.hasPrefix("ip=") || $0.hasPrefix("http=") }.joined(separator: " ")))
        }.resume(); s.finishTasksAndInvalidate()
      }
    }
  }
}
let app = NSApplication.shared; let a = A(); app.delegate = a; app.setActivationPolicy(.regular); app.run()
