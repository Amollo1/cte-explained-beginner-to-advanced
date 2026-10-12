# Module 11 Exercises

All three exercises use `parts` and `bom`. Always guard a BOM recursion with a path check, and reconcile a cost before trusting it.

| ID | Task | Tables | Self-check | Solution |
|---|---|---|---|---|
| 11-01 | **Explode the Bicycle.** (A) The purchase list: every **raw part** with its **total quantity** (quantities multiplied down the levels, then summed per part). (B) Reconcile: rows in the full explosion, deepest level, raw part types, raw units and total bolts. | `parts`, `bom` | A: 14 rows (Spoke `64`, Bolt `13`). B: `21, 3, 14, 96, 13` | [`11-01.sql`](11-01.sql) |
| 11-02 | **Cost roll-up.** (A) The unit cost of one Bicycle. (B) The rolled-up cost of **every assembly**. (C) Cross-check the Bicycle cost two independent ways, and show the two data-quality counts that make it trustworthy. | `parts`, `bom` | A: `259.30`. B: 6 assemblies (Frame `60.80`, Wheel Assembly `53.00`, Drivetrain `63.50`, Handlebar Assembly `29.00`, Crankset `28.50`). C: `259.30, 259.30, 0, 0` | [`11-02.sql`](11-02.sql) |
| 11-03 | **Where-used.** Trace the **Bolt** (part 17) upwards. (A) Every route up, with the bolts consumed. (B) Per assembly, the bolts in one unit and the number of routes. (C) Show that going up and going down agree on the Bicycle's bolts. | `parts`, `bom` | A: 5 rows. B: 4 assemblies (Bicycle `13` via `2` routes). C: `13, 13, t` | [`11-03.sql`](11-03.sql) |

## Hints

<details>
<summary>11-01</summary>

Anchor on one unit of the top-level part: `SELECT part_id, 0, 1, ARRAY[part_id] FROM parts WHERE part_id = 1`. The recursive step joins `bom` on `b.assembly_id = e.part_id` and carries `e.total_qty * b.qty`. A **raw part** is one that is not the `assembly_id` of any `bom` row (`NOT EXISTS`). After filtering, `GROUP BY` part and `SUM(total_qty)`: the Bolt is reached by two routes.
</details>

<details>
<summary>11-02</summary>

Part A: `SUM(total_qty * unit_cost)` over the raw parts of the explosion. Part B: a closure whose anchor is **every** `bom` line (`SELECT assembly_id, component_id, qty FROM bom`), carrying the root; the recursive step multiplies `c.total_qty * b.qty`. Sum per root, joining `parts` twice (once for the root's name, once for the component's price). Part C's second route: the Bicycle's own components, each at its price (raw parts) or its rolled-up cost (assemblies), multiplied by `qty`: `COALESCE(p.unit_cost, rolled_up.unit_cost)`.
</details>

<details>
<summary>11-03</summary>

Anchor on the lines where `component_id = 17`, keeping the `assembly_id` and the line's `qty`. The recursive step joins the other way: `bom b ON b.component_id = u.assembly_id`, and multiplies `u.bolts * b.qty`. Carry a `path` of ids and refuse to revisit one. For Part B, group by assembly. For Part C, put an explosion (downwards) in the same `WITH RECURSIVE` list and compare the totals.
</details>

## Stretch goals

1. **Explode a sub-assembly.** Change the anchor in 11-01 to the Drivetrain (`part_id = 4`). You should get `6` raw part types and a cost of `63.50`, the same figure as the Drivetrain's rolled-up cost in 11-02 Part B.
2. **Build ten bicycles.** Start the explosion with a quantity of `10` instead of `1`. How many bolts and spokes do you need, and what is the material cost? (Answer: `130` bolts, `640` spokes, `2593.00`.)
3. **See the `UNION` trap.** Inside a transaction, run `INSERT INTO bom VALUES (4, 17, 8);` and compare the Bolt total with `UNION ALL` against `UNION` (answer: `21` against `13`). Then `ROLLBACK;`.
4. **Where is the Hub used?** Adapt 11-03 to trace the Hub (`part_id = 9`) upwards. How many hubs does one Bicycle contain, and why is the answer not the same as the Hub's `qty` in the Wheel Assembly? (Answer: `2` against `1`, because a Bicycle uses two Wheel Assemblies.)
5. **Make the cost fail loudly.** Rewrite the cost query so that it raises an error, instead of returning a low total, when any raw part has no price. (Hint: divide the total by a `CASE` expression that is `1` when the count of unpriced raw parts is `0`, and `0` otherwise. Test it inside a transaction by setting the Hub's price to `NULL`, and expect `division by zero`.)
