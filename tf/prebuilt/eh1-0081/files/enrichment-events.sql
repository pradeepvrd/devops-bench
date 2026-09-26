-- Split from enrichment.sql for FlinkSessionJob (livingstacks.flinksql.SqlRunner):
-- one FlinkSessionJob CR tracks exactly one Flink job id, so enrichment.sql's two
-- independent EXECUTE STATEMENT SET blocks (orders x customers, events x products)
-- cannot both run under one CR. This file carries the events x products job only;
-- see enrichment-orders.sql for the other. No SQL semantics changed by the split:
-- the CREATE TABLE / INSERT statements below are unchanged from enrichment.sql,
-- just regrouped by which STATEMENT SET actually reads/writes them. enrichment.sql
-- itself is unchanged and remains what the current Job/sql-client submission path
-- (overlays/gke/flink-sql-submit-enrichment-job.yaml) runs.
SET 'pipeline.name' = '${SYSTEM}-enrichment';
SET 'execution.checkpointing.interval' = '30s';

-- price/total below are DOUBLE, not STRING. cdc's Postgres columns are
-- NUMERIC(10,2) (cdc/manifests/cnpg-cluster.yaml), and Debezium Server is
-- now configured with decimal.handling.mode=double (cdc's
-- debezium-server-application.properties), so NUMERIC columns arrive as
-- plain JSON numbers instead of base64-encoded Kafka Connect Decimal
-- bytes (e.g. the old "total":"AA=="). This is lossy for extreme
-- precision/scale but fine for this shop schema's money columns; see
-- cdc/README.md. See enrichment-orders.sql's header comment for the
-- broader CDC dimension/fact source shape (debezium-json decoding,
-- REPLICA IDENTITY FULL, the earliest-offset migration trap) that also
-- applies to products_cdc below.
CREATE TABLE products_cdc (
  id INT,
  name STRING,
  category STRING,
  price DOUBLE,
  stock INT,
  row_time TIMESTAMP(3) METADATA FROM 'timestamp' VIRTUAL,
  WATERMARK FOR row_time AS row_time - INTERVAL '5' SECOND,
  PRIMARY KEY (id) NOT ENFORCED
) WITH (
  'connector' = 'kafka',
  'topic' = 'cdc.public.products',
  'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP}',
  'properties.group.id' = '${SYSTEM}-flink-sql-enrich-products',
  'scan.startup.mode' = 'latest-offset',
  'format' = 'debezium-json',
  'debezium-json.schema-include' = 'false',
  -- Same idle-timeout reasoning as customers_cdc in enrichment-orders.sql:
  -- products_cdc is the right/versioned side of the events x products
  -- temporal join below.
  'scan.watermark.idle-timeout' = '10s'
);

-- Independent read of events.raw with its own consumer group, separate from
-- the core job.sql's events_raw table (different Flink job/session).
-- row_time (Kafka record timestamp) + watermark gives it the event-time
-- attribute needed for the temporal join below.
CREATE TABLE events_raw (
  event_id STRING,
  event_type STRING,
  event_time STRING,
  user_id STRING,
  session_id STRING,
  product_id STRING,
  category STRING,
  quantity INT,
  unit_price DOUBLE,
  currency STRING,
  row_time TIMESTAMP(3) METADATA FROM 'timestamp' VIRTUAL,
  WATERMARK FOR row_time AS row_time - INTERVAL '5' SECOND
) WITH (
  'connector' = 'kafka',
  'topic' = '${EVENTS_RAW_TOPIC}',
  'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP}',
  'properties.group.id' = '${SYSTEM}-flink-sql-enrich-events-raw',
  'properties.isolation.level' = 'read_committed',
  'scan.startup.mode' = 'latest-offset',
  'format' = 'json',
  'json.ignore-parse-errors' = 'true'
);

-- events.product-enriched: an internal per-event intermediate topic, not
-- one of the two deliverable topics. Splitting the per-event join from the
-- windowed aggregation across a real topic keeps each pipeline simple, and
-- keeps events_raw's watermark (used for the join) independent from
-- events_product_enriched_source's watermark (used for the window).
CREATE TABLE events_product_enriched_sink (
  event_id STRING,
  user_id STRING,
  event_time STRING,
  event_type STRING,
  product_id STRING,
  price DOUBLE,
  stock INT
) WITH (
  'connector' = 'kafka',
  'topic' = '${EVENTS_PRODUCT_ENRICHED_TOPIC}',
  'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP}',
  'format' = 'json'
);

CREATE TABLE events_product_enriched_source (
  event_time STRING,
  event_type STRING,
  product_id STRING,
  price DOUBLE,
  stock INT,
  event_ts AS TO_TIMESTAMP(event_time, 'yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''),
  WATERMARK FOR event_ts AS event_ts - INTERVAL '30' SECOND
) WITH (
  'connector' = 'kafka',
  'topic' = '${EVENTS_PRODUCT_ENRICHED_TOPIC}',
  'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP}',
  'properties.group.id' = '${SYSTEM}-flink-sql-enrich-product-activity',
  'scan.startup.mode' = 'earliest-offset',
  'format' = 'json',
  'json.ignore-parse-errors' = 'true'
);

-- product.activity: 1-minute windowed page_view/add_to_cart counts per
-- product_id, carrying the price/stock that was already resolved per event
-- in events_product_enriched_sink above. price is DOUBLE now (see the note
-- above products_cdc); MAX(price) below is still just "some price seen in
-- the window", not a meaningful numeric max, since price rarely changes
-- within a minute.
CREATE TABLE product_activity (
  window_start TIMESTAMP(3),
  window_end TIMESTAMP(3),
  product_id STRING,
  page_views BIGINT,
  add_to_carts BIGINT,
  price DOUBLE,
  stock INT
) WITH (
  'connector' = 'kafka',
  'topic' = '${PRODUCT_ACTIVITY_TOPIC}',
  'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP}',
  'format' = 'json'
);

-- Job 2: events x products event-time temporal join, then a 1-minute
-- tumbling window over the enriched stream (read back via the real Kafka
-- topic events.product-enriched, see events_product_enriched_sink/source
-- above).
EXECUTE STATEMENT SET
BEGIN

INSERT INTO events_product_enriched_sink
SELECT
  e.event_id,
  e.user_id,
  e.event_time,
  e.event_type,
  e.product_id,
  p.price,
  p.stock
FROM events_raw AS e
LEFT JOIN products_cdc FOR SYSTEM_TIME AS OF e.row_time AS p
ON TRY_CAST(e.product_id AS INT) = p.id;

INSERT INTO product_activity
SELECT
  TUMBLE_START(event_ts, INTERVAL '1' MINUTE) AS window_start,
  TUMBLE_END(event_ts, INTERVAL '1' MINUTE) AS window_end,
  product_id,
  COUNT(CASE WHEN event_type = 'page_view' THEN 1 END) AS page_views,
  COUNT(CASE WHEN event_type = 'add_to_cart' THEN 1 END) AS add_to_carts,
  MAX(price) AS price,
  MAX(stock) AS stock
FROM events_product_enriched_source
GROUP BY TUMBLE(event_ts, INTERVAL '1' MINUTE), product_id;

END;
