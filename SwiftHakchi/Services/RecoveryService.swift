import Foundation
import SWCompression
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "Recovery")

/// Port of Hakchi2-CE's `MembootTasks`: boot the console into hakchi's recovery
/// shell (from a running console with kexec, or over FEL), run a kernel/NAND task,
/// then reboot or continue booting.
///
/// Every public task follows CE's sequence:
/// 1. `enterRecovery`: shell memboot via `detached-fallback recovery` when the
///    console is online, otherwise FEL memboot; skipped when the console already
///    runs the recovery image (unless a reload is forced)
/// 2. the task itself
/// 3. `reboot` (or `boot` to continue into hakchi), unless the user is in their
///    own recovery session (`/user-recovery.flag`), which CE leaves running
actor RecoveryService {
    typealias Progress = @Sendable (String, Double) -> Void
    /// Asks the user for a stock kernel file when the console has no backup
    typealias KernelPicker = @MainActor @Sendable () -> URL?

    enum RecoveryError: LocalizedError {
        case notConnected
        case noFelDevice
        case notSupported
        case stockKernelMissing
        case invalidKernelFile
        case kernelCheckFailed
        case verifyFailed
        case invalidSystemImage
        case invalidUserDataBackup
        case imageTooLarge
        case projectLunar
        case cancelled
        case commandFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "The console is not connected."
            case .noFelDevice: return "Connect the console in FEL mode (hold RESET while plugging in USB)."
            case .notSupported: return "Not supported on this platform."
            case .stockKernelMissing: return "Stock kernel not found on system."
            case .invalidKernelFile: return "The original kernel file you've supplied is not a validated original kernel."
            case .kernelCheckFailed: return "Kernel checksum failed."
            case .verifyFailed: return "Verify failed. This is not good."
            case .invalidSystemImage: return "Invalid hsqs image."
            case .invalidUserDataBackup: return "Invalid user data backup."
            case .imageTooLarge: return "The image is too large."
            case .projectLunar: return "Project Lunar has been detected, installation cannot continue until it is removed."
            case .cancelled: return "Cancelled."
            case .commandFailed(let cmd, let err): return "\(cmd) failed: \(err)"
            }
        }
    }

    enum NandTask {
        case dumpNand, dumpSystem, dumpUserData, flashSystem, flashUserData
    }

    private let deviceManager: DeviceManager
    private let flashService: FlashService
    private let payloads = PayloadService.shared

    /// The recovery session and whether we opened it (and must close it)
    private var shell: SSHService?
    private var ownsShell = false
    /// The user was already in their own recovery session: CE leaves it running
    private var userRecovery = false

    init(deviceManager: DeviceManager) {
        self.deviceManager = deviceManager
        self.flashService = FlashService(felService: deviceManager.felService, deviceManager: deviceManager)
    }

    // MARK: - Entering recovery

    /// Boot into the recovery shell and return its session
    /// `requireSD`: the shell route is only used when the running system sees the
    /// SD card (`hakchi mmcUsed`), otherwise FEL is needed (CE's sdRequired)
    private func enterRecovery(forceReload: Bool = false, requireSD: Bool = false,
                               progress: Progress) async throws -> SSHService {
        let (connected, current, inRecovery, felPresent) = await MainActor.run {
            (deviceManager.isConnected, deviceManager.sshService, deviceManager.isRecoveryMode,
             deviceManager.felDevicePresent)
        }

        if connected, let current {
            let flag = (try? await current.execute("[ -f /user-recovery.flag ]"))?.succeeded ?? false
            userRecovery = inRecovery && flag
            var sdOK = true
            if requireSD {
                sdOK = (try? await current.execute("hakchi mmcUsed"))?.succeeded ?? false
            }
            if inRecovery && !forceReload && sdOK {
                logger.info("Already in recovery, reusing the session")
                await MainActor.run { deviceManager.suppressAutoConnect = true }
                shell = current
                ownsShell = false
                return current
            }
            // Membootable shell? (CE: [ -f /proc/atags ])
            if sdOK, (try? await current.execute("[ -f /proc/atags ]"))?.succeeded == true {
                try await shellMemboot(current, progress: progress)
                await MainActor.run { deviceManager.releaseSessionForRecovery() }
                progress("Waiting for the console to reboot...", 0.15)
                try await waitForDeviceToDisappear()
                return try await attachRecoveryShell(progress: progress)
            }
        }

        guard felPresent else { throw RecoveryError.noFelDevice }
        await MainActor.run { deviceManager.suppressAutoConnect = true }
        progress("Uploading the kernel over FEL...", 0.05)
        try await deviceManager.felService.memboot(
            fes1Data: try payloads.fes1(), ubootData: try payloads.uboot(), bootImgData: try payloads.bootImg())
        return try await attachRecoveryShell(progress: progress)
    }

    private func attachRecoveryShell(progress: Progress) async throws -> SSHService {
        progress("Waiting for the recovery shell...", 0.2)
        let s = try await flashService.waitForRecoveryShell(timeout: 120)
        shell = s
        ownsShell = true
        userRecovery = false
        await ConsoleToolsService(shell: s).showSplashScreen()
        return s
    }

    /// CE's `MembootTasks.Memboot`: kexec into hakchi's boot.img with the recovery
    /// command line, using the bundled static kexec and detached-fallback
    private func shellMemboot(_ s: SSHService, progress: Progress) async throws {
        progress("Membooting...", 0.05)
        do {
            _ = try await s.execute("uistop")
            try await expect(s, "mkdir -p /tmp/kexec/")
            try await uploadExecutable(s, payloads.bundledFile("tools/arm/kexec.static"), to: "/tmp/kexec/kexec")
            try await uploadExecutable(s, payloads.hmodFile("bin/detached-fallback"), to: "/tmp/kexec/detached-fallback")
            _ = try await s.execute("cat > /tmp/kexec/boot.img", input: try payloads.bootImg())
            // Only the network shell is supported here (CE's "Force Network memboots")
            _ = try? await s.execute(
                "cd /tmp/kexec/; /bin/sh /tmp/kexec/detached-fallback recovery /tmp/kexec/boot.img hakchi-shell",
                timeout: 3000)
        } catch {
            _ = try? await s.execute("uistart")
            throw error
        }
    }

    /// After a shell memboot the old RNDIS device has to go away before we wait
    /// for the new one, or we would reconnect to the dying system
    private func waitForDeviceToDisappear(timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, SSHService.deviceExists() {
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Close our session and let DeviceManager reconnect
    private func finish() async {
        if ownsShell, let shell { await shell.disconnect() }
        shell = nil
        ownsShell = false
        await MainActor.run { deviceManager.suppressAutoConnect = false }
    }

    /// CE's closing step for most tasks: reboot unless in a user recovery session
    private func rebootUnlessUserRecovery(_ s: SSHService) async {
        guard !userRecovery else { return }
        _ = try? await s.execute("sync; umount -ar; reboot -f", timeout: 3000)
    }

    // MARK: - Install / reset

    /// CE "Reset": wipe hakchi's state (`mod_uninstall reset`) and reinstall it
    func resetHakchi(progress: @escaping Progress) async throws {
        defer { Task { await self.finish() } }
        let s = try await enterRecovery(progress: progress)
        try await checkMdRootfs(s)
        progress("Resetting hakchi...", 0.35)
        try await expect(s, "hakchi mount_base")
        _ = try await s.execute("hakchi mod_uninstall reset", timeout: 120000)
        try await expect(s, "hakchi umount_base")
        try await flashService.continueInstall(
            shell: s, baseHmods: try payloads.baseHmods(), hakchiHmod: try payloads.hakchiHmod(),
            bootImg: try payloads.bootImg(), progress: progress, startProgress: 0.45)
        ownsShell = false // continueInstall closed the session for the reboot
        shell = nil
    }

    // MARK: - Uninstall / factory reset / format

    /// CE Uninstall: flash the stock kernel back and remove hakchi.
    /// `ignoreBackupKernel` (⌥ in the menu): ask for a kernel file and erase the backup.
    func uninstall(ignoreBackupKernel: Bool, pickKernel: @escaping KernelPicker,
                   progress: @escaping Progress) async throws {
        defer { Task { await self.finish() } }
        let s = try await enterRecovery(progress: progress)
        try await removeHakchi(s, ignoreBackupKernel: ignoreBackupKernel, pickKernel: pickKernel, progress: progress)
        progress("Rebooting...", 0.95)
        await rebootUnlessUserRecovery(s)
        progress("Done. Your console should be back to running the stock kernel.", 1.0)
    }

    /// CE Factory reset: uninstall, then format the user data partition
    func factoryReset(ignoreBackupKernel: Bool, pickKernel: @escaping KernelPicker,
                      progress: @escaping Progress) async throws {
        defer { Task { await self.finish() } }
        let s = try await enterRecovery(progress: progress)
        try await removeHakchi(s, ignoreBackupKernel: ignoreBackupKernel, pickKernel: pickKernel, progress: progress)
        try await formatDataPartition(s, progress: progress)
        progress("Rebooting...", 0.95)
        await rebootUnlessUserRecovery(s)
        progress("Done. Your console has been reset to factory settings.", 1.0)
    }

    /// CE "Format user data partition"; reinstalls hakchi afterwards if it was installed
    func formatUserData(progress: @escaping Progress) async throws {
        defer { Task { await self.finish() } }
        let s = try await enterRecovery(progress: progress)
        try await expect(s, "hakchi mount_base")
        let reinstall = (try? await s.execute("hakchi eval '[ -e \"$mountpoint/var/lib/hakchi/\" ]'"))?.succeeded ?? false
        _ = try? await s.execute("hakchi umount_base")
        try await formatDataPartition(s, progress: progress)
        if reinstall {
            try await flashService.continueInstall(
                shell: s, baseHmods: try payloads.baseHmods(), hakchiHmod: try payloads.hakchiHmod(),
                bootImg: try payloads.bootImg(), progress: progress, startProgress: 0.6)
            ownsShell = false
            shell = nil
        } else {
            await rebootUnlessUserRecovery(s)
        }
        progress("User data partition formatted.", 1.0)
    }

    private func removeHakchi(_ s: SSHService, ignoreBackupKernel: Bool, pickKernel: @escaping KernelPicker,
                              progress: Progress) async throws {
        let isMd = try await isMdPartitioning(s)
        if !isMd {
            progress("Reading the stock kernel...", 0.3)
            let kernel = try await stockKernel(s, ignoreBackup: ignoreBackupKernel, pickKernel: pickKernel)
            if ignoreBackupKernel {
                _ = try await s.execute("sunxi-flash log_write 68 1 </dev/zero")
            }
            progress("Flashing the stock kernel...", 0.5)
            try await flashKernel(s, kernel)
        }
        progress("Uninstalling hakchi...", 0.7)
        try await expect(s, "hakchi mount_base")
        _ = try await s.execute("hakchi mod_uninstall", timeout: 120000)
        try await expect(s, "hakchi umount_base")
    }

    private func formatDataPartition(_ s: SSHService, progress: Progress) async throws {
        progress("Formatting the user data partition...", 0.8)
        _ = try? await s.execute("hakchi umount_base")
        let info = try await nandInfo(s)
        guard let data = info.data else { throw RecoveryError.commandFailed("sunxi-part", "no data partition") }
        try await expectLong(s, ConsoleTools.formatDeviceCommand("/dev/\(data.device)"))
    }

    // MARK: - Kernels

    /// CE `GetStockKernel`: `hakchi getBackup2`, else a validated file chosen by the user
    private func stockKernel(_ s: SSHService, ignoreBackup: Bool, pickKernel: @escaping KernelPicker) async throws -> Data {
        if !ignoreBackup {
            let backup = try await s.downloadData(command: "hakchi getBackup2")
            if !backup.isEmpty { return backup }
        }
        guard let url = await pickKernel() else { throw RecoveryError.cancelled }
        let data = try Data(contentsOf: url)
        guard ConsoleTools.isValidatedStockKernel(data) else { throw RecoveryError.invalidKernelFile }
        return data
    }

    /// CE `FlashKernel`
    private func flashKernel(_ s: SSHService, _ kernel: Data) async throws {
        let upload = try await s.execute("cat > /kernel.img", input: kernel)
        guard upload.succeeded else { throw RecoveryError.commandFailed("kernel upload", upload.stderr) }
        guard (try await s.execute("sntool check /kernel.img")).succeeded else { throw RecoveryError.kernelCheckFailed }
        try await expect(s, "sntool kernel /kernel.img")
        guard (try await s.execute("hakchi flashBoot2 /kernel.img", timeout: 60000)).succeeded else {
            throw RecoveryError.verifyFailed
        }
    }

    /// "Dump original kernel (legacy)": `hakchi getBackup2` into a file
    func dumpStockKernel(to url: URL, progress: @escaping Progress) async throws {
        defer { Task { await self.finish() } }
        let s = try await enterRecovery(progress: progress)
        guard try await !isMdPartitioning(s) else { throw RecoveryError.notSupported }
        progress("Dumping the stock kernel...", 0.5)
        do {
            try await s.download(command: "hakchi getBackup2", to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw RecoveryError.stockKernelMissing
        }
        await rebootUnlessUserRecovery(s)
        progress("Kernel dumped.", 1.0)
    }

    // MARK: - Boot from RAM

    /// "Boot custom kernel from RAM": memboot, then continue the hakchi boot
    func bootCustomKernel(progress: @escaping Progress) async throws {
        defer { Task { await self.finish() } }
        let s = try await enterRecovery(progress: progress)
        try await bootHakchi(s, progress: progress)
    }

    /// "Boot recovery kernel from RAM": stay in recovery (marked as a user session)
    func bootRecoveryKernel(forceReload: Bool, progress: @escaping Progress) async throws {
        defer { Task { await self.finish() } }
        let s = try await enterRecovery(forceReload: forceReload, progress: progress)
        try await expect(s, "touch /user-recovery.flag")
        _ = try? await s.execute("uistart")
        progress("Your console is now in recovery mode.", 1.0)
    }

    /// "Boot original kernel from RAM" (CE `BootBackup2`)
    func bootOriginalKernel(pickKernel: @escaping KernelPicker, progress: @escaping Progress) async throws {
        defer { Task { await self.finish() } }
        let s = try await enterRecovery(progress: progress)
        guard try await !isMdPartitioning(s) else { throw RecoveryError.notSupported }
        progress("Booting the original kernel...", 0.5)
        if (try await s.execute("hakchi haveBackup2")).succeeded {
            _ = try? await s.execute("hakchi bootBackup2", timeout: 5000)
            return
        }
        // No backup2 on the console: kexec a stock kernel file (CE `MembootKexec`)
        let kernel = try await stockKernel(s, ignoreBackup: true, pickKernel: pickKernel)
        _ = try await s.execute("uistop")
        try await expect(s, "mkdir -p /tmp/kexec/")
        try await uploadExecutable(s, payloads.bundledFile("tools/arm/kexec.static"), to: "/tmp/kexec/kexec")
        try await uploadExecutable(s, payloads.bundledFile("tools/arm/unpackbootimg.static"), to: "/tmp/kexec/unpackbootimg")
        let unpack = try await s.execute("cat > /tmp/kexec/boot.img; cd /tmp/kexec/; ./unpackbootimg -i boot.img",
                                         input: kernel)
        guard unpack.succeeded else { throw RecoveryError.commandFailed("unpackbootimg", unpack.stderr) }
        try await expect(s, "cd /tmp/kexec/ && ./kexec -l -t zImage boot.img-zImage \"--command-line=$(cat boot.img-cmdline)\" --ramdisk=boot.img-ramdisk.gz --atags")
        _ = try? await s.execute("cd /tmp/; umount -ar")
        _ = try? await s.execute("/tmp/kexec/kexec -e", timeout: 3000)
    }

    /// CE `BootHakchi`: continue the boot; fail on a flash md5 mismatch
    private func bootHakchi(_ s: SSHService, progress: Progress) async throws {
        progress("Booting hakchi...", 0.8)
        var log = ""
        _ = try? await s.executeStreaming("boot", idleTimeout: 300000) { chunk in
            log += String(decoding: chunk, as: UTF8.self)
            return true
        }
        if let line = log.components(separatedBy: .newlines).first(where: { $0.hasPrefix("flash md5 mismatch! ") }) {
            throw RecoveryError.commandFailed("boot", String(line))
        }
        ownsShell = false
        if let shell { await shell.disconnect() }
        shell = nil
    }

    /// "Reboot" while in recovery: CE offers to finish the boot sequence instead
    func continueBoot(progress: @escaping Progress) async throws {
        defer { Task { await self.finish() } }
        let s = try await enterRecovery(progress: progress)
        _ = try? await s.execute("rm -f /user-recovery.flag")
        try await bootHakchi(s, progress: progress)
    }

    // MARK: - U-Boot

    /// "Flash uboot": normal mode or SD mode (CE `FlashUboot`)
    func flashUboot(sdMode: Bool, progress: @escaping Progress) async throws {
        defer { Task { await self.finish() } }
        let s = try await enterRecovery(progress: progress)
        progress("Flashing U-Boot...", 0.5)
        let result = try await s.execute("sntool sd \(sdMode ? "enable" : "disable")", timeout: 60000)
        guard result.succeeded else { throw RecoveryError.commandFailed("sntool sd", result.stdout + result.stderr) }
        await rebootUnlessUserRecovery(s)
        progress("U-Boot flashed.", 1.0)
    }

    // MARK: - SD card (CE Tasks/SDFormat)

    /// Format the SD card in the console (non-bootable layout: one ext4 partition
    /// after 128 MiB, mounted by hakchi as /media). CE's "bootable card" option
    /// depends on files its own code no longer prepares, so it is not offered.
    func formatSDCard(storeSaves: Bool, copySaves: Bool, progress: @escaping Progress) async throws {
        defer { Task { await self.finish() } }
        let s = try await enterRecovery(requireSD: true, progress: progress)

        progress("Flashing SD mode U-Boot...", 0.3)
        let uboot = try await s.execute("sntool sd enable", timeout: 60000)
        guard uboot.succeeded else { throw RecoveryError.commandFailed("sntool sd", uboot.stdout + uboot.stderr) }

        guard (try await s.execute("[ -b /dev/mmcblk0 ]")).succeeded else {
            throw RecoveryError.commandFailed("SD card", "No SD card is inserted in the classic.")
        }
        try await expect(s, "mkdir -p /squashtools /tmp")
        progress("Clearing the first 32 MB of the SD card...", 0.4)
        try await expectLong(s, "dd if=/dev/zero of=/dev/mmcblk0 bs=1M count=32")
        try await expect(s, "echo sdprep | dd \"of=/dev/mmcblk0\"")
        _ = try await s.execute("cat > /tmp/sfdisk", input: try payloads.bundledFile("tools/arm/sfdisk.static"))
        try await expect(s, "chmod +x /tmp/sfdisk")
        let part = try await s.execute("/tmp/sfdisk /dev/mmcblk0", input: Data("128M,,L\n".utf8))
        guard part.succeeded else { throw RecoveryError.commandFailed("sfdisk", part.stderr) }
        try await expect(s, "rm /tmp/sfdisk")

        progress("Formatting the SD card...", 0.55)
        try await expectLong(s, ConsoleTools.formatDeviceCommand("/dev/mmcblk0p1"))

        progress("Mounting the SD card...", 0.7)
        try await expect(s, "mkdir -p /data/")
        try await expect(s, "mount /dev/mmcblk0p1 /data/")
        try await expect(s, "mkdir -p /data/hakchi/games/")
        if storeSaves || copySaves {
            try await expect(s, "mkdir -p /data/hakchi/saves/")
        }
        if copySaves {
            progress("Copying saves from NAND to the SD card...", 0.8)
            let info = try await nandInfo(s)
            guard let data = info.data?.device else { throw RecoveryError.commandFailed("sunxi-part", "no data partition") }
            try await expect(s, "mkdir -p /\(data) && mount /dev/\(data) /\(data)")
            if (try await s.execute("[ -d /\(data)/clover/profiles/0 ]")).succeeded {
                try await expectLong(s, "rsync -avc /\(data)/clover/profiles/0 /data/hakchi/saves")
            }
            try await expect(s, "umount /\(data)/ && rmdir /\(data)/")
        }
        progress("Rebooting...", 0.95)
        _ = try? await s.execute("sync; umount -ar; reboot -f", timeout: 3000)
        progress("SD card formatted.", 1.0)
    }

    // MARK: - NAND (CE ProcessNand)

    /// Dump or flash NAND data. `file` is the destination (dump) or source (flash).
    func processNand(_ task: NandTask, file: URL, progress: @escaping Progress) async throws {
        defer { Task { await self.finish() } }
        let s = try await enterRecovery(progress: progress)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("hakchi-nand-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        var source = file
        if task == .flashSystem || task == .flashUserData {
            source = try Self.extractIfCompressed(file, into: temp)
        }

        // What kind of image is being flashed?
        let header = (task == .flashSystem || task == .flashUserData) ? try Self.readHeader(source) : Data()
        let isHsqs = ConsoleTools.isSquashFs(header)
        let isExt = ConsoleTools.isExtFs(header)
        let isTar = ConsoleTools.isTar(header)
        if task == .flashSystem && !(isHsqs || isExt || isTar) { throw RecoveryError.invalidSystemImage }
        if task == .flashUserData && !(isTar || isExt) { throw RecoveryError.invalidUserDataBackup }

        let hasNand = (try await s.execute("ls -lah /dev/nanda &> /dev/null && echo 1 || echo 0")).output == "1"
        let hasMmc = (try await s.execute("ls -lah /dev/mmcblk0 &> /dev/null && echo 1 || echo 0")).output == "1"
        let info = try await nandInfo(s)
        let rootfsDevice = "/dev/\(info.rootfs?.device ?? "")"
        let userDataDevice = "/dev/\(info.data?.device ?? "")"
        let hasKeyfile = (try await s.execute("[ -f /key-file ]")).succeeded
        let osDevice = hasKeyfile ? "/dev/mapper/root-crypt" : rootfsDevice
        // CE compared against "HSQS", which never matches the little-endian "hsqs"
        // magic; compare case-insensitively so the fast dd path is actually used.
        let systemIsHsqs = (try await s.execute("dd if=\(osDevice) bs=1 count=4", timeout: 5000))
            .output.lowercased() == "hsqs"
        let isMd = try await isMdPartitioning(s)

        var partitionSize: Int64 = 300 * 1024 * 1024
        switch task {
        case .dumpSystem:
            if systemIsHsqs {
                let blocks = try await s.execute(
                    "echo $((($(hexdump -e '1/4 \"%u\"' -s $((0x28)) -n 4 \(osDevice))+0xfff)/0x1000))")
                partitionSize = (Int64(blocks.output) ?? 0) * 4 * 1024
            } else {
                partitionSize = Int64(try await s.execute("blockdev --getsize64 \(osDevice)").output) ?? partitionSize
            }
        case .flashSystem:
            _ = try? await s.execute("hakchi umount_base")
            _ = try? await s.execute("umount /newroot")
            if hasKeyfile {
                _ = try? await s.execute("cryptsetup close root-crypt")
                try await expect(s, "cryptsetup open \(rootfsDevice) root-crypt --type plain --cipher aes-xts-plain --key-file /key-file")
            }
            partitionSize = Int64(try await s.execute("blockdev --getsize64 \(osDevice)").output) ?? partitionSize
        case .dumpUserData:
            try await expect(s, "hakchi mount_base")
            partitionSize = Int64(try await s.execute(
                "df -B 1 | grep /newroot/var/lib | head -n 1 | awk -e '{print $3 }'").output) ?? partitionSize
        case .flashUserData:
            partitionSize = Int64(try await s.execute("blockdev --getsize64 \(userDataDevice)").output) ?? partitionSize
        case .dumpNand:
            if hasNand {
                partitionSize = 536_870_912
            } else if hasMmc {
                partitionSize = Int64(try await s.execute("blockdev --getsize64 /dev/mmcblk0").output) ?? partitionSize
            }
        }

        let size = UInt64(max(partitionSize, 1))
        let report: SSHService.TransferProgress = { done, _ in
            progress(task == .flashSystem || task == .flashUserData ? "Flashing NAND..." : "Dumping NAND...",
                     min(0.95, 0.3 + 0.65 * Double(min(done, size)) / Double(size)))
        }

        if task == .flashSystem || task == .flashUserData {
            let fileSize = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
            if fileSize > partitionSize { throw RecoveryError.imageTooLarge }
        }

        switch task {
        case .dumpSystem:
            if systemIsHsqs {
                try await s.download(command: "dd if=\(osDevice) bs=128K count=\(partitionSize / 1024 / 4 / 32)",
                                     to: file, expectedSize: UInt64(partitionSize), progress: report)
            } else {
                // Not a squashfs: build one with mksquashfs on the console, then copy it out
                _ = try await s.execute("cat > /mksquashfs", input: try payloads.bundledFile("tools/arm/mksquashfs"))
                try await expect(s, "chmod +x /mksquashfs")
                _ = try? await s.execute("hakchi mount_base")
                _ = try? await s.execute("mkdir -p /tmp/")
                progress("Building the system image on the console...", 0.4)
                try await expectLong(s, "/mksquashfs /newroot/var/squashfs /tmp/rootfs.hsqs")
                let built = Int64(try await s.execute("ls -la /tmp/rootfs.hsqs | awk -e '{ print $5 }'").output) ?? 0
                _ = try? await s.execute("hakchi umount_base")
                try await s.download(command: "cat /tmp/rootfs.hsqs", to: file, expectedSize: UInt64(max(built, 1)),
                                     progress: report)
                _ = try? await s.execute("rm /tmp/rootfs.hsqs")
            }
        case .flashSystem:
            if isTar || (isMd && !isExt) {
                try await expect(s, "mkdir -p /tmp/rootfs /tmp/squashfs")
                if isHsqs {
                    try await uploadChecked(s, source, "dd of=/tmp/squashfs/squash.hsqs bs=128K", report)
                }
                try await expectLong(s, ConsoleTools.formatDeviceCommand(osDevice))
                try await expect(s, "mount \(osDevice) /tmp/rootfs")
                if isTar {
                    try await uploadChecked(s, source, "tar -xvf - -C /tmp/rootfs", report)
                } else if isHsqs {
                    try await expect(s, "mount /tmp/squashfs/squash.hsqs /tmp/squashfs/")
                    try await expectLong(s, "cd /tmp/squashfs; rsync -av ./ ../rootfs")
                    try await expect(s, "umount /tmp/squashfs")
                    try await expect(s, "rm -rf /tmp/squashfs")
                }
                try await expect(s, "umount /tmp/rootfs")
                try await expect(s, "rmdir /tmp/rootfs")
            } else {
                try await uploadChecked(s, source, "dd of=\(osDevice) bs=128K", report)
            }
            if hasKeyfile { try await expect(s, "cryptsetup close root-crypt") }
        case .dumpUserData:
            try await s.download(command: "tar -cvC /newroot/var/lib/ .", to: file,
                                 expectedSize: UInt64(partitionSize), progress: report)
        case .flashUserData:
            if isTar {
                try await expect(s, "hakchi mount_base")
                try await expectLong(s, "rm -rf /newroot/var/lib/*")
                try await uploadChecked(s, source, "tar -xvC /newroot/var/lib/", report)
            } else {
                try await uploadChecked(s, source, "dd of=\(userDataDevice) bs=128K", report)
            }
        case .dumpNand:
            if hasNand {
                _ = try? await s.execute("hakchi umount_base")
                try await s.download(command: "sntool sunxi_flash phy_read 0", to: file,
                                     expectedSize: UInt64(partitionSize), progress: report)
            } else if hasMmc {
                try await s.download(command: "dd if=/dev/mmcblk0 bs=1M", to: file,
                                     expectedSize: UInt64(partitionSize), progress: report)
            }
        }

        progress("Rebooting...", 0.97)
        await rebootUnlessUserRecovery(s)
        progress("Done.", 1.0)
    }

    // MARK: - Mega Drive checks (CE CheckMdRootfs)

    private func isMdPartitioning(_ s: SSHService) async throws -> Bool {
        (try await s.execute("hakchi ismdPartitioning")).succeeded
    }

    /// On Mega Drive consoles: refuse Project Lunar, warn about modified or unknown system files.
    /// `confirm` returns true to continue anyway.
    private func checkMdRootfs(_ s: SSHService) async throws {
        guard try await isMdPartitioning(s) else { return }
        try await expect(s, "hakchi mount_base")
        let squashfs = (try await s.execute("hakchi get squashfs")).output
        let initd = ConsoleTools.escapeShellArgument("\(squashfs)/etc/init.d")
        if !(try await s.execute("[ \"$(find \(initd) -name \"*_PL_*\" | wc -l)\" == \"0\" ]")).succeeded {
            throw RecoveryError.projectLunar
        }
        let versionFile = ConsoleTools.escapeShellArgument("\(squashfs)/version")
        let version = (try await s.execute("cat \(versionFile)")).output
        let tree = try await s.downloadData(command:
            "cd \"\(squashfs)\" && (echo \"$(cat \(versionFile))\"; find -type d | sort; find -type l | sort | while read link; do echo \"$link -> $(readlink \"$link\")\"; done; find -type f | sort | while read file; do md5sum \"$file\"; done)")
        let hash = ConsoleTools.md5Hex(tree)
        let verdict = ConsoleTools.checkMdRootfs(hash: hash, version: version)
        if verdict != .known {
            // Keep the listing for analysis, like CE's moon_hashes folder
            let dir = AppConfig.configDirectory.appendingPathComponent("moon_hashes", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let prefix = verdict == .modified ? "mismatched" : "unknown"
            try? tree.write(to: dir.appendingPathComponent("\(prefix)_\(version)_\(hash)"))
            let message = verdict == .modified
                ? "The system files appear to have been modified:\n\nVersion: \(version)\nHash: \(hash)\n\nDo you want to continue?"
                : "The system files are an unknown version:\n\nVersion: \(version)\nHash: \(hash)\n\nDo you want to continue?"
            let proceed = await MainActor.run { KernelDialogs.confirm(title: "System modification detected", message: message) }
            guard proceed else { throw RecoveryError.cancelled }
        }
        _ = try? await s.execute("hakchi umount_base")
    }

    // MARK: - Helpers

    private func nandInfo(_ s: SSHService) async throws -> ConsoleTools.NandInfo {
        let part = (try await s.execute("sunxi-part")).stdout
        let info = (try await s.execute("sunxi-flash nandinfo")).output
        return ConsoleTools.parseNandInfo(sunxiPart: part, nandInfo: info)
    }

    private func expect(_ s: SSHService, _ command: String) async throws {
        let result = try await s.execute(command, timeout: 60000)
        guard result.succeeded else { throw RecoveryError.commandFailed(command, result.stderr) }
    }

    /// Long-running command (mke2fs, rsync, mksquashfs): only times out when silent
    private func expectLong(_ s: SSHService, _ command: String) async throws {
        var output = ""
        let result = try await s.executeStreaming(command, idleTimeout: 600000) { chunk in
            output += String(decoding: chunk, as: UTF8.self)
            return true
        }
        guard result.succeeded else { throw RecoveryError.commandFailed(command, result.stderr + output.suffix(500)) }
    }

    private func uploadExecutable(_ s: SSHService, _ data: Data, to path: String) async throws {
        let result = try await s.execute("cat > \"\(path)\" && chmod +x \"\(path)\"", input: data)
        guard result.succeeded else { throw RecoveryError.commandFailed("upload \(path)", result.stderr) }
    }

    private func uploadChecked(_ s: SSHService, _ file: URL, _ command: String,
                               _ progress: @escaping SSHService.TransferProgress) async throws {
        let result = try await s.upload(fileURL: file, command: command, progress: progress)
        guard result.succeeded else { throw RecoveryError.commandFailed(command, result.stderr) }
    }

    /// First 4 KiB of a file (enough for the tar, squashfs and ext checks)
    static func readHeader(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 4096) ?? Data()
    }

    /// CE extracts .gz/.tgz/.xz/.bz2 images to a temporary file before flashing.
    /// For .tgz the first file inside the tarball is used, as CE's archive reader does.
    static func extractIfCompressed(_ url: URL, into dir: URL) throws -> URL {
        let ext = url.pathExtension.lowercased()
        guard ["gz", "tgz", "xz", "bz2"].contains(ext) else { return url }
        let packed = try Data(contentsOf: url, options: .alwaysMapped)
        var data: Data
        switch ext {
        case "xz": data = try XZArchive.unarchive(archive: packed)
        case "bz2": data = try BZip2.decompress(data: packed)
        default: data = try GzipArchive.unarchive(archive: packed)
        }
        if ext == "tgz", ConsoleTools.isTar(data),
           let first = try TarContainer.open(container: data).first(where: { $0.info.type == .regular }),
           let contents = first.data {
            data = contents
        }
        let out = dir.appendingPathComponent("dump.bin")
        try data.write(to: out)
        return out
    }
}
