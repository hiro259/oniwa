/// Deterministic one-step navigation over the ordered macOS Spaces on one
/// display. The live WindowServer state is reread between steps by the caller.
public enum SpaceNavigation {
    public enum Direction: Equatable {
        case left
        case right
    }

    public enum Decision: Equatable {
        case arrived
        case move(Direction, nextSpaceID: UInt64)
    }

    public enum PlanError: Error, Equatable {
        case emptyLayout
        case duplicateSpaceIDs
        case currentSpaceMissing
        case targetSpaceMissing
    }

    public static func nextStep(orderedSpaceIDs: [UInt64], current: UInt64,
                                target: UInt64) throws -> Decision {
        guard !orderedSpaceIDs.isEmpty else { throw PlanError.emptyLayout }
        guard Set(orderedSpaceIDs).count == orderedSpaceIDs.count else {
            throw PlanError.duplicateSpaceIDs
        }
        guard let currentIndex = orderedSpaceIDs.firstIndex(of: current) else {
            throw PlanError.currentSpaceMissing
        }
        guard let targetIndex = orderedSpaceIDs.firstIndex(of: target) else {
            throw PlanError.targetSpaceMissing
        }
        if currentIndex == targetIndex { return .arrived }
        let direction: Direction = targetIndex > currentIndex ? .right : .left
        let nextIndex = currentIndex + (direction == .right ? 1 : -1)
        return .move(direction, nextSpaceID: orderedSpaceIDs[nextIndex])
    }
}
