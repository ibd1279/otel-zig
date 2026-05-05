//! OpenTelemetry HTTP Semantic Conventions
//!
//! Stable and development attributes for HTTP spans and metrics.
//! Spec: https://github.com/open-telemetry/semantic-conventions/tree/v1.41.0/model/http

// Request attributes

pub const REQUEST_METHOD = "http.request.method";
pub const REQUEST_METHOD_ORIGINAL = "http.request.method_original";
pub const REQUEST_RESEND_COUNT = "http.request.resend_count";
pub const REQUEST_BODY_SIZE = "http.request.body.size";
pub const REQUEST_SIZE = "http.request.size";
/// Template base — append `.<lowercase-header-name>` to form the full key.
pub const REQUEST_HEADER = "http.request.header";

pub const RequestMethod = struct {
    pub const CONNECT = "CONNECT";
    pub const DELETE = "DELETE";
    pub const GET = "GET";
    pub const HEAD = "HEAD";
    pub const OPTIONS = "OPTIONS";
    pub const PATCH = "PATCH";
    pub const POST = "POST";
    pub const PUT = "PUT";
    pub const TRACE = "TRACE";
    pub const QUERY = "QUERY";
    /// Any method the instrumentation has no prior knowledge of.
    pub const other = "_OTHER";
};

// Response attributes

pub const RESPONSE_STATUS_CODE = "http.response.status_code";
pub const RESPONSE_BODY_SIZE = "http.response.body.size";
pub const RESPONSE_SIZE = "http.response.size";
/// Template base — append `.<lowercase-header-name>` to form the full key.
pub const RESPONSE_HEADER = "http.response.header";

// Routing

pub const ROUTE = "http.route";

// Connection pool

pub const CONNECTION_STATE = "http.connection.state";

pub const ConnectionState = struct {
    pub const active = "active";
    pub const idle = "idle";
};
