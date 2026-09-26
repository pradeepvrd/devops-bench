-- Split from enrichment.sql for FlinkSessionJob (livingstacks.flinksql.SqlRunner):
-- one FlinkSessionJob CR tracks exactly one Flink job id, so enrichment.sql's two
-- independent EXECUTE STATEMENT SET blocks (orders x customers, events x products)
-- cannot both run under one CR. This file carries the orders x customers job only;
-- see enrichment-events.sql for the other. No SQL semantics changed by the split:
-- the CREATE TABLE / INSERT statements below are unchanged from enrichment.sql,
-- just regrouped by which STATEMENT SET actually reads/writes them. enrichment.sql
-- itself is unchanged and remains what the current Job/sql-client submission path
-- (base/flink-sql-submit-job.yaml's sibling, overlays/gke/flink-sql-submit-enrichment-job.yaml)
-- runs.
SET 'pipeline.name' = '${SYSTEM}-enrichment';
SET 'execution.checkpointing.interval' = '30s';

-- CDC dimension/fact sources: debezium-json changelog format, decoded from
-- the same envelope shape the cdc stack's Debezium Server writes (before/
-- after/op fields, see cdc/README.md "CDC event shape"). cdc's Debezium
-- Server runs with debezium.format.value.schemas.enable=false (cdc's
-- debezium-server-application.properties), so messages are bare payload
-- objects with no "schema"/"payload" wrapper: debezium-json.schema-include
-- must be false to match (schema-include=true expects that wrapper and
-- throws a NullPointerException trying to read a nonexistent "payload"
-- field on these messages; this was previously masked entirely by
-- 'debezium-json.ignore-parse-errors' = 'true' silently dropping every
-- single CDC message, not just the updates it was nominally there for).
-- A PRIMARY KEY turns each into a versioned table
-- usable on the right side of a FOR SYSTEM_TIME AS OF temporal join.
-- row_time (the Kafka record's own timestamp) plus a watermark gives each
-- table a genuine event-time attribute: Flink 1.20 only supports
-- event-time temporal joins against PRIMARY KEY'd changelog/CDC-sourced
-- tables, not processing-time ones (FOR SYSTEM_TIME AS OF PROCTIME()/a
-- proc_time column fails to compile at all with "Processing-time temporal
-- join is not supported yet.").
-- cdc's Postgres tables now use REPLICA IDENTITY FULL (see
-- cdc/manifests/cnpg-cluster.yaml), so Debezium sends a full old-row image
-- on every UPDATE and Flink's debezium-json format can build the
-- UPDATE_BEFORE/UPDATE_AFTER changelog pair correctly: no more
-- 'debezium-json.ignore-parse-errors' needed for that reason, and it has
-- been removed here so a genuine future decode problem fails loud instead
-- of being silently swallowed.
--
-- MIGRATION TRAP: the cdc.public.* topics still retain messages produced
-- before REPLICA IDENTITY FULL and decimal.handling.mode=double were set
-- (before:null updates, and total/price as base64-encoded Kafka Connect
-- Decimal strings), and, further back, messages produced before Debezium
-- Server's schemas.enable=false setting took effect (a {schema, payload}
-- wrapper instead of today's flat envelope: customers.id=1's original seed
-- row is one such message). A strict parser reading 'earliest-offset'
-- would crash on that backlog immediately, on any of the cdc source
-- tables below, including customers_cdc (no NUMERIC column and no
-- historical UPDATE on that table changes the fact that its oldest seed
-- messages predate the flat-envelope switch). 'scan.startup.mode' =
-- 'latest-offset' is used on both: the job only reads messages
-- produced after the migration, so it never encounters the old shapes.
-- Documented in streaming/README.md. Trade-off: rows written before this
-- job's (re)submission and not touched again afterward will never appear
-- in orders.enriched, since the job never reads their INSERT event; this
-- is acceptable for a self-driving demo pipeline with continuous traffic.
CREATE TABLE customers_cdc (
  id INT,
  name STRING,
  email STRING,
  tier STRING,
  created_at STRING,
  row_time TIMESTAMP(3) METADATA FROM 'timestamp' VIRTUAL,
  WATERMARK FOR row_time AS row_time - INTERVAL '5' SECOND,
  PRIMARY KEY (id) NOT ENFORCED
) WITH (
  'connector' = 'kafka',
  'topic' = 'cdc.public.customers',
  'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP}',
  'properties.group.id' = '${SYSTEM}-flink-sql-enrich-customers',
  'scan.startup.mode' = 'latest-offset',
  'format' = 'debezium-json',
  'debezium-json.schema-include' = 'false',
  -- customers_cdc is the right/versioned side of an event-time temporal
  -- join below. Once it catches up on its backlog it goes quiet (customers
  -- are rarely updated), and without idle-timeout its stalled watermark
  -- would block the join's watermark from ever advancing past it, wedging
  -- orders_enriched_sink forever even though both jobs stay RUNNING with
  -- no errors. This tells Flink to stop waiting on this source once it's
  -- been quiet for 10s.
  'scan.watermark.idle-timeout' = '10s'
);

CREATE TABLE orders_cdc (
  id INT,
  customer_id INT,
  status STRING,
  total DOUBLE,
  created_at STRING,
  updated_at STRING,
  row_time TIMESTAMP(3) METADATA FROM 'timestamp' VIRTUAL,
  WATERMARK FOR row_time AS row_time - INTERVAL '5' SECOND,
  PRIMARY KEY (id) NOT ENFORCED
) WITH (
  'connector' = 'kafka',
  'topic' = 'cdc.public.orders',
  'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP}',
  'properties.group.id' = '${SYSTEM}-flink-sql-enrich-orders',
  'scan.startup.mode' = 'latest-offset',
  'format' = 'debezium-json',
  'debezium-json.schema-include' = 'false'
);

-- orders.enriched: each CDC order joined with its customer via an
-- event-time temporal join. Scope reduction: order_items/products are NOT
-- joined in here (a third changelog join plus a per-order line-item
-- aggregation added meaningfully more complexity for a first cut), so
-- orders x customers is the minimum viable join actually shipped.
-- upsert-kafka because the join output is a changelog (orders_cdc carries
-- inserts, status updates, and deletes), not an append-only stream.
CREATE TABLE orders_enriched_sink (
  order_id INT,
  customer_id INT,
  customer_name STRING,
  customer_tier STRING,
  status STRING,
  total DOUBLE,
  created_at STRING,
  updated_at STRING,
  PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
  'connector' = 'upsert-kafka',
  'topic' = '${ORDERS_ENRICHED_TOPIC}',
  'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP}',
  'key.format' = 'json',
  'value.format' = 'json'
);

-- Re-read our own sink topic as a plain append log (ignoring upsert-kafka's
-- key-based semantics) so the filesystem connector below, which cannot
-- consume update/delete changelog rows, has an insert-only stream to
-- archive.
CREATE TABLE orders_enriched_archive_source (
  order_id INT,
  customer_id INT,
  customer_name STRING,
  customer_tier STRING,
  status STRING,
  total DOUBLE,
  created_at STRING,
  updated_at STRING
) WITH (
  'connector' = 'kafka',
  'topic' = '${ORDERS_ENRICHED_TOPIC}',
  'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP}',
  'properties.group.id' = '${SYSTEM}-flink-sql-enrich-archive',
  'scan.startup.mode' = 'earliest-offset',
  'format' = 'json',
  'json.ignore-parse-errors' = 'true'
);

CREATE TABLE orders_enriched_archive (
  order_id INT,
  customer_id INT,
  customer_name STRING,
  customer_tier STRING,
  status STRING,
  total DOUBLE,
  created_at STRING,
  updated_at STRING,
  dt STRING,
  `hour` STRING
) PARTITIONED BY (dt, `hour`) WITH (
  'connector' = 'filesystem',
  'path' = '${GCS_ENRICHED_PATH}',
  'format' = 'json',
  'sink.partition-commit.policy.kind' = 'success-file',
  'sink.partition-commit.trigger' = 'process-time',
  'sink.partition-commit.delay' = '0s',
  'sink.rolling-policy.rollover-interval' = '2min',
  'sink.rolling-policy.check-interval' = '30s'
);

-- Job 1: orders x customers event-time temporal join, plus the plain
-- archival re-read of its own output (no join, no window). Both grouped in
-- one STATEMENT SET since neither is related to the product/activity
-- pipeline (see enrichment-events.sql).
EXECUTE STATEMENT SET
BEGIN

INSERT INTO orders_enriched_sink
SELECT
  o.id AS order_id,
  o.customer_id,
  c.name AS customer_name,
  c.tier AS customer_tier,
  o.status,
  o.total,
  o.created_at,
  o.updated_at
FROM orders_cdc AS o
LEFT JOIN customers_cdc FOR SYSTEM_TIME AS OF o.row_time AS c
ON o.customer_id = c.id;

-- created_at is a Postgres ISO-8601 timestamp string (e.g.
-- "2026-08-31T01:15:00.123456Z"), a different shape than Flink's
-- TIMESTAMP(3) string cast expects (space separator, no trailing Z,
-- max 3 fractional digits); TRY_CAST after normalizing the separator/suffix
-- is attempted, COALESCE falls back to CURRENT_TIMESTAMP for partitioning
-- safety, matching the pattern in overlays/gke/sql/job.sql.
INSERT INTO orders_enriched_archive
SELECT
  order_id, customer_id, customer_name, customer_tier, status, total, created_at, updated_at,
  DATE_FORMAT(COALESCE(TRY_CAST(REPLACE(REPLACE(created_at, 'T', ' '), 'Z', '') AS TIMESTAMP(3)), CURRENT_TIMESTAMP), 'yyyy-MM-dd') AS dt,
  DATE_FORMAT(COALESCE(TRY_CAST(REPLACE(REPLACE(created_at, 'T', ' '), 'Z', '') AS TIMESTAMP(3)), CURRENT_TIMESTAMP), 'HH') AS `hour`
FROM orders_enriched_archive_source;

END;
