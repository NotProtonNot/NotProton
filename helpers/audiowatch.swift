import CoreAudio
import Foundation
import System

if ProcessInfo.processInfo.environment["AUDIOWATCH_DEBUG_ENV"] != nil {
    let home = NSHomeDirectory()
    let cx =
        "\(home)/Library/Application Support/notproton/runners/crossover-27.0.0.41073-fex/CrossOver"
    let pfx =
        "\(home)/Library/Application Support/CrossOver/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/compatdata/2075800/pfx"

    let wineEnv: [String: String] = [
        "PATH": "\(cx)/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "CX_ROOT": cx,
        "CX_HOME": "\(home)/Library/Application Support/CrossOver",
        "WINELOADER":
            "\(home)/Library/Application Support/notproton/launchers/2075800/STAR WARS Zero Company™.app/Contents/MacOS/wine",
        "WINESERVER": "\(cx)/bin/wineserver-x86",
        "WINEPREFIX": pfx,
        "WINEMSYNC": "1",
        "WINEDEBUG": "err+all,fixme-all",
        "WINEDLLPATH":
            "\(pfx)/drive_c/Program Files (x86)/Steam:\(cx)/lib/wine/x86_64-windows:\(cx)/lib/wine/x86_64-unix",
    ]
    for (key, value) in wineEnv {
        setenv(key, value, 1)
    }
}

guard let gloader = ProcessInfo.processInfo.environment["WINELOADER"] else {
    print("WINELOADER isn't set in environment")
    exit(1)
}

guard ProcessInfo.processInfo.environment["WINEPREFIX"] != nil else {
    print("WINEPREFIX isn't set in environment")
    exit(1)
}

let rawEnv = ProcessInfo.processInfo.environment["AUDIOWATCH_VERBOSE"]
let verboseLogging: Bool

if let raw = rawEnv {
    if raw == "1" || raw.lowercased() == "true" {
        verboseLogging = true
    } else if raw == "0" || raw.lowercased() == "false" {
        verboseLogging = false
    } else {
        print(
            "[ERROR] audiowatch: AUDIOWATCH_VERBOSE environment variable has to be 0 or 1 if set at all"
        )
        exit(1)
    }
} else {
    verboseLogging = false
}

if verboseLogging {
    print("[DEBUG] audiowatch: verbose logging enabled")
}

func getChildEnvironmentProcess() -> [String: String] {
    let environment = ProcessInfo.processInfo.environment
    var filtered = environment.filter { (key, _) in
        !key.hasPrefix("DYLD_")
    }

    return filtered
}

func runWineProcess(arguments args: [String]) -> (output: String, status: Int32)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: gloader)
    process.arguments = args

    process.environment = getChildEnvironmentProcess()

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()

        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)

    } catch {
        print("[ERROR] Audiowatch: Failed to initialize process for \(gloader). \(error)")
        return nil
    }
}

// This Byte ordering was using AI :)

func getEndpointId(forGuidHex hex: String, input: Bool) -> String? {
    let chars = Array(hex.uppercased())
    guard chars.count == 32, chars.allSatisfy(\.isHexDigit) else {
        print("[ERROR] audioWatch: guid \"\(hex)\" is not 32 hex digits")
        return nil
    }

    func byte(_ i: Int) -> String { String(chars[i * 2...i * 2 + 1]) }
    func bytes(_ order: [Int]) -> String { order.map(byte).joined() }

    let guid = [
        bytes([3, 2, 1, 0]),  // Data1, reversed
        bytes([5, 4]),  // Data2, reversed
        bytes([7, 6]),  // Data3, reversed
        bytes([8, 9]),  // Data4[0...1], in order
        bytes(Array(10...15)),  // Data4[2...7], in order
    ].joined(separator: "-")

    return "{0.0.\(input ? 1 : 0).00000000}.{\(guid)}"
}

let driverKey = #"HKCU\Software\Wine\Drivers\winecoreaudio.drv"#

func setRegistryDefaultValue(valueName: String, value: String) {
    let args: [String] = [
        "reg", "add", driverKey,
        "/v", valueName, "/t", "REG_SZ",
        "/d", value, "/f",
    ]
    let result = runWineProcess(arguments: args)
    guard let (_, status) = result, status == 0 else {
        print("[ERROR] audioWatch: Failed to set value_name (\(valueName) on wine")
        return
    }
    print("audioWatch: Set default value on \(valueName)")
}

func getHexGuidForUID(uid: String, input: Bool) -> String? {
    let key = #"\#(driverKey)\devices\\#(input ? 1 : 0),\#(uid)"#
    if verboseLogging { print("[DEBUG] audioWatch: Query key is: \(key)") }

    let args: [String] = ["reg", "query", key, "/v", "guid"]
    let result = runWineProcess(arguments: args)
    if verboseLogging {
        print(
            "[DEBUG] audioWatch: Output from runWineProcess: \n \(result?.output ?? "no output was captured")"
        )
    }

    guard let (output, status) = result, status == 0 else {
        return nil
    }

    // trying to get GUID out of something like
    // guid    REG_BINARY    B7BDFD16E6EEF345B212B490F21956FB

    guard let sentinelRange = output.range(of: "REG_BINARY") else {
        return nil
    }
    var currentIndex = sentinelRange.upperBound
    while currentIndex < output.endIndex && output[currentIndex].isWhitespace {
        currentIndex = output.index(after: currentIndex)
    }
    if currentIndex == output.endIndex { return nil }
    let wordStart = currentIndex
    while currentIndex < output.endIndex && !output[currentIndex].isWhitespace {
        currentIndex = output.index(after: currentIndex)
    }
    let guid = String(output[wordStart..<currentIndex])
    if verboseLogging { print("[DEBUG] audioWatch: extracted guid \(guid) from wine output") }
    return guid
}

func getUIDFromCoreAudioDefaultDevice(input: Bool) -> String? {
    // yay CoreAudio APIs. First let's ask for the Device
    var addr = AudioObjectPropertyAddress(
        mSelector: input
            ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    var dev = AudioDeviceID(kAudioObjectUnknown)
    var devSize = UInt32(MemoryLayout<AudioObjectID>.stride)
    var status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &devSize, &dev)
    if (status != noErr) || (dev == kAudioDeviceUnknown) {
        print("[ERROR] Audiowatch: Unable to get the current audio device")
        return nil
    }

    //Now let's ask for the UID
    var uid: Unmanaged<CFString>?
    var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.stride)

    addr.mSelector = kAudioDevicePropertyDeviceUID
    status = AudioObjectGetPropertyData(dev, &addr, 0, nil, &uidSize, &uid)
    guard status == noErr, let unmanagedUID = uid else {
        print("[ERROR] Audiowatch: Cannot get uid for audio device")
        return nil
    }
    let cfUID = unmanagedUID.takeRetainedValue()
    if verboseLogging { print("[DEBUG] audiowatch: uid is: \(cfUID)") }
    return String(cfUID)
}

func handleAudioDeviceChange(input: Bool) {
    let uidForDefaultDevice = getUIDFromCoreAudioDefaultDevice(input: input)
    if verboseLogging {
        print(
            "uid from main for \(input ? "Mic":"Speakers") is: \(uidForDefaultDevice ?? "Nothing???")"
        )
    }

    guard let uid = uidForDefaultDevice else {
        print("[ERROR] audioWatch: Couldn't unwrap uidForDefaultDevice")
        return
    }

    guard let hexGuid = getHexGuidForUID(uid: uid, input: input) else {
        print("[ERROR] audioWatch: couldn't extract hexGuid from output from wine")
        return
    }

    guard let endPointId = getEndpointId(forGuidHex: hexGuid, input: input) else {
        return
    }

    setRegistryDefaultValue(valueName: input ? "DefaultInput" : "DefaultOutput", value: endPointId)
    setRegistryDefaultValue(
        valueName: input ? "DefaultVoiceInput" : "DefaultVoiceOutput", value: endPointId)
}

func startMonitoring(targetPid: Int) -> DispatchSourceProcess {
    let source = DispatchSource.makeProcessSource(
        identifier: Int32(targetPid), eventMask: .exit, queue: DispatchQueue.main)
    source.setEventHandler { exit(0) }
    source.resume()
    if kill(Int32(targetPid), 0) != 0 && errno == ESRCH { exit(0) }
    return source
}

let arguments = CommandLine.arguments
var targetPid: Int = 0
var runOnce = false

var i = 1
while i < arguments.count {
    let arg = arguments[i]

    if arg == "-w" {
        guard i + 1 < arguments.count else {
            print("[ERROR] Missing value for \(arg) option.")
            exit(1)
        }
        let pidString = arguments[i + 1]
        guard let pid = Int(pidString) else {
            print("[ERROR] PID must be a valid integer. Got: '\(pidString)'")
            exit(1)
        }
        targetPid = pid
        i += 2
    } else if arg == "--once" {
        runOnce = true
        i += 1
    } else {
        print("[ERROR] Unknown argument: \(arg)")
        print("Usage: audiowatch -w <pid> [--once]")
        exit(1)
    }
}

if runOnce {
    handleAudioDeviceChange(input: false)
    handleAudioDeviceChange(input: true)
    exit(0)
}

var processMonitoring: DispatchSourceProcess

if targetPid > 0 {
    print("audioWatch: Tracking for Process \(targetPid)")
    processMonitoring = startMonitoring(targetPid: targetPid)
}

var gQueue = DispatchQueue(label: "notproton.audiowatch")
var outAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var inAddr = outAddr
inAddr.mSelector = kAudioHardwarePropertyDefaultInputDevice

var listenerStatus = AudioObjectAddPropertyListenerBlock(
    AudioObjectID(kAudioObjectSystemObject), &outAddr, gQueue
) {
    (_, _) in
    handleAudioDeviceChange(input: false)
}
if listenerStatus != 0 {
    print("[ERROR] audiowatch: Failed to attach output change listener (error: \(listenerStatus))")
    exit(1)
}

listenerStatus = AudioObjectAddPropertyListenerBlock(
    AudioObjectID(kAudioObjectSystemObject), &inAddr, gQueue
) {
    (_, _) in
    handleAudioDeviceChange(input: true)
}

if listenerStatus != 0 {
    print("[ERROR] audiowatch: Failed to attach input change listener (error: \(listenerStatus))")
    exit(1)
}
dispatchMain()
