import Foundation

public struct AMLLSpringParameters: Hashable, Sendable {
    public var mass: Double
    public var damping: Double
    public var stiffness: Double
    public var soft: Bool

    public init(mass: Double = 1, damping: Double = 10, stiffness: Double = 100, soft: Bool = false) {
        self.mass = mass
        self.damping = damping
        self.stiffness = stiffness
        self.soft = soft
    }
}

/// Closed-form AMLL spring. Changing a target preserves velocity and avoids the
/// stop/restart vertical jitter produced by independent item animations.
public struct AMLLSpring: Sendable {
    public private(set) var position: Double
    public private(set) var velocity: Double = 0
    public private(set) var target: Double
    public private(set) var parameters = AMLLSpringParameters()

    public init(position: Double = 0) {
        self.position = position
        target = position
    }

    public mutating func snap(to value: Double) {
        position = value
        target = value
        velocity = 0
    }

    public mutating func updateTarget(_ value: Double, parameters: AMLLSpringParameters? = nil) {
        target = value
        if let parameters { self.parameters = parameters }
    }

    @discardableResult
    public mutating func step(deltaSeconds: Double) -> Double {
        let time = min(max(deltaSeconds, 0), 0.064)
        guard time > 0 else { return position }
        let delta = target - position
        let mass = max(parameters.mass, 0.0001)
        let stiffness = max(parameters.stiffness, 0.0001)
        let damping = max(parameters.damping, 0)
        let initialVelocity = velocity
        if parameters.soft || damping / (2 * sqrt(stiffness * mass)) >= 1 {
            let angularFrequency = -sqrt(stiffness / mass)
            let leftover = -angularFrequency * delta - initialVelocity
            let decay = exp(time * angularFrequency)
            position = target - (delta + time * leftover) * decay
            velocity = -(leftover + angularFrequency * (delta + time * leftover)) * decay
        } else {
            let dampingFrequency = sqrt(4 * mass * stiffness - damping * damping)
            let leftover = (damping * delta - 2 * mass * initialVelocity) / dampingFrequency
            let dfm = 0.5 * dampingFrequency / mass
            let dm = -0.5 * damping / mass
            let decay = exp(time * dm)
            let wave = cos(time * dfm) * delta + sin(time * dfm) * leftover
            position = target - wave * decay
            velocity = decay * (
                dfm * sin(time * dfm) * delta
                - dfm * cos(time * dfm) * leftover
                - dm * wave
            )
        }
        if isSettled { snap(to: target) }
        return position
    }

    public var isSettled: Bool { abs(target - position) < 0.1 && abs(velocity) < 0.1 }
}

public func lyricScrollSpringPolicy(
    isSeeking: Bool,
    isInterludeActive: Bool = false,
    intervalMs: Int64?
) -> AMLLSpringParameters {
    guard !isSeeking, !isInterludeActive, let intervalMs else {
        return .init(mass: 0.9, damping: 15, stiffness: 90)
    }
    let clamped = min(max(intervalMs, 100), 800)
    let linearRatio = 1 - Double(clamped - 100) / 700
    let ratio = pow(linearRatio, 0.2)
    let stiffness = 170 + ratio * 50
    return .init(mass: 0.9, damping: sqrt(stiffness) * 2.2, stiffness: stiffness)
}
