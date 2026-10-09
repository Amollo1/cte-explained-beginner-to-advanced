-- Exercise 05-01: top 3 products by revenue within each category (completed orders only).
-- ROW_NUMBER with a tiebreaker (product_id) gives exactly N rows per category, deterministically.
-- pct_of_category is a second window (SUM over the category) computed BEFORE the top-3 filter,
-- so it is the share of the whole category, not of the top 3.
WITH product_revenue AS (            -- grain: one row per product
    SELECT p.product_id, p.product_name, p.category_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM order_items i
    JOIN orders   o ON o.order_id   = i.order_id AND o.status = 'completed'
    JOIN products p ON p.product_id = i.product_id
    GROUP BY p.product_id, p.product_name, p.category_id
),
ranked AS (                          -- same grain, plus rank and share of category
    SELECT product_id, product_name, category_id, revenue,
           ROW_NUMBER() OVER (PARTITION BY category_id ORDER BY revenue DESC, product_id) AS rn,
           ROUND(100 * revenue / SUM(revenue) OVER (PARTITION BY category_id), 1)        AS pct_of_category
    FROM product_revenue
)
SELECT c.category_name,
       r.rn AS rank_in_category,
       r.product_name,
       ROUND(r.revenue, 2) AS revenue,
       r.pct_of_category
FROM ranked r
JOIN categories c ON c.category_id = r.category_id
WHERE r.rn <= 3
ORDER BY c.category_name, r.rn;
