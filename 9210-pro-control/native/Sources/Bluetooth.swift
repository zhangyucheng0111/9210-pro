import Foundation
import CoreBluetooth
import Combine

struct NearbyDevice: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

@MainActor final class BluetoothController: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published var devices: [NearbyDevice] = []
    @Published var status = "未连接"
    @Published var ready = false
    @Published private(set) var connecting = false
    @Published var scanning = false
    @Published var uncertain = false
    @Published private(set) var busy=false
    @Published var writePreference="auto"
    @Published var packetLimit=197
    @Published private(set) var linkDetails=""
    @Published private(set) var lastTransfer=""
    @Published private(set) var connectionPreferences=BluetoothConnectionPreferences()
    @Published private(set) var preferencesError:String?
    var autoConnectEnabled:Bool { connectionPreferences.autoConnect }
    var preferredDeviceName:String { connectionPreferences.preferredName }
    var preferredDeviceID:UUID? { connectionPreferences.preferredID }
    var hasStartedBluetooth:Bool { central != nil }
    /// Actual CoreBluetooth write call times, not motor-start or peripheral-acceptance times.
    private(set) var transferFirstWriteAt:Date?
    private(set) var transferLastWriteAt:Date?
    private(set) var firstWriteUptimeNS:UInt64?
    private(set) var lastWriteUptimeNS:UInt64?
    var onReady:(()->Void)?
    @Published var positions: [Int32] = []
    var onLog: ((String,String) -> Void)?
    private var central: CBCentralManager?
    private var known: [UUID:CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var disconnectingIDs:Set<UUID> = []
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var outbound: [Data] = []
    private var writing = false
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var completedReply:WireFrame?
    private var matcher:ReplyMatcher?
    private var writeContinuation:CheckedContinuation<Void,Error>?
    private var drainTask:Task<Void,Never>?
    private var lastWriteAt:Date?
    private var lastGlobalWriteUptimeNS:UInt64?
    private var minimumWriteIntervalNanoseconds=TransferPolicy.intervalNanoseconds
    private var sendOnlyOperation:UUID?
    private var sendOnlyCancellation:TransferCancellationToken?
    private var cancelSendOnlyAfterWrite=false
    private var transmitted=0
    private var received=0
    private var continuation: CheckedContinuation<WireFrame,Error>?
    private var timeout: Task<Void,Never>?
    private var scanTask: Task<Void,Never>?
    private var linkGeneration: UInt64 = 0
    private enum DiscoveryIntent { case none, manual, automatic }
    private var discoveryIntent=DiscoveryIntent.none
    private var automaticallyConnecting=false
    private var startupHandled=false
    private var preferencesAvailable=true
    private var preferencesStore:BluetoothPreferencesStore?
    private let stream = WireStream()
    private let serviceID = CBUUID(string:"FFE0"), writeID = CBUUID(string:"FFE1"), notifyID = CBUUID(string:"FFE2")

    func configurePreferences(at url:URL) {
        guard central == nil else { return }
        let store=BluetoothPreferencesStore(url:url);preferencesStore=store
        do { connectionPreferences=try store.load();preferencesAvailable=true;preferencesError=nil }
        catch {
            preferencesAvailable=false
            preferencesError="蓝牙连接设置读取失败，已暂停自动连接："+error.localizedDescription
            status="自动连接设置读取失败，可手动连接";onLog?("连接设置",preferencesError!)
        }
    }
    private func saveConnectionPreferences() {
        guard let store=preferencesStore else { return }
        do { try store.save(connectionPreferences);preferencesAvailable=true;preferencesError=nil }
        catch { preferencesError="蓝牙连接设置保存失败："+error.localizedDescription;onLog?("连接设置",preferencesError!) }
    }
    func setAutoConnectEnabled(_ enabled:Bool) {
        guard !busy else { return }
        connectionPreferences.autoConnect=enabled;saveConnectionPreferences()
        if enabled { connectDefaultDevice() }
        else {
            if automaticallyConnecting { disconnect() }
            else if discoveryIntent == .automatic { stopDiscovery();status="已取消自动查找，可手动选择设备" }
        }
    }
    /// Called only by the real app's launch path, never by model initialization.
    func startAutomaticConnection() {
        guard !startupHandled else { return };startupHandled=true
        guard autoConnectEnabled,preferencesAvailable,!ready,!connecting,!busy else { return }
        connectDefaultDevice()
    }
    func connectDefaultDevice() {
        guard preferencesAvailable,!ready,!connecting,!busy else { return }
        discoveryIntent = .automatic
        if central == nil { status="正在初始化蓝牙，准备连接 \(preferredDeviceName)…";central=CBCentralManager(delegate:self,queue:.main);return }
        if central?.state == .poweredOn { beginAutomaticAttempt() }
    }
    private func beginAutomaticAttempt() {
        guard discoveryIntent == .automatic,preferencesAvailable,!ready,!connecting,!busy,let central=central,central.state == .poweredOn else { return }
        if let id=preferredDeviceID,let target=central.retrievePeripherals(withIdentifiers:[id]).first {
            known[id]=target
            devices=[NearbyDevice(id:id,name:target.name ?? preferredDeviceName,rssi:0)]
            connect(id,automatically:true)
        } else { beginScan() }
    }
    /// Explicit scanning cancels automatic selection so the user can choose another device.
    func scan() {
        guard !ready,!connecting,!busy else { return }
        discoveryIntent = .manual
        if central == nil { central = CBCentralManager(delegate:self,queue:.main);return }
        guard central?.state == .poweredOn else { status="请在系统设置开启蓝牙并允许此 App 使用蓝牙";return }
        beginScan()
    }
    func chooseAnotherDevice() {
        guard !busy else { return }
        disconnect();scan()
    }
    private func stopDiscovery() {
        scanTask?.cancel();scanTask=nil;central?.stopScan();scanning=false;discoveryIntent = .none
    }
    private func beginScan() {
        guard discoveryIntent != .none,!ready,!connecting,!busy,central?.state == .poweredOn else { return }
        scanTask?.cancel()
        devices=[];known=[:];scanning=true
        status=discoveryIntent == .automatic ? "正在查找默认设备 \(preferredDeviceName)…" : "正在查找工作站…"
        central?.scanForPeripherals(withServices:nil,options:[CBCentralManagerScanOptionAllowDuplicatesKey:false])
        scanTask=Task {
            do { try await Task.sleep(nanoseconds:8_000_000_000) } catch { return }
            guard !Task.isCancelled,self.scanning else { return }
            let automatic=self.discoveryIntent == .automatic
            self.stopDiscovery()
            guard !self.ready,!self.connecting else { return }
            if automatic {
                let candidates=self.devices.map { BluetoothCandidate(id:$0.id,name:$0.name) }
                if let id=self.connectionPreferences.candidate(in:candidates) { self.connect(id,automatically:true) }
                else {
                    let count=candidates.filter { self.connectionPreferences.matches(id:$0.id,name:$0.name) }.count
                    self.status=count>1 ? "发现多个 \(self.preferredDeviceName)，请在连接面板选择" : "未找到默认设备 \(self.preferredDeviceName)，可在连接面板重试或更换"
                }
            } else { self.status="找到 \(self.devices.count) 个设备，请选择工作站" }
        }
    }
    func connect(_ id: UUID) { connect(id,automatically:false) }
    private func connect(_ id:UUID,automatically:Bool) {
        guard !busy,!ready,!connecting,central?.state == .poweredOn,let target=known[id] else { return }
        guard !disconnectingIDs.contains(id) else { status="上一次连接正在断开，请稍后重试";return }
        // A system-connected peripheral still needs this central's own
        // connect call (CBCentralManager.h). Reject only transitional states.
        guard target.state == .disconnected || target.state == .connected else { status="设备连接状态正在切换，请稍后重试";return }
        stopDiscovery();automaticallyConnecting=automatically
        linkGeneration &+= 1
        let generation=linkGeneration
        connecting=true;peripheral=target;writeCharacteristic=nil;notifyCharacteristic=nil
        target.delegate=self;status="正在连接 \(target.name ?? "工作站")…";stream.reset();positions=[]
        central?.connect(target,options:nil)
        timeout?.cancel();timeout=Task {
            do { try await Task.sleep(nanoseconds:12_000_000_000) } catch { return }
            guard !Task.isCancelled,self.linkGeneration==generation,self.connecting,!self.ready else { return }
            self.disconnect();self.status="连接／服务发现超时，请检查平板是否占用蓝牙"
        }
    }
    func disconnect() {
        stopDiscovery();automaticallyConnecting=false
        clearSession(error:ControlError.invalid("蓝牙连接已断开"));status="未连接"
    }
    private func isCurrentConnected(_ candidate:CBPeripheral) -> Bool {
        candidate === peripheral && candidate.state == .connected
    }
    private func clearSession(error:Error,cancelConnection:Bool=true) {
        let old=peripheral
        if busy { uncertain=true }
        ready=false;connecting=false;linkGeneration &+= 1
        peripheral=nil;writeCharacteristic=nil;notifyCharacteristic=nil
        old?.delegate=nil
        finish(.failure(error))
        stopDiscovery();automaticallyConnecting=false
        stream.reset();positions=[];lastWriteAt=nil;lastGlobalWriteUptimeNS=nil;linkDetails=""
        if cancelConnection,central?.state == .poweredOn,let old=old {
            if old.state != .disconnected { disconnectingIDs.insert(old.identifier) }
            central?.cancelPeripheralConnection(old)
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            let intent=discoveryIntent
            clearSession(error:ControlError.invalid("蓝牙不可用"),cancelConnection:false)
            discoveryIntent=intent
            disconnectingIDs.removeAll()
        }
        switch central.state {
        case .poweredOn:
            guard !ready,!connecting,!busy else { return }
            status="蓝牙已就绪"
            if discoveryIntent == .automatic { beginAutomaticAttempt() }
            else if discoveryIntent == .manual { beginScan() }
        case .unauthorized:status="蓝牙权限未允许，请到系统设置 → 隐私与安全性 → 蓝牙开启";ready=false
        case .poweredOff:status="Mac 蓝牙已关闭";ready=false
        case .unsupported:status="此 Mac 不支持蓝牙低功耗";ready=false
        default:status="蓝牙正在初始化";ready=false
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String:Any], rssi RSSI: NSNumber) {
        guard scanning,!connecting,!ready else { return }
        let name=advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "未命名设备"
        known[peripheral.identifier]=peripheral
        devices.removeAll { $0.id == peripheral.identifier };devices.append(NearbyDevice(id:peripheral.identifier,name:name,rssi:RSSI.intValue));devices.sort { $0.rssi > $1.rssi }
        if discoveryIntent == .automatic,preferredDeviceID != nil,
           connectionPreferences.matches(id:peripheral.identifier,name:name) { connect(peripheral.identifier,automatically:true) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { central.cancelPeripheralConnection(peripheral);return }
        guard connecting,isCurrentConnected(peripheral) else { return }
        status="检查工作站通信服务…";peripheral.discoverServices([serviceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if peripheral.state == .disconnected { disconnectingIDs.remove(peripheral.identifier) }
        guard peripheral === self.peripheral,connecting,peripheral.state == .disconnected else { return }
        let failure=error ?? ControlError.invalid("连接失败")
        clearSession(error:failure,cancelConnection:false);status=failure.localizedDescription
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral.state == .disconnected { disconnectingIDs.remove(peripheral.identifier) }
        guard peripheral === self.peripheral,peripheral.state == .disconnected else { return }
        clearSession(error:error ?? ControlError.invalid("工作站连接中断"),cancelConnection:false)
        status=error?.localizedDescription ?? "连接已断开";onLog?("连接",status)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard connecting,isCurrentConnected(peripheral) else { return }
        guard error == nil, let service=peripheral.services?.first(where: { $0.uuid == serviceID }) else { disconnect();status="此设备没有工作站 FFE0 服务";return }
        peripheral.discoverCharacteristics([writeID,notifyID],for:service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard connecting,isCurrentConnected(peripheral),service.uuid==serviceID,
              peripheral.services?.contains(where:{ $0 === service }) == true else { return }
        guard error == nil, let write=service.characteristics?.first(where: { $0.uuid == writeID }),let notify=service.characteristics?.first(where: { $0.uuid == notifyID }),write.properties.contains(.write) || write.properties.contains(.writeWithoutResponse),notify.properties.contains(.notify) || notify.properties.contains(.indicate) else { disconnect();status="写入或通知通道不符合工作站协议";return }
        writeCharacteristic=write;notifyCharacteristic=notify;writeType=TransferPolicy.prefersWithoutResponse(canWrite:write.properties.contains(.write),canWriteWithoutResponse:write.properties.contains(.writeWithoutResponse)) ? .withoutResponse : .withResponse
        if writePreference == "response" {
            guard write.properties.contains(.write) else { disconnect();status="设备不支持有响应写入";return }
            writeType = .withResponse
        }
        if writePreference == "noResponse",!write.properties.contains(.writeWithoutResponse) { disconnect();status="设备不支持无响应写入";return }
        linkDetails="FFE0 / FFE1 → FFE2 · \(writeType == .withoutResponse ? "无响应写入" : "有响应写入") · 单包上限 \(min(packetLimit,peripheral.maximumWriteValueLength(for:writeType))) 字节"
        onLog?("链路",linkDetails)
        peripheral.setNotifyValue(true,for:notify)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard connecting || ready,isCurrentConnected(peripheral),characteristic === notifyCharacteristic,
              characteristic.service?.peripheral === peripheral else { return }
        guard characteristic.uuid == notifyID, error == nil,characteristic.isNotifying else { disconnect();status=error?.localizedDescription ?? "订阅通知失败";return }
        guard connecting else { return }
        let name=devices.first(where:{ $0.id==peripheral.identifier })?.name ?? peripheral.name ?? preferredDeviceName
        timeout?.cancel();timeout=nil;connecting=false;automaticallyConnecting=false;ready=true
        connectionPreferences.remember(id:peripheral.identifier,name:name);saveConnectionPreferences()
        status="已连接 \(name)";onLog?("连接",status);onReady?()
    }
    func request(_ bytes: Data, timeoutSeconds: Double = 60) async throws -> WireFrame {
        guard ready,!connecting,!busy,let p=peripheral,isCurrentConnected(p),
              writeCharacteristic?.service?.peripheral === p,notifyCharacteristic?.isNotifying == true else { throw ControlError.invalid("工作站未连接或上一条指令仍在执行") }
        let outgoing=try Wire.decode(bytes)
        return try await withCheckedThrowingContinuation { pending in
            continuation=pending;matcher=ReplyMatcher(sent:outgoing)
            begin(bytes,timeoutSeconds:timeoutSeconds)
        }
    }
    // Jog 010C has no completion reply. Absolute motion 0102 must use request and wait for 8102 status 0.
    func sendOnly(_ bytes:Data,minimumIntervalNanoseconds:UInt64=TransferPolicy.intervalNanoseconds) async throws {
        guard ready,!connecting,!busy,let p=peripheral,isCurrentConnected(p),
              writeCharacteristic?.service?.peripheral === p,notifyCharacteristic?.isNotifying == true else { throw ControlError.invalid("工作站未连接或上一条指令仍在执行") }
        guard TransferPolicy.experimentalIntervalsNanoseconds.contains(minimumIntervalNanoseconds) else { throw ControlError.invalid("实验发送间隔只能选择 20、50 或 100 ms") }
        let frame=try Wire.decode(bytes)
        guard !frame.incoming else { throw ControlError.invalid("不能向设备发送回复帧") }
        if minimumIntervalNanoseconds != TransferPolicy.intervalNanoseconds {
            guard frame.code==0x010C,frame.payload.count==5 else { throw ControlError.invalid("短发送间隔仅用于完整实验点动指令") }
            try validateSingleFrameWrite([bytes])
        }
        try Task.checkCancellation()
        let operation=UUID()
        let cancellation=TransferCancellationToken()
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { (pending:CheckedContinuation<Void,Error>) in
                guard !Task.isCancelled,!cancellation.isCancelled else { pending.resume(throwing:CancellationError());return }
                writeContinuation=pending;matcher=nil;sendOnlyOperation=operation;sendOnlyCancellation=cancellation
                begin(bytes,timeoutSeconds:8,minimumIntervalNanoseconds:minimumIntervalNanoseconds)
            }
        },onCancel:{ [weak self] in
            cancellation.cancel()
            Task { @MainActor in self?.cancelSendOnly(operation) }
        })
    }
    /// Preflight for paired experimental jogs: each frame must fit one BLE write.
    /// Refuses fragmentation without changing the user's link settings.
    func validateSingleFrameWrite(_ commands:[Data]) throws {
        guard ready,!connecting,!busy,let p=peripheral,isCurrentConnected(p),
              writeCharacteristic?.service?.peripheral === p,notifyCharacteristic?.isNotifying == true else { throw ControlError.invalid("工作站未连接或上一条指令仍在执行") }
        for bytes in commands {
            let frame=try Wire.decode(bytes)
            guard !frame.incoming else { throw ControlError.invalid("实验只允许发送设备请求帧") }
        }
        let maximum=p.maximumWriteValueLength(for:writeType)
        guard TransferPolicy.experimentFramesFit(commands,maximum:maximum,limit:packetLimit) else {
            throw ControlError.invalid("当前蓝牙单包容量不足，无法完整发送实验指令；未发送动作。请检查单包上限与连接参数")
        }
    }
    private func cancelSendOnly(_ operation:UUID) {
        guard sendOnlyOperation==operation,writeContinuation != nil else { return }
        if transmitted>0 { uncertain=true }
        drainTask?.cancel();drainTask=nil;outbound=[]
        if writing {
            // Keep the in-flight GATT write owned until its callback; no further chunks may leave.
            cancelSendOnlyAfterWrite=true
        } else { finish(.failure(CancellationError())) }
    }
    private func begin(_ bytes:Data,timeoutSeconds:Double,minimumIntervalNanoseconds:UInt64=TransferPolicy.intervalNanoseconds) {
        guard let p=peripheral else { return }
        busy=true;transmitted=0;received=0;stream.reset()
        minimumWriteIntervalNanoseconds=minimumIntervalNanoseconds;cancelSendOnlyAfterWrite=false
        transferFirstWriteAt=nil;transferLastWriteAt=nil;firstWriteUptimeNS=nil;lastWriteUptimeNS=nil
        outbound=TransferPolicy.chunks(bytes,maximum:p.maximumWriteValueLength(for:writeType),limit:packetLimit)
        lastTransfer="准备发送 \(bytes.count) 字节 / \(outbound.count) 包";onLog?("TX",bytes.hex);onLog?("发送",lastTransfer)
        timeout?.cancel();timeout=Task {
            do { try await Task.sleep(nanoseconds:UInt64(timeoutSeconds*1_000_000_000)) } catch { return }
            guard !Task.isCancelled,self.busy else { return }
            let detail="发送 \(self.transmitted) 字节，收到 \(self.received) 字节，缓冲 \(self.stream.buffer.count) 字节，拒绝 \(self.stream.rejected) 个候选帧"
            let msg="回执超时（\(detail)）。未自动重发；请重新连接。"
            self.uncertain=true;self.onLog?("超时",msg);self.finish(.failure(ControlError.invalid(msg)));self.disconnect();self.status="回执超时 · 请重新连接"
        }
        drain()
    }
    private func drain() {
        guard !writing,drainTask == nil,ready,!connecting,let p=peripheral,isCurrentConnected(p),
              let c=writeCharacteristic,c.service?.peripheral === p,notifyCharacteristic?.isNotifying == true else { return }
        if let cancellation=sendOnlyCancellation,cancellation.isCancelled,let operation=sendOnlyOperation {
            cancelSendOnly(operation);return
        }
        guard !outbound.isEmpty else { wroteAll();return }
        if writeType == .withoutResponse && !p.canSendWriteWithoutResponse { return }
        if let last=lastGlobalWriteUptimeNS {
            let now=DispatchTime.now().uptimeNanoseconds,elapsed=now>=last ? now-last : 0
            if elapsed<minimumWriteIntervalNanoseconds { scheduleDrain(wait:minimumWriteIntervalNanoseconds-elapsed);return }
        }
        let chunk=outbound[0]
        var wroteAt=Date(),uptime=DispatchTime.now().uptimeNanoseconds
        let issueWrite={
            wroteAt=Date();uptime=DispatchTime.now().uptimeNanoseconds
            p.writeValue(chunk,for:c,type:self.writeType)
        }
        if let cancellation=sendOnlyCancellation,let operation=sendOnlyOperation {
            // No actor hop may separate this last check from the actual write.
            // Keep observable state and logging outside this lock to avoid
            // invoking app callbacks from the cancellation critical section.
            guard cancellation.performUnlessCancelled(issueWrite) else { cancelSendOnly(operation);return }
        } else { issueWrite() }
        outbound.removeFirst();transmitted+=chunk.count
        if writeType == .withResponse { writing=true }
        lastWriteAt=wroteAt;lastGlobalWriteUptimeNS=uptime;transferLastWriteAt=wroteAt;lastWriteUptimeNS=uptime
        if transferFirstWriteAt==nil { transferFirstWriteAt=wroteAt;firstWriteUptimeNS=uptime }
        onLog?("BLE TX",chunk.hex);lastTransfer="已写入 \(transmitted) 字节，等待回复"
        if writeType == .withoutResponse { scheduleDrain() }
    }
    private func scheduleDrain(wait:UInt64?=nil) {
        guard !outbound.isEmpty else { wroteAll();return }
        guard drainTask == nil else { return }
        drainTask=Task {
            do { try await Task.sleep(nanoseconds:wait ?? minimumWriteIntervalNanoseconds) } catch { return }
            self.drainTask=nil;self.drain()
        }
    }
    private func wroteAll() {
        guard !writing,outbound.isEmpty else { return }
        if let reply=completedReply { finish(.success(reply));return }
        guard let c=writeContinuation else { return }
        writeContinuation=nil;sendOnlyOperation=nil;sendOnlyCancellation=nil;cancelSendOnlyAfterWrite=false
        timeout?.cancel();timeout=nil;busy=false;lastTransfer="指令已发送";c.resume()
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { guard ready,isCurrentConnected(peripheral) else { return };drain() }
    func peripheral(_ peripheral: CBPeripheral,didWriteValueFor characteristic: CBCharacteristic,error: Error?) {
        guard ready,isCurrentConnected(peripheral),characteristic === writeCharacteristic,characteristic.uuid == writeID,writing else { return }
        writing=false
        if let error=error { uncertain=true;onLog?("写入失败",error.localizedDescription);finish(.failure(error));disconnect();return }
        if cancelSendOnlyAfterWrite { finish(.failure(CancellationError()));return }
        onLog?("写入确认","GATT 写入成功");scheduleDrain()
    }
    func peripheral(_ peripheral: CBPeripheral,didUpdateValueFor characteristic: CBCharacteristic,error: Error?) {
        guard ready,isCurrentConnected(peripheral),characteristic === notifyCharacteristic,characteristic.uuid == notifyID else { return }
        if let error=error { uncertain=true;clearSession(error:error);status="通知通道异常 · 请重新连接";onLog?("连接",error.localizedDescription);return }
        guard let data=characteristic.value else { return }
        received+=data.count;onLog?("BLE RX",data.hex)
        let rejected=stream.rejected
        let frames=stream.feed(data)
        if stream.rejected>rejected { onLog?("解析","拒绝 \(stream.rejected-rejected) 个候选帧；剩余缓冲 \(stream.buffer.count) 字节") }
        for frame in frames {
            onLog?("RX",frame.data.hex)
            if let p=frame.positions { positions=p }
            guard let matcher=matcher else { continue }
            guard transmitted>0 else {
                onLog?("回执","当前指令尚未写入，忽略提前回包：code=\(String(format:"%04X",frame.code)) step=\(frame.step)")
                continue
            }
            switch matcher.evaluate(frame) {
            case .unrelated:onLog?("回执","未归属当前指令：code=\(String(format:"%04X",frame.code)) step=\(frame.step)")
            case .busy:lastTransfer="工作站执行中";onLog?("回执","工作站执行中")
            case .failed(let value):uncertain=true;finish(.failure(ControlError.invalid("工作站返回错误状态 \(value)")))
            case .complete:
                lastTransfer="指令完成"
                if writing || !outbound.isEmpty { completedReply=frame } else { finish(.success(frame)) }
            }
        }
    }
    private func finish(_ result: Result<WireFrame,Error>) {
        timeout?.cancel();timeout=nil;matcher=nil;completedReply=nil;busy=false;writing=false;drainTask?.cancel();drainTask=nil;outbound=[]
        sendOnlyOperation=nil;sendOnlyCancellation=nil;cancelSendOnlyAfterWrite=false
        let c=continuation;continuation=nil;c?.resume(with:result)
        if case .failure(let error)=result {
            drainTask?.cancel();drainTask=nil;outbound=[];writing=false
            let w=writeContinuation;writeContinuation=nil;w?.resume(throwing:error)
        }
    }
    func stop() async throws {
        let deadline=Date().addingTimeInterval(3)
        while writing || !outbound.isEmpty {
            guard ready,Date()<deadline else { disconnect();throw ControlError.invalid("蓝牙发送未结束，已断开连接") }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        if busy { uncertain=true;finish(.failure(ControlError.stopped)) }
        _ = try await request(Wire.frame(payload:[1,0]),timeoutSeconds:10)
    }
}
