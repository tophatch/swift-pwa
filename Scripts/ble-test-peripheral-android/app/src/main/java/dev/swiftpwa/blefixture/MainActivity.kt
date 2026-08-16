package dev.swiftpwa.blefixture

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.view.WindowManager
import android.widget.ScrollView
import android.widget.TextView
import java.util.UUID

/**
 * A Bluetooth LE peripheral, the same one `ble-test-peripheral.swift` and
 * `ble-test-peripheral.py` publish — see ../README.md for why a third exists.
 *
 * Everything is on screen rather than in logcat: this is carried to whichever
 * machine is being tested, and the useful question there is "did the write
 * arrive", which shouldn't need `adb` to answer.
 */
class MainActivity : Activity() {

    private val serviceUuid = UUID.fromString("5057ab00-0000-4000-b000-000000000001")
    private val writeUuid = UUID.fromString("5057ab00-0000-4000-b000-000000000002")
    private val notifyUuid = UUID.fromString("5057ab00-0000-4000-b000-000000000003")
    private val readUuid = UUID.fromString("5057ab00-0000-4000-b000-000000000004")
    private val cccdUuid = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    private val localName = "swiftpwa"

    private lateinit var output: TextView
    private var server: BluetoothGattServer? = null
    private var notifyCharacteristic: BluetoothGattCharacteristic? = null
    private val subscribers = mutableSetOf<BluetoothDevice>()
    private val handler = Handler(Looper.getMainLooper())
    private var counter = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The screen staying on matters: Android only advertises while the
        // activity is in the foreground, so a locked phone is a fixture that
        // has quietly stopped existing.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        output = TextView(this).apply { setPadding(32, 32, 32, 32); textSize = 13f }
        setContentView(ScrollView(this).apply { addView(output) })

        val needed = arrayOf(Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT)
        val missing = needed.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) start() else requestPermissions(missing.toTypedArray(), 1)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
            start()
        } else {
            log("permission refused — nothing will advertise")
        }
    }

    private fun log(line: String) {
        handler.post { output.append(line + "\n") }
    }

    @SuppressLint("MissingPermission")
    private fun start() {
        val manager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = manager.adapter
        if (adapter == null || !adapter.isEnabled) {
            log("Bluetooth is off")
            return
        }

        val write = BluetoothGattCharacteristic(
            writeUuid,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )
        val notify = BluetoothGattCharacteristic(
            notifyUuid,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ
        ).apply {
            // Without a CCCD a central has nothing to write to subscribe, and
            // every platform reports that as "this characteristic can't
            // notify" — which looks like the central's fault.
            addDescriptor(
                BluetoothGattDescriptor(
                    cccdUuid,
                    BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
                )
            )
        }
        val read = BluetoothGattCharacteristic(
            readUuid,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ
        ).apply { value = "swift-pwa".toByteArray() }

        notifyCharacteristic = notify

        val service = BluetoothGattService(serviceUuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(write)
        service.addCharacteristic(notify)
        service.addCharacteristic(read)

        server = manager.openGattServer(this, serverCallback)
        server?.addService(service)

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()
        // The name goes in the *scan response*, not the advertisement: 31
        // bytes hold the flags and a 128-bit service UUID with almost nothing
        // to spare, and asking for both in one packet is refused outright.
        val advertisement = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(serviceUuid))
            .setIncludeDeviceName(false)
            .build()
        val scanResponse = AdvertiseData.Builder().setIncludeDeviceName(true).build()
        adapter.name = localName

        adapter.bluetoothLeAdvertiser?.startAdvertising(
            settings, advertisement, scanResponse,
            object : AdvertiseCallback() {
                override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                    log("advertising \"$localName\" as $serviceUuid")
                    log("  write  …0002   (echoes to …0003)")
                    log("  notify …0003   (+ a counter every 2s)")
                    log("  read   …0004 → \"swift-pwa\"")
                }

                override fun onStartFailure(errorCode: Int) {
                    // Worth naming: a refused advertisement otherwise looks
                    // exactly like a peripheral nobody happens to be near.
                    log("advertising refused (error $errorCode)")
                }
            }
        )

        handler.postDelayed(tick, 2000)
    }

    private val tick = object : Runnable {
        @SuppressLint("MissingPermission")
        override fun run() {
            if (subscribers.isNotEmpty()) {
                counter += 1
                val payload = "tick $counter".toByteArray()
                notifyCharacteristic?.value = payload
                for (device in subscribers.toList()) {
                    server?.notifyCharacteristicChanged(device, notifyCharacteristic, false)
                }
            }
            handler.postDelayed(this, 2000)
        }
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            log(if (newState == BluetoothGatt.STATE_CONNECTED) "connected" else "disconnected")
            if (newState != BluetoothGatt.STATE_CONNECTED) subscribers.remove(device)
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray
        ) {
            log("write ${value.size}B: ${String(value)}")
            if (responseNeeded) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
            // Echo straight back as a notification, so one round trip proves
            // write and notify at once.
            notifyCharacteristic?.value = value
            for (subscriber in subscribers.toList()) {
                server?.notifyCharacteristicChanged(subscriber, notifyCharacteristic, false)
            }
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice, requestId: Int, offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            log("read ${characteristic.uuid.toString().takeLast(4)}")
            server?.sendResponse(
                device, requestId, BluetoothGatt.GATT_SUCCESS, offset,
                characteristic.value ?: ByteArray(0)
            )
        }

        @SuppressLint("MissingPermission")
        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray
        ) {
            val enabling = value.isNotEmpty() && value[0].toInt() != 0
            if (enabling) subscribers.add(device) else subscribers.remove(device)
            log(if (enabling) "subscribed" else "unsubscribed")
            if (responseNeeded) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
        }
    }

    @SuppressLint("MissingPermission")
    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        server?.close()
        super.onDestroy()
    }
}
