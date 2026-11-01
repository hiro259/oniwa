/// Pure, fixed-layout plan for the experimental rapid Control+Arrow path.
/// No OS events are emitted here. A burst must be verified after completion;
/// unlike the normal navigation loop there are no per-step readbacks.
public enum ArrowBurstPlan {
    public enum Direction: Equatable {
        case left
        case right
    }

    public enum Result: Equatable {
        case arrived
        case burst(direction: Direction, steps: Int, path: [UInt64])
        case blocked(reason: String)
    }

    /// Bounded to avoid blind large jumps when Spaces are misidentified.
    public static func make(
        order: [UInt64], current: UInt64, target: UInt64, maxSteps: Int = 12
    ) -> Result {
        guard !order.isEmpty && order.count == Set(order).count else {
            return .blocked(reason: "invalid-space-order")
        }
        guard let from = order.firstIndex(of: current) else {
            return .blocked(reason: "current-not-in-order")
        }
        guard let to = order.firstIndex(of: target) else {
            return .blocked(reason: "target-not-in-order")
        }
        if from == to { return .arrived }
        let steps = abs(to - from)
        guard steps <= maxSteps else {
            return .blocked(reason: "step-limit")
        }
        let direction: Direction = to > from ? .right : .left
        let path = (1...steps).map { step in
            order[from + (direction == .right ? step : -step)]
        }
        return .burst(direction: direction, steps: steps, path: path)
    }
}
