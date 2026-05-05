//! OpenTelemetry Log Semantic Conventions
//!
//! Attributes defined in the log namespace.  Cross-cutting attributes
//! (exception.*, code.*, thread.*, http.*, k8s.*, cloud.*, service.*) live
//! in their own modules and are not duplicated here.
//! Spec: https://github.com/open-telemetry/semantic-conventions/tree/v1.41.0/model/log

// Log file attributes

pub const LOG_FILE_NAME = "log.file.name";
pub const LOG_FILE_NAME_RESOLVED = "log.file.name_resolved";
pub const LOG_FILE_PATH = "log.file.path";
pub const LOG_FILE_PATH_RESOLVED = "log.file.path_resolved";

// I/O stream

pub const LOG_IOSTREAM = "log.iostream";

pub const Iostream = struct {
    pub const stdout = "stdout";
    pub const stderr = "stderr";
};

// Log record

pub const LOG_RECORD_UID = "log.record.uid";

// Event

pub const EVENT_NAME = "event.name";
