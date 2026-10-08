-- Exercise 04-01: the fan-out trap on shipping_fee.
-- Three numbers in one row:
--   control_total      the true total, straight from orders (one row per order)
--   wrong_after_join   shipping_fee summed AFTER joining to order_items (rows repeated per line item)
--   fixed_with_cte     items summarised to one row per order first, then joined
-- LEFT JOIN is used so an order with no items could never drop out of the total.
WITH order_item_totals AS (          -- grain: one row per order
    SELECT order_id,
           SUM(quantity) AS units
    FROM order_items
    GROUP BY order_id
)
SELECT (SELECT SUM(shipping_fee) FROM orders)                                  AS control_total,
       (SELECT SUM(o.shipping_fee)
        FROM orders o
        JOIN order_items i ON i.order_id = o.order_id)                         AS wrong_after_join,
       (SELECT SUM(o.shipping_fee)
        FROM orders o
        LEFT JOIN order_item_totals t ON t.order_id = o.order_id)              AS fixed_with_cte;
