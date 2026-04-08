import os

extension Logger {
    static let inventory  = Logger(subsystem: "com.prunr.app", category: "Inventory")
    static let fsEvents   = Logger(subsystem: "com.prunr.app", category: "FSEvents")
    static let scan       = Logger(subsystem: "com.prunr.app", category: "Scan")
    static let state      = Logger(subsystem: "com.prunr.app", category: "StateMerge")
    static let progress   = Logger(subsystem: "com.prunr.app", category: "Progress")
    static let reconciler = Logger(subsystem: "com.prunr.app", category: "Reconciliation")
}
