//! OpenTelemetry Network Semantic Conventions
//!
//! Attributes for network layer and transport instrumentation.
//! Spec: https://github.com/open-telemetry/semantic-conventions/tree/v1.41.0/model/network

// Transport layer

pub const TRANSPORT = "network.transport";

pub const Transport = struct {
    pub const tcp = "tcp";
    pub const udp = "udp";
    pub const pipe = "pipe";
    pub const unix = "unix";
    pub const quic = "quic";
};

// Network layer

pub const TYPE = "network.type";

pub const Type = struct {
    pub const ipv4 = "ipv4";
    pub const ipv6 = "ipv6";
};

// Application protocol

pub const PROTOCOL_NAME = "network.protocol.name";
pub const PROTOCOL_VERSION = "network.protocol.version";

// Local endpoint

pub const LOCAL_ADDRESS = "network.local.address";
pub const LOCAL_PORT = "network.local.port";

// Peer endpoint

pub const PEER_ADDRESS = "network.peer.address";
pub const PEER_PORT = "network.peer.port";

// I/O direction

pub const IO_DIRECTION = "network.io.direction";

pub const IoDirection = struct {
    pub const transmit = "transmit";
    pub const receive = "receive";
};

// Interface

pub const INTERFACE_NAME = "network.interface.name";

// Connection state (TCP states per RFC 9293)

pub const CONNECTION_STATE = "network.connection.state";

pub const ConnectionState = struct {
    pub const closed = "closed";
    pub const close_wait = "close_wait";
    pub const closing = "closing";
    pub const established = "established";
    pub const fin_wait_1 = "fin_wait_1";
    pub const fin_wait_2 = "fin_wait_2";
    pub const last_ack = "last_ack";
    pub const listen = "listen";
    pub const syn_received = "syn_received";
    pub const syn_sent = "syn_sent";
    pub const time_wait = "time_wait";
};
