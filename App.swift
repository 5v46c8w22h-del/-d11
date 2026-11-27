import SwiftUI
import CoreBluetooth
import UIKit
import Network
import Darwin

@main
struct D11BLEAnalyzerApp: App {
    var body: some Scene {
        WindowGroup {
            AnalyzerView()
        }
    }
}

struct BLELogEntry: Identifiable, Codable {
    var id = UUID()
    var time: Date = Date()
    var direction: String
    var detail: String
    var hex: String = ""

    var line: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let suffix = hex.isEmpty ? "" : " | \(hex)"
        return "[\(formatter.string(from: time))] [\(direction)] \(detail)\(suffix)"
    }
}

final class BLEAnalyzer: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var stateText = "等待蓝牙授权"
    @Published var devices: [CBPeripheral] = []
    @Published var connectedName = "未连接"
    @Published var services: [CBService] = []
    @Published var selectedService: CBUUID?
    @Published var selectedCharacteristic: CBCharacteristic?
    @Published var characteristicRows: [String] = []
    @Published var logs: [BLELogEntry] = []
    @Published var isScanning = false
    @Published var isConnected = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var pendingPeripheral: CBPeripheral?
    private var characteristics: [CBCharacteristic] = []
    private let logLimit = 3000
    var onEntry: ((BLELogEntry) -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func add(_ direction: String, _ detail: String, data: Data? = nil) {
        let hex = data.map { Self.hex($0) } ?? ""
        let entry = BLELogEntry(direction: direction, detail: detail, hex: hex)
        logs.append(entry)
        if logs.count > logLimit {
            logs.removeFirst(logs.count - logLimit)
        }
        // 每条 BLE 日志（尤其 RX/TX/ACK/ERR）同步推送到已连接的 Windows 客户端。
        onEntry?(entry)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func parseHex(_ text: String) -> Data? {
        let cleaned = text
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()

        guard !cleaned.isEmpty, cleaned.count.isMultiple(of: 2) else {
            return nil
        }

        var bytes: [UInt8] = []
        var index = cleaned.startIndex

        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let value = UInt8(cleaned[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(value)
            index = next
        }

        return Data(bytes)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            stateText = "蓝牙已开启"
            add("SYS", stateText)
        case .poweredOff:
            stateText = "蓝牙已关闭"
            add("ERR", stateText)
        case .unauthorized:
            stateText = "蓝牙未授权"
            add("ERR", "蓝牙未授权，请检查系统设置")
        case .unsupported:
            stateText = "设备不支持 BLE"
            add("ERR", stateText)
        case .resetting:
            stateText = "蓝牙正在重置"
            add("SYS", stateText)
        default:
            stateText = "等待蓝牙状态"
        }
    }

    func scan() {
        guard central.state == .poweredOn else {
            stateText = "请先开启蓝牙并授权"
            add("ERR", stateText)
            return
        }

        devices.removeAll()
        isScanning = true
        stateText = "正在扫描附近 BLE 设备…"
        add("SYS", "开始扫描 BLE 设备（扫描结果不代表已连接）")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.isScanning else { return }
            self.central.stopScan()
            self.isScanning = false
            self.stateText = "扫描结束，发现 \(self.devices.count) 台设备"
            self.add("SYS", self.stateText)
        }
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        stateText = "已停止扫描"
        add("SYS", stateText)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover p: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = localName ?? p.name ?? "未命名设备"

        if !devices.contains(where: { $0.identifier == p.identifier }) {
            devices.append(p)
            add("SCAN", "发现设备：\(name)，RSSI \(RSSI) dBm，ID \(p.identifier.uuidString)")
        }
    }

    func connect(_ p: CBPeripheral) {
        stopScan()

        if let current = peripheral {
            if current === p && isConnected {
                add("SYS", "设备已经连接，无需重复连接")
                return
            }
            if current !== p {
                pendingPeripheral = p
                add("SYS", "先释放当前设备连接，再连接新设备")
                disconnect(reason: "切换设备，正在释放旧连接")
                return
            }
            // 同一设备正在连接时不重复发起 connect。
            add("SYS", "该设备正在连接或等待断开")
            return
        }

        beginConnect(p)
    }

    private func beginConnect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        services = []
        characteristics = []
        characteristicRows = []
        selectedCharacteristic = nil
        selectedService = nil
        isConnected = false
        connectedName = p.name ?? p.identifier.uuidString
        stateText = "正在连接 \(connectedName)…"
        add("SYS", stateText)
        central.connect(p, options: nil)
    }

    func disconnect(reason: String = "用户主动断开") {
        guard let p = peripheral else {
            isConnected = false
            connectedName = "未连接"
            stateText = "已断开"
            add("SYS", stateText)
            return
        }

        // 先取消所有通知订阅，再请求系统断开；保留 peripheral 引用，
        // 直到 didDisconnect 回调到达，避免状态提前清空及切换设备竞态。
        for characteristic in characteristics where characteristic.isNotifying {
            p.setNotifyValue(false, for: characteristic)
        }
        isConnected = false
        stateText = reason
        add("SYS", "\(reason)：正在停止通知并释放 BLE 连接")
        central.cancelPeripheralConnection(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard peripheral === p else { return }
        isConnected = true
        stateText = "已连接，正在发现服务"
        connectedName = p.name ?? p.identifier.uuidString
        add("SYS", "连接成功：\(connectedName)")
        p.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect p: CBPeripheral,
        error: Error?
    ) {
        stateText = "连接失败：\(error?.localizedDescription ?? "未知错误")"
        add("ERR", stateText)
        if peripheral === p {
            peripheral = nil
            isConnected = false
            connectedName = "未连接"
        }
        if let next = pendingPeripheral {
            pendingPeripheral = nil
            beginConnect(next)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral p: CBPeripheral,
        error: Error?
    ) {
        add("SYS", "系统已完成 BLE 断开：\(error?.localizedDescription ?? "正常断开")")
        guard peripheral === p else { return }

        p.delegate = nil
        peripheral = nil
        isConnected = false
        connectedName = "未连接"
        services = []
        characteristics = []
        characteristicRows = []
        selectedCharacteristic = nil
        selectedService = nil
        stateText = "已断开，蓝牙连接已释放"

        if let next = pendingPeripheral {
            pendingPeripheral = nil
            add("SYS", "旧连接已释放，开始连接下一台设备")
            beginConnect(next)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            add("ERR", "发现服务失败：\(error.localizedDescription)")
            return
        }

        services = p.services ?? []
        add("SYS", "发现 \(services.count) 个服务")

        for service in services {
            add("SVC", "服务 UUID：\(service.uuid.uuidString)")
            p.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ p: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            add("ERR", "特征发现失败 \(service.uuid): \(error.localizedDescription)")
            return
        }

        for characteristic in service.characteristics ?? [] {
            characteristics.append(characteristic)
            let props = Self.properties(characteristic.properties)
            characteristicRows.append(
                "\(service.uuid.uuidString) / \(characteristic.uuid.uuidString) [\(props)]"
            )
            add(
                "CHR",
                "服务 \(service.uuid.uuidString)，特征 \(characteristic.uuid.uuidString)，属性：\(props)"
            )
        }
    }

    static func properties(_ properties: CBCharacteristicProperties) -> String {
        var values: [String] = []
        if properties.contains(.read) { values.append("READ") }
        if properties.contains(.write) { values.append("WRITE") }
        if properties.contains(.writeWithoutResponse) { values.append("WRITE_NO_RESPONSE") }
        if properties.contains(.notify) { values.append("NOTIFY") }
        if properties.contains(.indicate) { values.append("INDICATE") }
        if properties.contains(.broadcast) { values.append("BROADCAST") }
        return values.isEmpty ? "无" : values.joined(separator: ", ")
    }

    func selectCharacteristic(_ characteristic: CBCharacteristic) {
        selectedCharacteristic = characteristic
        selectedService = characteristic.service?.uuid
        add("SYS", "选中目标特征：\(characteristic.uuid.uuidString)")
    }

    func subscribe(_ characteristic: CBCharacteristic) {
        guard let peripheral,
              characteristic.properties.contains(.notify) ||
              characteristic.properties.contains(.indicate) else {
            add("ERR", "该特征不支持通知")
            return
        }

        peripheral.setNotifyValue(true, for: characteristic)
        add("SYS", "请求订阅通知：\(characteristic.uuid.uuidString)")
    }

    func read(_ characteristic: CBCharacteristic) {
        guard let peripheral,
              characteristic.properties.contains(.read) else {
            add("ERR", "该特征不支持 READ")
            return
        }

        peripheral.readValue(for: characteristic)
        add("SYS", "请求读取：\(characteristic.uuid.uuidString)")
    }

    func write(_ data: Data, to characteristic: CBCharacteristic) {
        guard let peripheral else {
            add("ERR", "尚未连接设备")
            return
        }

        let writeType: CBCharacteristicWriteType
        if characteristic.properties.contains(.write) {
            writeType = .withResponse
        } else if characteristic.properties.contains(.writeWithoutResponse) {
            writeType = .withoutResponse
        } else {
            add("ERR", "所选特征不支持写入")
            return
        }

        add(
            "TX",
            "写入特征 \(characteristic.uuid.uuidString)，\(data.count) bytes",
            data: data
        )
        peripheral.writeValue(data, for: characteristic, type: writeType)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            add("ERR", "接收/读取失败 \(characteristic.uuid)：\(error.localizedDescription)")
            return
        }

        if let data = characteristic.value {
            add("RX", "特征 \(characteristic.uuid)，\(data.count) bytes", data: data)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            add("ERR", "写入回调失败 \(characteristic.uuid)：\(error.localizedDescription)")
        } else {
            add("ACK", "系统 BLE 写入回调成功：\(characteristic.uuid.uuidString)（不等于打印机已执行）")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            add("ERR", "通知订阅失败 \(characteristic.uuid)：\(error.localizedDescription)")
        } else {
            add("SYS", "通知状态 \(characteristic.uuid)：\(characteristic.isNotifying ? "已开启" : "已关闭")")
        }
    }

    func bridgeWrite(uuid: String, hex: String) -> String {
        guard isConnected else { return "ERROR: BLE_NOT_CONNECTED" }
        guard let data = Self.parseHex(hex) else { return "ERROR: INVALID_HEX" }
        guard let characteristic = characteristics.first(where: {
            $0.uuid.uuidString.caseInsensitiveCompare(uuid) == .orderedSame
        }) else { return "ERROR: CHARACTERISTIC_NOT_FOUND" }
        write(data, to: characteristic)
        return "OK: WRITE_QUEUED"
    }

    func bridgeSubscribe(uuid: String) -> String {
        guard isConnected else { return "ERROR: BLE_NOT_CONNECTED" }
        guard let characteristic = characteristics.first(where: {
            $0.uuid.uuidString.caseInsensitiveCompare(uuid) == .orderedSame
        }) else { return "ERROR: CHARACTERISTIC_NOT_FOUND" }
        subscribe(characteristic)
        return "OK: SUBSCRIBE_REQUESTED"
    }

    func bridgeRead(uuid: String) -> String {
        guard isConnected else { return "ERROR: BLE_NOT_CONNECTED" }
        guard let characteristic = characteristics.first(where: {
            $0.uuid.uuidString.caseInsensitiveCompare(uuid) == .orderedSame
        }) else { return "ERROR: CHARACTERISTIC_NOT_FOUND" }
        read(characteristic)
        return "OK: READ_REQUESTED"
    }

    func clearLogs() {
        logs.removeAll()
        add("SYS", "日志已清空")
    }
}


final class WiFiBLEBridge: ObservableObject {
    @Published var isRunning = false
    @Published var status = "未启动"
    @Published var localAddress = "请连接 Wi-Fi"
    @Published var lastClient = "尚无电脑连接"

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "D11.WiFiBLEBridge")
    var onCommand: (([String: String]) -> String)?
    var onLog: ((String, String) -> Void)?

    func start() {
        guard !isRunning else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let newListener = try NWListener(using: params, on: 8765)
            listener = newListener
            newListener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.status = "已启动，端口 8765"
                        self?.localAddress = Self.findWiFiIPv4() ?? "未获取到局域网 IP"
                    case .failed(let error):
                        self?.isRunning = false
                        self?.status = "启动失败：\(error.localizedDescription)"
                    case .cancelled:
                        self?.isRunning = false
                        self?.status = "已停止"
                    default:
                        break
                    }
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            newListener.start(queue: queue)
            status = "正在启动…"
        } catch {
            status = "启动失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        DispatchQueue.main.async {
            self.isRunning = false
            self.status = "已停止"
            self.lastClient = "尚无电脑连接"
        }
    }

    func sendEvent(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        let payload = Data((text + "\n").utf8)
        queue.async {
            for connection in self.connections.values {
                connection.send(content: payload, completion: .contentProcessed { _ in })
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .ready = state {
                DispatchQueue.main.async {
                    self.lastClient = "Windows 已连接"
                    self.onLog?("SYS", "Windows 客户端已连接到 Wi-Fi 蓝牙桥接")
                }
                self.receiveLine(connection, key: key, buffer: Data())
            } else {
                switch state {
                case .failed, .cancelled:
                    self.connections.removeValue(forKey: key)
                    DispatchQueue.main.async {
                        self.lastClient = self.connections.isEmpty ? "尚无电脑连接" : "Windows 已连接"
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLine(_ connection: NWConnection, key: ObjectIdentifier, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var pending = buffer
            if let data { pending.append(data) }

            while let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                self.processLine(Data(line), on: connection)
            }

            if error != nil || isComplete {
                self.connections.removeValue(forKey: key)
                connection.cancel()
                return
            }
            self.receiveLine(connection, key: key, buffer: pending)
        }
    }

    private func processLine(_ data: Data, on connection: NWConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            reply(["result": "ERROR", "message": "INVALID_JSON"], to: connection)
            return
        }
        let result = onCommand?(object) ?? "ERROR: NO_HANDLER"
        reply(["result": result], to: connection)
    }

    private func reply(_ object: [String: String], to connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        connection.send(content: data + Data([10]), completion: .contentProcessed { _ in })
    }

    private static func findWiFiIPv4() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(item.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  let addr = item.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: host)
            if name == "en0" { break }
        }
        return address
    }
}

struct AnalyzerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var ble = BLEAnalyzer()
    @StateObject private var bridge = WiFiBLEBridge()
    @State private var hexInput = "55 55"
    @State private var showShare = false
    @State private var exportURL: URL?
    @State private var filter = "全部"
    @State private var alertText = ""
    @State private var showAlert = false

    private var chosenCharacteristic: CBCharacteristic? {
        ble.selectedCharacteristic
    }

    private var visibleLogs: [BLELogEntry] {
        if filter == "全部" { return ble.logs }
        return ble.logs.filter { $0.direction == filter }
    }

    var body: some View {
        NavigationStack {
            List {
                bridgeSection
                deviceSection
                servicesSection
                sendSection
                logsSection
            }
            .navigationTitle("D11 BLE Analyzer")
            .onAppear {
                bridge.onCommand = { command in
                    let action = command["action"] ?? ""
                    switch action {
                    case "write":
                        guard let uuid = command["uuid"], let hex = command["hex"] else {
                            return "ERROR: MISSING_UUID_OR_HEX"
                        }
                        return ble.bridgeWrite(uuid: uuid, hex: hex)
                    case "subscribe":
                        guard let uuid = command["uuid"] else { return "ERROR: MISSING_UUID" }
                        return ble.bridgeSubscribe(uuid: uuid)
                    case "read":
                        guard let uuid = command["uuid"] else { return "ERROR: MISSING_UUID" }
                        return ble.bridgeRead(uuid: uuid)
                    case "status":
                        return ble.isConnected ? "BLE_CONNECTED" : "BLE_DISCONNECTED"
                    default:
                        return "ERROR: UNKNOWN_ACTION"
                    }
                }
                bridge.onLog = { direction, message in ble.add(direction, message) }
                ble.onEntry = { entry in
                    bridge.sendEvent([
                        "type": "ble_event",
                        "time": ISO8601DateFormatter().string(from: entry.time),
                        "direction": entry.direction,
                        "detail": entry.detail,
                        "hex": entry.hex
                    ])
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .background {
                    bridge.stop()
                    ble.disconnect(reason: "应用进入后台，自动释放打印机连接")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: exportLog) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                if let url = exportURL {
                    ActivityView(activityItems: [url])
                }
            }
            .alert("提示", isPresented: $showAlert) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(alertText)
            }
        }
    }

    private var bridgeSection: some View {
        Section("Windows Wi-Fi 蓝牙桥接") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(bridge.status).font(.headline)
                    Text("电脑连接地址：\(bridge.localAddress):8765")
                        .font(.caption)
                        .textSelection(.enabled)
                    Text(bridge.lastClient)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(bridge.isRunning ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
            }

            HStack {
                Button("启动桥接") { bridge.start() }
                    .disabled(bridge.isRunning)
                Button("停止桥接") { bridge.stop() }
                    .disabled(!bridge.isRunning)
            }

            Text("电脑与 iPhone 必须连接同一 Wi-Fi。桥接只转发本工具支持的 BLE 操作，不会监听官方 APP。不要在不可信的公共 Wi-Fi 上启动。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var deviceSection: some View {
        Section("设备") {
            HStack {
                VStack(alignment: .leading) {
                    Text(ble.connectedName).font(.headline)
                    Text(ble.stateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(ble.isConnected ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
            }

            HStack {
                Button(ble.isScanning ? "扫描中…" : "扫描设备") {
                    ble.scan()
                }
                .disabled(ble.isScanning)

                Button("停止扫描") {
                    ble.stopScan()
                }
                .disabled(!ble.isScanning)

                Button("断开并释放") {
                    ble.disconnect()
                }
                .disabled(!ble.isConnected && ble.connectedName == "未连接")
            }

            ForEach(ble.devices, id: \.identifier) { device in
                deviceButton(device)
            }
        }
    }

    private func deviceButton(_ device: CBPeripheral) -> some View {
        Button {
            ble.connect(device)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(device.name ?? "未命名设备")
                    Text(device.identifier.uuidString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if ble.isConnected && ble.connectedName == device.name {
                    Text("已连接").foregroundStyle(.green)
                }
            }
        }
    }

    private var servicesSection: some View {
        Section("服务与特征值") {
            if ble.characteristicRows.isEmpty {
                Text("连接设备后自动发现服务和特征值")
                    .foregroundStyle(.secondary)
            }

            ForEach(ble.services, id: \.uuid) { service in
                DisclosureGroup("服务：\(service.uuid.uuidString)") {
                    ForEach(service.characteristics ?? [], id: \.uuid) { characteristic in
                        characteristicRow(characteristic, service: service)
                    }
                }
            }
        }
    }

    private func characteristicRow(
        _ characteristic: CBCharacteristic,
        service: CBService
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                ble.selectCharacteristic(characteristic)
            } label: {
                HStack {
                    Text(characteristic.uuid.uuidString)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    if ble.selectedCharacteristic === characteristic {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
            }

            Text(BLEAnalyzer.properties(characteristic.properties))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if characteristic.properties.contains(.notify) ||
                    characteristic.properties.contains(.indicate) {
                    Button("订阅通知") {
                        ble.subscribe(characteristic)
                    }
                    .buttonStyle(.bordered)
                }

                if characteristic.properties.contains(.read) {
                    Button("读取") {
                        ble.read(characteristic)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var sendSection: some View {
        Section("手动发送 HEX") {
            Text("选择支持 WRITE 或 WRITE_NO_RESPONSE 的特征值后发送。这里只记录本工具自身发出的数据，不会截获官方 APP 的通信。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(
                "例如：55 55 40 01 41 AA AA",
                text: $hexInput,
                axis: .vertical
            )
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.characters)

            Button("发送到所选特征值", action: sendHex)
                .disabled(!ble.isConnected)
        }
    }

    private func sendHex() {
        guard let characteristic = chosenCharacteristic else {
            showMessage("请先在上方选择一个特征值")
            return
        }

        guard let data = BLEAnalyzer.parseHex(hexInput) else {
            showMessage("HEX 格式无效：请输入偶数个十六进制字符")
            return
        }

        ble.write(data, to: characteristic)
    }

    private var logsSection: some View {
        Section {
            logControls

            Text("记录数：\(visibleLogs.count)（最多保留 3000 条）")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(visibleLogs.reversed()) { entry in
                logRow(entry)
            }
        } header: {
            Text("实时通信日志")
        }
    }

    private var logControls: some View {
        HStack {
            Picker("筛选", selection: $filter) {
                ForEach(
                    ["全部", "TX", "RX", "ACK", "ERR", "SYS", "SCAN", "SVC", "CHR"],
                    id: \.self
                ) { value in
                    Text(value).tag(value)
                }
            }

            Spacer()

            Button("导出日志", action: exportLog)

            Button("清空") {
                ble.clearLogs()
            }
            .foregroundStyle(.red)
        }
    }

    private func logRow(_ entry: BLELogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.direction)
                    .font(.caption.bold())
                    .foregroundStyle(color(for: entry.direction))

                Spacer()

                Text(entry.time, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(entry.detail).font(.caption)

            if !entry.hex.isEmpty {
                Text(entry.hex)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }

    private func color(for key: String) -> Color {
        switch key {
        case "TX": return .blue
        case "RX": return .green
        case "ERR": return .red
        case "ACK": return .purple
        default: return .secondary
        }
    }

    private func showMessage(_ message: String) {
        alertText = message
        showAlert = true
    }

    private func exportLog() {
        let logText = ble.logs.map(\.line).joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("D11-BLE-Log-\(Int(Date().timeIntervalSince1970)).txt")

        do {
            try logText.write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
            showShare = true
        } catch {
            showMessage("导出失败：\(error.localizedDescription)")
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ controller: UIActivityViewController,
        context: Context
    ) {}
}
