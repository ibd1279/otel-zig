//! OpenTelemetry Metrics Semantic Conventions
//!
//! Standard metric names for HTTP, database, and RPC instrumentation,
//! plus the Units helper for instrument configuration.
//! Spec: https://github.com/open-telemetry/semantic-conventions/tree/v1.41.0/model

// HTTP server metrics

pub const HTTP_SERVER_REQUEST_DURATION = "http.server.request.duration";
pub const HTTP_SERVER_ACTIVE_REQUESTS = "http.server.active_requests";
pub const HTTP_SERVER_REQUEST_BODY_SIZE = "http.server.request.body.size";
pub const HTTP_SERVER_RESPONSE_BODY_SIZE = "http.server.response.body.size";

// HTTP client metrics

pub const HTTP_CLIENT_REQUEST_DURATION = "http.client.request.duration";
pub const HTTP_CLIENT_REQUEST_BODY_SIZE = "http.client.request.body.size";
pub const HTTP_CLIENT_RESPONSE_BODY_SIZE = "http.client.response.body.size";
pub const HTTP_CLIENT_OPEN_CONNECTIONS = "http.client.open_connections";
pub const HTTP_CLIENT_CONNECTION_DURATION = "http.client.connection.duration";
pub const HTTP_CLIENT_ACTIVE_REQUESTS = "http.client.active_requests";

// Database client metrics

pub const DB_CLIENT_OPERATION_DURATION = "db.client.operation.duration";
pub const DB_CLIENT_RESPONSE_RETURNED_ROWS = "db.client.response.returned_rows";
pub const DB_CLIENT_CONNECTION_COUNT = "db.client.connection.count";
pub const DB_CLIENT_CONNECTION_IDLE_MAX = "db.client.connection.idle.max";
pub const DB_CLIENT_CONNECTION_IDLE_MIN = "db.client.connection.idle.min";
pub const DB_CLIENT_CONNECTION_MAX = "db.client.connection.max";
pub const DB_CLIENT_CONNECTION_PENDING_REQUESTS = "db.client.connection.pending_requests";
pub const DB_CLIENT_CONNECTION_TIMEOUTS = "db.client.connection.timeouts";
pub const DB_CLIENT_CONNECTION_CREATE_TIME = "db.client.connection.create_time";
pub const DB_CLIENT_CONNECTION_WAIT_TIME = "db.client.connection.wait_time";
pub const DB_CLIENT_CONNECTION_USE_TIME = "db.client.connection.use_time";

// RPC metrics

pub const RPC_SERVER_CALL_DURATION = "rpc.server.call.duration";
pub const RPC_CLIENT_CALL_DURATION = "rpc.client.call.duration";

// Units — UCUM symbols used in OTel metric definitions

pub const Units = struct {
    // Time
    pub const NANOSECOND = "ns";
    pub const MICROSECOND = "us";
    pub const MILLISECOND = "ms";
    pub const SECOND = "s";
    pub const MINUTE = "min";
    pub const HOUR = "h";
    pub const DAY = "d";

    // Bytes
    pub const BYTES = "By";
    pub const KIBIBYTES = "KiBy";
    pub const MEBIBYTES = "MiBy";
    pub const GIBIBYTES = "GiBy";
    pub const TEBIBYTES = "TiBy";
    pub const KILOBYTES = "kBy";
    pub const MEGABYTES = "MBy";
    pub const GIGABYTES = "GBy";
    pub const TERABYTES = "TBy";

    // Throughput
    pub const BYTES_PER_SECOND = "By/s";
    pub const KIBIBYTES_PER_SECOND = "KiBy/s";
    pub const MEBIBYTES_PER_SECOND = "MiBy/s";

    // Frequency
    pub const HERTZ = "Hz";
    pub const KILOHERTZ = "kHz";
    pub const MEGAHERTZ = "MHz";
    pub const GIGAHERTZ = "GHz";

    // Dimensionless / counts
    pub const PERCENT = "%";
    pub const UNIT = "1";

    // Annotated counts (curly-brace unit syntax)
    pub const CELSIUS = "Cel";
    pub const REQUESTS = "{request}";
    pub const CONNECTIONS = "{connection}";
    pub const TOKENS = "{token}";
    pub const MESSAGES = "{message}";
    pub const OPERATIONS = "{operation}";
    pub const THREADS = "{thread}";
    pub const ROWS = "{row}";
};
