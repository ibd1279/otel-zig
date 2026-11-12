//! OpenTelemetry Messaging Semantic Conventions
//!
//! Attributes for messaging / queue / pub-sub instrumentation.
//! Spec: https://github.com/open-telemetry/semantic-conventions/tree/v1.45.0/model/messaging
//!
//! Note: broker-specific attributes moved out of the `messaging.` namespace in
//! semconv v1.44/v1.45 (`messaging.kafka.*` -> `kafka.*`, `messaging.gcp_pubsub.*`
//! -> `gcp.pubsub.*`, `messaging.eventhubs.*`/`messaging.servicebus.*` ->
//! `azure.*`, and `messaging.{rabbitmq,rocketmq}.*` -> those namespaces).

// General attributes

pub const SYSTEM_NAME = "messaging.system.name";
pub const OPERATION_TYPE = "messaging.operation.type";
pub const OPERATION_NAME = "messaging.operation.name";
pub const CLIENT_ID = "messaging.client.id";

pub const SystemName = struct {
    pub const activemq = "activemq";
    pub const @"aws.sns" = "aws.sns";
    pub const @"aws.sqs" = "aws.sqs";
    pub const @"azure.eventgrid" = "azure.eventgrid";
    pub const @"azure.eventhubs" = "azure.eventhubs";
    pub const @"azure.servicebus" = "azure.servicebus";
    pub const @"gcp.pubsub" = "gcp.pubsub";
    pub const jms = "jms";
    pub const kafka = "kafka";
    pub const pulsar = "pulsar";
    pub const rabbitmq = "rabbitmq";
    pub const rocketmq = "rocketmq";
};

pub const OperationType = struct {
    pub const create = "create";
    pub const send = "send";
    pub const receive = "receive";
    pub const process = "process";
    pub const settle = "settle";
    // Note: "deliver" (renamed to "process") and "publish" (renamed to "send") are deprecated — omitted.
};

// Destination

pub const DESTINATION_NAME = "messaging.destination.name";
pub const DESTINATION_SUBSCRIPTION_NAME = "messaging.destination.subscription.name";
pub const DESTINATION_TEMPLATE = "messaging.destination.template";
pub const DESTINATION_ANONYMOUS = "messaging.destination.anonymous";
pub const DESTINATION_TEMPORARY = "messaging.destination.temporary";
pub const DESTINATION_PARTITION_ID = "messaging.destination.partition.id";

// Consumer

pub const CONSUMER_GROUP_NAME = "messaging.consumer.group.name";

// Message

pub const MESSAGE_ID = "messaging.message.id";
pub const MESSAGE_CONVERSATION_ID = "messaging.message.conversation_id";
pub const MESSAGE_ENVELOPE_SIZE = "messaging.message.envelope.size";
pub const MESSAGE_BODY_SIZE = "messaging.message.body.size";

// Batch

pub const BATCH_MESSAGE_COUNT = "messaging.batch.message_count";

// Kafka-specific attributes

pub const KAFKA_MESSAGE_KEY = "kafka.message.key";
pub const KAFKA_OFFSET = "kafka.offset";
pub const KAFKA_MESSAGE_TOMBSTONE = "kafka.message.tombstone";

// RabbitMQ-specific attributes

pub const RABBITMQ_DESTINATION_ROUTING_KEY = "rabbitmq.destination.routing_key";
pub const RABBITMQ_MESSAGE_DELIVERY_TAG = "rabbitmq.message.delivery_tag";

// RocketMQ-specific attributes

pub const ROCKETMQ_NAMESPACE = "rocketmq.namespace";
pub const ROCKETMQ_CONSUMPTION_MODEL = "rocketmq.consumption_model";
pub const ROCKETMQ_MESSAGE_TYPE = "rocketmq.message.type";
pub const ROCKETMQ_MESSAGE_TAG = "rocketmq.message.tag";
pub const ROCKETMQ_MESSAGE_KEYS = "rocketmq.message.keys";
pub const ROCKETMQ_MESSAGE_GROUP = "rocketmq.message.group";
pub const ROCKETMQ_MESSAGE_DELIVERY_TIMESTAMP = "rocketmq.message.delivery_timestamp";
pub const ROCKETMQ_MESSAGE_DELAY_TIME_LEVEL = "rocketmq.message.delay_time_level";

pub const RocketmqConsumptionModel = struct {
    pub const clustering = "clustering";
    pub const broadcasting = "broadcasting";
};

pub const RocketmqMessageType = struct {
    pub const normal = "normal";
    pub const fifo = "fifo";
    pub const delay = "delay";
    pub const transaction = "transaction";
};

// GCP Pub/Sub-specific attributes

pub const GCP_PUBSUB_MESSAGE_ORDERING_KEY = "gcp.pubsub.message.ordering_key";
pub const GCP_PUBSUB_MESSAGE_ACK_ID = "gcp.pubsub.message.ack_id";
pub const GCP_PUBSUB_MESSAGE_ACK_DEADLINE = "gcp.pubsub.message.ack_deadline";
pub const GCP_PUBSUB_MESSAGE_DELIVERY_ATTEMPT = "gcp.pubsub.message.delivery_attempt";

// Azure Service Bus-specific attributes

pub const SERVICEBUS_MESSAGE_DELIVERY_COUNT = "azure.servicebus.message.delivery_count";
pub const SERVICEBUS_MESSAGE_ENQUEUED_TIME = "azure.servicebus.message.enqueued_time";
pub const SERVICEBUS_DISPOSITION_STATUS = "azure.servicebus.disposition_status";

pub const ServicebusDispositionStatus = struct {
    pub const complete = "complete";
    pub const abandon = "abandon";
    pub const dead_letter = "dead_letter";
    pub const @"defer" = "defer";
};

// Azure Event Hubs-specific attributes

pub const EVENTHUBS_MESSAGE_ENQUEUED_TIME = "azure.eventhubs.message.enqueued_time";
