import Foundation

public enum CLICommand: Equatable, Sendable {
    case help
    case version
    case status(json: Bool)
    case refresh(waitSeconds: Int)
    case doctor
    case skill
}

public enum CLIArgumentParser {
    public static func parse(_ arguments: [String]) -> Result<CLICommand, CLIUsageError> {
        guard let first = arguments.first else {
            return .failure(.usage)
        }

        switch first {
        case "-h", "--help":
            return .success(.help)
        case "--version", "-V":
            return .success(.version)
        case "status":
            return parseStatus(Array(arguments.dropFirst()))
        case "refresh":
            return parseRefresh(Array(arguments.dropFirst()))
        case "doctor":
            if arguments.count > 1 {
                return .failure(.usage)
            }
            return .success(.doctor)
        case "skill":
            if arguments.count > 1 {
                return .failure(.usage)
            }
            return .success(.skill)
        default:
            return .failure(.usage)
        }
    }

    private static func parseStatus(_ arguments: [String]) -> Result<CLICommand, CLIUsageError> {
        var json = false
        for argument in arguments {
            switch argument {
            case "--json":
                json = true
            default:
                return .failure(.usage)
            }
        }
        return .success(.status(json: json))
    }

    private static func parseRefresh(_ arguments: [String]) -> Result<CLICommand, CLIUsageError> {
        var waitSeconds = 0
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--wait" {
                guard index + 1 < arguments.count,
                      let seconds = Int(arguments[index + 1]),
                      seconds >= 0 else {
                    return .failure(.usage)
                }
                waitSeconds = seconds
                index += 2
                continue
            }
            return .failure(.usage)
        }
        return .success(.refresh(waitSeconds: waitSeconds))
    }
}

public enum CLIUsageError: Error, Equatable {
    case usage
}

public enum CLIHelp {
    public static let text = """
    allowancebar — read Allowance Bar usage snapshots (read-only)

    Usage:
      allowancebar status [--json]
      allowancebar refresh [--wait SECONDS]
      allowancebar doctor
      allowancebar skill
      allowancebar --version
      allowancebar --help

    Commands:
      status    Print the usage snapshot (table by default, --json for raw JSON)
      refresh   Ask the running app to refresh (allowancebar://refresh)
      doctor    Print a redacted environment and snapshot report
      skill     Print the agent skill markdown (e.g. allowancebar skill > ~/.codex/skills/allowancebar/SKILL.md)

    Exit codes:
      0  success
      1  usage error
      2  no snapshot (enable agent access in Allowance Bar Settings → Agents)
      3  Allowance Bar app is not running
      4  refresh timed out waiting for an updated snapshot
    """
}
