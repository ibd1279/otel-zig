//! OpenTelemetry MCP (Model Context Protocol) Semantic Conventions
//!
//! Attribute names and known values for MCP instrumentation.
//! Spec: https://github.com/open-telemetry/semantic-conventions-genai (pegged to semconv v1.41.0)

// Method

pub const METHOD_NAME = "mcp.method.name";

/// Known MCP method names.  Values containing `/` or mixed-case use quoted identifiers.
pub const MethodName = struct {
    pub const initialize = "initialize";
    pub const ping = "ping";

    pub const @"notifications/cancelled" = "notifications/cancelled";
    pub const @"notifications/initialized" = "notifications/initialized";
    pub const @"notifications/message" = "notifications/message";
    pub const @"notifications/progress" = "notifications/progress";
    pub const @"notifications/prompts/list_changed" = "notifications/prompts/list_changed";
    pub const @"notifications/resources/list_changed" = "notifications/resources/list_changed";
    pub const @"notifications/resources/updated" = "notifications/resources/updated";
    pub const @"notifications/roots/list_changed" = "notifications/roots/list_changed";
    pub const @"notifications/tools/list_changed" = "notifications/tools/list_changed";

    pub const @"completion/complete" = "completion/complete";
    pub const @"elicitation/create" = "elicitation/create";
    pub const @"logging/setLevel" = "logging/setLevel";
    pub const @"prompts/get" = "prompts/get";
    pub const @"prompts/list" = "prompts/list";
    pub const @"resources/list" = "resources/list";
    pub const @"resources/read" = "resources/read";
    pub const @"resources/subscribe" = "resources/subscribe";
    pub const @"resources/templates/list" = "resources/templates/list";
    pub const @"resources/unsubscribe" = "resources/unsubscribe";
    pub const @"roots/list" = "roots/list";
    pub const @"sampling/createMessage" = "sampling/createMessage";
    pub const @"tools/call" = "tools/call";
    pub const @"tools/list" = "tools/list";
};

// Session

pub const SESSION_ID = "mcp.session.id";

// Resource

pub const RESOURCE_URI = "mcp.resource.uri";

// Protocol

pub const PROTOCOL_VERSION = "mcp.protocol.version";

// Metrics

pub const CLIENT_OPERATION_DURATION = "mcp.client.operation.duration";
pub const SERVER_OPERATION_DURATION = "mcp.server.operation.duration";
pub const CLIENT_SESSION_DURATION = "mcp.client.session.duration";
pub const SERVER_SESSION_DURATION = "mcp.server.session.duration";
