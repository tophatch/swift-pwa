#!/usr/bin/env python3
"""A Bluetooth LE peripheral to point `ble.*` at, for machines without a Mac.

    python3 Scripts/ble-test-peripheral.py [hciN]

The companion to `ble-test-peripheral.swift`: same service, same three
characteristics, same behaviour, so a central checked against one is checked
against the other. It exists because BLE verification is bounded by radio
range, not by the network — a fixture on a Mac at a desk can't be seen by a
box in another room, and every backend has to be checked against a peripheral
it can actually hear.

Needs BlueZ (`bluetoothd`) plus python3-dbus and PyGObject, which a desktop
Ubuntu already has. No pairing and no agent: everything here is open, because
the point is to exercise a central, not a security model.

What it exposes:

  …0002  write, write-without-response  — echoes what you write to …0003
  …0003  notify                         — echoes, plus a counter every 2s
  …0004  read                           — a fixed string
"""

import sys

import dbus
import dbus.mainloop.glib
import dbus.service

from gi.repository import GLib

BLUEZ = "org.bluez"
LE_ADVERTISING_MANAGER = "org.bluez.LEAdvertisingManager1"
GATT_MANAGER = "org.bluez.GattManager1"
DBUS_OM = "org.freedesktop.DBus.ObjectManager"
DBUS_PROPERTIES = "org.freedesktop.DBus.Properties"

SERVICE_UUID = "5057ab00-0000-4000-b000-000000000001"
WRITE_UUID = "5057ab00-0000-4000-b000-000000000002"
NOTIFY_UUID = "5057ab00-0000-4000-b000-000000000003"
READ_UUID = "5057ab00-0000-4000-b000-000000000004"
# Eight characters, and not a byte more: a legacy advertisement carries 31
# bytes, of which the flags take 3 and a 128-bit service UUID takes 18, leaving
# exactly 10 for the name AD (2 of header + 8 of text). CoreBluetooth quietly
# spills the overflow into the scan response; BlueZ hands the controller the
# whole thing and some controllers answer "Invalid Parameters (0x0d)" — which
# is what a too-long name looks like from up here.
LOCAL_NAME = "swiftpwa"

BASE_PATH = "/com/swiftpwa/test"


class Application(dbus.service.Object):
    """The GATT tree BlueZ reads through ObjectManager when it's registered."""

    def __init__(self, bus):
        self.path = BASE_PATH
        self.services = []
        dbus.service.Object.__init__(self, bus, self.path)

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def add_service(self, service):
        self.services.append(service)

    @dbus.service.method(DBUS_OM, out_signature="a{oa{sa{sv}}}")
    def GetManagedObjects(self):
        response = {}
        for service in self.services:
            response[service.get_path()] = service.properties()
            for characteristic in service.characteristics:
                response[characteristic.get_path()] = characteristic.properties()
        return response


class Service(dbus.service.Object):
    def __init__(self, bus, index, uuid, primary=True):
        self.path = f"{BASE_PATH}/service{index}"
        self.uuid = uuid
        self.primary = primary
        self.characteristics = []
        dbus.service.Object.__init__(self, bus, self.path)

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def add_characteristic(self, characteristic):
        self.characteristics.append(characteristic)

    def properties(self):
        return {
            "org.bluez.GattService1": {
                "UUID": self.uuid,
                "Primary": self.primary,
                "Characteristics": dbus.Array(
                    [c.get_path() for c in self.characteristics], signature="o"
                ),
            }
        }

    @dbus.service.method(DBUS_PROPERTIES, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        if interface != "org.bluez.GattService1":
            raise InvalidArgs()
        return self.properties()["org.bluez.GattService1"]


class Characteristic(dbus.service.Object):
    def __init__(self, bus, index, uuid, flags, service):
        self.path = f"{service.path}/char{index}"
        self.uuid = uuid
        self.flags = flags
        self.service = service
        self.notifying = False
        self.value = []
        dbus.service.Object.__init__(self, bus, self.path)
        service.add_characteristic(self)

    def get_path(self):
        return dbus.ObjectPath(self.path)

    def properties(self):
        return {
            "org.bluez.GattCharacteristic1": {
                "Service": self.service.get_path(),
                "UUID": self.uuid,
                "Flags": self.flags,
            }
        }

    @dbus.service.method(DBUS_PROPERTIES, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        if interface != "org.bluez.GattCharacteristic1":
            raise InvalidArgs()
        return self.properties()["org.bluez.GattCharacteristic1"]

    @dbus.service.signal(DBUS_PROPERTIES, signature="sa{sv}as")
    def PropertiesChanged(self, interface, changed, invalidated):
        pass

    @dbus.service.method("org.bluez.GattCharacteristic1", in_signature="a{sv}", out_signature="ay")
    def ReadValue(self, options):
        return self.value

    @dbus.service.method("org.bluez.GattCharacteristic1", in_signature="aya{sv}")
    def WriteValue(self, value, options):
        raise NotSupported()

    @dbus.service.method("org.bluez.GattCharacteristic1")
    def StartNotify(self):
        self.notifying = True
        print(f"subscribed to {self.uuid}", flush=True)

    @dbus.service.method("org.bluez.GattCharacteristic1")
    def StopNotify(self):
        self.notifying = False
        print(f"unsubscribed from {self.uuid}", flush=True)

    def push(self, payload):
        """Send a notification, if anyone is listening."""
        if not self.notifying:
            return
        self.value = dbus.Array([dbus.Byte(b) for b in payload], signature="y")
        self.PropertiesChanged(
            "org.bluez.GattCharacteristic1", {"Value": self.value}, []
        )


class WriteCharacteristic(Characteristic):
    def __init__(self, bus, index, service, echo_to):
        super().__init__(bus, index, WRITE_UUID, ["write", "write-without-response"], service)
        self.echo_to = echo_to

    def WriteValue(self, value, options):
        payload = bytes(bytearray(value))
        printable = payload.decode("utf-8", "replace")
        print(f"write {len(payload)}B: {printable}", flush=True)
        # Echo straight back as a notification, so one round trip proves write
        # and notify at once.
        self.echo_to.push(payload)


class NotifyCharacteristic(Characteristic):
    def __init__(self, bus, index, service):
        super().__init__(bus, index, NOTIFY_UUID, ["notify"], service)


class ReadCharacteristic(Characteristic):
    def __init__(self, bus, index, service):
        super().__init__(bus, index, READ_UUID, ["read"], service)
        self.value = dbus.Array([dbus.Byte(b) for b in b"swift-pwa"], signature="y")


class Advertisement(dbus.service.Object):
    def __init__(self, bus, index):
        self.path = f"{BASE_PATH}/advertisement{index}"
        dbus.service.Object.__init__(self, bus, self.path)

    def get_path(self):
        return dbus.ObjectPath(self.path)

    @dbus.service.method(DBUS_PROPERTIES, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        if interface != "org.bluez.LEAdvertisement1":
            raise InvalidArgs()
        return {
            "Type": "peripheral",
            "ServiceUUIDs": dbus.Array([SERVICE_UUID], signature="s"),
            "LocalName": dbus.String(LOCAL_NAME),
        }

    @dbus.service.method("org.bluez.LEAdvertisement1")
    def Release(self):
        print("advertisement released by BlueZ", flush=True)


class InvalidArgs(dbus.exceptions.DBusException):
    _dbus_error_name = "org.freedesktop.DBus.Error.InvalidArgs"


class NotSupported(dbus.exceptions.DBusException):
    _dbus_error_name = "org.bluez.Error.NotSupported"


def find_adapter(bus, preferred=None):
    """The adapter to advertise on, or None if nothing here can.

    `preferred` (e.g. "hci1") matters on a box with two controllers: pinning
    the fixture to one leaves the other free to run the central under test, so
    a single machine can verify itself. A host never hears its own
    advertisement, but a *second radio* in the same host does.
    """
    manager = dbus.Interface(bus.get_object(BLUEZ, "/"), DBUS_OM)
    candidates = [
        path
        for path, interfaces in manager.GetManagedObjects().items()
        if LE_ADVERTISING_MANAGER in interfaces and GATT_MANAGER in interfaces
    ]
    if preferred:
        wanted = [p for p in candidates if p.endswith("/" + preferred)]
        if not wanted:
            sys.exit(
                f"ble-test-peripheral: no adapter {preferred} that can advertise "
                f"(found: {', '.join(sorted(candidates)) or 'none'})"
            )
        return wanted[0]
    return sorted(candidates)[0] if candidates else None


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()

    preferred = sys.argv[1] if len(sys.argv) > 1 else None
    adapter = find_adapter(bus, preferred)
    if adapter is None:
        sys.exit(
            "ble-test-peripheral: no Bluetooth adapter that can advertise "
            "(is bluetoothd running, and is the adapter powered?)"
        )
    print(f"using adapter {adapter}", flush=True)

    app = Application(bus)
    service = Service(bus, 0, SERVICE_UUID)
    notify = NotifyCharacteristic(bus, 1, service)
    WriteCharacteristic(bus, 0, service, echo_to=notify)
    ReadCharacteristic(bus, 2, service)
    app.add_service(service)

    gatt_manager = dbus.Interface(bus.get_object(BLUEZ, adapter), GATT_MANAGER)
    advertising_manager = dbus.Interface(bus.get_object(BLUEZ, adapter), LE_ADVERTISING_MANAGER)
    advertisement = Advertisement(bus, 0)

    loop = GLib.MainLoop()

    def fail(error):
        # BlueZ refuses an advertisement for reasons worth reading — most
        # often another one is already registered, or the adapter is down.
        print(f"ble-test-peripheral: {error}", file=sys.stderr, flush=True)
        loop.quit()

    gatt_manager.RegisterApplication(
        app.get_path(), {},
        reply_handler=lambda: print("GATT application registered", flush=True),
        error_handler=fail,
    )
    advertising_manager.RegisterAdvertisement(
        advertisement.get_path(), {},
        reply_handler=lambda: print(
            f'advertising "{LOCAL_NAME}" as {SERVICE_UUID}', flush=True
        ),
        error_handler=fail,
    )

    counter = [0]

    def tick():
        counter[0] += 1
        notify.push(f"tick {counter[0]}".encode())
        return True

    GLib.timeout_add_seconds(2, tick)

    print("ble-test-peripheral — ^C to stop", flush=True)
    try:
        loop.run()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            advertising_manager.UnregisterAdvertisement(advertisement.get_path())
            gatt_manager.UnregisterApplication(app.get_path())
        except dbus.exceptions.DBusException:
            # Already gone if BlueZ is what went away.
            pass


if __name__ == "__main__":
    main()
