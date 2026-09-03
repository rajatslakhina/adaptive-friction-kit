/// The nine states QA has to be able to force from an Xcode scheme: three
/// signals × three availabilities. Parsed from launch arguments or the
/// environment so a scheme's "Arguments Passed On Launch" can select any cell
/// without a code change.
public struct QAScenario: Sendable, Hashable, CaseIterable, CustomStringConvertible {
    public enum Availability: String, Sendable, Hashable, CaseIterable {
        /// The evaluator answers within the deadline.
        case available
        /// The user revoked authorization; a 60 s cooldown is reported.
        case notAuthorized
        /// The evaluator never answers inside the policy's deadline.
        case timeout
    }

    public let signal: CoachingSignal
    public let availability: Availability

    public init(signal: CoachingSignal, availability: Availability) {
        self.signal = signal
        self.availability = availability
    }

    public static let signalKey = "AF_SIGNAL"
    public static let availabilityKey = "AF_AVAILABILITY"

    /// All nine cells, signals outer, availabilities inner.
    public static var allCases: [QAScenario] {
        CoachingSignal.allCases.flatMap { signal in
            Availability.allCases.map { QAScenario(signal: signal, availability: $0) }
        }
    }

    /// Reads `AF_SIGNAL` (`unknown` | `medium` | `high`) and `AF_AVAILABILITY`
    /// (`available` | `notAuthorized` | `timeout`) from a dictionary such as
    /// `ProcessInfo.processInfo.environment`. Returns `nil` if neither key is
    /// present; an unrecognised value falls back to that key's default
    /// (`unknown` / `available`) so a typo in a scheme cannot crash a launch.
    public static func parse(_ values: [String: String]) -> QAScenario? {
        let rawSignal = values[signalKey]
        let rawAvailability = values[availabilityKey]
        guard rawSignal != nil || rawAvailability != nil else { return nil }
        let signal = rawSignal.flatMap { raw in
            CoachingSignal.allCases.first { "\($0)" == raw.lowercased() }
        } ?? .unknown
        let availability = rawAvailability.flatMap { raw in
            Availability.allCases.first { $0.rawValue.lowercased() == raw.lowercased() }
        } ?? .available
        return QAScenario(signal: signal, availability: availability)
    }

    /// Reads a launch-argument list of the form `-AF_SIGNAL high -AF_AVAILABILITY timeout`.
    public static func parse(arguments: [String]) -> QAScenario? {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("-"), index + 1 < arguments.count {
                let key = String(argument.dropFirst())
                if key == signalKey || key == availabilityKey {
                    values[key] = arguments[index + 1]
                    index += 2
                    continue
                }
            }
            index += 1
        }
        return parse(values)
    }

    /// The simulated behaviour that reproduces this scenario. The timeout
    /// latency is 10 s so that any sane policy deadline expires first.
    public func behaviour(priorSignal: CoachingSignal? = nil) -> SimulatedBehaviour {
        switch availability {
        case .available:
            return SimulatedBehaviour(availability: .available, signal: signal, priorSignal: priorSignal)
        case .notAuthorized:
            return SimulatedBehaviour(availability: .unavailable(.notAuthorized(cooldown: .seconds(60))),
                                      signal: signal, priorSignal: priorSignal)
        case .timeout:
            return SimulatedBehaviour(availability: .available, signal: signal, priorSignal: priorSignal,
                                      latency: .seconds(10))
        }
    }

    public var description: String { "\(signal)/\(availability.rawValue)" }
}
