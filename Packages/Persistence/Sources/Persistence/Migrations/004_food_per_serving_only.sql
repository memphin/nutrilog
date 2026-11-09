-- Foods copied from an online source that only gives values per serving, with no usable serving weight (backlog #19).
-- 1 → the per-100 columns hold the values of ONE serving, and the default serving is a stand-in of 100 g/ml, so
-- logging "1 serving" is right but gram amounts are not. The UI hides gram entry and asks for the serving weight.
ALTER TABLE food ADD COLUMN per_serving_only INTEGER NOT NULL DEFAULT 0;
