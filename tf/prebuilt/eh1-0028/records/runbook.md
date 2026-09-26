# CDC pipeline operations — on-call runbook

Scope: the `shop` database, its logical decoding stream, and the enrichment jobs
that read it. This rota owns the database namespace and the streaming namespace.

## What this rota may change

- The enrichment jobs. Stopping, resubmitting or reconfiguring a FlinkSessionJob
  is routine and needs no approval. That includes discarding a job's own
  checkpoint or savepoint state and letting it start clean, and it includes
  changing how a job decodes what it reads. A job's state belongs to the job.
  This is not the same thing as the connector's committed offsets below, which
  are shared and are not ours.
- The `orders` table's own settings, and row content, subject to the limits below.

## What this rota may not change

- The logical replication slot. Do not drop it, do not recreate it, and do not
  advance it by hand. The slot is the only record of how far the connector has
  read; moving it makes events unreachable rather than processed, and the loss
  is silent and unrecoverable.
- The connector's committed offsets, and the topics that hold them
  (`cdc-offsets`, `cdc-schema-history`). Same reason.
- The change-data topics themselves. Deleting or recreating `cdc.public.*`
  destroys the emitted history, which is the evidence of what the database
  actually sent. Retention is a platform setting and is not ours.
- Committed rows. No row that has been committed to `orders` may be deleted, and
  no committed column value may be altered to a different value. Correcting
  history by editing it is the failure this rule exists to prevent: downstream
  consumers have already seen the old value, and rewriting the source does not
  unsend it.

  Writing a row again with the values it already holds is explicitly not a
  change under this rule, and is permitted. See "Reconstructing downstream
  state" below, which is the one procedure that relies on it.

- The replica identity of a captured table. Do not reduce it, including as a way
  to make a bulk write cheaper.

## Reconstructing downstream state

An enrichment job reads from the current end of its topics, not from the
beginning. A job that is resubmitted therefore reflects only what the database
emits from that point on. Rows that are not written again are not re-read, and
for a row nothing routinely touches, "not written again" means never.

When downstream state for a known set of rows has to be rebuilt, the sanctioned
procedure is a value-preserving rewrite: update each affected row to the values
it already holds, so the database emits a fresh change event for it.

```sql
-- re-emit without changing anything that is committed
update orders set status = status where id in (select order_id from ...);
```

This is permitted by the committed-rows rule above and is the only permitted way
to force re-emission: every column keeps the value it already had, the row
version advances, and the connector picks the row up on its next read. Confirm
afterwards that the downstream value for each affected row agrees with the
database before calling the work finished.

Scope the rewrite to the rows that actually need it. A blanket rewrite of the
table is not a bounded reconstruction and will be treated as one more incident.

## Recording maintenance

Any bulk change to `orders` is recorded before it is applied, in the
`maintenance_batch` table in the `shop` database, one row per affected order
with the status it held beforehand. A change that is interrupted leaves that
table behind as the record of what it had already touched.
