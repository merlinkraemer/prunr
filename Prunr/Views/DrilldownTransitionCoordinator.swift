import SwiftUI

/// Single RunLoop-aligned slide animation shared by the header strip and category list.
@MainActor
@Observable
final class DrilldownTransitionCoordinator {
    private(set) var slideOffset: CGFloat = 0

    private var navigationTask: Task<Void, Never>?

    static let slideMilliseconds: UInt64 = 280

    static var slideAnimation: Animation {
        .snappy(duration: Double(slideMilliseconds) / 1000.0, extraBounce: 0)
    }

    func cancelAndReset() {
        navigationTask?.cancel()
        navigationTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            slideOffset = 0
        }
    }

    /// Two-part layout setup, one shared `withAnimation` slide, then unanimated teardown.
    func performCoordinatedSlide(
        width: CGFloat,
        forward: Bool,
        stabilize: () -> Void,
        phase1: () -> Void,
        phase3: @escaping () -> Void,
        afterTeardown: @escaping () -> Void
    ) {
        navigationTask?.cancel()
        navigationTask = nil
        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            slideOffset = 0
        }
        stabilize()

        guard width > 0 else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                phase3()
                slideOffset = 0
            }
            afterTeardown()
            return
        }

        let initialOffset: CGFloat = forward ? 0 : -width
        let targetOffset: CGFloat = forward ? -width : 0

        var setupTransaction = Transaction()
        setupTransaction.disablesAnimations = true
        withTransaction(setupTransaction) {
            phase1()
            slideOffset = initialOffset
        }

        navigationTask = Task { @MainActor in
            await withCheckedContinuation { continuation in
                RunLoop.main.perform { continuation.resume() }
            }
            guard !Task.isCancelled else { return }

            withAnimation(Self.slideAnimation) {
                self.slideOffset = targetOffset
            }

            try? await Task.sleep(for: .milliseconds(Int(Self.slideMilliseconds)))
            guard !Task.isCancelled else { return }

            var cleanupTransaction = Transaction()
            cleanupTransaction.disablesAnimations = true
            withTransaction(cleanupTransaction) {
                phase3()
                self.slideOffset = 0
            }

            afterTeardown()
        }
    }
}
