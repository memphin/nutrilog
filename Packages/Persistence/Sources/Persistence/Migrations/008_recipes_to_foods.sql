-- Recipes were removed in favour of saved meals (issue #68): the app has foods and meals only. A recipe was stored
-- as a food with computed per-100 values, so existing recipes simply become ordinary custom foods. Nothing is
-- deleted: their `recipe_ingredient` rows stay (unused by the app) and the food keeps its values and servings.
UPDATE food
SET source = 'custom', updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now'), revision = revision + 1
WHERE source = 'recipe';
