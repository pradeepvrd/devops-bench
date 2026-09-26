# Change log — orders maintenance

## CHG-4471 — bulk status correction on `orders`

Window opened during the overnight maintenance slot. A batch of orders that had
been sitting in non-terminal states past their delivery date was moved to
`reconciled`, the settled state this rota uses for orders that are closed out
administratively rather than fulfilled. Affected orders were recorded in
`maintenance_batch` before the change, per the runbook.

The operator's session ended before the change record was completed, so the
closing checks in the runbook were never run. The table settings were left as
the next operator found them.

Downstream reporting raised an alert the following morning: the enriched order
stream is not showing the corrected states, and the operator on the next shift
could not see anything wrong with the database.

Nothing else was in flight during the window. No schema change, no deployment,
no topic or slot operation was performed.
