-- 001: uploader AI-generated declaration on videos.
-- Optional for now (defaults to 0/false); the mandatory uploader toggle and
-- the viewer-facing "AI-generated" label ship with the premium upload/feed
-- redesign. Safe to run on existing DBs (ADD COLUMN with default).
ALTER TABLE videos ADD COLUMN is_ai_generated INTEGER NOT NULL DEFAULT 0;
