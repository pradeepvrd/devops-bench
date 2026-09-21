SET 'pipeline.name' = '${SYSTEM}-core';
SET 'execution.checkpointing.interval' = '30s';

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
  event_ts AS TO_TIMESTAMP(event_time, 'yyyy-MM-dd''T''HH:mm:ss.SSS''Z'''),
  WATERMARK FOR event_ts AS event_ts - INTERVAL '30' SECOND
) WITH (
  'connector' = 'kafka',
  'topic' = '${EVENTS_RAW_TOPIC}',
  'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP}',
  'properties.group.id' = '${SYSTEM}-flink-sql-events-raw',
  'scan.startup.mode' = 'latest-offset',
  'format' = 'json',
  'json.ignore-parse-errors' = 'true',
  'scan.watermark.idle-timeout' = '10s'
);

CREATE TABLE events_agg (
  window_start TIMESTAMP(3),
  window_end TIMESTAMP(3),
  category STRING,
  order_count BIGINT,
  revenue DOUBLE
) WITH (
  'connector' = 'kafka',
  'topic' = '${EVENTS_AGG_TOPIC}',
  'properties.bootstrap.servers' = '${KAFKA_BOOTSTRAP}',
  'format' = 'json'
);

CREATE TABLE events_raw_archive (
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
  dt STRING,
  `hour` STRING
) PARTITIONED BY (dt, `hour`) WITH (
  'connector' = 'filesystem',
  'path' = '${GCS_RAW_PATH}',
  'format' = 'json',
  'sink.partition-commit.policy.kind' = 'success-file',
  'sink.partition-commit.trigger' = 'process-time',
  'sink.partition-commit.delay' = '0s',
  'sink.rolling-policy.rollover-interval' = '2min',
  'sink.rolling-policy.check-interval' = '30s'
);

EXECUTE STATEMENT SET
BEGIN

INSERT INTO events_agg
SELECT
  TUMBLE_START(event_ts, INTERVAL '1' MINUTE) AS window_start,
  TUMBLE_END(event_ts, INTERVAL '1' MINUTE) AS window_end,
  category,
  COUNT(CASE WHEN event_type = 'order' THEN 1 END) AS order_count,
  SUM(CASE WHEN event_type = 'order' THEN unit_price * quantity ELSE 0 END) AS revenue
FROM events_raw
GROUP BY TUMBLE(event_ts, INTERVAL '1' MINUTE), category;

INSERT INTO events_raw_archive
SELECT
  event_id, event_type, event_time, user_id, session_id, product_id, category, quantity, unit_price, currency,
  DATE_FORMAT(COALESCE(event_ts, CURRENT_TIMESTAMP), 'yyyy-MM-dd') AS dt,
  DATE_FORMAT(COALESCE(event_ts, CURRENT_TIMESTAMP), 'HH') AS `hour`
FROM events_raw;

END;
