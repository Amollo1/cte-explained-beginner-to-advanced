-- Exercise 12-01: archive the cancelled orders AND their line items in ONE statement.
-- order_items references orders, so the items must be moved too. Constraints are checked at the end of
-- the statement, so deleting parents and children together is allowed.
-- Everything runs inside BEGIN ... ROLLBACK so the practice data is left untouched.

CREATE OR REPLACE FUNCTION pg_temp.try_sql(q text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION
    WHEN query_canceled THEN RETURN 'CANCELED: ' || SQLERRM;
    WHEN OTHERS         THEN RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

-- Part A: run the archive and count. Expected: 113 orders left, 7 archived, 268 items left, 18 archived.
BEGIN;
CREATE TEMP TABLE before_counts AS
SELECT (SELECT COUNT(*) FROM orders) AS orders_before, (SELECT COUNT(*) FROM order_items) AS items_before;

WITH cancelled AS (                                        -- the orders to move
    SELECT order_id FROM orders WHERE status = 'cancelled'
),
del_items AS (                                              -- 1. remove their line items...
    DELETE FROM order_items
    WHERE order_id IN (SELECT order_id FROM cancelled)
    RETURNING item_id, order_id, product_id, quantity, discount
),
arch_items AS (                                             -- 2. ...and file them in the archive
    INSERT INTO order_items_archive (item_id, order_id, product_id, quantity, discount)
    SELECT item_id, order_id, product_id, quantity, discount FROM del_items
),
del_orders AS (                                             -- 3. remove the orders themselves...
    DELETE FROM orders
    WHERE order_id IN (SELECT order_id FROM cancelled)
    RETURNING order_id, customer_id, order_date, status, shipping_fee
)
INSERT INTO orders_archive (order_id, customer_id, order_date, status, shipping_fee)   -- 4. ...and archive them
SELECT order_id, customer_id, order_date, status, shipping_fee FROM del_orders;
SELECT (SELECT COUNT(*) FROM orders)                              AS orders_left,
       (SELECT COUNT(*) FROM orders_archive)                      AS orders_archived,
       (SELECT COUNT(*) FROM order_items)                         AS items_left,
       (SELECT COUNT(*) FROM order_items_archive)                 AS items_archived,
       (SELECT COUNT(*) FROM orders WHERE status = 'cancelled')   AS cancelled_left;

-- Part B: reconcile. Nothing may be lost or duplicated: left + archived must equal the original counts.
SELECT b.orders_before,
       (SELECT COUNT(*) FROM orders) + (SELECT COUNT(*) FROM orders_archive)              AS orders_accounted_for,
       b.items_before,
       (SELECT COUNT(*) FROM order_items) + (SELECT COUNT(*) FROM order_items_archive)    AS items_accounted_for
FROM before_counts b;
ROLLBACK;

-- Part C: ATOMICITY. Put a clashing row in the archive first. The statement then fails on the primary
-- key, and because it is ONE statement the deletes are undone as well. Expected: 23505, 120, 286, 0.
BEGIN;
INSERT INTO orders_archive (order_id, customer_id, order_date, status, shipping_fee)
SELECT order_id, customer_id, order_date, status, shipping_fee
FROM orders
WHERE order_id = (SELECT MIN(order_id) FROM orders WHERE status = 'cancelled');

SELECT LEFT(pg_temp.try_sql($q$
WITH cancelled AS (                                        -- the orders to move
    SELECT order_id FROM orders WHERE status = 'cancelled'
),
del_items AS (                                              -- 1. remove their line items...
    DELETE FROM order_items
    WHERE order_id IN (SELECT order_id FROM cancelled)
    RETURNING item_id, order_id, product_id, quantity, discount
),
arch_items AS (                                             -- 2. ...and file them in the archive
    INSERT INTO order_items_archive (item_id, order_id, product_id, quantity, discount)
    SELECT item_id, order_id, product_id, quantity, discount FROM del_items
),
del_orders AS (                                             -- 3. remove the orders themselves...
    DELETE FROM orders
    WHERE order_id IN (SELECT order_id FROM cancelled)
    RETURNING order_id, customer_id, order_date, status, shipping_fee
)
INSERT INTO orders_archive (order_id, customer_id, order_date, status, shipping_fee)   -- 4. ...and archive them
SELECT order_id, customer_id, order_date, status, shipping_fee FROM del_orders $q$), 5) AS sqlstate_of_failed_archive;

SELECT (SELECT COUNT(*) FROM orders)              AS orders_still_there,
       (SELECT COUNT(*) FROM order_items)         AS items_still_there,
       (SELECT COUNT(*) FROM order_items_archive) AS items_archived;
ROLLBACK;

-- Part D: the practice data is back to normal. Expected: 120, 286, 0, 0.
SELECT (SELECT COUNT(*) FROM orders)              AS orders,
       (SELECT COUNT(*) FROM order_items)         AS order_items,
       (SELECT COUNT(*) FROM orders_archive)      AS orders_archive,
       (SELECT COUNT(*) FROM order_items_archive) AS order_items_archive;
