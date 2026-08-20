package com.jeromegsq.thortoolbox.nso

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.jeromegsq.thortoolbox.gamepad.RootShell
import java.util.ArrayDeque

/**
 * The NSO GameCube controller (Switch 2), over Bluetooth LE.
 *
 * This pad speaks a proprietary Nintendo GATT protocol rather than HID-over-GATT,
 * so nothing on the Android side recognises it on its own: it has to be talked
 * through a fixed init sequence before it emits a single button press. The
 * sequence, the handles and the two crypto blobs below are the ones documented by
 * RyanCopley/NSO-GameCube-Controller-Pairing-App and trevlars/switch2-controllers-linux.
 *
 * The Linux tools reach the pad through a raw L2CAP ATT socket at low security,
 * writing straight to numbered handles. Android has no equivalent — there is no
 * `hci0` here at all, the Qualcomm HAL owns the radio — so this goes through the
 * ordinary [BluetoothGatt] client instead and finds each documented handle by
 * matching `getInstanceId()`, which is that attribute's ATT handle. That mapping
 * is the part most likely to differ on real hardware, which is why every attribute
 * discovered is reported to the UI: a run that fails still says what the pad
 * actually exposes.
 *
 * Owned by the process, not by whatever screen happens to be watching. A pad is
 * a pad whether or not its diagnostic page is open — tying the GATT connection
 * to that page's lifetime dropped the link the moment it closed, which the stack
 * reported as `reason=0x16`, "terminated by local host".
 */
@SuppressLint("MissingPermission")
class NsoGamepad private constructor(private val context: Context) {

    /** Where events go while a screen is watching, and nowhere otherwise. */
    var listener: ((Map<String, Any?>) -> Unit)? = null
        set(value) {
            field = value
            if (value == null) return
            // A screen arriving mid-session would otherwise face a blank page
            // until the next event, however long the pad has been connected.
            // The session line goes first so it knows which pad the rest is about.
            value(mapOf("kind" to "session", "address" to lastAddress, "active" to wanted))
            history.forEach(value)
        }

    /**
     * Whether a connected pad is republished as an evdev node for gpmerge to
     * merge. Off leaves this a read-only diagnostic — nothing system-wide is
     * created, and no root shell is asked for.
     */
    var publish: Boolean = true

    private val main = Handler(Looper.getMainLooper())
    private val adapter: BluetoothAdapter? =
        context.getSystemService(BluetoothManager::class.java)?.adapter
    private val prefs: SharedPreferences = context.getSharedPreferences("nso_pad", Context.MODE_PRIVATE)

    private var gatt: BluetoothGatt? = null
    private var scanning = false

    /** Whether this scan is looking for a pad to connect to on its own. */
    private var autoConnecting = false

    /** Whether the link is actually up, as opposed to merely wanted. */
    private var connected = false

    /** The pad to come back to, and whether going away was asked for. */
    private var lastAddress: String? = null
    private var wanted = false
    private var retries = 0

    /** Rolls through the rumble packet's 4-bit transaction id, wrapping freely. */
    private var rumbleTid = 0

    /**
     * The pad remembered from whenever one last connected successfully, so a
     * screen opened cold can offer a one-tap reconnect instead of a scan.
     * Survives the process — a scan needs the radio and takes a few seconds
     * each time, and it is the same pad every time anyway.
     */
    var knownAddress: String? = prefs.getString(PREF_ADDRESS, null)
        private set
    var knownName: String? = prefs.getString(PREF_NAME, null)
        private set

    /**
     * Recent non-input events, replayed to a screen that attaches later. Input
     * is deliberately left out: it arrives sixty times a second and only the
     * live value is worth anything.
     */
    private val history = ArrayDeque<Map<String, Any?>>()

    /** GATT allows one outstanding operation; everything queues through here. */
    private val pending = ArrayDeque<Op>()
    private var busy = false

    /** The root helper publishing this pad as an evdev node, once asked for. */
    private var feed: Process? = null
    private var feedIn: java.io.Writer? = null

    private class Op(val label: String, val run: () -> Boolean)

    // ---- Public API -----------------------------------------------------------

    fun startScan() {
        val scanner = adapter?.bluetoothLeScanner
        if (adapter?.isEnabled != true || scanner == null) {
            emit("error", "message" to "Bluetooth is off")
            return
        }
        if (scanning) return
        scanning = true
        log("Scanning — hold SYNC on the pad until it appears")
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        scanner.startScan(null, settings, scanCallback)
    }

    fun stopScan() {
        if (!scanning) return
        scanning = false
        adapter?.bluetoothLeScanner?.stopScan(scanCallback)
        log("Scan stopped")
    }

    /**
     * The whole bring-up behind one press: come back to the pad already known,
     * or scan and connect to the first thing that looks like one.
     *
     * The manual path — scan, read the list, pick a row — exists because the
     * pad's advertised name is not documented and the list had to be trusted
     * over any filter. It still does, which is why nothing is ever hidden
     * there; but by now `likely` has been right every time on real hardware, so
     * making the user read it once per session buys nothing. This is that same
     * choice made automatically, and the list is one button away if it guesses
     * wrong.
     */
    fun autoConnect() {
        if (wanted && gatt != null) {
            log("Already connected to ${lastAddress ?: "the pad"}")
            return
        }

        val known = knownAddress
        if (known != null) {
            log("Auto connect — coming back to $known")
            connect(known)
            return
        }

        if (autoConnecting) {
            log("Auto connect already running")
            return
        }
        autoConnecting = true
        emit("state", "state" to "scanning")
        log("Auto connect — scanning for the pad, hold SYNC if it is asleep")
        startScan()
        if (!scanning) {
            // startScan bailed out: the radio is off, and it said so already.
            autoConnecting = false
            return
        }
        main.postDelayed({
            if (!autoConnecting) return@postDelayed
            autoConnecting = false
            stopScan()
            emit("state", "state" to "idle")
            emit("error", "message" to "No pad answered — hold SYNC until its lights run, then try again")
        }, AUTO_TIMEOUT_MS)
    }

    fun connect(address: String) {
        autoConnecting = false
        stopScan()
        closeGatt()
        lastAddress = address
        wanted = true
        retries = 0
        // Says which pad this session is about. A screen that picked the
        // address itself knows already; one that pressed auto connect does not,
        // and would otherwise sit on the scan list while the pad came up.
        emit("session", "address" to address, "active" to true)
        open(address, auto = false)
    }

    /**
     * `autoConnect` is false for the first attempt and true for every retry.
     *
     * The two are different mechanisms rather than a preference: false is a
     * direct connection attempt that gives up quickly, true parks the request
     * in the stack until the pad advertises again. First contact wants the
     * former — the pad is right there, in pairing mode. Coming back from a
     * pad that idled out wants the latter, since nobody knows when it wakes.
     */
    private fun open(address: String, auto: Boolean) {
        val device = adapter?.getRemoteDevice(address)
        if (device == null) {
            emit("error", "message" to "No such device: $address")
            return
        }
        log(if (auto) "Waiting for $address to come back" else "Connecting to $address")
        emit("state", "state" to "connecting")
        gatt = device.connectGatt(context, auto, callback, BluetoothDevice.TRANSPORT_LE)
    }

    /** Asked for by the user: stays down until something asks it back up. */
    fun disconnect() {
        wanted = false
        lastAddress = null
        autoConnecting = false
        stopScan()
        closeGatt()
        // Nothing emits a state line on the way down when there was no live
        // connection to drop, and the tile still has to stop saying "searching".
        announce()
    }

    private fun closeGatt() {
        pending.clear()
        busy = false
        connected = false
        // The next connection does its own bring-up, and its own insisting.
        sawInput = false
        main.removeCallbacks(ledBurst)
        // Nothing left to send it to — stop rather than let the loop keep
        // ticking against a gatt that queueRumble will just no-op on.
        rumbleWanted = false
        main.removeCallbacks(rumbleTick)
        gatt?.let {
            it.disconnect()
            it.close()
        }
        gatt = null
        stopFeed()
    }

    /** Whether a pad is connected, or on its way back. */
    fun isActive() = wanted

    /**
     * The whole session in one word, for the surfaces that are not screens —
     * the quick settings tile and the home screen widget. They cannot hold
     * [listener] (there is one, and it belongs to whichever screen is open) and
     * have no room for a log anyway: all they show is this.
     */
    enum class Status { OFF, SCANNING, CONNECTING, CONNECTED }

    fun status(): Status = when {
        connected -> Status.CONNECTED
        autoConnecting -> Status.SCANNING
        wanted -> Status.CONNECTING
        else -> Status.OFF
    }

    /**
     * What the tile and the widget do with a press: bring the pad up if it is
     * not, put it down if it is. One entry point so both agree, and so neither
     * has to know the difference between a scan and a reconnection.
     */
    fun toggle() {
        if (status() == Status.OFF) autoConnect() else disconnect()
    }

    /** Redraws the tile and the widget. Cheap, and only fired on real changes. */
    private fun announce() {
        main.post {
            NsoTileService.refresh(context)
            NsoWidget.refresh(context)
        }
    }

    /** The remembered pad, for a screen to offer as a one-tap reconnect. */
    fun knownPad(): Map<String, Any?>? =
        knownAddress?.let { mapOf("address" to it, "name" to knownName) }

    /**
     * Remembered on an actual connection, not on a bare attempt — an address
     * that never answers is not worth surfacing as a quick-reconnect target.
     */
    private fun rememberKnown(address: String, name: String?) {
        knownAddress = address
        knownName = name
        prefs.edit().putString(PREF_ADDRESS, address).putString(PREF_NAME, name).apply()
    }

    /**
     * Brings the link back after a drop that nobody asked for — the pad idling
     * out, walking out of range, or the radio glitching.
     *
     * The old [BluetoothGatt] is closed rather than reused: Android leaks the
     * client interface otherwise, and there are only a handful of them per
     * process, so a pad that reconnects all evening would eventually stop being
     * able to.
     */
    private fun reconnect() {
        val address = lastAddress
        if (!wanted || address == null) return

        gatt?.close()
        gatt = null
        retries++
        val delay = if (retries <= 3) 1000L else 5000L
        log("Reconnecting in ${delay}ms (attempt $retries)")
        main.postDelayed({ if (wanted) open(address, auto = true) }, delay)
    }

    /**
     * Starts the root helper that republishes this pad as an evdev node.
     *
     * Everything downstream keys off that node rather than off this class:
     * gpmerge discovers it like any other pad and folds it into the merged
     * controller, so the NSO reaches games — and picks up the profiles and
     * shortcuts — without anything else having to know it arrived over BLE.
     */
    private fun startFeed() {
        if (feed != null) return
        val process = try {
            // chmod first, every time: a Magisk module's files come back from a
            // boot without their execute bit, and the helper then fails in a way
            // that looks exactly like a pad that connected fine — because it
            // did. Everything downstream is missing instead, silently, until
            // someone reads this log. `exec` so the shell hands the helper its
            // own stdin, which is the whole protocol between them.
            ProcessBuilder("su", "-c", "chmod 755 $FEED_BIN 2>/dev/null; exec $FEED_BIN")
                .redirectErrorStream(true)
                .start()
        } catch (e: Exception) {
            log("feed: cannot start $FEED_BIN — ${e.message}")
            return
        }
        feed = process
        feedIn = process.outputStream.bufferedWriter()

        // The helper reports which node it took and any trouble reaching uinput
        // on this same stream — save for one thing: a game asking the pad to
        // rumble arrives here too, as "rumble 0"/"rumble 1", because the helper
        // holds no GATT connection of its own to act on it with.
        Thread {
            try {
                process.inputStream.bufferedReader().forEachLine { line ->
                    val on = line.removePrefix("rumble ").trim()
                    if (line.startsWith("rumble ") && (on == "0" || on == "1")) {
                        main.post { setRumbling(on == "1") }
                    } else {
                        log("feed: $line")
                    }
                }
            } catch (e: Exception) {
                // Closing the process is what ends this read; nothing to say.
            }
        }.apply { isDaemon = true }.start()
        log("feed: started")
    }

    private fun stopFeed() {
        // Closing stdin is the helper's cue to tear its uinput node down, so it
        // gets the chance before the process is killed out from under it.
        try {
            feedIn?.close()
        } catch (e: Exception) {
            // Already gone.
        }
        feedIn = null
        feed?.destroy()
        feed = null
    }

    // ---- Scanning -------------------------------------------------------------

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device ?: return
            val name = device.name ?: result.scanRecord?.deviceName ?: ""
            // Only a hint for the UI to sort on: the pad's advertised name is
            // not documented anywhere, so nothing is filtered out on it. It is
            // also what an auto connect goes on, since it has to pick one.
            val likely = name.contains("GameCube", true) || name.contains("NSO", true)
            emit(
                "device",
                "address" to device.address,
                "name" to name,
                "rssi" to result.rssi,
                "likely" to likely,
            )

            if (autoConnecting && likely) {
                log("Auto connect — ${if (name.isEmpty()) device.address else name} looks like the pad")
                // Clears autoConnecting and stops the scan on the way through.
                connect(device.address)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            scanning = false
            autoConnecting = false
            emit("error", "message" to "Scan failed ($errorCode)")
        }
    }

    // ---- GATT -----------------------------------------------------------------

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothGatt.STATE_CONNECTED) {
                retries = 0
                connected = true
                log("Connected (status $status)")
                emit("state", "state" to "connected")
                lastAddress?.let { rememberKnown(it, g.device?.name) }
                // Ahead of discovery on purpose: input reports are 63 bytes and the
                // default 23-byte MTU silently truncates every notification to 20.
                main.post { g.requestMtu(517) }
                // The default (BALANCED) connection interval runs tens of ms —
                // a notification can only land once per interval, so that is
                // most of a button press's latency right there. HIGH asks for
                // the tightest one the controller will grant — DCK, where it
                // exists, was added for latency-sensitive ranging and asks
                // for tighter still; a stack that does not honour it simply
                // treats the request as HIGH. 2M PHY is a smaller win stacked
                // on top — it only shortens the radio's own airtime per
                // packet — and a pad or chipset that cannot do it just
                // ignores the request, so there is nothing to guard.
                g.requestConnectionPriority(
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        BluetoothGatt.CONNECTION_PRIORITY_DCK
                    } else {
                        BluetoothGatt.CONNECTION_PRIORITY_HIGH
                    },
                )
                g.setPreferredPhy(BluetoothDevice.PHY_LE_2M, BluetoothDevice.PHY_LE_2M, BluetoothDevice.PHY_OPTION_NO_PREFERRED)
            } else if (newState == BluetoothGatt.STATE_DISCONNECTED) {
                connected = false
                sawInput = false
                main.removeCallbacks(ledBurst)
                log("Disconnected (status $status)")
                emit("state", "state" to "disconnected")
                pending.clear()
                busy = false
                stopFeed()
                reconnect()
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            log("MTU $mtu (status $status)")
            if (mtu < 185) log("warn: MTU below 185 — notifications may be dropped")
            main.post { g.discoverServices() }
        }

        // 1 = 1M PHY (the fallback every BLE radio supports), 2 = 2M. Logged
        // rather than acted on: whichever one it settled on is already live.
        override fun onPhyUpdate(g: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) {
            log("PHY tx=$txPhy rx=$rxPhy (status $status)")
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            log("Discovery finished (status $status)")
            if (status != BluetoothGatt.GATT_SUCCESS) {
                emit("error", "message" to "Service discovery failed ($status)")
                return
            }
            dumpTree(g)
            initSequence(g)
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
            value: ByteArray,
        ) = onNotify(ch, value)

        // The pre-33 shape of the same callback. Both are overridden because the
        // platform picks which one it calls by API level; the guard stops a 33+
        // device that happens to call both from reporting every report twice.
        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                onNotify(ch, ch.value ?: ByteArray(0))
            }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) =
            step(status, "write ${handleOf(ch)}")

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) =
            step(status, "CCCD of ${handleOf(d.characteristic)}")
    }

    /** Reports every attribute the pad exposes, handle and UUID, to the UI. */
    private fun dumpTree(g: BluetoothGatt) {
        for (service in g.services) {
            // "what", not "kind": `kind` is the event tag itself, and an extra of
            // the same name would overwrite it on the way out.
            emit("attr", "what" to "service", "handle" to service.instanceId, "uuid" to service.uuid.toString())
            for (ch in service.characteristics) {
                emit(
                    "attr",
                    "what" to "char",
                    "handle" to ch.instanceId,
                    "uuid" to ch.uuid.toString(),
                    "props" to ch.properties,
                )
                for (d in ch.descriptors) {
                    // Descriptors have no handle to report: Android never exposes
                    // one. The parent's is listed instead, which is the useful
                    // fact anyway — a CCCD sits at its characteristic's handle
                    // plus one, so this says where it would be.
                    emit("attr", "what" to "desc", "handle" to ch.instanceId, "uuid" to d.uuid.toString())
                }
            }
        }
    }

    /**
     * The documented bring-up, in order. Every step is queued rather than fired
     * at once: GATT drops any operation started while another is outstanding, and
     * a silently dropped write here looks exactly like a pad that never responds.
     */
    private fun initSequence(g: BluetoothGatt) {
        val local = localAddress()
        if (local == null) {
            emit("error", "message" to "Could not read the local Bluetooth address")
            return
        }
        log("Local address ${local.joinToString(":") { "%02X".format(it) }}")

        queueCccd(g, H_SERVICE_CTRL_CHAR, ENABLE, "enable proprietary service")
        queueCccd(g, H_CMD_RESP_CHAR, ENABLE, "enable command responses")

        val minusOne = local.copyOf().also { it[it.size - 1] = (it[it.size - 1] - 1).toByte() }
        queueCommand(g, command(0x15, 0x01, byteArrayOf(0x00, 0x02) + local + minusOne), "pair step 1")
        queueCommand(g, command(0x15, 0x04, byteArrayOf(0x00) + NONCE_A), "pair step 2")
        queueCommand(g, command(0x15, 0x02, byteArrayOf(0x00) + NONCE_B), "pair step 3")
        queueCommand(g, command(0x15, 0x03, byteArrayOf(0x00)), "pair step 4")
        // Sent here as the documented sequence has it, and again once input is
        // actually flowing — see [ledBurst] for why once is not enough.
        queueCommand(g, ledCommand(PLAYER_ONE), "player LED")

        queueNotify(g, H_INPUT_CHAR, "enable input")
        // Last, and deliberately: the input CCCD only starts delivering once the
        // command channel stops being subscribed to.
        queueCccd(g, H_CMD_RESP_CHAR, DISABLE, "close command channel")
        drain()

        // Brought up alongside the pad rather than on the first report: creating
        // the node takes a root shell and a moment, and doing that inside the
        // first notification would drop it.
        if (publish) startFeed()
    }

    // ---- Operation queue ------------------------------------------------------

    /**
     * Writes [value] to the CCCD of the characteristic at [charHandle].
     *
     * Addressed through the parent rather than by the CCCD's own handle because
     * Android never exposes descriptor handles — only services and characteristics
     * carry an `instanceId`. It comes out at the same attribute either way: a CCCD
     * sits one handle past the characteristic it belongs to, which is exactly how
     * the documented pairs line up (`0x000A`/`0x000B`, `0x001A`/`0x001B`).
     */
    private fun queueCccd(g: BluetoothGatt, charHandle: Int, value: ByteArray, label: String) {
        pending.add(
            Op(label) {
                val d = findCccd(g, charHandle)
                if (d == null) {
                    log("skip $label — no CCCD on characteristic ${"0x%04X".format(charHandle)}")
                    false
                } else {
                    writeDescriptor(g, d, value)
                }
            },
        )
    }

    private fun queueNotify(g: BluetoothGatt, charHandle: Int, label: String) {
        pending.add(
            Op(label) {
                val d = findCccd(g, charHandle)
                if (d == null) {
                    log("skip $label — no CCCD on characteristic ${"0x%04X".format(charHandle)}")
                    false
                } else {
                    // Both halves are needed: the local flag routes notifications
                    // into the callback, the CCCD write is what asks the pad to
                    // send them at all.
                    g.setCharacteristicNotification(d.characteristic, true)
                    writeDescriptor(g, d, ENABLE)
                }
            },
        )
    }

    // ---- Player LED -----------------------------------------------------------
    //
    // The lamp row is the pad saying which player it is. Left alone it runs the
    // "looking for a host" chase, and that is what keeps cycling on a pad that
    // is otherwise perfectly connected: the one command that stops it goes out
    // during bring-up, as a write with no response, while the pad is still
    // working through its own pairing steps — and a pad that was not ready to
    // hear it says nothing about having missed it. Nothing here can read the
    // lamps back either, so the only honest answer is to say it again once the
    // link has proved itself, and to leave a way to say it by hand.

    /** `[mask, 0x00, …]`, mask being the lamps to light — 0x01 is the first. */
    private fun ledCommand(mask: Int) =
        command(0x09, 0x07, byteArrayOf(mask.toByte(), 0x00, 0, 0, 0, 0, 0, 0))

    /** Sets the lamps now, on whatever connection is up. Safe to repeat: the
     * pad takes the last one it hears and there is no state to confuse. */
    fun setPlayerLed(mask: Int = PLAYER_ONE) {
        val g = gatt ?: return
        queueCommand(g, ledCommand(mask), "player LED")
        drain()
    }

    /** Whether input has been seen on this connection, which is the only proof
     * available that the pad is done with its own bring-up. */
    private var sawInput = false

    private var ledAttempts = 0

    /**
     * Re-sends the player LED a few times over the seconds that follow the
     * first input report, spaced out because the pad ignoring it is a matter of
     * timing rather than of the command being wrong. Harmless if the lamps were
     * already right — it is the same command with the same value.
     */
    private val ledBurst = object : Runnable {
        override fun run() {
            if (gatt == null || ledAttempts >= LED_ATTEMPTS) return
            ledAttempts++
            setPlayerLed()
            main.postDelayed(this, LED_RETRY_MS)
        }
    }

    private fun queueCommand(g: BluetoothGatt, payload: ByteArray, label: String) {
        pending.add(
            Op(label) {
                val ch = findCharacteristic(g, H_CMD_WRITE)
                if (ch == null) {
                    log("skip $label — no characteristic at handle ${"0x%04X".format(H_CMD_WRITE)}")
                    false
                } else {
                    writeCharacteristic(g, ch, payload)
                }
            },
        )
    }

    /**
     * 0..100, persisted across launches. The motor itself only knows on and
     * off — there is no magnitude byte in the packet below — so anything
     * short of full strength is faked by chopping "on" up with brief gaps,
     * the standard trick for a binary vibration motor. 0 mutes it outright,
     * as a disable switch rather than a very short, very frequent buzz.
     */
    var rumbleStrength: Int = prefs.getInt(PREF_RUMBLE_STRENGTH, 100)
        set(value) {
            field = value.coerceIn(0, 100)
            prefs.edit().putInt(PREF_RUMBLE_STRENGTH, field).apply()
        }

    /** Whether a game currently wants the pad rumbling, PWM duty cycle aside. */
    private var rumbleWanted = false

    private val rumbleTick = object : Runnable {
        override fun run() {
            if (!rumbleWanted) return
            val strength = rumbleStrength
            if (strength <= 0) {
                // Muted: recheck on the same cadence rather than spinning, so
                // turning the strength back up while a game still wants it
                // rumbling resumes within one period instead of needing a
                // fresh play request.
                main.postDelayed(this, RUMBLE_PERIOD_MS)
                return
            }
            queueRumble(true)
            val onMs = RUMBLE_PERIOD_MS * strength / 100
            if (onMs < RUMBLE_PERIOD_MS) main.postDelayed({ if (rumbleWanted) queueRumble(false) }, onMs)
            main.postDelayed(this, RUMBLE_PERIOD_MS)
        }
    }

    /**
     * A short pulse at [rumbleStrength], so "does rumble work" has a one-tap
     * answer from the diagnostic screen — no game, no [publish] merge, no
     * gpmerge shortcut needed to find out.
     */
    fun testRumble() {
        setRumbling(true)
        main.postDelayed({ setRumbling(false) }, TEST_PULSE_MS)
    }

    /** Starts or stops the PWM loop; the loop itself reads [rumbleStrength]
     * fresh every period, so a strength change takes effect on the pad within
     * one period rather than waiting for the next play request. */
    private fun setRumbling(on: Boolean) {
        if (rumbleWanted == on) return
        rumbleWanted = on
        main.removeCallbacks(rumbleTick)
        if (on) {
            rumbleTick.run()
        } else {
            queueRumble(false)
        }
    }

    /**
     * 21 bytes to the rumble handle: byte 1 is `0x50` with a rolling 4-bit
     * transaction id in its low nibble — the pad appears to ignore a repeat of
     * the same id — byte 2 is plain on/off, the rest zero. From
     * RyanCopley/NSO-GameCube-Controller-Pairing-App; this unit's motor takes
     * no waveform, so on/off is the whole vocabulary — [rumbleStrength] fakes
     * the rest by how often this gets called with `false` in between.
     */
    private fun queueRumble(on: Boolean) {
        val g = gatt ?: return
        val payload = ByteArray(21)
        payload[1] = (0x50 or (rumbleTid and 0x0F)).toByte()
        payload[2] = if (on) 0x01 else 0x00
        rumbleTid = (rumbleTid + 1) and 0x0F

        pending.add(
            Op("rumble ${if (on) "on" else "off"}") {
                val ch = findCharacteristic(g, H_RUMBLE)
                if (ch == null) {
                    log("skip rumble — no characteristic at handle ${"0x%04X".format(H_RUMBLE)}")
                    false
                } else {
                    writeCharacteristic(g, ch, payload)
                }
            },
        )
        drain()
    }

    private fun drain() {
        if (busy) return
        val op = pending.poll() ?: return
        busy = true
        log("→ ${op.label}")
        if (!op.run()) {
            // Never started, so no callback is coming to advance the queue.
            busy = false
            main.post { drain() }
        }
    }

    private fun step(status: Int, what: String) {
        if (status != BluetoothGatt.GATT_SUCCESS) log("warn: $what returned $status")
        busy = false
        main.post { drain() }
    }

    // ---- Attribute lookup -----------------------------------------------------

    private fun findCharacteristic(g: BluetoothGatt, handle: Int): BluetoothGattCharacteristic? {
        for (s in g.services) {
            for (c in s.characteristics) {
                if (c.instanceId == handle) return c
            }
        }
        return null
    }

    /**
     * The Client Characteristic Configuration descriptor of the characteristic at
     * [charHandle] — the standard `0x2902`, falling back to whatever single
     * descriptor the characteristic carries if this pad names it something else.
     */
    private fun findCccd(g: BluetoothGatt, charHandle: Int): BluetoothGattDescriptor? {
        val ch = findCharacteristic(g, charHandle) ?: return null
        return ch.getDescriptor(CCCD) ?: ch.descriptors.singleOrNull()
    }

    private fun handleOf(ch: BluetoothGattCharacteristic) = "0x%04X".format(ch.instanceId)

    // ---- Writes, across the API-33 split --------------------------------------

    @Suppress("DEPRECATION")
    private fun writeCharacteristic(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray): Boolean {
        val type = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeCharacteristic(ch, value, type) == BluetoothGatt.GATT_SUCCESS
        } else {
            ch.writeType = type
            ch.value = value
            g.writeCharacteristic(ch)
        }
    }

    @Suppress("DEPRECATION")
    private fun writeDescriptor(g: BluetoothGatt, d: BluetoothGattDescriptor, value: ByteArray): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(d, value) == BluetoothGatt.GATT_SUCCESS
        } else {
            d.value = value
            g.writeDescriptor(d)
        }
    }

    // ---- Input ----------------------------------------------------------------

    private fun onNotify(ch: BluetoothGattCharacteristic, value: ByteArray) {
        if (value.size < 62) {
            // The diagnostic screen is the only reader, and it clears
            // [listener] on the way out rather than staying subscribed —
            // building this mid-game, for nobody, would be the one report in
            // sixty (or more) that costs more than it has to.
            if (listener != null) emit("raw", "handle" to ch.instanceId, "hex" to value.hex())
            return
        }
        // Bytes 0-2 are a rolling per-report counter, not state — measured live
        // against the real pad, since the layout the reference implementations
        // document does not match this unit's firmware at all: buttons and Z sit
        // in byte 4, start/home/capture/C in byte 5, d-pad/L/ZL in byte 6, the
        // sticks at 10-12/13-15 rather than 5-7/8-10, and the triggers all the
        // way out at 60/61 rather than 12/13.
        val buttons = (value[4].u() shl 16) or (value[5].u() shl 8) or value[6].u()
        val left = stick(value, 10)
        val right = stick(value, 13)
        val lt = value[60].u()
        val rt = value[61].u()

        // A real report is the pad saying it is all the way up — which is the
        // moment the player LED is worth insisting on, and the earliest one
        // that can be told apart from a link that merely opened.
        if (!sawInput) {
            sawInput = true
            ledAttempts = 0
            main.postDelayed(ledBurst, LED_FIRST_MS)
        }

        writeFeed(buttons, left, right, lt, rt)
        // writeFeed() above is the only part of this that reaches the game;
        // everything below is for the diagnostic screen. Skip it when
        // nothing is listening — mid-game, this runs on every single report
        // and the bit list alone allocates for no reader.
        if (listener == null) return
        emit(
            "input",
            "buttons" to buttons,
            "bits" to (0 until 24).filter { ((buttons shr it) and 1) == 1 },
            "lx" to left.first,
            "ly" to left.second,
            "rx" to right.first,
            "ry" to right.second,
            "lt" to lt,
            "rt" to rt,
            "hex" to value.hex(),
        )
    }

    /**
     * One line per report, which is the whole protocol the helper speaks.
     *
     * Failures here take the feed down rather than being retried: the helper only
     * stops reading if it died or its node went away, and in both cases every
     * later write would fail the same way — leaving the log repeating itself
     * sixty times a second.
     */
    private fun writeFeed(buttons: Int, left: Pair<Int, Int>, right: Pair<Int, Int>, lt: Int, rt: Int) {
        val out = feedIn ?: return
        try {
            out.write("$buttons ${left.first} ${left.second} ${right.first} ${right.second} $lt $rt\n")
            out.flush()
        } catch (e: Exception) {
            log("feed: stopped — ${e.message}")
            stopFeed()
        }
    }

    /** Two 12-bit axes packed into three bytes, centre near 0x800. */
    private fun stick(b: ByteArray, at: Int): Pair<Int, Int> {
        val x = b[at].u() or ((b[at + 1].u() and 0x0F) shl 8)
        val y = (b[at + 1].u() shr 4) or (b[at + 2].u() shl 4)
        return x to y
    }

    // ---- Plumbing -------------------------------------------------------------

    /**
     * Android hands ordinary apps a fixed `02:00:00:00:00:00` instead of the real
     * adapter address, and the pairing handshake sends that address to the pad —
     * so the placeholder would be handshaking on behalf of a device that does not
     * exist. Root reads the real one out of secure settings.
     */
    private fun localAddress(): ByteArray? {
        val out = RootShell.run("settings get secure bluetooth_address")
        val text = out.out.firstOrNull()?.trim()?.uppercase()
        val parts = text?.split(":").orEmpty()
        if (parts.size != 6) return null
        return try {
            ByteArray(6) { parts[it].toInt(16).toByte() }
        } catch (e: NumberFormatException) {
            null
        }
    }

    /** `[cmd, 0x91, 0x01, sub, 0x00, len, 0x00, 0x00]` then the payload. */
    private fun command(cmd: Int, sub: Int, payload: ByteArray): ByteArray =
        byteArrayOf(cmd.toByte(), 0x91.toByte(), 0x01, sub.toByte(), 0x00, payload.size.toByte(), 0x00, 0x00) + payload

    private fun log(message: String) = emit("log", "message" to message)

    private fun emit(kind: String, vararg extra: Pair<String, Any?>) {
        val map = HashMap<String, Any?>(extra.size + 1)
        map["kind"] = kind
        for ((k, v) in extra) map[k] = v

        // A state line is exactly what the tile and the widget draw, so it is
        // also the one thing worth waking them for.
        if (kind == "state") announce()

        // Scan results and input are the live picture, worthless once stale; a
        // session line is the state of things right now, and the listener setter
        // already sends a fresh one — replaying an old one would announce a pad
        // that has since been disconnected. The rest is the story of the session
        // and worth replaying to a late arrival.
        if (kind != "input" && kind != "device" && kind != "session") {
            history.add(map)
            while (history.size > MAX_HISTORY) history.poll()
        }
        main.post { listener?.invoke(map) }
    }

    private fun Byte.u() = toInt() and 0xFF

    private fun ByteArray.hex() = joinToString(" ") { "%02X".format(it) }

    companion object {
        /**
         * The one pad for the whole process.
         *
         * Held here rather than created per screen because the connection has to
         * outlive any screen: the point of merging it into the AYN pad is that it
         * works in games, and by then nothing of this app is on top.
         */
        @Volatile
        private var instance: NsoGamepad? = null

        fun get(context: Context): NsoGamepad =
            instance ?: synchronized(this) {
                instance ?: NsoGamepad(context.applicationContext).also { instance = it }
            }

        /**
         * Scanning and connecting are separate runtime permissions from Android
         * 12; below that they are install-time and this comes back empty.
         *
         * Lives here rather than with the screen that asks for them: the tile
         * and the widget need the same two, and neither is an activity that
         * could ask — all they can do is check, and send the user to the app.
         */
        fun missingPermissions(context: Context): List<String> {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return emptyList()
            return listOf(android.Manifest.permission.BLUETOOTH_SCAN, android.Manifest.permission.BLUETOOTH_CONNECT)
                .filter { context.checkSelfPermission(it) != android.content.pm.PackageManager.PERMISSION_GRANTED }
        }

        private const val PREF_ADDRESS = "address"
        private const val PREF_NAME = "name"
        private const val PREF_RUMBLE_STRENGTH = "rumble_strength"

        private const val MAX_HISTORY = 300

        /** How long an auto connect keeps scanning before it gives up and says
         * so. Long enough to cover holding SYNC after pressing the button,
         * short enough that the radio is not left scanning for a pad that is
         * in another room. */
        private const val AUTO_TIMEOUT_MS = 20_000L

        /** The first lamp, as a bitmask — player one. */
        const val PLAYER_ONE = 0x01

        /** How long after the first input report the player LED is said again,
         * and how many times after that. Spread over a few seconds because the
         * pad ignoring it is a matter of when it arrives, not of what it says. */
        private const val LED_FIRST_MS = 400L
        private const val LED_RETRY_MS = 1500L
        private const val LED_ATTEMPTS = 3

        /** The PWM period the rumble duty cycle is chopped against. Short
         * enough that even a low strength still feels continuous rather than
         * pulsing, long enough not to flood the BLE link with writes. */
        private const val RUMBLE_PERIOD_MS = 120L

        /** Long enough to be unmistakable, short enough to feel like a tap
         * rather than the pad being stuck on. */
        private const val TEST_PULSE_MS = 400L

        /**
         * Characteristic handles, matched against `getInstanceId()`.
         *
         * The protocol notes are written in terms of the CCCDs — `0x0005`,
         * `0x000B`, `0x001B` — but Android can only look up characteristics, so
         * these are the handles one below each of those: the characteristic the
         * CCCD belongs to. `0x000A` is the input characteristic named directly by
         * the reference implementation, which is what confirms the offset.
         */
        private const val H_SERVICE_CTRL_CHAR = 0x0004
        private const val H_INPUT_CHAR = 0x000A
        private const val H_CMD_WRITE = 0x0014
        private const val H_RUMBLE = 0x0016
        private const val H_CMD_RESP_CHAR = 0x001A

        private val CCCD: java.util.UUID = java.util.UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** Installed by the gpmerge Magisk module, alongside the merger itself. */
        private const val FEED_BIN = "/data/adb/modules/gpmerge/nsofeed"

        private val ENABLE = byteArrayOf(0x01, 0x00)
        private val DISABLE = byteArrayOf(0x00, 0x00)

        private val NONCE_A = byteArrayOf(
            0xEA.toByte(), 0xBD.toByte(), 0x47, 0x13, 0x89.toByte(), 0x35, 0x42, 0xC6.toByte(),
            0x79, 0xEE.toByte(), 0x07, 0xF2.toByte(), 0x53, 0x2C, 0x6C, 0x31,
        )
        private val NONCE_B = byteArrayOf(
            0x40, 0xB0.toByte(), 0x8A.toByte(), 0x5F, 0xCD.toByte(), 0x1F, 0x9B.toByte(), 0x41,
            0x12, 0x5C, 0xAC.toByte(), 0xC6.toByte(), 0x3F, 0x38, 0xA0.toByte(), 0x73,
        )
    }
}
