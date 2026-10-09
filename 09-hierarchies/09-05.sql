-- Exercise 09-05: revenue per top-level category, including all descendant categories.
-- Part A: carry the ROOT id down the tree, then add each category's own revenue under its root.
WITH RECURSIVE tree(category_id, root_id) AS (
    SELECT category_id, category_id
    FROM categories
    WHERE parent_id IS NULL
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
SELECT r.category_name,
       ROUND(SUM(lr.revenue), 2) AS revenue
FROM tree t
JOIN categories   r  ON r.category_id  = t.root_id
JOIN leaf_revenue lr ON lr.category_id = t.category_id
GROUP BY r.category_id, r.category_name
ORDER BY revenue DESC, r.category_name;

-- Reconcile: the top-level figures must add up to the overall completed-order revenue (184254.90).
WITH RECURSIVE tree(category_id, root_id) AS (
    SELECT category_id, category_id FROM categories WHERE parent_id IS NULL
    UNION ALL
    SELECT c.category_id, t.root_id FROM categories c JOIN tree t ON c.parent_id = t.category_id
),
leaf_revenue AS (                   -- grain: one row per category that has sales (completed orders)
    SELECT p.category_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM order_items i
    JOIN orders   o ON o.order_id   = i.order_id AND o.status = 'completed'
    JOIN products p ON p.product_id = i.product_id
    GROUP BY p.category_id
)
SELECT ROUND((SELECT SUM(lr.revenue) FROM tree t JOIN leaf_revenue lr ON lr.category_id = t.category_id), 2) AS sum_of_top_level,
       ROUND((SELECT SUM(i.quantity * p.unit_price * (1 - i.discount))
              FROM order_items i
              JOIN orders   o ON o.order_id   = i.order_id AND o.status = 'completed'
              JOIN products p ON p.product_id = i.product_id), 2)                                      AS control_total;

-- Part B: roll up at EVERY level using a closure (each category paired with all its descendants).
WITH RECURSIVE closure(ancestor_id, category_id) AS (
    SELECT category_id, category_id FROM categories          -- every node is its own descendant
    UNION ALL
    SELECT cl.ancestor_id, c.category_id
    FROM closure cl
    JOIN categories c ON c.parent_id = cl.category_id
),
leaf_revenue AS (                   -- grain: one row per category that has sales (completed orders)
    SELECT p.category_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM order_items i
    JOIN orders   o ON o.order_id   = i.order_id AND o.status = 'completed'
    JOIN products p ON p.product_id = i.product_id
    GROUP BY p.category_id
)
SELECT a.category_id,
       a.category_name,
       ROUND(COALESCE(SUM(lr.revenue), 0), 2) AS rolled_up_revenue
FROM closure cl
JOIN categories a ON a.category_id = cl.ancestor_id
LEFT JOIN leaf_revenue lr ON lr.category_id = cl.category_id
GROUP BY a.category_id, a.category_name
ORDER BY a.category_id;
