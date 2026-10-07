-- Exercise 00-01: row count of every practice table.
-- Expected: 11 rows. departments 7, employees 30, customers 30, categories 12,
-- products 20, orders 120, order_items 286, routes 12, parts 20, bom 20, customers_raw 20.
SELECT *
FROM (SELECT 'bom'           AS table_name, COUNT(*) AS row_count FROM bom
      UNION ALL SELECT 'categories',    COUNT(*) FROM categories
      UNION ALL SELECT 'customers',     COUNT(*) FROM customers
      UNION ALL SELECT 'customers_raw', COUNT(*) FROM customers_raw
      UNION ALL SELECT 'departments',   COUNT(*) FROM departments
      UNION ALL SELECT 'employees',     COUNT(*) FROM employees
      UNION ALL SELECT 'order_items',   COUNT(*) FROM order_items
      UNION ALL SELECT 'orders',        COUNT(*) FROM orders
      UNION ALL SELECT 'parts',         COUNT(*) FROM parts
      UNION ALL SELECT 'products',      COUNT(*) FROM products
      UNION ALL SELECT 'routes',        COUNT(*) FROM routes) t
ORDER BY table_name;
