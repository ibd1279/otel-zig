//! OpenTelemetry Database Semantic Conventions
//!
//! Attributes for database client instrumentation.
//! Spec: https://github.com/open-telemetry/semantic-conventions/tree/v1.41.0/model/db

// Collection / namespace

pub const COLLECTION_NAME = "db.collection.name";
pub const NAMESPACE = "db.namespace";

// Operation

pub const OPERATION_NAME = "db.operation.name";
pub const OPERATION_BATCH_SIZE = "db.operation.batch.size";
/// Template base — append `.<param-name>` to form the full key.
pub const OPERATION_PARAMETER = "db.operation.parameter";

// Query

pub const QUERY_TEXT = "db.query.text";
pub const QUERY_SUMMARY = "db.query.summary";
/// Template base — append `.<param-name>` to form the full key.
pub const QUERY_PARAMETER = "db.query.parameter";

// Stored procedure

pub const STORED_PROCEDURE_NAME = "db.stored_procedure.name";

// Response

pub const RESPONSE_STATUS_CODE = "db.response.status_code";
pub const RESPONSE_RETURNED_ROWS = "db.response.returned_rows";

// System

pub const SYSTEM_NAME = "db.system.name";

pub const SystemName = struct {
    pub const other_sql = "other_sql";
    pub const @"softwareag.adabas" = "softwareag.adabas";
    pub const @"actian.ingres" = "actian.ingres";
    pub const @"aws.dynamodb" = "aws.dynamodb";
    pub const @"aws.redshift" = "aws.redshift";
    pub const @"azure.cosmosdb" = "azure.cosmosdb";
    pub const @"intersystems.cache" = "intersystems.cache";
    pub const cassandra = "cassandra";
    pub const clickhouse = "clickhouse";
    pub const cockroachdb = "cockroachdb";
    pub const couchbase = "couchbase";
    pub const couchdb = "couchdb";
    pub const derby = "derby";
    pub const elasticsearch = "elasticsearch";
    pub const firebirdsql = "firebirdsql";
    pub const @"gcp.spanner" = "gcp.spanner";
    pub const geode = "geode";
    pub const h2database = "h2database";
    pub const hbase = "hbase";
    pub const hive = "hive";
    pub const hsqldb = "hsqldb";
    pub const @"ibm.db2" = "ibm.db2";
    pub const @"ibm.informix" = "ibm.informix";
    pub const @"ibm.netezza" = "ibm.netezza";
    pub const influxdb = "influxdb";
    pub const instantdb = "instantdb";
    pub const mariadb = "mariadb";
    pub const memcached = "memcached";
    pub const mongodb = "mongodb";
    pub const @"microsoft.sql_server" = "microsoft.sql_server";
    pub const mysql = "mysql";
    pub const neo4j = "neo4j";
    pub const opensearch = "opensearch";
    pub const @"oracle.db" = "oracle.db";
    pub const postgresql = "postgresql";
    pub const redis = "redis";
    pub const @"sap.hana" = "sap.hana";
    pub const @"sap.maxdb" = "sap.maxdb";
    pub const sqlite = "sqlite";
    pub const teradata = "teradata";
    pub const trino = "trino";
};

// Client connection pool

pub const CLIENT_CONNECTION_STATE = "db.client.connection.state";

pub const ClientConnectionState = struct {
    pub const idle = "idle";
    pub const used = "used";
};

pub const CLIENT_CONNECTION_POOL_NAME = "db.client.connection.pool.name";
