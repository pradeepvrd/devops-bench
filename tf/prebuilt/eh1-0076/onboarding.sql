\set ON_ERROR_STOP on
-- Orders CDC onboarding for eh1-0076: establishes the
-- debezium logical replication slot on shop-1 and creates cdc_probe.

-- 1. Release any slot the scene's pre-rollout connector already claimed.
--
-- module.scene_cdc starts debezium-server before this job runs, and it claims
-- the same slot name and reconnects every 3-5s forever
-- (errors.max.retries=-1). The connector is therefore scaled to zero by
-- kubectl_manifest.connector_quiesce before this job starts, so nothing can
-- reconnect while we work; connector.tf scales it back afterwards with the
-- task's real configuration.
--
-- Note we do NOT fence with ALTER ROLE debezium NOLOGIN the way eh1-0012's
-- violator does: debezium is a CNPG *managed* role (managed.roles[].login =
-- true on Cluster/shop), so the operator's role reconciler would race us to
-- undo it. Quiescing the Deployment is the fence CNPG does not own.
--
-- pg_terminate_backend only *requests* termination, so a drop issued in the
-- same breath still observes the slot as active -- that is the failure this
-- loop exists to prevent. pg_replication_slots reads shared memory rather
-- than an MVCC snapshot, so the loop sees fresh state on each iteration.
DO $$
DECLARE
  deadline timestamptz := clock_timestamp() + interval '60 seconds';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'debezium') THEN
    RETURN;
  END IF;

  LOOP
    PERFORM pg_terminate_backend(active_pid) FROM pg_replication_slots
      WHERE slot_name = 'debezium' AND active_pid IS NOT NULL;

    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM pg_replication_slots
      WHERE slot_name = 'debezium' AND active_pid IS NOT NULL
    );

    IF clock_timestamp() > deadline THEN
      RAISE EXCEPTION
        'replication slot "debezium" still active after 60s; connector was expected to be quiesced';
    END IF;

    PERFORM pg_sleep(1);
  END LOOP;

  PERFORM pg_drop_replication_slot('debezium');
END $$;

-- 2. Create the debezium logical replication slot. The cluster runs a single
-- instance for this task, so there is no standby and no failover path; the
-- failover flag is left false deliberately rather than carried over.
SELECT pg_create_logical_replication_slot('debezium', 'pgoutput', false, false, false);

-- 3. Create the cdc_probe role used by the verifier.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cdc_probe') THEN
    CREATE ROLE cdc_probe LOGIN;
  END IF;
END $$;

-- Set outside the block above: psql does not substitute variables inside a
-- dollar-quoted string.
ALTER ROLE cdc_probe WITH LOGIN PASSWORD :'probe_password';

GRANT CONNECT ON DATABASE shop TO cdc_probe;
GRANT USAGE ON SCHEMA public TO cdc_probe;
GRANT SELECT, INSERT ON public.customers TO cdc_probe;
GRANT SELECT, INSERT ON public.orders TO cdc_probe;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO cdc_probe;

-- 4. Seed initial baseline customers and orders so CDC starts with active history.
INSERT INTO public.customers (name, email, tier)
VALUES
  ('Baseline Customer Alpha', 'alpha@orders.example', 'gold'),
  ('Baseline Customer Beta', 'beta@orders.example', 'standard')
ON CONFLICT (email) DO NOTHING;

INSERT INTO public.orders (customer_id, status, total)
SELECT c.id, 'completed', 29.99
FROM public.customers c
WHERE c.email = 'alpha@orders.example'
LIMIT 1;
