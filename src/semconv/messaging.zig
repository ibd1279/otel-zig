//! OpenTelemetry Messaging Semantic Conventions
//!
//! Attributes for messaging / queue / pub-sub instrumentation.
//! Spec: https://github.com/open-telemetry/semantic-conventions/tree/v1.41.0/model/messaging

// General attributes

pub const SYSTEM = "messaging.system";
pub const OPERATION_TYPE = "messaging.operation.type";
pub const OPERATION_NAME = "messaging.operation.name";
pub const CLIENT_ID = "messaging.client.id";

pub const System = struct {
    pub const activemq = "activemq";
    pub const @"aws.sns" = "aws.sns";
    pub const aws_sqs = "aws_sqs";
    pub const eventgrid = "eventgrid";
    pub const eventhubs = "eventhubs";
    pub const servicebus = "servicebus";
    pub const gcp_pubsub = "gcp_pubsub";
    pub const jms = "jms";
    pub const kafka = "kafka";
    pub const rabbitmq = "rabbitmq";
    pub const rocketmq = "rocketmq";
    pub const pulsar = "pulsar";
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

pub const KAFKA_MESSAGE_KEY = "messaging.kafka.message.key";
pub const KAFKA_OFFSET = "messaging.kafka.offset";
pub const KAFKA_MESSAGE_TOMBSTONE = "messaging.kafka.message.tombstone";

// RabbitMQ-specific attributes

pub const RABBITMQ_DESTINATION_ROUTING_KEY = "messaging.rabbitmq.destination.routing_key";
pub const RABBITMQ_MESSAGE_DELIVERY_TAG = "messaging.rabbitmq.message.delivery_tag";

// RocketMQ-specific attributes

pub const ROCKETMQ_NAMESPACE = "messaging.rocketmq.namespace";
pub const ROCKETMQ_CONSUMPTION_MODEL = "messaging.rocketmq.consumption_model";
pub const ROCKETMQ_MESSAGE_TYPE = "messaging.rocketmq.message.type";
pub const ROCKETMQ_MESSAGE_TAG = "messaging.rocketmq.message.tag";
pub const ROCKETMQ_MESSAGE_KEYS = "messaging.rocketmq.message.keys";
pub const ROCKETMQ_MESSAGE_GROUP = "messaging.rocketmq.message.group";
pub const ROCKETMQ_MESSAGE_DELIVERY_TIMESTAMP = "messaging.rocketmq.message.delivery_timestamp";
pub const ROCKETMQ_MESSAGE_DELAY_TIME_LEVEL = "messaging.rocketmq.message.delay_time_level";

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

pub const GCP_PUBSUB_MESSAGE_ORDERING_KEY = "messaging.gcp_pubsub.message.ordering_key";
pub const GCP_PUBSUB_MESSAGE_ACK_ID = "messaging.gcp_pubsub.message.ack_id";
pub const GCP_PUBSUB_MESSAGE_ACK_DEADLINE = "messaging.gcp_pubsub.message.ack_deadline";
pub const GCP_PUBSUB_MESSAGE_DELIVERY_ATTEMPT = "messaging.gcp_pubsub.message.delivery_attempt";

// Azure Service Bus-specific attributes

pub const SERVICEBUS_MESSAGE_DELIVERY_COUNT = "messaging.servicebus.message.delivery_count";
pub const SERVICEBUS_MESSAGE_ENQUEUED_TIME = "messaging.servicebus.message.enqueued_time";
pub const SERVICEBUS_DISPOSITION_STATUS = "messaging.servicebus.disposition_status";

pub const ServicebusDispositionStatus = struct {
    pub const complete = "complete";
    pub const abandon = "abandon";
    pub const dead_letter = "dead_letter";
    pub const @"defer" = "defer";
};

// Azure Event Hubs-specific attributes

pub const EVENTHUBS_MESSAGE_ENQUEUED_TIME = "messaging.eventhubs.message.enqueued_time";
