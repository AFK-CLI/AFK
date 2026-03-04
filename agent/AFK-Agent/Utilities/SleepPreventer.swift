//
//  SleepPreventer.swift
//  AFK-Agent
//

import Foundation
import IOKit.pwr_mgt
import OSLog

final class SleepPreventer {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive: Bool = false

    func start() {
        guard !isActive else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "AFK Agent preventing sleep during active sessions" as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            isActive = true
            AppLogger.statusBar.info("Sleep prevention started")
        } else {
            AppLogger.statusBar.error("Failed to create sleep assertion: \(result)")
        }
    }

    func stop() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        isActive = false
        AppLogger.statusBar.info("Sleep prevention stopped")
    }

    deinit {
        stop()
    }
}
