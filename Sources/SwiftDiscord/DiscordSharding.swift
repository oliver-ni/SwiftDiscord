// The MIT License (MIT)
// Copyright (c) 2016 Erik Little

// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without
// limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
// Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
// Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
// BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
// EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.

import Dispatch
import Foundation

/// Struct that represents shard information.
/// Used when a client is doing manual sharding.
public struct DiscordShardInformation {
    // MARK: Properties
    
    /// This client's shard number
    public let shardNum: Int

    /// The total number of shards this bot will have.
    public let totalShards: Int
    
    // MARK: Initializers

    /**
        Creates a new DiscordShardInformation
    */
    public init(shardNum: Int, totalShards: Int) {
        self.shardNum = shardNum
        self.totalShards = totalShards
    }
}


/// Protocol that represents a sharded gateway connection. This is the top-level protocol for `DiscordEngineSpec` and
/// `DiscordEngine`
public protocol DiscordShard {
    // MARK: Properties

    /// Whether this shard is connected to the gateway
    var connected: Bool { get }

    /// A reference to the manager
    weak var manager: DiscordShardManager? { get set }

    /// The total number of shards.
    var numShards: Int { get }

    /// This shard's number.
    var shardNum: Int { get }

    // MARK: Methods

    /**
        Starts the connection to the Discord gateway.
    */
    func connect()

    /**
        Disconnects the engine. An `engine.disconnect` is fired on disconnection.
    */
    func disconnect()

    /**
        Sends a gateway payload to Discord.

        - parameter payload: The payload object.
    */
    func sendGatewayPayload(_ payload: DiscordGatewayPayload)
}

/// The delegate for a `DiscordShardManager`.
public protocol DiscordShardManagerDelegate : class, DiscordClientSpec {
    // MARK: Methods

    /**
        Signals that the manager has finished connecting.

        - parameter manager: The manager.
        - parameter didConnect: Should always be true.
    */
    func shardManager(_ manager: DiscordShardManager, didConnect connected: Bool)

    /**
        Signals that the manager has disconnected.

        - parameter manager: The manager.
        - parameter didDisconnectWithReason: The reason the manager disconnected.
    */
    func shardManager(_ manager: DiscordShardManager, didDisconnectWithReason reason: String)
}

/**
    The shard manager is responsible for a client's shards. It decides when a client is considered connected.
    Connected being when all shards have recieved a ready event and are receiving events from the gateway. It also
    decides when a client has fully disconnected. Disconnected being when all shards have closed.
*/
open class DiscordShardManager {
    // MARK: Properties

    /// - returns: The shard with num `n`
    public subscript(n: Int) -> DiscordShard {
        return shards.first(where: { $0.shardNum == n })!
    }

    /// The individual shards.
    public var shards = [DiscordShard]()

    private let shardQueue = DispatchQueue(label: "shardQueue")

    private var closed = false
    private var closedShards = 0
    private var connectedShards = 0
    private weak var delegate: DiscordShardManagerDelegate?

    init(delegate: DiscordShardManagerDelegate) {
        self.delegate = delegate
    }

    // MARK: Methods

    private func cleanUp() {
        shards.removeAll()
        closedShards = 0
        connectedShards = 0
    }

    /**
        Connects all shards to the gateway.

        **Note** This method is an async method.
    */
    open func connect() {
        closed = false

        DispatchQueue.global().async {[shards = self.shards] in
            for shard in shards {
                guard !self.closed else { break }

                shard.connect()

                Thread.sleep(forTimeInterval: 5.0)
            }
        }
    }

    /**
        Creates a new shard.

        - parameter delegate: The delegate for this shard.
        - parameter withShardNum: The shard number for the new shard.
        - parameter totalShards: The total number of shards.
        - returns: A new `DiscordShard`
    */
    open func createShardWithDelegate(_ delegate: DiscordShardManagerDelegate, withShardNum shardNum: Int,
            totalShards: Int) -> DiscordShard {
        let engine = DiscordEngine(client: delegate, shardNum: shardNum, numShards: totalShards)

        engine.manager = self

        return engine
    }

    /**
        Disconnects all shards.
    */
    open func disconnect() {
        func _disconnect() {
            closed = true

            for shard in shards {
                shard.disconnect()
            }

            if connectedShards != shards.count {
                // Still connecting, say we disconnected, since we never connected to begin with
                delegate?.shardManager(self, didDisconnectWithReason: "Closed")
            }
        }

        shardQueue.async(execute: _disconnect)
    }

    /**
        Use when you will have multiple shards spread across a few instances.

        - parameter withInfo: The information about this single shard.
    */
    open func manuallyShatter(withInfo info: DiscordShardInformation) {
        guard let delegate = self.delegate else { return }

        DefaultDiscordLogger.Logger.verbose("Manually shattering shard #%@", type: "DiscordShardManager",
            args: info.shardNum)

        cleanUp()

        shards.append(createShardWithDelegate(delegate, withShardNum: info.shardNum, totalShards: info.totalShards))
    }

    /**
        Sends a payload on the specified shard.

        - parameter payload: The payload to send.
        - parameter onShard: The shard to send the payload on.
    */
    open func sendPayload(_ payload: DiscordGatewayPayload, onShard shard: Int) {
        self[shard].sendGatewayPayload(payload)
    }

    /**
        Creates the shards for this manager.

        - parameter into: The number of shards to create.
    */
    open func shatter(into numberOfShards: Int) {
        guard let delegate = self.delegate else { return }

        DefaultDiscordLogger.Logger.verbose("Shattering into %@ shards", type: "DiscordShardManager",
            args: numberOfShards)

        cleanUp()

        for i in 0..<numberOfShards {
            shards.append(createShardWithDelegate(delegate, withShardNum: i, totalShards: numberOfShards))
        }
    }

    /**
        Used by shards to signal that they have connected.

        - parameter shardNum: The number of the shard that disconnected.
    */
    open func signalShardConnected(shardNum: Int) {
        func _signalShardConnected() {
            DefaultDiscordLogger.Logger.verbose("Shard #%@, connected", type: "DiscordShardManager",
                args: shardNum)

            connectedShards += 1

            guard connectedShards == shards.count else { return }

            delegate?.shardManager(self, didConnect: true)
        }

        shardQueue.async(execute: _signalShardConnected)
    }

    /**
        Used by shards to signal that they have disconnected

        - parameter shardNum: The number of the shard that disconnected.
    */
    open func signalShardDisconnected(shardNum: Int) {
        func _signalShardDisconnected() {
            DefaultDiscordLogger.Logger.verbose("Shard #%@, disconnected", type: "DiscordShardManager",
                args: shardNum)

            closedShards += 1

            guard closedShards == shards.count else { return }

            delegate?.shardManager(self, didDisconnectWithReason: "Closed")
        }

        shardQueue.async(execute: _signalShardDisconnected)
    }
}