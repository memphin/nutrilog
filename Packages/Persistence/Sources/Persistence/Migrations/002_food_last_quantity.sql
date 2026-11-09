-- Remember the quantity last used for each food so the quantity sheet can prefill it (backlog #8).
-- last_serving_id NULL → last_amount is in the food's base unit (g/ml); otherwise it is a serving count.
ALTER TABLE food ADD COLUMN last_serving_id TEXT;
ALTER TABLE food ADD COLUMN last_amount REAL;
