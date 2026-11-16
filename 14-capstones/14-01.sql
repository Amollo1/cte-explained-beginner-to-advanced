-- Capstone 1: SALES ANALYTICS MART (a star schema ready for Power BI or Tableau).
--
-- The business need: analysts want revenue, orders, categories and customers without re-writing joins.
-- The design:
--   dim_date, dim_customer, dim_product      descriptive tables (the category tree is flattened into a path)
--   fact_order_line                          GRAIN: one row per order line (quantities and amounts)
--   fact_order                               GRAIN: one row per order (shipping fee lives here, so it is never repeated)
--   kpi_monthly, kpi_category, kpi_customer  ready-made KPI views
-- Two fact tables, each at its own grain, are what prevents the fan-out error from Module 4.
-- The file ends with a SELF-CHECK table: every row must say passed = true.
-- HOW THIS FILE IS USED
--   In this course repository the file runs inside BEGIN ... ROLLBACK, so the practice data is never changed
--   and the automated tests can run it again and again.
--   To KEEP the objects in YOUR OWN project repository, copy the file, delete the BEGIN; and ROLLBACK; lines
--   (or replace ROLLBACK; with COMMIT;) and run it once against your own database.

BEGIN;

CREATE SCHEMA mart;
COMMENT ON SCHEMA mart IS 'Star-schema reporting mart built from orders, order_items, customers, products and categories.';

-- DIM_DATE: one row per calendar day, from the first to the LAST ORDER DATE (taken from the data, not a fixed year).
CREATE TABLE mart.dim_date AS
SELECT d::date                                  AS date_key,
       EXTRACT(YEAR FROM d)::int                AS year,
       EXTRACT(QUARTER FROM d)::int             AS quarter,
       EXTRACT(MONTH FROM d)::int               AS month,
       date_trunc('month', d)::date             AS month_start,
       to_char(d, 'FMMonth')                    AS month_name,
       to_char(d, 'FMDay')                      AS weekday_name,
       EXTRACT(ISODOW FROM d)::int              AS iso_weekday,
       (EXTRACT(ISODOW FROM d) >= 6)            AS is_weekend
FROM generate_series((SELECT MIN(order_date) FROM orders)::timestamp,
                     (SELECT MAX(order_date) FROM orders)::timestamp,
                     interval '1 day') AS d;
ALTER TABLE mart.dim_date ADD PRIMARY KEY (date_key);
COMMENT ON TABLE mart.dim_date IS 'One row per calendar day between the first and last order.';

-- DIM_CUSTOMER
CREATE TABLE mart.dim_customer AS
SELECT c.customer_id AS customer_key, c.customer_name, c.country, c.segment, c.signup_date,
       (SELECT MIN(o.order_date) FROM orders o WHERE o.customer_id = c.customer_id) AS first_order_date
FROM customers c;
ALTER TABLE mart.dim_customer ADD PRIMARY KEY (customer_key);
COMMENT ON TABLE mart.dim_customer IS 'One row per customer. first_order_date is NULL for customers who never ordered.';

-- DIM_PRODUCT: the category tree is flattened with a recursive CTE (Module 9): a readable path and the top-level category.
CREATE TABLE mart.dim_product AS
WITH RECURSIVE tree(category_id, root_name, breadcrumb) AS (
    SELECT category_id, category_name, category_name::text FROM categories WHERE parent_id IS NULL
    UNION ALL
    SELECT c.category_id, t.root_name, t.breadcrumb || ' > ' || c.category_name
    FROM categories c JOIN tree t ON c.parent_id = t.category_id
)
SELECT p.product_id AS product_key, p.product_name, p.unit_price AS list_price,
       p.category_id, t.breadcrumb AS category_path, t.root_name AS top_category
FROM products p
JOIN tree t ON t.category_id = p.category_id;
ALTER TABLE mart.dim_product ADD PRIMARY KEY (product_key);
COMMENT ON TABLE mart.dim_product IS 'One row per product with its full category path and top-level category.';

-- FACT_ORDER_LINE: GRAIN = one row per order line. Amounts are NOT rounded here; reports round at the end.
CREATE TABLE mart.fact_order_line AS
SELECT i.item_id, i.order_id, o.customer_id AS customer_key, i.product_id AS product_key,
       o.order_date AS date_key, o.status,
       i.quantity, p.unit_price, i.discount,
       i.quantity * p.unit_price                         AS gross_amount,
       i.quantity * p.unit_price * i.discount            AS discount_amount,
       i.quantity * p.unit_price * (1 - i.discount)      AS net_amount
FROM order_items i
JOIN orders   o ON o.order_id   = i.order_id
JOIN products p ON p.product_id = i.product_id;
ALTER TABLE mart.fact_order_line ADD PRIMARY KEY (item_id);
COMMENT ON TABLE mart.fact_order_line IS 'GRAIN: one row per order line. Sum net_amount freely; do not sum order-level columns here.';

-- FACT_ORDER: GRAIN = one row per order. Line amounts are summarised FIRST (aggregate, then join), so the
-- order-level shipping fee is counted exactly once per order.
CREATE TABLE mart.fact_order AS
SELECT o.order_id, o.customer_id AS customer_key, o.order_date AS date_key, o.status, o.shipping_fee,
       COALESCE(l.line_count, 0) AS line_count, COALESCE(l.units, 0) AS units, COALESCE(l.net_amount, 0) AS net_amount
FROM orders o
LEFT JOIN (SELECT order_id, COUNT(*) AS line_count, SUM(quantity) AS units, SUM(net_amount) AS net_amount
           FROM mart.fact_order_line GROUP BY order_id) l ON l.order_id = o.order_id;
ALTER TABLE mart.fact_order ADD PRIMARY KEY (order_id);
COMMENT ON TABLE mart.fact_order IS 'GRAIN: one row per order. shipping_fee lives here, at its own grain.';

-- Integrity: the database itself now refuses orphan keys.
ALTER TABLE mart.fact_order
    ADD FOREIGN KEY (customer_key) REFERENCES mart.dim_customer,
    ADD FOREIGN KEY (date_key)     REFERENCES mart.dim_date;
ALTER TABLE mart.fact_order_line
    ADD FOREIGN KEY (order_id)     REFERENCES mart.fact_order,
    ADD FOREIGN KEY (product_key)  REFERENCES mart.dim_product,
    ADD FOREIGN KEY (customer_key) REFERENCES mart.dim_customer,
    ADD FOREIGN KEY (date_key)     REFERENCES mart.dim_date;

-- Foreign keys do NOT create indexes in PostgreSQL (Module 13): index the columns that reports join and filter on.
CREATE INDEX ON mart.fact_order_line (order_id);
CREATE INDEX ON mart.fact_order_line (product_key);
CREATE INDEX ON mart.fact_order_line (customer_key);
CREATE INDEX ON mart.fact_order_line (date_key);
CREATE INDEX ON mart.fact_order (customer_key);
CREATE INDEX ON mart.fact_order (date_key);
ANALYZE mart.dim_date; ANALYZE mart.fact_order; ANALYZE mart.fact_order_line;

-- KPI 1: monthly revenue with month-over-month growth and a running total. A month calendar guards LAG against
-- missing months (Modules 5 and 8): a month with no sales shows 0, it is never skipped.
CREATE VIEW mart.kpi_monthly AS
WITH months AS (
    SELECT DISTINCT month_start FROM mart.dim_date
),
monthly AS (
    SELECT d.month_start, COUNT(*) AS completed_orders, SUM(o.net_amount) AS net_revenue
    FROM mart.fact_order o
    JOIN mart.dim_date d ON d.date_key = o.date_key
    WHERE o.status = 'completed'
    GROUP BY d.month_start
),
filled AS (
    SELECT m.month_start,
           COALESCE(x.completed_orders, 0) AS completed_orders,
           COALESCE(x.net_revenue, 0)      AS net_revenue
    FROM months m
    LEFT JOIN monthly x ON x.month_start = m.month_start
)
SELECT month_start, completed_orders,
       ROUND(net_revenue, 2) AS net_revenue,
       ROUND(100 * (net_revenue - LAG(net_revenue) OVER w) / NULLIF(LAG(net_revenue) OVER w, 0), 1) AS mom_growth_pct,
       ROUND(SUM(net_revenue) OVER (ORDER BY month_start ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2) AS running_revenue
FROM filled
WINDOW w AS (ORDER BY month_start);

-- KPI 2: revenue by top-level category, with share of total.
CREATE VIEW mart.kpi_category AS
SELECT p.top_category,
       ROUND(SUM(l.net_amount), 2) AS net_revenue,
       SUM(l.quantity)             AS units,
       ROUND(100 * SUM(l.net_amount) / SUM(SUM(l.net_amount)) OVER (), 1) AS pct_of_total
FROM mart.fact_order_line l
JOIN mart.dim_product p ON p.product_key = l.product_key
WHERE l.status = 'completed'
GROUP BY p.top_category;

-- KPI 3: customers ranked within their country.
CREATE VIEW mart.kpi_customer AS
SELECT c.customer_key, c.customer_name, c.country,
       COUNT(*)                    AS completed_orders,
       ROUND(SUM(o.net_amount), 2) AS net_revenue,
       RANK() OVER (PARTITION BY c.country ORDER BY SUM(o.net_amount) DESC) AS rank_in_country
FROM mart.fact_order o
JOIN mart.dim_customer c ON c.customer_key = o.customer_key
WHERE o.status = 'completed'
GROUP BY c.customer_key, c.customer_name, c.country;

-- Part A: what the mart contains. Expected: 5 tables with 546, 30, 20, 286 and 120 rows.
SELECT t.table_name,
       (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from mart.%I', t.table_name), false, true, '')))[1]::text AS row_count,
       (SELECT COUNT(*) FROM information_schema.columns c WHERE c.table_schema = 'mart' AND c.table_name = t.table_name)             AS columns,
       obj_description(format('mart.%I', t.table_name)::regclass, 'pg_class')                                                       AS description
FROM information_schema.tables t
WHERE t.table_schema = 'mart' AND t.table_type = 'BASE TABLE'
ORDER BY CASE t.table_name WHEN 'dim_date' THEN 1 WHEN 'dim_customer' THEN 2 WHEN 'dim_product' THEN 3
                           WHEN 'fact_order_line' THEN 4 WHEN 'fact_order' THEN 5 END;

-- Part B: the KPI views a dashboard would read. First four months, then the categories.
SELECT * FROM mart.kpi_monthly ORDER BY month_start LIMIT 4;
SELECT * FROM mart.kpi_category ORDER BY net_revenue DESC;

-- Part C: SELF-CHECKS. Every row must say passed = true.
WITH checks(ord, check_name, expected, actual) AS (
    VALUES
    (1,  'dim_date covers every day from first to last order',
         ((SELECT MAX(order_date) - MIN(order_date) + 1 FROM orders))::text,
         (SELECT COUNT(*) FROM mart.dim_date)::text),
    (2,  'every order line is in the fact table',
         (SELECT COUNT(*) FROM order_items)::text,
         (SELECT COUNT(*) FROM mart.fact_order_line)::text),
    (3,  'every order is in the fact table',
         (SELECT COUNT(*) FROM orders)::text,
         (SELECT COUNT(*) FROM mart.fact_order)::text),
    (4,  'no order date is missing from dim_date',
         '0',
         (SELECT COUNT(*) FROM orders o WHERE NOT EXISTS (SELECT 1 FROM mart.dim_date d WHERE d.date_key = o.order_date))::text),
    (5,  'completed revenue matches the base tables (independent control total)',
         (SELECT ROUND(SUM(i.quantity * p.unit_price * (1 - i.discount)), 2)
          FROM order_items i JOIN orders o ON o.order_id = i.order_id JOIN products p ON p.product_id = i.product_id
          WHERE o.status = 'completed')::text,
         (SELECT ROUND(SUM(net_amount), 2) FROM mart.fact_order_line WHERE status = 'completed')::text),
    (6,  'order grain and line grain agree on total net revenue',
         (SELECT ROUND(SUM(net_amount), 2) FROM mart.fact_order_line)::text,
         (SELECT ROUND(SUM(net_amount), 2) FROM mart.fact_order)::text),
    (7,  'shipping is counted once per order (no fan-out)',
         (SELECT SUM(shipping_fee) FROM orders)::text,
         (SELECT SUM(shipping_fee) FROM mart.fact_order)::text),
    (8,  'category KPI adds up to completed revenue',
         (SELECT ROUND(SUM(net_amount), 2) FROM mart.fact_order_line WHERE status = 'completed')::text,
         (SELECT SUM(net_revenue) FROM mart.kpi_category)::text),
    (9,  'monthly KPI covers all 18 months',
         '18',
         (SELECT COUNT(*) FROM mart.kpi_monthly)::text),
    (10, 'March 2025 growth is 136.0 percent',
         '136.0',
         (SELECT mom_growth_pct FROM mart.kpi_monthly WHERE month_start = DATE '2025-03-01')::text),
    (11, 'the running total ends at the completed revenue',
         (SELECT ROUND(SUM(net_amount), 2) FROM mart.fact_order_line WHERE status = 'completed')::text,
         (SELECT MAX(running_revenue) FROM mart.kpi_monthly)::text)
)
SELECT check_name, expected, actual, (expected = actual) AS passed
FROM checks
ORDER BY ord;

ROLLBACK;
