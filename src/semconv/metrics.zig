//! OpenTelemetry Metrics Semantic Conventions
//!
//! This module defines standard metric names and units according to
//! the OpenTelemetry semantic conventions specification.
//!
//! These conventions ensure consistent naming for metrics across
//! different implementations and languages.
//!
//! See: https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/metrics/semantic_conventions/README.md

// HTTP metrics
pub const HTTP_SERVER_DURATION = "http.server.duration";
pub const HTTP_SERVER_REQUEST_DURATION = "http.server.request.duration";
pub const HTTP_SERVER_REQUEST_SIZE = "http.server.request.size";
pub const HTTP_SERVER_REQUEST_BODY_SIZE = "http.server.request.body.size";
pub const HTTP_SERVER_RESPONSE_SIZE = "http.server.response.size";
pub const HTTP_SERVER_RESPONSE_BODY_SIZE = "http.server.response.body.size";
pub const HTTP_SERVER_ACTIVE_REQUESTS = "http.server.active_requests";
pub const HTTP_CLIENT_DURATION = "http.client.duration";
pub const HTTP_CLIENT_REQUEST_SIZE = "http.client.request.size";
pub const HTTP_CLIENT_RESPONSE_SIZE = "http.client.response.size";

// Database metrics
pub const DB_CLIENT_CONNECTIONS_USAGE = "db.client.connections.usage";
pub const DB_CLIENT_CONNECTIONS_IDLE_MAX = "db.client.connections.idle.max";
pub const DB_CLIENT_CONNECTIONS_IDLE_MIN = "db.client.connections.idle.min";
pub const DB_CLIENT_CONNECTIONS_MAX = "db.client.connections.max";
pub const DB_CLIENT_CONNECTIONS_PENDING_REQUESTS = "db.client.connections.pending_requests";
pub const DB_CLIENT_CONNECTIONS_TIMEOUTS = "db.client.connections.timeouts";
pub const DB_CLIENT_CONNECTIONS_CREATE_TIME = "db.client.connections.create_time";
pub const DB_CLIENT_CONNECTIONS_WAIT_TIME = "db.client.connections.wait_time";
pub const DB_CLIENT_CONNECTIONS_USE_TIME = "db.client.connections.use_time";

// RPC metrics
pub const RPC_SERVER_DURATION = "rpc.server.duration";
pub const RPC_SERVER_REQUEST_SIZE = "rpc.server.request.size";
pub const RPC_SERVER_RESPONSE_SIZE = "rpc.server.response.size";
pub const RPC_SERVER_REQUESTS_PER_RPC = "rpc.server.requests_per_rpc";
pub const RPC_SERVER_RESPONSES_PER_RPC = "rpc.server.responses_per_rpc";
pub const RPC_CLIENT_DURATION = "rpc.client.duration";
pub const RPC_CLIENT_REQUEST_SIZE = "rpc.client.request.size";
pub const RPC_CLIENT_RESPONSE_SIZE = "rpc.client.response.size";
pub const RPC_CLIENT_REQUESTS_PER_RPC = "rpc.client.requests_per_rpc";
pub const RPC_CLIENT_RESPONSES_PER_RPC = "rpc.client.responses_per_rpc";

// System metrics
pub const SYSTEM_CPU_TIME = "system.cpu.time";
pub const SYSTEM_CPU_UTILIZATION = "system.cpu.utilization";
pub const SYSTEM_MEMORY_USAGE = "system.memory.usage";
pub const SYSTEM_MEMORY_UTILIZATION = "system.memory.utilization";
pub const SYSTEM_PAGING_USAGE = "system.paging.usage";
pub const SYSTEM_PAGING_UTILIZATION = "system.paging.utilization";
pub const SYSTEM_PAGING_FAULTS = "system.paging.faults";
pub const SYSTEM_PAGING_OPERATIONS = "system.paging.operations";
pub const SYSTEM_DISK_IO = "system.disk.io";
pub const SYSTEM_DISK_OPERATIONS = "system.disk.operations";
pub const SYSTEM_DISK_TIME = "system.disk.time";
pub const SYSTEM_DISK_MERGED = "system.disk.merged";
pub const SYSTEM_FILESYSTEM_USAGE = "system.filesystem.usage";
pub const SYSTEM_FILESYSTEM_UTILIZATION = "system.filesystem.utilization";
pub const SYSTEM_NETWORK_PACKETS = "system.network.packets";
pub const SYSTEM_NETWORK_DROPPED = "system.network.dropped";
pub const SYSTEM_NETWORK_ERRORS = "system.network.errors";
pub const SYSTEM_NETWORK_IO = "system.network.io";
pub const SYSTEM_NETWORK_CONNECTIONS = "system.network.connections";

// Process metrics
pub const PROCESS_CPU_TIME = "process.cpu.time";
pub const PROCESS_CPU_UTILIZATION = "process.cpu.utilization";
pub const PROCESS_MEMORY_USAGE = "process.memory.usage";
pub const PROCESS_MEMORY_VIRTUAL = "process.memory.virtual";
pub const PROCESS_DISK_IO = "process.disk.io";
pub const PROCESS_NETWORK_IO = "process.network.io";
pub const PROCESS_THREADS = "process.threads";
pub const PROCESS_OPEN_FILE_DESCRIPTORS = "process.open_file_descriptors";
pub const PROCESS_CONTEXT_SWITCHES = "process.context_switches";
pub const PROCESS_PAGING_FAULTS = "process.paging.faults";

// Runtime metrics
pub const RUNTIME_JVM_MEMORY_AREA = "runtime.jvm.memory.area";
pub const RUNTIME_JVM_MEMORY_POOL = "runtime.jvm.memory.pool";
pub const RUNTIME_JVM_MEMORY_INIT = "runtime.jvm.memory.init";
pub const RUNTIME_JVM_MEMORY_USAGE = "runtime.jvm.memory.usage";
pub const RUNTIME_JVM_MEMORY_COMMITTED = "runtime.jvm.memory.committed";
pub const RUNTIME_JVM_MEMORY_LIMIT = "runtime.jvm.memory.limit";
pub const RUNTIME_JVM_MEMORY_USAGE_AFTER_LAST_GC = "runtime.jvm.memory.usage_after_last_gc";
pub const RUNTIME_JVM_GC_DURATION = "runtime.jvm.gc.duration";
pub const RUNTIME_JVM_GC_COUNT = "runtime.jvm.gc.count";
pub const RUNTIME_JVM_THREADS_COUNT = "runtime.jvm.threads.count";
pub const RUNTIME_JVM_CLASSES_LOADED = "runtime.jvm.classes.loaded";
pub const RUNTIME_JVM_CLASSES_UNLOADED = "runtime.jvm.classes.unloaded";
pub const RUNTIME_JVM_CLASSES_CURRENT_LOADED = "runtime.jvm.classes.current_loaded";
pub const RUNTIME_JVM_CPU_TIME = "runtime.jvm.cpu.time";
pub const RUNTIME_JVM_CPU_RECENT_UTILIZATION = "runtime.jvm.cpu.recent_utilization";

// Common units
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
    pub const GIBIBYTES_PER_SECOND = "GiBy/s";
    pub const TEBIBYTES_PER_SECOND = "TiBy/s";
    
    // Frequency
    pub const HERTZ = "Hz";
    pub const KILOHERTZ = "kHz";
    pub const MEGAHERTZ = "MHz";
    pub const GIGAHERTZ = "GHz";
    
    // Percentage
    pub const PERCENT = "%";
    
    // Count
    pub const UNIT = "1";
    
    // Other
    pub const CELSIUS = "Cel";
    pub const REQUESTS = "{requests}";
    pub const ERRORS = "{errors}";
    pub const PACKETS = "{packets}";
    pub const CONNECTIONS = "{connections}";
    pub const MESSAGES = "{messages}";
    pub const OPERATIONS = "{operations}";
    pub const THREADS = "{threads}";
};

// Metric instrument types
pub const InstrumentType = struct {
    pub const COUNTER = "counter";
    pub const UP_DOWN_COUNTER = "updowncounter";
    pub const HISTOGRAM = "histogram";
    pub const GAUGE = "gauge";
    pub const OBSERVABLE_COUNTER = "observable_counter";
    pub const OBSERVABLE_UP_DOWN_COUNTER = "observable_updowncounter";
    pub const OBSERVABLE_GAUGE = "observable_gauge";
};