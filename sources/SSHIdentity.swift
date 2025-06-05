//
//  SSHIdentity.swift
//  iTerm2SharedARC
//
//  Created by George Nachman on 5/12/22.
//

import Foundation

public protocol SSHHostnameFinder: AnyObject {
    func sshHostname(forHost host: String) -> String
}

public class SSHIdentity: NSObject, Codable {
    static let localhost = SSHIdentity(host: Host.current().localizedName ?? "My Mac",
                                       hostname: "localhost",
                                       username: nil,
                                       port: 0)

    static func ==(lhs: SSHIdentity, rhs: SSHIdentity) -> Bool {
        return lhs.state == rhs.state
    }

    private struct State: Equatable, Codable, CustomDebugStringConvertible {
        var debugDescription: String {
            let hostport = hostname + ":\(port)"
            if let username = username {
                return username + "@" + hostport
            }
            return hostport
        }

        var compactDescription: String {
            let hostport: String
            if port == 22 {
                hostport = hostname
            } else {
                hostport = hostname + " port \(port)"
            }
            if let username = username, username != NSUserName() {
                return username + "@" + hostport
            }
            return hostport
        }

        let host: String
        let hostname: String
        let username: String?
        let port: Int

        var commandLine: String {
            let parts = [username.map { "-l \($0)" },
                         port == 22 ? nil : "-p \(port)",
                         "\(hostname)"].compactMap { $0 }
            return parts.joined(separator: " ")
        }
    }
    private let state: State

    @objc public var commandLine: String {
        return state.commandLine
    }

    @objc public var json: Data {
        return try! JSONEncoder().encode(state)
    }

    @objc public var compactDescription: String {
        return state.compactDescription
    }

    public override var debugDescription: String {
        return state.debugDescription
    }

    public override var description: String {
        return state.debugDescription
    }

    var host: String {
        state.host
    }

    @objc public var hostname: String {
        return state.hostname
    }

    @objc public var username: String? {
        return state.username
    }

    @objc public var port: Int {
        return state.port
    }

    public var stringIdentifier: String {
        return state.compactDescription
    }

    public init?(stringIdentifier: String, hostnameFinder: SSHHostnameFinder)  {
        guard let at = stringIdentifier.range(of: "@"),
              let colon = stringIdentifier.range(of: ":") else {
            return nil
        }
        guard at.lowerBound < colon.lowerBound else {
            return nil
        }
        let username = stringIdentifier[..<at.lowerBound]
        guard let port = Int(stringIdentifier[colon.upperBound...]) else {
            return nil
        }
        let host = String(stringIdentifier[at.upperBound..<colon.lowerBound])
        state = State(host: host,
                      hostname: hostnameFinder.sshHostname(forHost: host),
                      username: username.isEmpty ? nil : String(username),
                      port: port)
    }

    @objc
    public init?(_ json: Data?) {
        guard let data = json else {
            return nil
        }
        if let state = try? JSONDecoder().decode(State.self, from: data) {
            self.state = state
        } else {
            return nil
        }
    }

    @objc
    public init(host: String, hostname: String, username: String?, port: Int) {
        state = State(host: host, hostname: hostname, username: username, port: port)
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SSHIdentity else {
            return false
        }
        return other.state == state
    }

    public override func isEqual(to object: Any?) -> Bool {
        guard let other = object as? SSHIdentity else {
            return false
        }
        return other.state == state
    }

    // We make an effort to figure out the real hostname, but there's no guarantee that we succeed.
    // For example, the user could do `it2ssh foo` where `foo` is only defined in /etc/hosts.
    // The remote host could report itself as either `foo` or `foo.example.com`. In the case where
    // they are both `foo` it's wise to match state.host (derived from the it2ssh command line)
    // against the `host` parameter (derived from shell integration control sequences from the
    // remote host).
    public func matches(host: String?, user: String?) -> Bool {
        DLog("matches: \(hostname) or \(state.host) == \(host ?? "(nil)") && \(state.username ?? "(nil)") == \(user ?? "(nil)")")
        guard (hostname == host || state.host == host) else {
            return false
        }
        if state.username == nil {
            return true
        }
        return state.username == user
    }

    override public var hash: Int {
        var combined = UInt(0)
        combined = iTermCombineHash(UInt(bitPattern: state.host.hashValue), combined)
        combined = iTermCombineHash(UInt(bitPattern: state.hostname.hashValue), combined)
        combined = iTermCombineHash(UInt(bitPattern: state.username.hashValue), combined)
        combined = iTermCombineHash(UInt(bitPattern: state.port.hashValue), combined)
        return Int(bitPattern: combined)
    }
}

extension SSHIdentity {
    var displayName: String {
        let hostport: String
        if state.port == 22 || state.port == 0 {
            hostport = state.host
        } else {
            hostport = state.host + ":\(state.port)"
        }
        if let username = state.username, username != NSUserName() {
            return username + "@" + hostport
        }
        return hostport
    }
}

// MARK: - UserDefaults Support
extension SSHIdentity {
    /// Convert the SSHIdentity to a dictionary that can be stored in UserDefaults
    @objc public func toUserDefaultsObject() -> [String: Any] {
        var dict: [String: Any] = [
            "host": state.host,
            "hostname": state.hostname,
            "port": state.port
        ]

        if let username = state.username {
            dict["username"] = username
        }

        return dict
    }

    /// Create an SSHIdentity from a UserDefaults object (dictionary)
    @objc public convenience init?(userDefaultsObject: Any?) {
        guard let dict = userDefaultsObject as? [String: Any],
              let host = dict["host"] as? String,
              let hostname = dict["hostname"] as? String,
              let port = dict["port"] as? Int else {
            return nil
        }

        let username = dict["username"] as? String

        self.init(host: host, hostname: hostname, username: username, port: port)
    }
}
