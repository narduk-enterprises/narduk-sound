import Foundation

@testable import NardukMusicCore

// The conductor's tests were written against Wirewatcher's network traffic, its first source. These are test-only
// copies of those traffic types and of Wirewatcher's adapter (TrafficMusicAdapter), so the tests keep their traffic
// scenarios and also prove that adapter's mapping: one signal per throughput tick, then one carrying the events.

enum TrafficDirection: Hashable {
    case inbound, outbound, local
}

enum TrafficEventKind: Hashable {
    case dnsQuery
    case dnsError
    case tlsHello(serverName: String?)
    case tcpSyn
    case tcpRst
    case retransmission
    case icmpReply(rtt: Double?)
    case icmpUnreachable
    case multicastDiscovery
    case newDestination(host: String)
    case newApp(bundleID: String)
    case newLANHost
    case wifiEvent
}

struct TrafficEvent: Hashable {
    var time: Double
    var kind: TrafficEventKind
    var direction: TrafficDirection
    var app: String?

    init(time: Double, kind: TrafficEventKind, direction: TrafficDirection, app: String? = nil) {
        self.time = time
        self.kind = kind
        self.direction = direction
        self.app = app
    }
}

struct ThroughputTick: Hashable {
    var time: Double
    var interval: Double
    var bytesIn: Int
    var bytesOut: Int
    var packets: Int
    var bytesPerApp: [String: Int]

    init(
        time: Double, interval: Double, bytesIn: Int, bytesOut: Int, packets: Int,
        bytesPerApp: [String: Int] = [:]
    ) {
        self.time = time
        self.interval = interval
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.packets = packets
        self.bytesPerApp = bytesPerApp
    }
}

struct TrafficBatch: Hashable {
    var events: [TrafficEvent]
    var ticks: [ThroughputTick]

    init(events: [TrafficEvent] = [], ticks: [ThroughputTick] = []) {
        self.events = events
        self.ticks = ticks
    }
}

enum TrafficAdapter {
    /// One signal per tick for the bytes, then one for the batch's per-app bytes and events. The per-app bytes ride
    /// on the last signal so the conductor trims its source table once per batch, as the traffic conductor did.
    static func signals(_ batch: TrafficBatch) -> [MusicSignal] {
        var signals = batch.ticks.map { tick in
            MusicSignal(
                time: tick.time,
                flow: MusicFlow(inbound: Double(tick.bytesIn), outbound: Double(tick.bytesOut)))
        }
        var flow = MusicFlow()
        for tick in batch.ticks {
            for (app, bytes) in tick.bytesPerApp { flow.sources[app, default: 0] += Double(bytes) }
        }
        var cues: [MusicCue] = []
        for event in batch.events {
            let tally = tally(event.kind)
            flow.starts += tally.connections
            flow.faults += tally.errors
            let pan =
                event.direction == .inbound
                ? -DropConductor.panWidth : event.direction == .outbound ? DropConductor.panWidth : 0
            cues.append(cue(event.kind, pan: pan))
        }
        guard !flow.sources.isEmpty || !batch.events.isEmpty else { return signals }
        let time = batch.events.first?.time ?? batch.ticks.last?.time ?? 0
        signals.append(MusicSignal(time: time, flow: flow, cues: cues))
        return signals
    }

    /// Connections (starts) and errors (faults) an event counts as.
    static func tally(_ kind: TrafficEventKind) -> (connections: Double, errors: Double) {
        switch kind {
        case .dnsQuery, .tcpSyn, .tlsHello, .newDestination: (1, 0)
        case .dnsError, .tcpRst, .retransmission, .icmpUnreachable: (0, 1)
        default: (0, 0)
        }
    }

    static func cue(_ kind: TrafficEventKind, pan: Double) -> MusicCue {
        switch kind {
        case .dnsQuery: .tick("DNS query", pan: pan)
        case .dnsError: .stutter("DNS error", pan: pan)
        case .tlsHello(let name): .spark("TLS \(name ?? "handshake")", key: name ?? "", pan: pan)
        case .tcpSyn: .ghost("TCP SYN", pan: pan)
        case .tcpRst: .impact("TCP reset", pan: pan)
        case .retransmission: .scratch("retransmission", pan: pan)
        case .icmpUnreachable: .tapeStop("ICMP unreachable", pan: pan)
        case .wifiEvent: .tapeStop("Wi-Fi event", pan: pan)
        case .icmpReply(let rtt):
            // Low ping = high zap: 1 ms tops the range, 200 ms bottoms it.
            .zap("ping reply", height: 1 - log10(max(1, min(200, (rtt ?? 0.02) * 1000))) / log10(200), pan: pan)
        case .multicastDiscovery: .sparkle("mDNS / SSDP", pan: pan)
        case .newDestination(let host): .voice("new destination \(host)", key: host, pan: pan)
        case .newApp(let bundleID): .voice("new app \(bundleID)", key: bundleID, pan: pan)
        case .newLANHost: .voice("new LAN host", variant: 0, pan: pan)
        }
    }
}

extension DropConductor {
    mutating func ingest(_ batch: TrafficBatch) {
        for signal in TrafficAdapter.signals(batch) { ingest(signal) }
    }
}
