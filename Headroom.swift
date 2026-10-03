// Headroom: a tiny menu bar app that answers "is my Mac fast or slow right now?"
// and shows which apps are to blame. Build with ./build.sh.
//
// Built to cost almost nothing: while the popover is closed it only reads a few
// kernel counters every 5 s. Per-app numbers come from libproc and Docker's own
// socket, and only while the popover is open. No child processes are spawned.

import SwiftUI
import Darwin
import ServiceManagement

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
    // How full the menu bar capsule is, in points of its 18 pt glyph.
    var level: CGFloat {
        switch self {
        case .smooth: return 4
        case .busy: return 7.6
        case .slow: return 11.6
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
    var appMem = 0.0, wired = 0.0, compressed = 0.0  // GB, the parts of memUsed
    var swapUsed = 0.0  // GB
    var cpuTicks: (user: UInt64, system: UInt64, idle: UInt64) = (0, 0, 0)
    var thermal = ProcessInfo.ThermalState.nominal  // fair, serious, critical = throttling
}

struct Container: Identifiable {
    var id: String { name }
    let name: String
    let image: String
    let project: String  // compose project, "" if none
    let port: Int?  // first published host port
    let uptime: String  // "8 days", "31 min"
    var cpu: Double? = nil  // percent of one core, like docker stats
    var mb: Double? = nil
    var restarting = false  // crash-looping under a restart policy

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

// CPU as a share of the whole Mac. libproc and docker stats count per core, so
// a busy app reads "815%"; everywhere on screen we show its share, "82%".
let coreCount = Double(ProcessInfo.processInfo.activeProcessorCount)
func cpuShare(_ perCore: Double) -> Double { min(perCore / coreCount, 100) }

func formatMB(_ mb: Double) -> String {
    // From 1000 MB up, GB reads better than "1010 MB".
    mb >= 1000 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
}

// MARK: - Settings

// UserDefaults keys. Views read them with @AppStorage; the model reads them directly.
enum Pref {
    static let menuText = "menuText"  // MenuText raw value
    static let appCount = "appCount"  // apps listed in the popover
    static let showDocker = "showDocker"
    static let lastContainers = "lastRunningContainers"  // offered back after Docker breaks
}

// What sits next to the capsule in the menu bar.
enum MenuText: String, CaseIterable {
    case none, memory, cpu

    var label: String {
        switch self {
        case .none: return "Icon only"
        case .memory: return "Icon and MEM %"
        case .cpu: return "Icon and CPU %"
        }
    }
}

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
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
        let page = Double(vm_kernel_page_size) / gb
        s.appMem = (Double(vm.internal_page_count) - Double(vm.purgeable_count)) * page
        s.wired = Double(vm.wire_count) * page
        s.compressed = Double(vm.compressor_page_count) * page
        s.memUsed = s.appMem + s.wired + s.compressed
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
        s.cpuTicks = (UInt64(t.0) + UInt64(t.3), UInt64(t.1), UInt64(t.2))  // user + nice, system, idle
    }
    s.thermal = ProcessInfo.processInfo.thermalState
    return s
}

// Free and total space on the startup disk, in GB as Finder counts them.
// "Important usage" includes space macOS can purge, which is what Finder shows.
func sampleDisk() -> (free: Double, total: Double)? {
    let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
    guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
          let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity
    else { return nil }
    return (Double(free) / 1e9, Double(total) / 1e9)
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
        // Running plus restarting: a crash loop is exactly what we want to catch.
        let filter = #"{"status":["running","restarting"]}"#
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let list = Docker.json("/containers/json?filters=\(filter)") as? [[String: Any]]
        else { return nil }
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
            item.restarting = (c["State"] as? String) == "restarting"

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
    @Published var text = ""  // optional percentage next to the capsule
}

enum DockerState { case off, up, unresponsive }

// What's behind the verdict, so the header can name the app responsible.
enum Cause { case none, memory, cpu }

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
    private(set) var cause = Cause.none
    private(set) var cpuSplit: (user: Double, system: Double) = (0, 0)  // percent of the whole Mac
    private(set) var disk: (free: Double, total: Double)?
    private var tickCount = 0
    private(set) var dockerState = DockerState.off
    private var dockerFailures = 0

    // State the user changes.
    @Published var stoppedHere: [Container] = []  // stopped from this popover, offered for Start
    @Published var busy: Set<String> = []  // containers being stopped or started
    @Published var expanded: Set<String> = []  // projects shown open
    @Published var restartStatus: String?  // non-nil while restarting Docker
    @Published var confirmRestart = false

    private(set) var isOpen = false
    private var lastTicks: (user: UInt64, system: UInt64, idle: UInt64)?
    private var systemTimer: Timer?
    private var appTimer: Timer?
    private var openTicks = 0
    private let queue = DispatchQueue(label: "headroom.scan", qos: .utility)
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
        if let last = lastTicks {
            let user = Double(s.cpuTicks.user &- last.user), system = Double(s.cpuTicks.system &- last.system)
            let all = user + system + Double(s.cpuTicks.idle &- last.idle)
            if all > 0 {
                cpuSplit = (user / all * 100, system / all * 100)
                push(&cpuHistory, cpuSplit.user + cpuSplit.system)
            }
        }
        lastTicks = s.cpuTicks
        // Disk space barely moves, so once a minute is plenty.
        if tickCount % 12 == 0 { disk = sampleDisk() }
        tickCount += 1
        push(&memHistory, s.memUsed)
        push(&swapHistory, s.swapUsed)
        judge()
        refreshLabel()
        if isOpen { objectWillChange.send() }
    }

    func refreshLabel() {
        let mode = MenuText(rawValue: UserDefaults.standard.string(forKey: Pref.menuText) ?? "") ?? .none
        let text: String
        switch mode {
        case .none: text = ""
        // Labeled, so a bare percentage is never a guess.
        case .memory: text = String(format: "MEM %.0f%%", sample.memUsed / max(sample.total, 1) * 100)
        case .cpu: text = String(format: "CPU %.0f%%", cpuNow)
        }
        if status.text != text { status.text = text }
    }

    func scanApps() {
        guard isOpen else { return }
        let withDocker = restartStatus == nil && openTicks % 2 == 0  // every 4 s
        openTicks += 1
        // Docker Desktop running is what matters, not the VM: when the VM dies
        // the app stays up and its socket stops answering.
        let desktopRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.docker.docker").isEmpty
        queue.async { [procs, docker] in
            let apps = procs.scan()
            let containers = withDocker && desktopRunning ? docker.scan() : nil
            DispatchQueue.main.async {
                self.apps = apps
                if self.restartStatus != nil {
                    // leave Docker alone mid-restart
                } else if !desktopRunning {
                    self.containers = []
                    self.dockerState = .off
                    self.dockerFailures = 0
                } else if let containers {
                    self.containers = containers
                    self.stoppedHere.removeAll { c in containers.contains { $0.name == c.name } }
                    self.dockerState = .up
                    self.dockerFailures = 0
                    self.rememberRunning(containers)
                } else if withDocker {
                    // Two misses in a row (8 s), so Docker starting up doesn't count.
                    self.dockerFailures += 1
                    if self.dockerFailures >= 2 {
                        self.dockerState = .unresponsive
                        self.containers = []
                    }
                }
                if self.isOpen { self.objectWillChange.send() }
            }
        }
    }

    // MARK: Docker memory

    // The containers running at the last good scan, databases first. If Docker
    // breaks, these are what a restart brings back.
    var lastRunning: [String] {
        UserDefaults.standard.stringArray(forKey: Pref.lastContainers) ?? []
    }

    private func rememberRunning(_ list: [Container]) {
        let names = list.filter { !$0.restarting }.sorted { $0.isInfra && !$1.isInfra }.map(\.name)
        if names != lastRunning { UserDefaults.standard.set(names, forKey: Pref.lastContainers) }
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
        var cause = Cause.none
        let recentCPU = cpuHistory.suffix(Int(30 / Self.tick))
        let cpu = recentCPU.isEmpty ? 0 : recentCPU.reduce(0, +) / Double(recentCPU.count)

        switch sample.pressure {
        case 4: v = .slow; why.append("Memory is critically low"); cause = .memory
        case 2: v = max(v, .busy); why.append("Memory is getting tight"); cause = .memory
        default: break
        }
        if swapTrend > 0.25 {
            v = .slow; why.append("Swapping to disk"); cause = .memory
        } else if swapTrend > 0.06 {
            v = max(v, .busy); why.append("Swap is growing"); cause = .memory
        }
        if cpu > 90 {
            v = .slow; why.append(String(format: "CPU maxed out (%.0f%%)", cpu))
            if cause == .none { cause = .cpu }
        } else if cpu > 70 {
            v = max(v, .busy); why.append(String(format: "CPU working hard (%.0f%%)", cpu))
            if cause == .none { cause = .cpu }
        }
        switch sample.thermal {
        case .critical:
            v = .slow; why.append("Mac is very hot, CPU heavily throttled")
            if cause == .none { cause = .cpu }
        case .serious:
            v = max(v, .busy); why.append("Mac is hot, CPU throttled")
            if cause == .none { cause = .cpu }
        default: break
        }
        if let disk {
            if disk.free < 5 {
                v = .slow; why.append(String(format: "Only %.0f GB free on disk", disk.free))
            } else if disk.free < 10 {
                v = max(v, .busy); why.append(String(format: "Disk almost full, %.0f GB free", disk.free))
            }
        }
        reasons = why
        self.cause = cause
        if status.verdict != v { status.verdict = v }
    }

    // MARK: Docker

    var dockerVM: AppUsage? { apps.first { $0.isDockerVM } }

    // The app most responsible for the current verdict, e.g. "Chrome is using 6.1 GB".
    var culprit: String? {
        let candidates = apps.filter { !$0.isSystem && $0.name != "Headroom" }
        switch cause {
        case .none:
            return nil
        case .memory:
            guard let top = candidates.max(by: { $0.mb < $1.mb }), top.mb >= 500 else { return nil }
            if top.isDockerVM, let c = containers.max(by: { ($0.mb ?? 0) < ($1.mb ?? 0) }), (c.mb ?? 0) > 0 {
                return "Docker is using \(formatMB(top.mb)), most of it \(c.name)"
            }
            return "\(top.name) is using \(formatMB(top.mb))"
        case .cpu:
            // Per-core percentages pass 100 ("773%"); a share of the whole Mac reads better here.
            // Under 10% it isn't a culprit, e.g. when heat alone is the cause.
            let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
            let top = candidates.max(by: { $0.cpu < $1.cpu })
            // CPU we can't attribute to your apps belongs to macOS itself: Spotlight,
            // WindowServer, kernel_task. Those run as root, so we can't see them one by one.
            let system = cpuNow * cores - candidates.reduce(0) { $0 + $1.cpu }
            if system / cores >= 10 && system > (top?.cpu ?? 0) {
                return String(format: "macOS system processes are using %.0f%% of your CPU", min(system / cores, 100))
            }
            guard let top, top.cpu / cores >= 10 else { return nil }
            let share = min(top.cpu / cores, 100)
            if top.isDockerVM, let c = containers.max(by: { ($0.cpu ?? 0) < ($1.cpu ?? 0) }), (c.cpu ?? 0) >= 5 {
                return String(format: "Docker (%@) is using %.0f%% of your CPU", c.name, share)
            }
            return String(format: "%@ is using %.0f%% of your CPU", top.name, share)
        }
    }

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
        let names = containers.isEmpty ? lastRunning
                                       : containers.sorted { $0.isInfra && !$1.isInfra }.map(\.name)
        restartStatus = "Quitting Docker…"
        dockerState = .up
        dockerFailures = 0
        DispatchQueue.global(qos: .userInitiated).async {
            NSAppleScript(source: "quit app \"Docker\"")?.executeAndReturnError(nil)
            var waited = 0
            while Docker.isUp && waited < 60 { Thread.sleep(forTimeInterval: 1); waited += 1 }
            Thread.sleep(forTimeInterval: 5)  // let the backend exit before reopening

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
    @State private var showSettings = false
    @AppStorage(Pref.appCount) private var appCount = 5
    @AppStorage(Pref.showDocker) private var showDocker = true

    var body: some View {
        VStack(spacing: 8) {
            if showSettings {
                SettingsView(model: model) { showSettings = false }
            } else {
                header
                HStack(spacing: 8) { tiles }
                appsCard
                if showDocker && (model.dockerState != .off || model.restartStatus != nil) {
                    DockerCard(model: model)
                }
                footer
            }
        }
        .padding(10)
        .frame(width: 340)
        .onAppear {
            model.opened()
            // Open on the list that shows the culprit.
            sort = model.cause == .cpu ? .cpu : .memory
        }
        .onDisappear {
            model.closed()
            confirmQuit = false
            showSettings = false
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
                    // One line per reason: several can be true at once.
                    ForEach(model.reasons.isEmpty ? ["Plenty of memory and CPU to spare"] : model.reasons,
                            id: \.self) { reason in
                        Text(reason)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let culprit = model.culprit {
                        Text(culprit)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Tiles

    @ViewBuilder var tiles: some View {
        let s = model.sample
        let swapWord = model.swapTrend > 0.06 ? "growing"
                     : model.swapTrend < -0.06 ? "shrinking" : "steady"
        let memColor: Color = s.pressure >= 4 ? .red : s.pressure >= 2 ? .orange : .green
        Tile(label: "Memory", value: String(format: "%.1f GB", s.memUsed),
             detail: model.pressureLabel,
             detailColor: s.pressure >= 4 ? .red : s.pressure >= 2 ? .warnText : .secondary,
             history: model.memHistory, maxY: s.total, color: memColor,
             parts: [(s.appMem, memColor), (s.wired, .blue), (s.compressed, .purple)], partsTotal: s.total,
             partsHelp: String(format: "App %.1f GB · Wired %.1f GB · Compressed %.1f GB · Free and cache %.1f GB",
                               s.appMem, s.wired, s.compressed, max(s.total - s.memUsed, 0)))
            .help(String(format: "%.1f of %.0f GB in use. Pressure: %@", s.memUsed, s.total,
                         model.pressureLabel.lowercased()))

        // Heat replaces the core count when macOS is throttling the CPU.
        let heat: (String, Color)? = switch s.thermal {
        case .fair: ("Warm", .secondary)
        case .serious: ("Hot, throttled", .warnText)
        case .critical: ("Very hot, throttled", .red)
        default: nil
        }
        Tile(label: "CPU", value: String(format: "%.0f%%", model.cpuNow),
             detail: heat?.0 ?? "\(ProcessInfo.processInfo.activeProcessorCount) cores",
             detailColor: heat?.1 ?? .secondary,
             history: model.cpuHistory, maxY: 100,
             color: model.cpuNow > 90 ? .red : model.cpuNow > 70 ? .orange : .blue,
             parts: [(model.cpuSplit.user, .blue), (model.cpuSplit.system, .red)], partsTotal: 100,
             partsHelp: String(format: "User %.0f%% · System %.0f%% · Idle %.0f%%", model.cpuSplit.user,
                               model.cpuSplit.system, max(100 - model.cpuNow, 0)))

        // Swap lives on the startup disk, so this tile also watches disk space.
        let disk = model.disk
        let diskLow = (disk?.free ?? .infinity) < 10
        let diskColor: Color = (disk?.free ?? .infinity) < 5 ? .red : diskLow ? .orange : .gray
        Tile(label: "Swap", value: String(format: "%.1f GB", s.swapUsed),
             detail: diskLow ? String(format: "%.0f GB disk free", disk!.free) : swapWord,
             detailColor: diskLow ? .warnText : swapWord == "growing" ? .warnText : .secondary,
             history: model.swapHistory, maxY: max(1, (model.swapHistory.max() ?? 0) * 1.2),
             color: swapWord == "growing" ? .orange : .gray,
             parts: disk.map { [($0.total - $0.free, diskColor)] } ?? [], partsTotal: disk?.total ?? 1,
             partsHelp: disk.map { String(format: "Startup disk: %.0f GB free of %.0f GB", $0.free, $0.total) } ?? "")
    }

    // MARK: Apps

    var appsCard: some View {
        let all = model.apps.filter { !$0.isDockerVM && $0.name != "Headroom" }
        let key: (AppUsage) -> Double = { sort == .memory ? $0.mb : $0.cpu }
        let rows = Array(all.sorted { key($0) > key($1) }.prefix(appCount))
        let top = max(rows.first.map(key) ?? 1, 1)

        return Card {
            VStack(spacing: 2) {
                HStack {
                    // Only when the Mac actually is slow: a big app on a healthy Mac isn't slowing you down.
                    Text(model.status.verdict != .smooth && rows.contains { isHot($0) } ? "Slowing you down" : "Top apps")
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
                    ProgressView().controlSize(.small).frame(height: 26 * CGFloat(appCount))
                }
                ForEach(rows) { app in
                    AppRow(app: app, sort: sort, share: key(app) / top, hot: isHot(app),
                           model: model)
                }
            }
        }
    }

    func isHot(_ app: AppUsage) -> Bool {
        !app.isSystem && (sort == .memory ? app.mb >= 2048 : cpuShare(app.cpu) >= 25)
    }

    // MARK: Footer

    // Asks before quitting, in place, so the popover keeps its size.
    var footer: some View {
        HStack {
            if confirmQuit {
                Text("Quit Headroom?").foregroundStyle(.secondary)
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
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.hoverPlain)
                .help("Settings")
                Button {
                    confirmQuit = true
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.hoverPlain)
                .help("Quit Headroom")
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
    var parts: [(Double, Color)] = []  // what the value is made of, drawn as a thin bar
    var partsTotal: Double = 1
    var partsHelp = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail).font(.caption2).foregroundStyle(detailColor).lineLimit(1)
            PartsBar(parts: parts, total: partsTotal)
                .padding(.top, 5)
                .help(partsHelp)
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

// A thin stacked bar: each part's share of the total, the rest left as track.
struct PartsBar: View {
    let parts: [(Double, Color)]
    let total: Double

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1) {
                ForEach(parts.indices, id: \.self) { i in
                    let share = max(parts[i].0, 0) / max(total, 0.001)
                    if share > 0.005 {
                        Rectangle().fill(parts[i].1).frame(width: g.size.width * min(share, 1))
                    }
                }
                Spacer(minLength: 0)
            }
            .background(Color.track)
            .clipShape(Capsule())
        }
        .frame(height: 4)
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
                Text(sort == .memory ? formatMB(app.mb) : String(format: "%.0f%%", cpuShare(app.cpu)))
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
        var parts = [formatMB(app.mb), String(format: "%.0f%% CPU", cpuShare(app.cpu))]
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
                        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
                        Text(String(format: "%@ · %.0f%% CPU", formatMB(vm.mb), min(vm.cpu / cores, 100)))
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
                } else if model.dockerState == .unresponsive {
                    DockerDownNote(model: model)
                } else {
                    CrashNote(model: model)
                    ForEach(model.projects, id: \.name) { project in
                        ProjectRow(name: project.name, items: project.items, model: model)
                        if model.expanded.contains(project.name) {
                            ForEach(project.items) { ContainerRow(c: $0, model: model) }
                        }
                    }
                    if model.projects.isEmpty {
                        Text("No containers running")
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
                        .fill(c.restarting ? Color.red
                              : model.isStopped(c) ? Color.secondary.opacity(0.35) : Color.green)
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
                .fill(c.restarting ? Color.red : stopped ? Color.secondary.opacity(0.35) : Color.green)
                .frame(width: 6, height: 6)
                .frame(width: 18)
            Text(c.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if busy {
                Text(stopped ? "Starting…" : "Stopping…").foregroundStyle(.secondary)
                ProgressView().controlSize(.mini)
            } else {
                if c.restarting {
                    if !hovering { Text("Crashing").foregroundStyle(Color.warnText) }
                } else {
                    // CPU steps aside on hover to make room for Stop; the port stays,
                    // since hovering the row is the only way to reach it.
                    if let cpu = c.cpu, cpuShare(cpu) >= 5, !stopped, !hovering {
                        Text(String(format: "%.0f%%", cpuShare(cpu)))
                            .foregroundStyle(Color.warnText)
                            .monospacedDigit()
                            .help("Share of your Mac's CPU")
                    }
                    if let port = c.port, !stopped {
                        // A plain String: SwiftUI formats numbers inside text literals for the
                        // locale, which turned port 8003 into "8,003".
                        let label = ":" + String(port)
                        if c.isInfra {
                            Text(verbatim: label).foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            // Web containers open in the browser; databases have nothing to show.
                            Button {
                                NSWorkspace.shared.open(URL(string: "http://localhost" + label)!)
                            } label: {
                                Text(verbatim: label)
                            }
                            .buttonStyle(.hoverSmall)
                            .help(Text(verbatim: "Open localhost" + label))
                        }
                    }
                }
                if hovering {
                    Button(stopped ? "Start" : "Stop") {
                        stopped ? model.start([c.name]) : model.stop([c.name])
                    }
                    .buttonStyle(.hoverSmall)
                }
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
        if let cpu = c.cpu { parts.append(String(format: "%.0f%% CPU", cpuShare(cpu))) }
        return parts.joined(separator: " · ")
    }
}

// A container stuck restarting burns CPU and can kick off other work on every
// start (on Sep 24 one re-ran a chown that made Spotlight re-index 217 PDFs a minute).
struct CrashNote: View {
    @ObservedObject var model: Model

    var body: some View {
        let crashing = model.containers.filter(\.restarting)
        if !crashing.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.warnText)
                Text(crashing.count == 1 ? "\(crashing[0].name) keeps crashing"
                     : "\(crashing.count) containers keep crashing")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(crashing.count == 1 ? "Stop" : "Stop All") { model.stop(crashing.map(\.name)) }
                    .buttonStyle(.hoverSmall)
            }
            .font(.callout)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12)))
            .padding(.bottom, 4)
            .help("Docker keeps restarting \(crashing.count == 1 ? "this container" : "these containers") because \(crashing.count == 1 ? "it exits" : "they exit") on start. Stopping ends the loop until you start \(crashing.count == 1 ? "it" : "them") again.")
        }
    }
}

// Docker Desktop is running but its engine stopped answering, usually because
// the VM died. Restarting brings it back, along with whatever was running.
struct DockerDownNote: View {
    @ObservedObject var model: Model

    var body: some View {
        let count = model.lastRunning.count
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.warnText)
                Text("Docker isn't responding").fontWeight(.medium)
            }
            Text(count == 0 ? "Restarting Docker usually fixes this."
                 : "\(count) container\(count == 1 ? " was" : "s were") running. Restarting Docker brings \(count == 1 ? "it" : "them") back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Restart Docker") { model.restartDocker() }
                    .buttonStyle(.hoverProminent(.accentColor))
            }
        }
        .font(.callout)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.orange.opacity(0.12)))
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

// MARK: - Settings view

// Settings live inside the popover rather than in a separate window: windows
// opened from a menu bar app tend to appear behind whatever is in front.
struct SettingsView: View {
    @ObservedObject var model: Model
    let done: () -> Void
    @AppStorage(Pref.menuText) private var menuText = MenuText.none.rawValue
    @AppStorage(Pref.appCount) private var appCount = 5
    @AppStorage(Pref.showDocker) private var showDocker = true
    @State private var loginStatus = LoginItem.status
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done", action: done)
                    .buttonStyle(.hoverBordered)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SettingRow("Open at login") {
                        Toggle("Open at login", isOn: Binding(
                            get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                            set: { on in
                                do { try LoginItem.set(on); loginError = nil } catch {
                                    loginError = error.localizedDescription
                                }
                                loginStatus = LoginItem.status
                            }))
                    }
                    if loginStatus == .requiresApproval {
                        HStack {
                            Text("macOS needs your OK in Login Items.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                                .buttonStyle(.hoverSmall)
                        }
                    }
                    if let loginError {
                        Text(loginError).font(.caption).foregroundStyle(Color.warnText)
                    }
                    Divider()
                    SettingRow("Menu bar shows") {
                        Picker("Menu bar shows", selection: $menuText) {
                            ForEach(MenuText.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SettingRow("Apps to list") {
                        Picker("Apps to list", selection: $appCount) {
                            ForEach([5, 7, 10], id: \.self) { Text("\($0)").tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                    Divider()
                    SettingRow("Show Docker") { Toggle("Show Docker", isOn: $showDocker) }
                }
            }

            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Headroom \(version)").fontWeight(.medium)
                        Text("Free and open source, MIT license").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("GitHub") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/julioest/headroom")!)
                    }
                    .buttonStyle(.hoverBordered)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .onChange(of: menuText) { model.refreshLabel() }
        .onAppear { loginStatus = LoginItem.status }
    }

    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}

// Label on the left, control on the right, like System Settings.
struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: () -> Control

    init(_ title: String, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.control = control
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            control().labelsHidden()
        }
        .frame(minHeight: 22)
    }
}

// MARK: - Menu bar

// A capsule that fills as the Mac gets busy: the empty space at the top is the
// headroom. Smooth stays a plain template image so it blends in like system
// icons; busy and slow are drawn in orange and red. Built once per verdict.
@MainActor
enum MenuIcon {
    private static var cache: [Verdict: NSImage] = [:]

    static func image(_ v: Verdict) -> NSImage {
        if let img = cache[v] { return img }
        let color = v == .smooth ? NSColor.black : v.nsColor
        // Flipped so the coordinates read top-down, like the design sketches.
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            color.set()
            let capsule = NSBezierPath(roundedRect: NSRect(x: 4.75, y: 1.75, width: 8.5, height: 14.5),
                                       xRadius: 4.25, yRadius: 4.25)
            capsule.lineWidth = 1.5
            capsule.stroke()
            let r = min(2.4, v.level / 2)  // a short fill stays a pill, not a blob
            NSBezierPath(roundedRect: NSRect(x: 6.6, y: 14.65 - v.level, width: 4.8, height: v.level),
                         xRadius: r, yRadius: r).fill()
            return true
        }
        img.isTemplate = v == .smooth
        img.accessibilityDescription = v.title
        cache[v] = img
        return img
    }
}

struct MenuLabel: View {
    @ObservedObject var status: Status

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuIcon.image(status.verdict))
            if !status.text.isEmpty {
                Text(status.text).monospacedDigit()
            }
        }
    }
}

@main
struct HeadroomApp: App {
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
