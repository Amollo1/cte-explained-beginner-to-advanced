# Module 9: Hierarchies: Org Charts & Category Trees

**Level:** Advanced  |  **Time:** about 3 hours  |  **Files:** [`examples.sql`](examples.sql) · [`exercises.md`](exercises.md)

## Learning objectives

By the end of this module you can:

- traverse any parent-child table from the top down, and from a node upward,
- carry **depth**, **text paths** and **path arrays** through a recursion,
- list a subtree, and count direct and indirect reports for every manager at once,
- build breadcrumbs and **roll up** a measure through a category tree,
- output a tree in outline order with indentation,
- check a hierarchy for problems, and know which traversals can loop forever.

---

## 9.1 Hierarchies in a table

A hierarchy is stored as a **parent-child table** (an *adjacency list*): each row holds its own id and a pointer to its parent. This course has two:

| Table | Pointer | Root | Levels |
|---|---|---|---|
| `employees` | `manager_id` points to `emp_id` | the CEO (`manager_id IS NULL`) | 5 |
| `categories` | `parent_id` points to `category_id` | Electronics and Office (`parent_id IS NULL`) | 3 |

Vocabulary used throughout:

| Term | Meaning |
|---|---|
| **root** | a row with no parent |
| **parent / child** | one step up / one step down |
| **ancestors / descendants** | all rows above / below, at any distance |
| **leaf** | a row with no children |
| **depth (level)** | steps from the root, counting the root as level 1 |
| **subtree** | a row and all of its descendants |

**Why recursion?** With a fixed number of levels you could join the table to itself that many times. But a self-join per level breaks the moment the organisation gains a level, and you rarely know the depth in advance. A recursive CTE follows the pointers for as many rounds as the data needs (Module 8).

## 9.2 The top-down template

Almost every hierarchy query starts from this shape:

```sql
WITH RECURSIVE org(emp_id, first_name, last_name, job_title, depth, path_ids, chain) AS (
    SELECT emp_id, first_name, last_name, job_title,
           1,                              -- the root is level 1
           ARRAY[emp_id],                  -- path of ids from the root, used for ordering
           first_name::text                -- path of names from the root, used for display
    FROM employees
    WHERE manager_id IS NULL               -- anchor: the root (nobody above them)
    UNION ALL
    SELECT e.emp_id, e.first_name, e.last_name, e.job_title,
           o.depth + 1,
           o.path_ids || e.emp_id,
           o.chain || ' > ' || e.first_name
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id  -- recursive member: the people who report to the previous round
)
SELECT depth, emp_id, first_name || ' ' || last_name AS employee, job_title
FROM org
ORDER BY depth, emp_id
LIMIT 8;
```

```
 depth | emp_id |   employee    |      job_title
-------+--------+---------------+---------------------
     1 |      1 | Amina Hassan  | CEO
     2 |      2 | Brian Otieno  | VP Engineering
     2 |      3 | Carla Mendes  | VP Sales
     2 |      4 | David Kimani  | VP Finance
     2 |      5 | Elena Petrova | VP HR
     2 |      6 | Farid Rahman  | VP Data & Analytics
     3 |      7 | Grace Wanjiru | Engineering Manager
     3 |      8 | Hassan Ali    | Engineering Manager
```

The join condition is the whole trick: **`child.parent_pointer = current_row.id`**. Round by round: the CEO; then everyone whose `manager_id` is the CEO's id; then everyone whose `manager_id` is one of *those* people; and so on.

### Always reconcile: did it reach everyone?

```
 depth | people                          employees_reached | employees_total | max_depth
-------+--------                        -------------------+-----------------+-----------
     1 |      1                                          30 |              30 |         5
     2 |      5
     3 |      7
     4 |     16
     5 |      1
```

30 reached out of 30, with a maximum depth of 5. If `employees_reached` were smaller than `employees_total`, some rows are cut off from the root (see 9.9). This one-line check belongs in every hierarchy query you ship.

## 9.3 What to carry down

Each round can pass information from parent to child. The right column depends on the job:

| Carry | Built as | Used for |
|---|---|---|
| `depth` | `o.depth + 1` | levels, indentation, limiting depth |
| `chain` (text path) | `o.chain \|\| ' > ' \|\| e.first_name` | displaying "who is above me" |
| `path_ids` (integer array) | `o.path_ids \|\| e.emp_id` | ordering the tree (9.8) |
| `root_id` | copy from parent unchanged | rolling a measure up to the top (9.7) |

Management chains for three employees:

```
 emp_id | depth |                  chain
--------+-------+-----------------------------------------
      3 |     2 | Amina > Carla
     14 |     4 | Amina > Brian > Grace > Nia
     30 |     5 | Amina > Farid > Mohamed > Zane > Daniel
```

Nothing is looked up afterwards: the chain was **built on the way down**, so each row already knows its whole ancestry.

## 9.4 Subtrees

To list everyone under a particular manager, keep the same recursion and change **only the anchor**: start at that manager instead of the root.

```sql
WITH RECURSIVE subtree(emp_id, level_below) AS (
    SELECT emp_id, 0 FROM employees WHERE emp_id = 6        -- Farid Rahman; try any emp_id
    UNION ALL
    SELECT e.emp_id, s.level_below + 1
    FROM employees e
    JOIN subtree s ON e.manager_id = s.emp_id
)
SELECT s.level_below, e.emp_id, e.first_name || ' ' || e.last_name AS employee
FROM subtree s
JOIN employees e ON e.emp_id = s.emp_id
WHERE s.level_below > 0                                      -- leave out the manager themself
ORDER BY s.level_below, e.emp_id;
```

```
 level_below | emp_id |    employee
-------------+--------+----------------
           1 |     13 | Mohamed Yusuf
           2 |     26 | Zane Ochieng
           2 |     27 | Abena Boateng
           2 |     28 | Bilal Chaudhry
           2 |     29 | Chipo Moyo
           3 |     30 | Daniel Kiprop
```

Six people sit below Farid, down to three levels.

## 9.5 Going upward

Reverse the join to walk **up** from one person to the top. The anchor is the person; each round joins to their manager:

```sql
WITH RECURSIVE chain_up(emp_id, manager_id, levels_above) AS (
    SELECT emp_id, manager_id, 0 FROM employees WHERE emp_id = 30        -- anchor: Daniel
    UNION ALL
    SELECT e.emp_id, e.manager_id, c.levels_above + 1
    FROM employees e
    JOIN chain_up c ON e.emp_id = c.manager_id                           -- the join runs the other way
)
SELECT c.levels_above, e.first_name || ' ' || e.last_name AS person, e.job_title
FROM chain_up c
JOIN employees e ON e.emp_id = c.emp_id
ORDER BY c.levels_above;
```

```
 levels_above |    person    |      job_title
--------------+---------------+---------------------
            0 | Daniel Kiprop | Junior Analyst
            1 | Zane Ochieng  | Senior Data Analyst
            2 | Mohamed Yusuf | Data Manager
            3 | Farid Rahman  | VP Data & Analytics
            4 | Amina Hassan  | CEO
```

| Direction | Anchor | Recursive join |
|---|---|---|
| **Top-down** (descendants) | the root, or a chosen node | `child.parent_id = current.id` |
| **Bottom-up** (ancestors) | one node | `parent.id = current.parent_id` |

The same two directions return in Module 11 as "explode" and "where-used".

## 9.6 Headcount for everyone at once: the closure

How many people report to each manager, directly and indirectly? Running a subtree query per manager would be clumsy. Instead, anchor on **every reporting line**, so each manager is paired with all of their descendants. This set of pairs is called the **closure** (or transitive closure) of the hierarchy:

```sql
WITH RECURSIVE reports(manager_id, emp_id, distance) AS (
    SELECT manager_id, emp_id, 1
    FROM employees
    WHERE manager_id IS NOT NULL                    -- every direct reporting line
    UNION ALL
    SELECT r.manager_id, e.emp_id, r.distance + 1
    FROM reports r
    JOIN employees e ON e.manager_id = r.emp_id     -- extend each line one level further down
)
SELECT m.first_name || ' ' || m.last_name       AS manager,
       COUNT(*) FILTER (WHERE r.distance = 1)   AS direct_reports,
       COUNT(*)                                 AS total_reports
FROM reports r
JOIN employees m ON m.emp_id = r.manager_id
GROUP BY m.emp_id, m.first_name, m.last_name
ORDER BY total_reports DESC, m.emp_id;
```

```
    manager    | direct_reports | total_reports
---------------+----------------+---------------
 Amina Hassan  |              5 |            29
 Brian Otieno  |              2 |             7
 Carla Mendes  |              2 |             6
 Farid Rahman  |              1 |             6
 Mohamed Yusuf |              4 |             5
 David Kimani  |              1 |             3
 Grace Wanjiru |              3 |             3
 Elena Petrova |              1 |             2
 Hassan Ali    |              2 |             2
 Irene Achieng |              2 |             2
 James Mwangi  |              2 |             2
 Kofi Mensah   |              2 |             2
 Lina Schmidt  |              1 |             1
 Zane Ochieng  |              1 |             1
```

Sanity checks you can do by eye: the CEO's `total_reports` is **29** (everyone but themself), and the `direct_reports` column adds up to **29** too (every non-root employee has exactly one manager). Farid has one direct report (Mohamed) but six in total, because the team sits below Mohamed.

The `distance` column is what makes this work: it records how many levels apart a manager and a report are.

## 9.7 The category tree: breadcrumbs and roll-ups

The same template works on `categories`. Carrying a text path produces **breadcrumbs**:

```
 depth | category_id |             breadcrumb
-------+-------------+------------------------------------
     1 |           1 | Electronics
     2 |           2 | Electronics > Computers
     3 |           3 | Electronics > Computers > Laptops
     3 |           4 | Electronics > Computers > Desktops
     2 |           5 | Electronics > Phones
     3 |           6 | Electronics > Phones > Smartphones
     2 |           7 | Electronics > Accessories
     1 |           8 | Office
     2 |           9 | Office > Furniture
     3 |          10 | Office > Furniture > Chairs
     3 |          11 | Office > Furniture > Desks
     2 |          12 | Office > Stationery
```

Products are attached to the **lowest** categories (Laptops, Desktops, Smartphones, Accessories, Chairs, Desks, Stationery). A report for "Electronics" must therefore **add up its descendants**. There are two standard techniques.

### Technique 1: carry the root down

Pass the top-level id down unchanged, then group by it:

```sql
WITH RECURSIVE tree(category_id, root_id) AS (
    SELECT category_id, category_id FROM categories WHERE parent_id IS NULL
    UNION ALL
    SELECT c.category_id, t.root_id
    FROM categories c
    JOIN tree t ON c.parent_id = t.category_id
),
leaf_revenue AS (                   -- grain: one row per category that has sales (completed orders)
    SELECT p.category_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM order_items i
    JOIN orders   o ON o.order_id   = i.order_id AND o.status = 'completed'
    JOIN products p ON p.product_id = i.product_id
    GROUP BY p.category_id
)
SELECT r.category_name, ROUND(SUM(lr.revenue), 2) AS revenue
FROM tree t
JOIN categories   r  ON r.category_id  = t.root_id
JOIN leaf_revenue lr ON lr.category_id = t.category_id
GROUP BY r.category_id, r.category_name
ORDER BY revenue DESC;
```

```
 category_name | revenue
---------------+-----------
 Electronics   | 148555.50
 Office        |  35699.40
```

**Reconcile:** 148,555.50 + 35,699.40 = **184,254.90**, the same overall completed revenue you reconciled in Modules 4 and 5. Note that `leaf_revenue` is summarised to one row per category *before* joining, which is the Module 4 rule applied again.

### Technique 2: the closure, for every level

Technique 1 gives only the top level. To roll up at **every** level (Computers, Phones, Furniture, ...), pair each category with all its descendants, **including itself** (distance 0, so its own sales count):

```sql
WITH RECURSIVE closure(ancestor_id, category_id) AS (
    SELECT category_id, category_id FROM categories          -- every node is its own descendant
    UNION ALL
    SELECT cl.ancestor_id, c.category_id
    FROM closure cl
    JOIN categories c ON c.parent_id = cl.category_id
),
leaf_revenue AS ( ... same as above ... )
SELECT a.category_id, a.category_name,
       ROUND(COALESCE(SUM(lr.revenue), 0), 2) AS rolled_up_revenue
FROM closure cl
JOIN categories a ON a.category_id = cl.ancestor_id
LEFT JOIN leaf_revenue lr ON lr.category_id = cl.category_id
GROUP BY a.category_id, a.category_name
ORDER BY a.category_id;
```

```
 category_id | category_name | rolled_up_revenue
-------------+---------------+-------------------
           1 | Electronics   |         148555.50
           2 | Computers     |         106700.00
           3 | Laptops       |          71847.50
           4 | Desktops      |          34852.50
           5 | Phones        |          23292.50
           6 | Smartphones   |          23292.50
           7 | Accessories   |          18563.00
           8 | Office        |          35699.40
           9 | Furniture     |          34934.00
          10 | Chairs        |          16133.00
          11 | Desks         |          18801.00
          12 | Stationery    |            765.40
```

Check it: Computers 106,700.00 = Laptops 71,847.50 + Desktops 34,852.50. The `LEFT JOIN` keeps categories with no sales of their own (Computers has none directly), and `COALESCE` turns a missing total into 0.

Technique 1 is lighter (one value per row, carried down). Technique 2 is more general: a closure answers any ancestor/descendant question.

## 9.8 Putting the tree in order

`ORDER BY depth` lists the tree **level by level**: all VPs, then all managers. That is correct, but it does not look like an organisation chart:

```
 depth | emp_id | person            depth | emp_id | person
-------+--------+--------           -------+--------+---------
     1 |      1 | Amina                  1 |      1 | Amina
     2 |      2 | Brian                  2 |      2 | Brian
     2 |      3 | Carla                  3 |      7 | Grace
     2 |      4 | David                  4 |     14 | Nia
     2 |      5 | Elena                  4 |     15 | Omar
     2 |      6 | Farid                  4 |     16 | Priya
     3 |      7 | Grace                  3 |      8 | Hassan
     3 |      8 | Hassan                 4 |     17 | Quentin
     3 |      9 | Irene                  4 |     18 | Rita
```

Left: `ORDER BY depth, emp_id` (level order). Right: **`ORDER BY path_ids`** (outline order): each manager is immediately followed by their own team, and only then the next manager. This works because the integer array `path_ids` for Nia is `{1,2,7,14}`, and arrays sort element by element, so a parent's path (a prefix) always sorts directly before its children's paths.

Add indentation with `repeat('    ', depth - 1)`:

```
 emp_id |                  org_chart
--------+----------------------------------------------
      1 | Amina Hassan (CEO)
      2 |     Brian Otieno (VP Engineering)
      7 |         Grace Wanjiru (Engineering Manager)
     14 |             Nia Njeri (Software Engineer)
     15 |             Omar Farouk (Software Engineer)
     16 |             Priya Nair (QA Engineer)
      8 |         Hassan Ali (Engineering Manager)
     17 |             Quentin Dube (DevOps Engineer)
     18 |             Rita Kamau (Backend Developer)
      3 |     Carla Mendes (VP Sales)
      9 |         Irene Achieng (Sales Manager)
     19 |             Samuel Okoth (Account Executive)
```

Two design choices to notice. The path is made of **integer ids**, so the order is the same on every machine (sorting text paths depends on the database's collation settings). And siblings come out in `emp_id` order; sorting them by name needs an extra sort key, which one of the stretch goals builds.

## 9.9 Data quality and safety

A foreign key guarantees that `manager_id` points to a real employee. It does **not** stop cycles. Anyone can make two employees each other's manager. Let us do exactly that, inside a transaction we then roll back: employees 14 and 15 become each other's managers, cut off from the rest of the company.

**Top-down from the root still finishes**, and the reconciliation exposes the problem:

```
 employees_reached | employees_total | unreachable_ids
-------------------+-----------------+-----------------
                28 |              30 | {14,15}
```

28 of 30 reached, and the two missing ids are named. The cycle is never visited, because no path leads to it from the root.

**But two other traversals run forever on the same data:**

| Traversal | Loops forever on a cycle? | Why |
|---|---|---|
| **Top-down from the root** | **No** | Every row has one parent, so a cycle can never be reached from the root; it is just skipped |
| **Upward from a node** inside the cycle | **Yes** | The chain of managers goes round and round |
| **Closure** (anchor on every row) | **Yes** | The anchor includes rows inside the cycle |

We confirmed this: with a 300 ms `statement_timeout`, both the upward query and the closure were cancelled. A **depth guard** makes them safe:

```sql
SELECT e.emp_id, e.manager_id, u.depth + 1
FROM employees e
JOIN up u ON e.emp_id = u.manager_id
WHERE u.depth < 10                                   -- the guard: stop after 10 levels
```

With the guard, the same upward query returned exactly 10 rows and stopped.

**Rules for production hierarchy queries:**

1. **Reconcile** `reached = total` after any top-down traversal.
2. Put a **depth guard** (`distance < 20`, or a sensible maximum) on every upward and closure traversal.
3. Run an **audit query** now and then to list unreachable rows, and check there is exactly one root.
4. Remember a cycle is a *data* defect: find and fix the rows, rather than only guarding against them. Module 10 shows proper cycle detection.

## 9.10 Other ways to store a hierarchy

Everything here uses an **adjacency list** (a parent pointer). It is the easiest model to write to and keep correct, and recursion handles the reads. Alternatives trade write simplicity for read speed:

| Model | Idea | Reads | Writes |
|---|---|---|---|
| **Adjacency list** (this module) | parent pointer | needs recursion | simple |
| **Materialized path** | store the path as a column | simple `LIKE` or `ltree` queries | update paths when nodes move |
| **Closure table** | store every ancestor-descendant pair | very fast | maintain many rows |
| **Nested sets** | store left/right numbers | fast subtree queries | expensive to change |
| **`ltree` extension** | PostgreSQL's path type with an index | fast | path maintenance |

For most business hierarchies (org charts, categories, parts) the adjacency list plus recursive CTEs is the right place to start. Module 13 compares the options with `EXPLAIN ANALYZE`.

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Wrong join direction | Anchor row alone, or the whole table | Top-down: `child.parent_id = current.id`. Bottom-up: `parent.id = current.parent_id` |
| Anchoring at every row when you meant one subtree | Duplicate and overlapping results | Anchor at one node, or accept pairs and group by manager |
| Forgetting a depth guard on upward or closure queries | Query never finishes if data has a cycle | `WHERE depth < N` |
| Not reconciling `reached` vs `total` | Missing rows go unnoticed | Compare the traversal's count to `COUNT(*)` |
| Ordering by `depth` and expecting an outline | Level order, not tree order | `ORDER BY path_ids` |
| Sorting a path stored as text | Order depends on collation | Use an integer array |
| Summing a measure directly on the hierarchy join | Totals doubled, or leaf-only | Summarise to one row per node first, then roll up |
| Counting the node itself in subtree or closure results | Headcount off by one | Filter `level_below > 0`, or decide whether distance 0 belongs |

## Key takeaways

- A hierarchy is a parent-child table. Recursion follows the pointers: **anchor at the root, then join `child.parent = current.id`**.
- **Carry** depth, text paths, integer path arrays or the root id down the tree, depending on the job.
- Change only the **anchor** for a subtree; reverse the **join** to go upward.
- A **closure** (anchor on every edge) answers headcounts and roll-ups for every node in one pass.
- Order a tree with an **integer path array**, and indent with `repeat(...)`.
- Top-down from the root cannot loop, but **upward and closure queries can**: add a depth guard, and **reconcile** reached against total.

## Checkpoint

<details>
<summary>1. What is the recursive join condition for walking down an org chart, and for walking up?</summary>

Down: `JOIN org o ON e.manager_id = o.emp_id` (children whose manager is the current row). Up: `JOIN chain_up c ON e.emp_id = c.manager_id` (the manager of the current row).
</details>

<details>
<summary>2. Why does <code>ORDER BY path_ids</code> give outline order but <code>ORDER BY depth</code> does not?</summary>

A parent's path is a prefix of its children's paths, and arrays sort element by element, so each parent sorts directly before its subtree. `depth` only groups people by level.
</details>

<details>
<summary>3. A traversal from the root reaches 28 of 30 employees. What does that tell you, and how do you find the two missing rows?</summary>

Two rows are not connected to the root (for example a detached cycle, since a foreign key cannot prevent cycles). List the employees whose id is not in the traversal result (`WHERE emp_id NOT IN (SELECT emp_id FROM org)`).
</details>

<details>
<summary>4. Which hierarchy traversals can loop forever on corrupt data, and which cannot?</summary>

Top-down from the root cannot, because a single-parent structure cannot have a cycle reachable from the root. Upward traversals that start inside a cycle, and closures that anchor on every row, can, so they need a depth guard.
</details>

**Next:** do the [exercises](exercises.md), then continue to Module 10: Graphs, Cycles & `SEARCH`/`CYCLE` *(coming soon)*.
