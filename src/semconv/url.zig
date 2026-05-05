//! OpenTelemetry URL Semantic Conventions
//!
//! Attribute names for URL components. Used across HTTP, RPC, database,
//! and any other signal that references a network resource by URL.
//! Spec: semantic-conventions/model/url/registry.yaml (v1.41.0)

// Stable

pub const FULL = "url.full";
pub const PATH = "url.path";
pub const QUERY = "url.query";
pub const SCHEME = "url.scheme";
pub const FRAGMENT = "url.fragment";

// Development

pub const DOMAIN = "url.domain";
pub const EXTENSION = "url.extension";
pub const ORIGINAL = "url.original";
pub const PORT = "url.port";
pub const REGISTERED_DOMAIN = "url.registered_domain";
pub const SUBDOMAIN = "url.subdomain";
pub const TEMPLATE = "url.template";
pub const TOP_LEVEL_DOMAIN = "url.top_level_domain";
