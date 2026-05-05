//! OpenTelemetry Resource Semantic Conventions
//!
//! Standard resource attribute names drawn from multiple sub-namespaces
//! (service, telemetry, process, host, os, container, k8s, cloud, device, deployment).
//! Spec: https://github.com/open-telemetry/semantic-conventions/tree/v1.41.0/model

// Service

pub const SERVICE_NAME = "service.name";
pub const SERVICE_VERSION = "service.version";
pub const SERVICE_NAMESPACE = "service.namespace";
pub const SERVICE_INSTANCE_ID = "service.instance.id";

// Telemetry SDK

pub const TELEMETRY_SDK_NAME = "telemetry.sdk.name";
pub const TELEMETRY_SDK_LANGUAGE = "telemetry.sdk.language";
pub const TELEMETRY_SDK_VERSION = "telemetry.sdk.version";
pub const TELEMETRY_DISTRO_NAME = "telemetry.distro.name";
pub const TELEMETRY_DISTRO_VERSION = "telemetry.distro.version";

pub const TelemetrySdkLanguage = struct {
    pub const cpp = "cpp";
    pub const dotnet = "dotnet";
    pub const erlang = "erlang";
    pub const go = "go";
    pub const java = "java";
    pub const nodejs = "nodejs";
    pub const php = "php";
    pub const python = "python";
    pub const ruby = "ruby";
    pub const rust = "rust";
    pub const swift = "swift";
    pub const webjs = "webjs";
    /// Not yet in the upstream spec — added here as a local extension.
    pub const zig = "zig";
};

// Process

pub const PROCESS_PID = "process.pid";
pub const PROCESS_PARENT_PID = "process.parent_pid";
pub const PROCESS_EXECUTABLE_NAME = "process.executable.name";
pub const PROCESS_EXECUTABLE_PATH = "process.executable.path";
pub const PROCESS_COMMAND = "process.command";
pub const PROCESS_COMMAND_LINE = "process.command_line";
pub const PROCESS_COMMAND_ARGS = "process.command_args";
pub const PROCESS_OWNER = "process.owner";
pub const PROCESS_RUNTIME_NAME = "process.runtime.name";
pub const PROCESS_RUNTIME_VERSION = "process.runtime.version";
pub const PROCESS_RUNTIME_DESCRIPTION = "process.runtime.description";

// Host

pub const HOST_ID = "host.id";
pub const HOST_NAME = "host.name";
pub const HOST_TYPE = "host.type";
pub const HOST_ARCH = "host.arch";
pub const HOST_IMAGE_NAME = "host.image.name";
pub const HOST_IMAGE_ID = "host.image.id";
pub const HOST_IMAGE_VERSION = "host.image.version";

pub const HostArch = struct {
    pub const amd64 = "amd64";
    pub const arm32 = "arm32";
    pub const arm64 = "arm64";
    pub const ia64 = "ia64";
    pub const ppc32 = "ppc32";
    pub const ppc64 = "ppc64";
    pub const s390x = "s390x";
    pub const x86 = "x86";
};

// Operating system

pub const OS_TYPE = "os.type";
pub const OS_DESCRIPTION = "os.description";
pub const OS_NAME = "os.name";
pub const OS_VERSION = "os.version";
pub const OS_BUILD_ID = "os.build_id";

pub const OsType = struct {
    pub const windows = "windows";
    pub const linux = "linux";
    pub const darwin = "darwin";
    pub const freebsd = "freebsd";
    pub const netbsd = "netbsd";
    pub const openbsd = "openbsd";
    pub const dragonflybsd = "dragonflybsd";
    pub const hpux = "hpux";
    pub const aix = "aix";
    pub const solaris = "solaris";
    pub const zos = "zos";
};

// Container

pub const CONTAINER_NAME = "container.name";
pub const CONTAINER_ID = "container.id";
pub const CONTAINER_RUNTIME_NAME = "container.runtime.name";
pub const CONTAINER_RUNTIME_VERSION = "container.runtime.version";
pub const CONTAINER_IMAGE_NAME = "container.image.name";
pub const CONTAINER_IMAGE_TAGS = "container.image.tags";
pub const CONTAINER_IMAGE_ID = "container.image.id";

// Kubernetes

pub const K8S_CLUSTER_NAME = "k8s.cluster.name";
pub const K8S_CLUSTER_UID = "k8s.cluster.uid";
pub const K8S_NODE_NAME = "k8s.node.name";
pub const K8S_NODE_UID = "k8s.node.uid";
pub const K8S_NAMESPACE_NAME = "k8s.namespace.name";
pub const K8S_POD_UID = "k8s.pod.uid";
pub const K8S_POD_NAME = "k8s.pod.name";
pub const K8S_CONTAINER_NAME = "k8s.container.name";
pub const K8S_CONTAINER_RESTART_COUNT = "k8s.container.restart_count";
pub const K8S_REPLICASET_UID = "k8s.replicaset.uid";
pub const K8S_REPLICASET_NAME = "k8s.replicaset.name";
pub const K8S_DEPLOYMENT_UID = "k8s.deployment.uid";
pub const K8S_DEPLOYMENT_NAME = "k8s.deployment.name";
pub const K8S_STATEFULSET_UID = "k8s.statefulset.uid";
pub const K8S_STATEFULSET_NAME = "k8s.statefulset.name";
pub const K8S_DAEMONSET_UID = "k8s.daemonset.uid";
pub const K8S_DAEMONSET_NAME = "k8s.daemonset.name";
pub const K8S_JOB_UID = "k8s.job.uid";
pub const K8S_JOB_NAME = "k8s.job.name";
pub const K8S_CRONJOB_UID = "k8s.cronjob.uid";
pub const K8S_CRONJOB_NAME = "k8s.cronjob.name";

// Cloud

pub const CLOUD_PROVIDER = "cloud.provider";
pub const CLOUD_ACCOUNT_ID = "cloud.account.id";
pub const CLOUD_REGION = "cloud.region";
pub const CLOUD_AVAILABILITY_ZONE = "cloud.availability_zone";
pub const CLOUD_PLATFORM = "cloud.platform";
pub const CLOUD_RESOURCE_ID = "cloud.resource_id";

pub const CloudProvider = struct {
    pub const akamai_cloud = "akamai_cloud";
    pub const alibaba_cloud = "alibaba_cloud";
    pub const aws = "aws";
    pub const azure = "azure";
    pub const gcp = "gcp";
    pub const heroku = "heroku";
    pub const hetzner = "hetzner";
    pub const ibm_cloud = "ibm_cloud";
    pub const oracle_cloud = "oracle_cloud";
    pub const tencent_cloud = "tencent_cloud";
    pub const vultr = "vultr";
};

// Device

pub const DEVICE_ID = "device.id";
pub const DEVICE_MANUFACTURER = "device.manufacturer";
pub const DEVICE_MODEL_IDENTIFIER = "device.model.identifier";
pub const DEVICE_MODEL_NAME = "device.model.name";

// Deployment

pub const DEPLOYMENT_ENVIRONMENT_NAME = "deployment.environment.name";
pub const DEPLOYMENT_NAME = "deployment.name";
pub const DEPLOYMENT_ID = "deployment.id";

pub const DeploymentEnvironmentName = struct {
    pub const production = "production";
    pub const staging = "staging";
    pub const @"test" = "test";
    pub const development = "development";
};
