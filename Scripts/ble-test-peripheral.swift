#!/usr/bin/env swift
//
// A Bluetooth LE peripheral to point `ble.*` at.
//
//     swift Scripts/ble-test-peripheral.swift
//
// Verifying a BLE central needs something to talk to, and the four backends
// have to be checked against the *same* peripheral or a difference in the
// device explains away a difference in the runtime. So this advertises one,
// from a Mac, using CoreBluetooth's peripheral role.
//
// macOS-only, and deliberately not a SwiftPM product: it's a verification
// fixture, not something an adopter builds. It needs a Mac that isn't the one
// running the central under test — a host won't discover its own advertisement.
//
// What it exposes (all under the swift-pwa test service):
//
//   …0002  write, write-without-response  — echoes what you write to …0003
//   …0003  notify                         — echoes, plus a counter every 2s
//   …0004  read                           — a fixed string
//
// The service UUID is a made-up 128-bit one rather than an assigned 16-bit
// value, so a scan filtered to it can't pick up someone's headphones.

import CoreBluetooth
import Foundation

// Unbuffered, because this is normally watched through a log file while
// something else drives the central, and a block-buffered stdout would show
// nothing until it exits.
setvbuf(stdout, nil, _IONBF, 0)

let serviceUUID = CBUUID(string: "5057AB00-0000-4000-B000-000000000001")
let writeUUID = CBUUID(string: "5057AB00-0000-4000-B000-000000000002")
let notifyUUID = CBUUID(string: "5057AB00-0000-4000-B000-000000000003")
let readUUID = CBUUID(string: "5057AB00-0000-4000-B000-000000000004")
/// Kept in step with the BlueZ fixture, which can't go longer: 31 bytes of
/// advertisement, minus 3 for flags and 18 for a 128-bit service UUID, leaves
/// exactly 10 for the name. CoreBluetooth would spill the rest into the scan
/// response; BlueZ hands it to the controller, which refuses.
let localName = "swiftpwa"

final class TestPeripheral: NSObject, CBPeripheralManagerDelegate {
    private var manager: CBPeripheralManager!
    private var notifyCharacteristic: CBMutableCharacteristic!
    private var counter = 0
    private var subscribers = 0

    func start() {
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            publish(on: peripheral)
        case .unauthorized:
            // A command-line tool has no bundle of its own, so the Bluetooth
            // grant belongs to whatever launched it. Over SSH there's nothing
            // to prompt, which reads as a flat refusal.
            fail(
                "Bluetooth is not authorized for this process — run it from a Terminal that has been granted Bluetooth in System Settings ▸ Privacy & Security."
            )
        case .poweredOff:
            fail("Bluetooth is switched off on this Mac.")
        case .unsupported:
            fail("this Mac has no Bluetooth LE.")
        default:
            print("waiting for Bluetooth (\(peripheral.state.rawValue))…")
        }
    }

    private func publish(on peripheral: CBPeripheralManager) {
        let write = CBMutableCharacteristic(
            type: writeUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        notifyCharacteristic = CBMutableCharacteristic(
            type: notifyUUID, properties: [.notify], value: nil, permissions: [.readable]
        )
        // A characteristic with a fixed `value` is answered by the system
        // without ever calling the delegate, which is what we want for a read
        // that's only there to prove reads work.
        let read = CBMutableCharacteristic(
            type: readUUID,
            properties: [.read],
            value: Data("swift-pwa".utf8),
            permissions: [.readable]
        )

        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [write, notifyCharacteristic, read]
        peripheral.add(service)
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID]
        ])
        print("advertising \"\(localName)\" as \(serviceUUID.uuidString)")
        print("  write  \(writeUUID.uuidString)  (echoes to notify)")
        print("  notify \(notifyUUID.uuidString)  (+ a counter every 2s)")
        print("  read   \(readUUID.uuidString)  → \"swift-pwa\"")

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard subscribers > 0 else { return }
        counter += 1
        let payload = Data("tick \(counter)".utf8)
        manager.updateValue(payload, for: notifyCharacteristic, onSubscribedCentrals: nil)
    }

    func peripheralManager(
        _: CBPeripheralManager, central _: CBCentral, didSubscribeTo characteristic: CBCharacteristic
    ) {
        subscribers += 1
        print("subscribed to \(characteristic.uuid.uuidString) (\(subscribers) total)")
    }

    func peripheralManager(
        _: CBPeripheralManager, central _: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        subscribers = max(0, subscribers - 1)
        print("unsubscribed from \(characteristic.uuid.uuidString) (\(subscribers) left)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let value = request.value ?? Data()
            print(
                "write \(value.count)B: \(String(data: value, encoding: .utf8) ?? value.map { String(format: "%02x", $0) }.joined())"
            )
            // Echo it straight back as a notification, so one round trip
            // proves write and notify at once.
            manager.updateValue(value, for: notifyCharacteristic, onSubscribedCentrals: nil)
        }
        // Only a `.write` (with response) carries a request to respond to;
        // responding to a write-without-response is an API misuse.
        if let first = requests.first, first.characteristic.properties.contains(.write) {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    func peripheralManager(_: CBPeripheralManager, didAdd _: CBService, error: (any Error)?) {
        if let error { fail("couldn't publish the service: \(error.localizedDescription)") }
    }

    /// Without this, a refused advertisement looks exactly like a peripheral
    /// nobody happens to be near — the fixture prints "advertising" and then
    /// stays quiet either way, and the first thing it would break is the
    /// verification it exists for.
    func peripheralManagerDidStartAdvertising(_: CBPeripheralManager, error: (any Error)?) {
        if let error { fail("couldn't start advertising: \(error.localizedDescription)") }
        print("advertising for real — the radio accepted it")
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ble-test-peripheral: \(message)\n".utf8))
        exit(1)
    }
}

let peripheral = TestPeripheral()
peripheral.start()
print("ble-test-peripheral — ^C to stop")
RunLoop.main.run()
