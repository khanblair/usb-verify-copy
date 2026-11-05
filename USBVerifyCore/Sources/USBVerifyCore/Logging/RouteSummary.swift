import Foundation

public struct RouteSummary: Equatable, Sendable {
    public var routeKey: String
    public var route: Route?
    public var total: Int
    public var passed: Int
    public var failed: Int

    public init(routeKey: String, route: Route?, total: Int, passed: Int, failed: Int) {
        self.routeKey = routeKey
        self.route = route
        self.total = total
        self.passed = passed
        self.failed = failed
    }
}

public enum RouteHistory {
    public static func summaries(from runs: [RunRecord]) -> [RouteSummary] {
        var groups: [String: (route: Route?, total: Int, passed: Int, failed: Int)] = [:]
        for run in runs {
            let key = run.route?.key ?? "unknown"
            var current = groups[key] ?? (route: run.route, total: 0, passed: 0, failed: 0)
            if current.route == nil && run.route != nil {
                current.route = run.route
            }
            current.total += 1
            if run.result == "PASS" {
                current.passed += 1
            } else if run.result == "FAIL" {
                current.failed += 1
            }
            groups[key] = current
        }

        let summaries = groups.map { (key, value) in
            RouteSummary(
                routeKey: key,
                route: value.route,
                total: value.total,
                passed: value.passed,
                failed: value.failed
            )
        }

        return summaries.sorted { a, b in
            if a.failed != b.failed {
                return a.failed > b.failed
            }
            if a.total != b.total {
                return a.total > b.total
            }
            return a.routeKey < b.routeKey
        }
    }
}
