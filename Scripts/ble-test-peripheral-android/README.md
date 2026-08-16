# `ble-test-peripheral` for Android

The third peripheral fixture, and the one that can be **carried**.

The other two run on a Mac (`../ble-test-peripheral.swift`) and on a Linux box
(`../ble-test-peripheral.py`). BLE verification is bounded by radio range, not
by the network, so a fixture is only useful to the machines within a few metres
of it — and a phone goes wherever the machine under test is.

It is also the only one that is **LE-only**. A Mac and a Linux box are
dual-mode: they advertise over LE from the same address their classic radio
uses, so BlueZ merges the two identities and `Device1.Connect()` takes the
classic route, failing `br-connection-key-missing`. A peripheral that has never
spoken classic Bluetooth doesn't give it the option.

Same service and characteristics as the other two:

| | |
| :--- | :--- |
| service | `5057ab00-0000-4000-b000-000000000001` |
| `…0002` | write, write-without-response — echoes to `…0003` |
| `…0003` | notify — the echo, plus a counter every 2s |
| `…0004` | read — `swift-pwa` |

## Running it

```bash
./gradlew installDebug
adb shell am start -n dev.swiftpwa.blefixture/.MainActivity
```

It advertises while the activity is in the foreground and stops when it isn't,
which is Android's rule rather than a choice here. Keep the screen on.
