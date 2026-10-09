-- Exercise 09-04: a breadcrumb for every category, e.g. Electronics > Computers > Laptops.
-- Rows are listed in tree (outline) order by sorting on the path of ids.
WITH RECURSIVE tree(category_id, category_name, depth, path_ids, breadcrumb) AS (
    SELECT category_id, category_name, 1, ARRAY[category_id], category_name::text
    FROM categories
    WHERE parent_id IS NULL                -- anchor: top-level categories
    UNION ALL
    SELECT c.category_id, c.category_name, t.depth + 1,
           t.path_ids || c.category_id,
           t.breadcrumb || ' > ' || c.category_name
    FROM categories c
    JOIN tree t ON c.parent_id = t.category_id
)
SELECT depth,
       category_id,
       breadcrumb
FROM tree
ORDER BY path_ids;
