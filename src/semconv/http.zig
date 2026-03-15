//! OpenTelemetry HTTP Semantic Conventions
//!
//! This module defines standard HTTP attribute names that are common across
//! traces, metrics, and logs according to the OpenTelemetry semantic conventions.
//!
//! These conventions ensure consistent naming for HTTP-related attributes
//! across different implementations and languages.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/semantic_conventions/http.md

// HTTP request attributes
pub const HTTP_REQUEST_METHOD = "http.request.method";
pub const HTTP_REQUEST_BODY_SIZE = "http.request.body.size";
pub const HTTP_REQUEST_HEADER = "http.request.header";

// HTTP response attributes
pub const HTTP_RESPONSE_STATUS_CODE = "http.response.status_code";
pub const HTTP_RESPONSE_BODY_SIZE = "http.response.body.size";
pub const HTTP_RESPONSE_HEADER = "http.response.header";

// HTTP connection attributes
pub const HTTP_CONNECTION_STATE = "http.connection.state";
pub const HTTP_CONNECTION_TYPE = "http.connection.type";

// Network attributes used with HTTP
pub const NETWORK_PROTOCOL_NAME = "network.protocol.name";
pub const NETWORK_PROTOCOL_VERSION = "network.protocol.version";
pub const NETWORK_TRANSPORT = "network.transport";
pub const NETWORK_TYPE = "network.type";
pub const NETWORK_LOCAL_ADDRESS = "network.local.address";
pub const NETWORK_LOCAL_PORT = "network.local.port";
pub const NETWORK_PEER_ADDRESS = "network.peer.address";
pub const NETWORK_PEER_PORT = "network.peer.port";

// Server attributes
pub const SERVER_ADDRESS = "server.address";
pub const SERVER_PORT = "server.port";

// Client attributes
pub const CLIENT_ADDRESS = "client.address";
pub const CLIENT_PORT = "client.port";

// URL attributes
pub const URL_FULL = "url.full";
pub const URL_SCHEME = "url.scheme";
pub const URL_PATH = "url.path";
pub const URL_QUERY = "url.query";
pub const URL_FRAGMENT = "url.fragment";
pub const URL_TEMPLATE = "url.template";

// HTTP route (matched route template)
pub const HTTP_ROUTE = "http.route";

// User agent
pub const USER_AGENT_ORIGINAL = "user_agent.original";

// HTTP method values
pub const HttpRequestMethodValues = struct {
    pub const CONNECT = "CONNECT";
    pub const DELETE = "DELETE";
    pub const GET = "GET";
    pub const HEAD = "HEAD";
    pub const OPTIONS = "OPTIONS";
    pub const PATCH = "PATCH";
    pub const POST = "POST";
    pub const PUT = "PUT";
    pub const TRACE = "TRACE";
    pub const OTHER = "_OTHER";
};

// Network transport values
pub const NetworkTransportValues = struct {
    pub const TCP = "tcp";
    pub const UDP = "udp";
    pub const PIPE = "pipe";
    pub const UNIX = "unix";
};

// Network type values
pub const NetworkTypeValues = struct {
    pub const IPV4 = "ipv4";
    pub const IPV6 = "ipv6";
};

// HTTP connection state values
pub const HttpConnectionStateValues = struct {
    pub const ACTIVE = "active";
    pub const IDLE = "idle";
};

// Common HTTP status code ranges
pub const HttpStatusClass = struct {
    pub fn isInformational(code: u16) bool {
        return code >= 100 and code < 200;
    }
    
    pub fn isSuccess(code: u16) bool {
        return code >= 200 and code < 300;
    }
    
    pub fn isRedirection(code: u16) bool {
        return code >= 300 and code < 400;
    }
    
    pub fn isClientError(code: u16) bool {
        return code >= 400 and code < 500;
    }
    
    pub fn isServerError(code: u16) bool {
        return code >= 500 and code < 600;
    }
    
    pub fn isError(code: u16) bool {
        return code >= 400;
    }
};

// Common header names (lowercase as per spec)
pub const CommonHeaders = struct {
    pub const CONTENT_TYPE = "content-type";
    pub const CONTENT_LENGTH = "content-length";
    pub const CONTENT_ENCODING = "content-encoding";
    pub const HOST = "host";
    pub const USER_AGENT = "user-agent";
    pub const ACCEPT = "accept";
    pub const ACCEPT_ENCODING = "accept-encoding";
    pub const ACCEPT_LANGUAGE = "accept-language";
    pub const AUTHORIZATION = "authorization";
    pub const CACHE_CONTROL = "cache-control";
    pub const CONNECTION = "connection";
    pub const COOKIE = "cookie";
    pub const REFERER = "referer";
    pub const X_FORWARDED_FOR = "x-forwarded-for";
    pub const X_FORWARDED_PROTO = "x-forwarded-proto";
    pub const X_FORWARDED_HOST = "x-forwarded-host";
    pub const X_REQUEST_ID = "x-request-id";
    pub const X_CORRELATION_ID = "x-correlation-id";
    pub const X_TRACE_ID = "x-trace-id";
};

// HTTP protocol versions
pub const HttpProtocolVersionValues = struct {
    pub const HTTP_1_0 = "1.0";
    pub const HTTP_1_1 = "1.1";
    pub const HTTP_2_0 = "2.0";
    pub const HTTP_3_0 = "3.0";
    pub const SPDY_1 = "SPDY/1";
    pub const SPDY_2 = "SPDY/2";
    pub const SPDY_3 = "SPDY/3";
    pub const QUIC = "QUIC";
};