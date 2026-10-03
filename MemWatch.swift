// MemWatch: a tiny menu bar app that answers "is my Mac fast or slow right now?"
// and shows which apps are to blame. Build with ./build.sh.
//
// Built to cost almost nothing: while the popover is closed it only reads a few
// kernel counters every 5 s. Per-app numbers come from libproc and Docker's own
// socket, and only while the popover is open. No child processes are spawned.

import SwiftUI
import Darwin

let gb = 1_073_741_824.0
let dockerSocket = NSHomeDirectory() + "/.docker/run/docker.sock"

// MARK: - Types

enum Verdict: Int, Comparable {
    case smooth, busy, slow

    static func < (a: Verdict, b: Verdict) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .smooth: return "Running smoothly"
        case .busy: return "A bit busy"
        case .slow: return "Slowing down"
        }
    }
    var symbol: String {
        switch self {
        case .smooth: return "checkmark.circle.fill"
        case .busy: return "exclamationmark.circle.fill"
        case .slow: return "exclamationmark.triangle.fill"
        }
    }
    var gauge: String {
        switch self {
        case .smooth: return "gauge.with.dots.needle.33percent"
        case .busy: return "gauge.with.dots.needle.67percent"
        case .slow: return "gauge.with.dots.needle.100percent"
        }
    }
    var color: Color {
        switch self {
        case .smooth: return .green
        case .busy: return .orange
        case .slow: return .red
        }
    }
    var nsColor: NSColor {
        switch self {
        case .smooth: return .systemGreen
        case .busy: return .systemOrange
        case .slow: return .systemRed
        }
    }
}

struct AppUsage: Identifiable {
    var id: String { name }
    let name: String
    let bundlePath: String?  // the .app to take the icon from and to quit
    let mb: Double
    let cpu: Double  // percent of one core, summed over the app's processes
    let count: Int
    let isSystem: Bool  // part of macOS, nothing to act on

    var isDockerVM: Bool { name == "Docker VM" }
}

// Cheap system numbers, sampled every tick.
struct Sample {
    var pressure: Int32 = 1  // kernel level: 1 normal, 2 warn, 4 critical
    var memUsed = 0.0  // GB, the "Memory Used" Activity Monitor shows
    var total = 0.0  // GB
    var swapUsed = 0.0  // GB
    var cpuTicks: (busy: UInt64, total: UInt64) = (0, 0)
}

struct Container: Identifiable {
    var id: String { name }
    let name: String
    let image: String
    let project: String  // compose project, "" if none
    let port: Int?  // first published host port
    let uptime: String  // "8 days", "31 min"
    var cpu: Double? = nil
    var mb: Double? = nil

    // Databases and caches go first when starting things back up.
    var isInfra: Bool {
        ["postgres", "redis", "mysql", "mariadb", "mongo"].contains { image.hasPrefix($0) }
    }

    // "website-v2-web" -> "web": the project row already names the project.
    var shortImage: String {
        guard !project.isEmpty, image.hasPrefix(project + "-") else { return image }
        return String(image.dropFirst(project.count + 1))
    }
}

func formatMB(_ mb: Double) -> String {
    // From 1000 MB up, GB reads better than "1010 MB".
    mb >= 1000 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
}

// MARK: - System sample (kernel counters, microseconds)

func sampleSystem() -> Sample {
    var s = Sample()
    s.total = Double(ProcessInfo.processInfo.physicalMemory) / gb

    var level: Int32 = 1
    var size = MemoryLayout<Int32>.size
    if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
        s.pressure = level
    }

    var swap = xsw_usage()
    size = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
        s.swapUsed = Double(swap.xsu_used) / gb
    }

    var vm = vm_statistics64()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    if kr == KERN_SUCCESS {
        let page = Double(vm_kernel_page_size)
        let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
        let pages = app + Double(vm.wire_count) + Double(vm.compressor_page_count)
        s.memUsed = pages * page / gb
    }

    var cpu = host_cpu_load_info()
    var cpuCount = mach_msg_type_number_t(
        MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let ckr = withUnsafeMutablePointer(to: &cpu) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cpuCount)
        }
    }
    if ckr == KERN_SUCCESS {
        let t = cpu.cpu_ticks
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)  // user, system, nice
        s.cpuTicks = (busy, busy + UInt64(t.2))  // + idle
    }
    return s
}

// MARK: - Per-app scan (libproc, ~3 ms for all processes)

// Group helpers under their app: ".../Google Chrome.app/.../Helper" -> "Google Chrome".
func appGroup(_ path: String) -> (name: String, bundle: String?) {
    if path.contains("Virtualization.VirtualMachine") {
        return ("Docker VM", "/Applications/Docker.app")
    }
    if path.contains("com.apple.WebKit") {
        return ("Safari & WebKit", "/Applications/Safari.app")
    }
    if path.hasSuffix("/claude") || path.contains("/claude/versions/") { return ("Claude Code", nil) }
    // Plain string slicing: URL(fileURLWithPath:) stats the disk to check for a directory.
    if let r = path.range(of: ".app/") {
        let bundle = String(path[..<r.lowerBound])
        let name = bundle.split(separator: "/").last.map(String.init) ?? bundle
        return (name, bundle + ".app")
    }
    return (path.split(separator: "/").last.map(String.init) ?? path, nil)
}

// Keeps the previous CPU times so each scan can turn them into a percentage.
// Only touched from Model's background queue.
final class ProcScanner: @unchecked Sendable {
    private var lastCPU: [pid_t: UInt64] = [:]  // ns
    private var lastWall: UInt64 = 0  // ns
    // pid -> app it belongs to. Worked out once per process, not every scan.
    private var owners: [pid_t: (name: String, bundle: String?, system: Bool)] = [:]
    private let ticksToNs: Double = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()
    private let systemDirs = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"]

    // Processes owned by other users (WindowServer, daemons) can't be read
    // without root; they're macOS internals you couldn't quit anyway.
    func scan() -> [AppUsage] {
        let now = UInt64(Double(mach_absolute_time()) * ticksToNs)
        let wall = lastWall > 0 ? Double(now - lastWall) : 0
        lastWall = now

        let n = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(n) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))

        var cpuNow: [pid_t: UInt64] = [:]
        var seen: [pid_t: (name: String, bundle: String?, system: Bool)] = [:]
        var groups: [String: (bundle: String?, mb: Double, cpu: Double, count: Int, system: Bool)] = [:]
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)

        for pid in pids.prefix(Int(max(got, 0))) where pid > 0 {
            var ri = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard ok == 0 else { continue }

            let t = UInt64(Double(ri.ri_user_time + ri.ri_system_time) * ticksToNs)
            cpuNow[pid] = t
            var cpu = 0.0
            if wall > 0, let prev = lastCPU[pid], t >= prev { cpu = Double(t - prev) / wall * 100 }
            let mb = Double(ri.ri_phys_footprint) / 1_048_576
            guard mb >= 1 || cpu > 0 else { continue }

            let owner: (name: String, bundle: String?, system: Bool)
            if let o = owners[pid] {
                owner = o
            } else {
                guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
                let path = String(cString: buf)
                let (name, bundle) = appGroup(path)
                let system = systemDirs.contains { path.hasPrefix($0) }
                    && name != "Docker VM" && name != "Safari & WebKit"
                owner = (name, bundle, system)
            }
            seen[pid] = owner

            let g = groups[owner.name] ?? (owner.bundle, 0, 0, 0, true)
            groups[owner.name] = (g.bundle, g.mb + mb, g.cpu + cpu, g.count + 1, g.system && owner.system)
        }
        lastCPU = cpuNow
        owners = seen  // drops exited pids, so a reused pid gets looked up again

        return groups.map {
            AppUsage(name: $0.key, bundlePath: $0.value.bundle, mb: $0.value.mb,
                     cpu: $0.value.cpu, count: $0.value.count, isSystem: $0.value.system)
        }
    }
}

// MARK: - Docker (Engine API over its unix socket, no CLI)

enum Docker {
    // Minimal HTTP/1.0 over the socket: the server closes the connection after
    // one response, so there is no chunking or keep-alive to deal with.
    static func request(_ method: String, _ path: String, timeout: Int = 3) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(dockerSocket.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let req = "\(method) \(path) HTTP/1.0\r\nHost: docker\r\nContent-Length: 0\r\n\r\n"
        guard req.withCString({ write(fd, $0, strlen($0)) }) > 0 else { return nil }

        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            data.append(chunk, count: n)
        }
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8),
              let code = head.split(separator: " ").dropFirst().first.flatMap({ Int($0) }),
              (200..<300).contains(code) else { return nil }
        return data[split.upperBound...]
    }

    static func json(_ path: String) -> Any? {
        request("GET", path).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    static var isUp: Bool {
        request("GET", "/_ping", timeout: 1).map { String(decoding: $0, as: UTF8.self) } == "OK"
    }

    static func stop(_ name: String) { _ = request("POST", "/containers/\(name)/stop", timeout: 30) }
    static func start(_ name: String) { _ = request("POST", "/containers/\(name)/start", timeout: 30) }

    // "Up 9 hours (healthy)" -> "9 hr", "Up About an hour" -> "1 hr"
    static func shortUptime(_ status: String) -> String {
        var s = status.replacingOccurrences(of: "Up ", with: "")
            .replacingOccurrences(of: "About ", with: "")
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        for (long, short) in [("an ", "1 "), ("a ", "1 "), (" minutes", " min"), (" minute", " min"),
                              (" hours", " hr"), (" hour", " hr"), (" seconds", " sec"),
                              ("Less than 1 second", "just now")] {
            s = s.replacingOccurrences(of: long, with: short)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

// Lists running containers with CPU and memory. Keeps the previous CPU counters
// because one-shot stats carry no "previous" sample of their own.
final class DockerScanner: @unchecked Sendable {
    private var lastCPU: [String: (container: UInt64, system: UInt64)] = [:]

    func scan() -> [Container]? {
        guard let list = Docker.json("/containers/json") as? [[String: Any]] else { return nil }
        var next: [String: (UInt64, UInt64)] = [:]
        let containers: [Container] = list.compactMap { c in
            guard let name = (c["Names"] as? [String])?.first?.trimmingCharacters(in: ["/"])
            else { return nil }
            let labels = c["Labels"] as? [String: String] ?? [:]
            let port = (c["Ports"] as? [[String: Any]])?.compactMap { $0["PublicPort"] as? Int }.first
            var item = Container(
                name: name, image: c["Image"] as? String ?? "",
                project: labels["com.docker.compose.project"] ?? "", port: port,
                uptime: Docker.shortUptime(c["Status"] as? String ?? ""))

            if let st = Docker.json("/containers/\(name)/stats?stream=false&one-shot=true")
                as? [String: Any] {
                let mem = st["memory_stats"] as? [String: Any] ?? [:]
                let usage = (mem["usage"] as? NSNumber)?.doubleValue ?? 0
                let inactive = ((mem["stats"] as? [String: Any])?["inactive_file"] as? NSNumber)?
                    .doubleValue ?? 0
                item.mb = max(usage - inactive, 0) / 1_048_576

                let cs = st["cpu_stats"] as? [String: Any] ?? [:]
                let total = ((cs["cpu_usage"] as? [String: Any])?["total_usage"] as? NSNumber)?
                    .uint64Value ?? 0
                let system = (cs["system_cpu_usage"] as? NSNumber)?.uint64Value ?? 0
                let cpus = Double((cs["online_cpus"] as? NSNumber)?.intValue ?? 1)
                if let prev = lastCPU[name], system > prev.system, total >= prev.container {
                    item.cpu = Double(total - prev.container) / Double(system - prev.system) * cpus * 100
                }
                next[name] = (total, system)
            }
            return item
        }
        lastCPU = next
        return containers
    }
}

// MARK: - Model

// Only the menu bar icon watches this, so it redraws only when the verdict flips.
@MainActor
final class Status: ObservableObject {
    @Published var verdict = Verdict.smooth
}

@MainActor
final class Model: ObservableObject {
    static let tick = 5.0  // seconds, system counters
    static let openTick = 2.0  // seconds, apps while the popover is open
    static let historyLength = 180  // 15 minutes of system ticks

    let status = Status()

    // Data refreshed on timers. Not @Published: refresh() sends one change
    // notification per update, and none at all while the popover is closed.
    private(set) var sample = Sample()
    private(set) var cpuHistory: [Double] = []  // percent busy
    private(set) var memHistory: [Double] = []  // GB used
    private(set) var swapHistory: [Double] = []  // GB
    private(set) var apps: [AppUsage] = []
    private(set) var containers: [Container] = []  // running
    private(set) var reasons: [String] = []

    // State the user changes.
    @Published var stoppedHere: [Container] = []  // stopped from this popover, offered for Start
    @Published var busy: Set<String> = []  // containers being stopped or started
    @Published var expanded: Set<String> = []  // projects shown open
    @Published var restartStatus: String?  // non-nil while restarting Docker
    @Published var confirmRestart = false

    private(set) var isOpen = false
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var systemTimer: Timer?
    private var appTimer: Timer?
    private var openTicks = 0
    private let queue = DispatchQueue(label: "memwatch.scan", qos: .utility)
    private let procs = ProcScanner()
    private let docker = DockerScanner()

    init() {
        tickSystem()
        systemTimer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickSystem() }
        }
        systemTimer?.tolerance = 1  // let macOS batch our wakeups with others
    }

    // MARK: Open / close

    func opened() {
        guard !isOpen else { return }
        isOpen = true
        openTicks = 0
        scanApps()
        // A second scan soon after, so CPU percentages have a baseline to diff against.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.scanApps() }
        appTimer = Timer.scheduledTimer(withTimeInterval: Self.openTick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanApps() }
        }
        appTimer?.tolerance = 0.3
        objectWillChange.send()
    }

    // Popover closed: stop scanning and start fresh next time.
    func closed() {
        isOpen = false
        appTimer?.invalidate()
        appTimer = nil
        expanded = []
        stoppedHere = []
        confirmRestart = false
    }

    // MARK: Sampling

    var cpuNow: Double { cpuHistory.last ?? 0 }

    // Swap change over the last two minutes, in GB.
    var swapTrend: Double {
        guard let last = swapHistory.last else { return 0 }
        let back = min(swapHistory.count - 1, Int(120 / Self.tick))
        return last - swapHistory[swapHistory.count - 1 - back]
    }

    var pressureLabel: String {
        switch sample.pressure {
        case 4: return "Critical"
        case 2: return "Elevated"
        default: return "Normal"
        }
    }

    private func tickSystem() {
        let s = sampleSystem()
        sample = s
        if let last = lastTicks, s.cpuTicks.total > last.total {
            let pct = Double(s.cpuTicks.busy - last.busy) / Double(s.cpuTicks.total - last.total) * 100
            push(&cpuHistory, pct)
        }
        lastTicks = s.cpuTicks
        push(&memHistory, s.memUsed)
        push(&swapHistory, s.swapUsed)
        judge()
        if isOpen { objectWillChange.send() }
    }

    func scanApps() {
        guard isOpen else { return }
        let withDocker = restartStatus == nil && openTicks % 2 == 0  // every 4 s
        openTicks += 1
        queue.async { [procs, docker] in
            let apps = procs.scan()
            let hasVM = apps.contains { $0.isDockerVM }
            let containers = withDocker && hasVM ? docker.scan() : nil
            DispatchQueue.main.async {
                self.apps = apps
                if !hasVM && self.restartStatus == nil {
                    self.containers = []
                } else if let containers {
                    self.containers = containers
                    self.stoppedHere.removeAll { c in containers.contains { $0.name == c.name } }
                }
                if self.isOpen { self.objectWillChange.send() }
            }
        }
    }

    private func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > Self.historyLength { a.removeFirst(a.count - Self.historyLength) }
    }

    // macOS's own pressure level is the best memory signal; growing swap means
    // it is paging right now; CPU counts only when it stays high for 30s.
    private func judge() {
        var v = Verdict.smooth
        var why: [String] = []
        let recentCPU = cpuHistory.suffix(Int(30 / Self.tick))
        let cpu = recentCPU.isEmpty ? 0 : recentCPU.reduce(0, +) / Double(recentCPU.count)

        switch sample.pressure {
        case 4: v = .slow; why.append("Memory is critically low")
        case 2: v = max(v, .busy); why.append("Memory is getting tight")
        default: break
        }
        if swapTrend > 0.25 {
            v = .slow; why.append("Swapping to disk")
        } else if swapTrend > 0.06 {
            v = max(v, .busy); why.append("Swap is growing")
        }
        if cpu > 90 {
            v = .slow; why.append(String(format: "CPU maxed out (%.0f%%)", cpu))
        } else if cpu > 70 {
            v = max(v, .busy); why.append(String(format: "CPU working hard (%.0f%%)", cpu))
        }
        reasons = why
        if status.verdict != v { status.verdict = v }
    }

    // MARK: Docker

    var dockerVM: AppUsage? { apps.first { $0.isDockerVM } }

    // Running and just-stopped containers, grouped by compose project.
    var projects: [(name: String, items: [Container])] {
        Dictionary(grouping: containers + stoppedHere, by: \.project)
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.name < $1.name }
    }

    func isStopped(_ c: Container) -> Bool { stoppedHere.contains { $0.name == c.name } }

    // Memory the VM holds beyond what its containers use, once stats are in.
    var vmSlackMB: Double? {
        guard let vm = dockerVM, !containers.isEmpty,
              containers.allSatisfy({ $0.mb != nil }) else { return nil }
        return vm.mb - containers.reduce(0) { $0 + ($1.mb ?? 0) }
    }

    func toggle(_ project: String) {
        if expanded.contains(project) { expanded.remove(project) } else { expanded.insert(project) }
    }

    func stop(_ names: [String]) {
        guard !names.isEmpty else { return }
        busy.formUnion(names)
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: names.count) { Docker.stop(names[$0]) }
            DispatchQueue.main.async {
                self.busy.subtract(names)
                let gone = self.containers.filter { names.contains($0.name) }
                self.containers.removeAll { names.contains($0.name) }
                self.stoppedHere += gone
                self.scanApps()
            }
        }
    }

    func start(_ names: [String]) {
        guard !names.isEmpty else { return }
        busy.formUnion(names)
        DispatchQueue.global(qos: .userInitiated).async {
            names.forEach(Docker.start)
            DispatchQueue.main.async {
                self.busy.subtract(names)
                self.openTicks = 0  // make the next scan include Docker
                self.scanApps()
            }
        }
    }

    // Quitting Docker Desktop hands the VM's memory back to macOS. Containers
    // without a restart policy stay down after that, so start them again ourselves.
    func restartDocker() {
        confirmRestart = false
        let names = containers.sorted { $0.isInfra && !$1.isInfra }.map(\.name)
        restartStatus = "Quitting Docker…"
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: "quit app \"Docker\"")?.executeAndReturnError(nil)
            var waited = 0
            while Docker.isUp && waited < 60 { Thread.sleep(forTimeInterval: 1); waited += 1 }
            Thread.sleep(forTimeInterval: 2)

            DispatchQueue.main.async {
                self.restartStatus = "Starting Docker…"
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Docker.app"),
                                                   configuration: .init())
            }
            waited = 0
            while !Docker.isUp && waited < 180 { Thread.sleep(forTimeInterval: 1); waited += 1 }

            if !names.isEmpty {
                DispatchQueue.main.async { self.restartStatus = "Starting \(names.count) containers…" }
                names.forEach(Docker.start)
            }
            DispatchQueue.main.async {
                self.restartStatus = nil
                self.openTicks = 0
                self.scanApps()
            }
        }
    }

    // MARK: Apps

    func quit(_ app: AppUsage) {
        guard let path = app.bundlePath else { return }
        for r in NSWorkspace.shared.runningApplications where r.bundleURL?.path == path {
            r.terminate()
        }
    }
}

// MARK: - UI

// Colors tuned per appearance. System orange is too light to read as text on
// a light background, so text gets a deeper shade; fills keep the system hue.
extension Color {
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    // Translucent white tiles in light mode, a soft lift in dark mode.
    static let card = adaptive(light: .white.withAlphaComponent(0.62),
                               dark: .white.withAlphaComponent(0.07))
    static let cardEdge = adaptive(light: .black.withAlphaComponent(0.06),
                                   dark: .white.withAlphaComponent(0.08))
    static let track = adaptive(light: .black.withAlphaComponent(0.08),
                                dark: .white.withAlphaComponent(0.12))
    static let hover = adaptive(light: .black.withAlphaComponent(0.05),
                                dark: .white.withAlphaComponent(0.08))
    static let hoverStrong = adaptive(light: .black.withAlphaComponent(0.08),
                                      dark: .white.withAlphaComponent(0.14))
    static let warnText = adaptive(light: NSColor(srgbRed: 0.75, green: 0.32, blue: 0, alpha: 1),
                                   dark: .systemOrange)
}

enum SortKey: String, CaseIterable { case memory = "Memory", cpu = "CPU" }

// One button style for the whole popover. The system macOS styles don't react
// to the pointer, so every button here lights up on hover and dims on press.
// The fade is scoped to the button, so it never touches the window size.
enum HoverKind {
    case plain  // no background until hovered: footer icons
    case bordered  // soft fill: Quit…, Stop, Cancel
    case prominent(Color)  // solid: the confirming action
}

struct HoverButtonStyle: ButtonStyle {
    var kind: HoverKind = .bordered
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        HoverButton(configuration: configuration, kind: kind, small: small)
    }
}

private struct HoverButton: View {
    let configuration: ButtonStyle.Configuration
    let kind: HoverKind
    let small: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(small ? .caption.weight(.medium) : .subheadline)
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? 7 : 8)
            .padding(.vertical, small ? 2 : 3)
            .background(RoundedRectangle(cornerRadius: small ? 5 : 6, style: .continuous)
                .fill(fill(pressed: pressed)))
            .brightness(pressedBrightness(pressed))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 && isEnabled }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }

    var foreground: Color {
        switch kind {
        case .plain: return hovering ? .primary : .secondary
        case .bordered: return .primary
        case .prominent: return .white
        }
    }

    func fill(pressed: Bool) -> Color {
        switch kind {
        case .plain: return pressed ? .hoverStrong.opacity(1.4) : hovering ? .hoverStrong : .clear
        case .bordered: return Color.primary.opacity(pressed ? 0.2 : hovering ? 0.15 : 0.09)
        case .prominent(let c): return c
        }
    }

    // Solid buttons brighten on hover and darken on press, like the system ones.
    func pressedBrightness(_ pressed: Bool) -> Double {
        guard case .prominent = kind else { return 0 }
        return pressed ? -0.12 : hovering ? 0.08 : 0
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    static var hoverPlain: HoverButtonStyle { HoverButtonStyle(kind: .plain) }
    static var hoverBordered: HoverButtonStyle { HoverButtonStyle(kind: .bordered) }
    static var hoverSmall: HoverButtonStyle { HoverButtonStyle(kind: .bordered, small: true) }
    static func hoverProminent(_ c: Color, small: Bool = false) -> HoverButtonStyle {
        HoverButtonStyle(kind: .prominent(c), small: small)
    }
}

// Menus can't take a ButtonStyle, so the sort menu gets the same hover by hand.
struct HoverMenuBackground: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.hover : .clear))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// App icons are cached: NSWorkspace builds a fresh image on every call.
@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func app(_ path: String) -> NSImage? {
        if let img = cache[path] { return img }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // Draw once at display size; the source icon is up to 1024 px and
        // scaling it down on every redraw shows up in profiles.
        let src = NSWorkspace.shared.icon(forFile: path)
        let size = NSSize(width: 36, height: 36)  // 18 pt at 2x
        let img = NSImage(size: NSSize(width: 18, height: 18))
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            src.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            rep.size = NSSize(width: 18, height: 18)
            img.addRepresentation(rep)
        }
        cache[path] = img
        return img
    }
}

// The grouped-card look of Control Center.
struct Card<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                shape.fill(Color.card)
                if let tint { shape.fill(tint.opacity(0.12)) }
                shape.strokeBorder(Color.cardEdge, lineWidth: 0.5)
            }
    }
}

struct ContentView: View {
    @ObservedObject var model: Model
    @State private var sort = SortKey.memory
    @State private var confirmQuit = false

    var body: some View {
        VStack(spacing: 8) {
            header
            HStack(spacing: 8) { tiles }
            appsCard
            if model.dockerVM != nil || model.restartStatus != nil {
                DockerCard(model: model)
            }
            footer
        }
        .padding(10)
        .frame(width: 340)
        .onAppear { model.opened() }
        .onDisappear {
            model.closed()
            confirmQuit = false
        }
    }

    // MARK: Header

    var header: some View {
        let v = model.status.verdict
        return Card(tint: v.color) {
            HStack(spacing: 10) {
                Image(systemName: v.symbol)
                    .font(.system(size: 26))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, v.color)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy, value: v)
                VStack(alignment: .leading, spacing: 1) {
                    Text(v.title).font(.headline)
                    Text(model.reasons.isEmpty ? "Plenty of memory and CPU to spare"
                                               : model.reasons.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: Tiles

    @ViewBuilder var tiles: some View {
        let s = model.sample
        let swapWord = model.swapTrend > 0.06 ? "growing"
                     : model.swapTrend < -0.06 ? "shrinking" : "steady"
        Tile(label: "Memory", value: String(format: "%.1f GB", s.memUsed),
             detail: model.pressureLabel,
             detailColor: s.pressure >= 4 ? .red : s.pressure >= 2 ? .warnText : .secondary,
             history: model.memHistory, maxY: s.total,
             color: s.pressure >= 4 ? .red : s.pressure >= 2 ? .orange : .green)
            .help(String(format: "%.1f of %.0f GB in use. Pressure: %@", s.memUsed, s.total,
                         model.pressureLabel.lowercased()))
        Tile(label: "CPU", value: String(format: "%.0f%%", model.cpuNow),
             detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores",
             detailColor: .secondary,
             history: model.cpuHistory, maxY: 100,
             color: model.cpuNow > 90 ? .red : model.cpuNow > 70 ? .orange : .blue)
        Tile(label: "Swap", value: String(format: "%.1f GB", s.swapUsed),
             detail: swapWord, detailColor: swapWord == "growing" ? .warnText : .secondary,
             history: model.swapHistory, maxY: max(1, (model.swapHistory.max() ?? 0) * 1.2),
             color: swapWord == "growing" ? .orange : .gray)
    }

    // MARK: Apps

    var appsCard: some View {
        let all = model.apps.filter { !$0.isDockerVM && $0.name != "MemWatch" }
        let key: (AppUsage) -> Double = { sort == .memory ? $0.mb : $0.cpu }
        let rows = Array(all.sorted { key($0) > key($1) }.prefix(5))
        let top = max(rows.first.map(key) ?? 1, 1)

        return Card {
            VStack(spacing: 2) {
                HStack {
                    Text(rows.contains { isHot($0) } ? "Slowing you down" : "Top apps")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Picker("Sort by", selection: $sort) {
                            ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(sort.rawValue)
                    }
                    .menuStyle(.borderlessButton)
                    .font(.subheadline)
                    .fixedSize()
                    .modifier(HoverMenuBackground())
                }
                .padding(.bottom, 2)

                if rows.isEmpty {
                    ProgressView().controlSize(.small).frame(height: 26 * 5)
                }
                ForEach(rows) { app in
                    AppRow(app: app, sort: sort, share: key(app) / top, hot: isHot(app),
                           model: model)
                }
            }
        }
    }

    func isHot(_ app: AppUsage) -> Bool {
        !app.isSystem && (sort == .memory ? app.mb >= 2048 : app.cpu >= 50)
    }

    // MARK: Footer

    // Asks before quitting, in place, so the popover keeps its size.
    var footer: some View {
        HStack {
            if confirmQuit {
                Text("Quit MemWatch?").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { confirmQuit = false }
                    .buttonStyle(.hoverBordered)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.hoverProminent(.red))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                } label: {
                    Label("Activity Monitor", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.hoverPlain)
                Spacer()
                Button {
                    confirmQuit = true
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.hoverPlain)
                .help("Quit MemWatch")
            }
        }
        .font(.subheadline)
        .frame(height: 24)
        .padding(.top, 2)
    }
}

struct Tile: View {
    let label: String
    let value: String
    let detail: String
    let detailColor: Color
    let history: [Double]
    let maxY: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail).font(.caption2).foregroundStyle(detailColor)
            Sparkline(values: history, maxY: maxY, color: color)
                .frame(height: 20)
                .padding(.top, 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            shape.fill(Color.card)
            shape.strokeBorder(Color.cardEdge, lineWidth: 0.5)
        }
    }
}

// No animations on values that refresh every few seconds: each one keeps the
// display link redrawing the window at 120 Hz, which tripled our CPU and grew
// memory. Only user actions animate (the chevron, the verdict symbol).

// A plain Path instead of Swift Charts: one shape, no layout engine.
struct Sparkline: View {
    let values: [Double]
    let maxY: Double
    let color: Color

    var body: some View {
        ZStack {
            SparkShape(values: values, maxY: maxY, closed: true)
                .fill(LinearGradient(colors: [color.opacity(0.3), color.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
            SparkShape(values: values, maxY: maxY, closed: false)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

struct SparkShape: Shape {
    let values: [Double]
    let maxY: Double
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1, maxY > 0 else { return p }
        let step = rect.width / CGFloat(values.count - 1)
        let point = { (i: Int) -> CGPoint in
            let v = min(max(values[i] / maxY, 0), 1)
            return CGPoint(x: CGFloat(i) * step, y: rect.maxY - CGFloat(v) * (rect.height - 1.5))
        }
        p.move(to: point(0))
        for i in 1..<values.count { p.addLine(to: point(i)) }
        if closed {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
        return p
    }
}

// Thin capsule showing a row's share of the biggest row.
struct ShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.track)
                Capsule().fill(color)
                    .frame(width: max(4, g.size.width * min(max(share, 0), 1)))
            }
        }
        .frame(width: 64, height: 5)
    }
}

struct AppRow: View {
    let app: AppUsage
    let sort: SortKey
    let share: Double
    let hot: Bool
    @ObservedObject var model: Model
    @State private var hovering = false
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18, height: 18)
            if confirming {
                // Same row, same height: the confirm swaps in without resizing the popover.
                Text("Quit \(app.name)?").lineLimit(1)
                Spacer(minLength: 6)
                Button("Cancel") { confirming = false }
                    .buttonStyle(.hoverSmall)
                Button("Quit") {
                    confirming = false
                    model.quit(app)
                }
                .buttonStyle(.hoverProminent(.red, small: true))
            } else {
                Text(app.name).lineLimit(1)
                Spacer(minLength: 6)
                if hovering && canQuit {
                    Button("Quit…") { confirming = true }
                        .buttonStyle(.hoverSmall)
                } else {
                    ShareBar(share: share, color: hot ? .orange : .accentColor)
                }
                Text(sort == .memory ? formatMB(app.mb) : String(format: "%.0f%%", app.cpu))
                    .monospacedDigit()
                    .fontWeight(hot ? .semibold : .regular)
                    .foregroundStyle(hot ? Color.warnText : Color.primary)
                    .frame(width: 58, alignment: .trailing)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hovering ? Color.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDisappear { confirming = false }
        .help(tooltip)
    }

    var tooltip: String {
        var parts = [formatMB(app.mb), String(format: "%.0f%% CPU", app.cpu)]
        if app.count > 1 { parts.append("\(app.count) processes") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder var icon: some View {
        if let path = app.bundlePath, let img = Icons.app(path) {
            Image(nsImage: img).resizable()
        } else {
            Image(systemName: app.name == "Claude Code" ? "terminal.fill" : "gearshape.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
        }
    }

    var canQuit: Bool {
        guard let path = app.bundlePath, !app.isSystem else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == path }
    }
}

// MARK: Docker card

// Expanding and collapsing is deliberately not animated: the popover window
// resizes to fit, and animating that resize makes the whole window flicker.
struct DockerCard: View {
    @ObservedObject var model: Model

    var body: some View {
        Card {
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    if let img = Icons.app("/Applications/Docker.app") {
                        Image(nsImage: img).resizable().frame(width: 16, height: 16)
                    }
                    Text("Docker")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let vm = model.dockerVM {
                        Text(String(format: "%@ · %.0f%% CPU", formatMB(vm.mb), vm.cpu))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .help("Memory and CPU of Docker's Linux VM, which runs every container")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 2)

                if let status = model.restartStatus {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                } else {
                    ForEach(model.projects, id: \.name) { project in
                        ProjectRow(name: project.name, items: project.items, model: model)
                        if model.expanded.contains(project.name) {
                            ForEach(project.items) { ContainerRow(c: $0, model: model) }
                        }
                    }
                    if model.projects.isEmpty {
                        Text(model.dockerVM == nil ? "Docker isn't running" : "Loading containers…")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .frame(height: 26)
                    }
                    SlackNote(model: model)
                }
            }
        }
    }
}

struct ProjectRow: View {
    let name: String
    let items: [Container]
    @ObservedObject var model: Model
    @State private var hovering = false

    var body: some View {
        let running = items.filter { !model.isStopped($0) }
        let mb = running.reduce(0) { $0 + ($1.mb ?? 0) }
        let anyBusy = items.contains { model.busy.contains($0.name) }
        let open = model.expanded.contains(name)

        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .animation(.snappy(duration: 0.15), value: open)
                .frame(width: 18)
            Text(name.isEmpty ? "Other" : name).lineLimit(1)
            HStack(spacing: 3) {
                ForEach(items) { c in
                    Circle()
                        .fill(model.isStopped(c) ? Color.secondary.opacity(0.35) : Color.green)
                        .frame(width: 5, height: 5)
                }
            }
            .help("\(running.count) of \(items.count) running")
            Spacer(minLength: 6)
            if anyBusy {
                ProgressView().controlSize(.mini)
            } else if hovering {
                if running.isEmpty {
                    Button("Start") { model.start(items.map(\.name)) }
                        .buttonStyle(.hoverSmall)
                } else {
                    Button(running.count == 1 ? "Stop" : "Stop All") {
                        model.stop(running.map(\.name))
                    }
                    .buttonStyle(.hoverSmall)
                }
            }
            Text(running.isEmpty ? "Stopped" : mb > 0 ? formatMB(mb) : "")
                .monospacedDigit()
                .foregroundStyle(running.isEmpty ? .secondary : .primary)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hovering ? Color.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.toggle(name) }
    }
}

struct ContainerRow: View {
    let c: Container
    @ObservedObject var model: Model
    @State private var hovering = false

    var body: some View {
        let stopped = model.isStopped(c)
        let busy = model.busy.contains(c.name)

        HStack(spacing: 8) {
            Circle()
                .fill(stopped ? Color.secondary.opacity(0.35) : Color.green)
                .frame(width: 6, height: 6)
                .frame(width: 18)
            Text(c.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if busy {
                Text(stopped ? "Starting…" : "Stopping…").foregroundStyle(.secondary)
                ProgressView().controlSize(.mini)
            } else if hovering {
                Button(stopped ? "Start" : "Stop") {
                    stopped ? model.start([c.name]) : model.stop([c.name])
                }
                .buttonStyle(.hoverSmall)
            } else if let port = c.port, !stopped {
                Text(":\(port)").foregroundStyle(.secondary).monospacedDigit()
            }
            Text(stopped ? "Stopped" : c.mb.map(formatMB) ?? "")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
        .font(.callout)
        .opacity(stopped && !hovering ? 0.6 : 1)
        .padding(.leading, 14)
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(hovering ? Color.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tooltip)
    }

    // "web · up 9 hr · 7% CPU"
    var tooltip: String {
        var parts = [c.shortImage, "up " + c.uptime]
        if let cpu = c.cpu { parts.append(String(format: "%.0f%% CPU", cpu)) }
        return parts.joined(separator: " · ")
    }
}

// The VM grows to fit what containers once used and keeps it; only a Docker
// restart gives it back. One line until clicked, then an inline confirm.
struct SlackNote: View {
    @ObservedObject var model: Model

    var body: some View {
        if let slack = model.vmSlackMB, slack >= 2048 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "memorychip").foregroundStyle(Color.warnText)
                    Text("\(formatMB(slack)) idle in the VM")
                    Spacer()
                    if !model.confirmRestart {
                        Button("Reclaim…") { model.confirmRestart = true }
                            .buttonStyle(.hoverSmall)
                    }
                }
                .help("Docker's VM keeps memory its containers no longer use. Restarting Docker gives it back to macOS.")
                if model.confirmRestart {
                    Text("Docker will quit and reopen, then start your \(model.containers.count) running containers again. Takes about a minute.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Cancel") { model.confirmRestart = false }
                            .buttonStyle(.hoverBordered)
                        Button("Restart Docker") { model.restartDocker() }
                            .buttonStyle(.hoverProminent(.accentColor))
                    }
                }
            }
            .font(.callout)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12)))
            .padding(.top, 4)
        }
    }
}

// MARK: - Menu bar

// A gauge whose needle and color follow the verdict. Smooth stays a plain
// template image so it blends in like system icons. Built once per verdict.
@MainActor
enum MenuIcon {
    private static var cache: [Verdict: NSImage] = [:]

    static func image(_ v: Verdict) -> NSImage {
        if let img = cache[v] { return img }
        let base = NSImage(systemSymbolName: v.gauge, accessibilityDescription: v.title)!
        let img: NSImage
        if v == .smooth {
            img = base
            img.isTemplate = true
        } else {
            img = base.withSymbolConfiguration(.init(paletteColors: [v.nsColor])) ?? base
            img.isTemplate = false
        }
        cache[v] = img
        return img
    }
}

struct MenuLabel: View {
    @ObservedObject var status: Status

    var body: some View {
        Image(nsImage: MenuIcon.image(status.verdict))
    }
}

@main
struct MemWatchApp: App {
    // @State, not @StateObject: the scene itself shouldn't re-render when the
    // model changes. Only the label (via Status) and the open popover observe.
    @State private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            MenuLabel(status: model.status)
        }
        .menuBarExtraStyle(.window)
    }
}
