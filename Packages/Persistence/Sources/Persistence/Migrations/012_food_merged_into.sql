-- Duplicate foods: a food merged away (Settings → Duplicate foods) points to the food it was merged into, so a copy
-- of a bundled / USDA food that was merged into another isn't offered or revived again. NULL for every other food,
-- including one the user deleted. Follow the chain to the final active food (a kept food may be merged later too).
ALTER TABLE food ADD COLUMN merged_into_id TEXT REFERENCES food(id);
