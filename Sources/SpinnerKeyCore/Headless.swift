import Foundation

#if canImport(Security)
/// Command-line entry points, used by the launchd agent (`rotate`) and for troubleshooting.
public enum Headless {
    public static let commands: Set<String> = ["rotate", "rotate-now", "status", "help"]

    public static func run(_ command: String) -> Int32 {
        switch command {
        case "rotate": return blocking { await rotate(force: false) }
        case "rotate-now": return blocking { await rotate(force: true) }
        case "status": return status()
        default:
            print("""
            Usage: SpinnerKey [command]
              (no command)  open the configuration window
              rotate        rotate any keys that are due (what the scheduler runs)
              rotate-now    rotate all enabled keys immediately
              status        show rotation status
            """)
            return 0
        }
    }

    static func rotate(force: Bool) async -> Int32 {
        let store = Store()
        let logger = Logger.shared
        let notify = (try? store.loadConfig().notifyOnFailure) ?? true
        do {
            let report = try await Wiring.makeRotator(store: store, logger: logger).run(force: force)
            if report.failures.isEmpty { return 0 }
            if notify {
                Notifier.notify(report.failures.map { "\($0.provider.displayName): \($0.message)" }.joined(separator: "\n"))
            }
            return 1
        } catch SpinnerKeyError.alreadyRunning {
            logger.info("Skipped: another rotation is in progress.")
            return 0
        } catch {
            logger.error(error.localizedDescription)
            if notify { Notifier.notify(error.localizedDescription) }
            return 1
        }
    }

    static func status() -> Int32 {
        let store = Store()
        do {
            let config = try store.loadConfig()
            let state = try store.loadState()
            print("Automatic rotation: \(config.scheduleEnabled ? "on" : "off"), every \(config.intervalHours)h")
            for job in config.jobs {
                let js = state.jobs[job.id] ?? JobState()
                print("\(job.provider.displayName) [\(job.enabled ? "enabled" : "disabled")] → \(job.targets.map(\.displayName).joined(separator: ", "))")
                print("  last rotated: \(js.lastRotatedAt.map { "\($0)" } ?? "never")")
                print("  next due:     \(Rotator.nextDue(js, config: config).map { "\($0)" } ?? "next check")")
                print("  pending revocations: \(js.pendingRevocations.count)")
                if let error = js.lastError { print("  last error:   \(error)") }
            }
            return 0
        } catch {
            print(error.localizedDescription)
            return 1
        }
    }

    private static func blocking(_ operation: @escaping () async -> Int32) -> Int32 {
        final class Box { var value: Int32 = 1 }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }
}
#endif
