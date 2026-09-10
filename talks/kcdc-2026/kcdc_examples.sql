-- =============================================================================
-- KCDC 2026: Postgres for Everything — Companion SQL File
-- =============================================================================
-- All examples from the talk, organized by section.
-- Requires: Bluebox dataset loaded, PostGIS, pg_trgm extensions.
-- Optional: pgvector, Apache AGE, pg_duckdb
--
-- Setup: Load bluebox_schema_v0.4.sql and bluebox_dataonly_v0.4.sql
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 0: VERIFY SETUP
-- ─────────────────────────────────────────────────────────────────────────────

-- Check extensions
SELECT extname, extversion FROM pg_extension ORDER BY extname;

-- Check bluebox tables
SELECT schemaname, tablename, n_live_tup
FROM pg_stat_user_tables
WHERE schemaname = 'bluebox'
ORDER BY n_live_tup DESC;

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1: JOB QUEUES — SKIP LOCKED
-- ─────────────────────────────────────────────────────────────────────────────

-- Create a simple job queue table
CREATE TABLE IF NOT EXISTS bluebox.job_queue (
    job_id BIGSERIAL PRIMARY KEY,
    job_type TEXT NOT NULL,
    payload JSONB,
    status TEXT DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT now(),
    attempted_at TIMESTAMPTZ,
    attempts INT DEFAULT 0
);

-- Enqueue: overdue rental returns
INSERT INTO bluebox.job_queue (job_type, payload)
SELECT 'process_return',
    jsonb_build_object(
        'rental_id', rental_id,
        'customer_id', customer_id,
        'days_overdue', EXTRACT(DAY FROM now() - upper(rental_period))
    )
FROM bluebox.rental
WHERE upper(rental_period) < now() - interval '7 days'
  AND upper(rental_period) IS NOT NULL
LIMIT 20;

-- Worker: claim a single job (run in multiple sessions to see SKIP LOCKED)
BEGIN;
UPDATE bluebox.job_queue
SET status = 'processing',
    attempted_at = now(),
    attempts = attempts + 1
WHERE job_id = (
    SELECT job_id FROM bluebox.job_queue
    WHERE status = 'pending'
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT 1
)
RETURNING *;
-- (do work here)
-- UPDATE bluebox.job_queue SET status = 'completed' WHERE job_id = <id>;
COMMIT;

-- Check queue state
SELECT status, count(*) FROM bluebox.job_queue GROUP BY status;

-- Cleanup
-- DROP TABLE bluebox.job_queue;

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2: EVENTS / PUB-SUB — LISTEN / NOTIFY
-- ─────────────────────────────────────────────────────────────────────────────

-- Create trigger function to notify on new rentals
CREATE OR REPLACE FUNCTION bluebox.notify_new_rental()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('new_rental',
        json_build_object(
            'rental_id', NEW.rental_id,
            'customer_id', NEW.customer_id,
            'inventory_id', NEW.inventory_id,
            'rented_at', lower(NEW.rental_period)
        )::text
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Attach trigger
DROP TRIGGER IF EXISTS rental_notify ON bluebox.rental;
CREATE TRIGGER rental_notify
    AFTER INSERT ON bluebox.rental
    FOR EACH ROW EXECUTE FUNCTION bluebox.notify_new_rental();

-- In a separate session, run:
-- LISTEN new_rental;
-- Then insert a rental and watch for notification:
-- INSERT INTO bluebox.rental (rental_period, inventory_id, customer_id, store_id)
-- VALUES (tstzrange(now(), NULL), 1, 1, 1);

-- Cleanup
-- DROP TRIGGER rental_notify ON bluebox.rental;
-- DROP FUNCTION bluebox.notify_new_rental();

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3: CACHING — UNLOGGED TABLES
-- ─────────────────────────────────────────────────────────────────────────────

-- Create cache table (no WAL = fast writes, lost on crash)
CREATE UNLOGGED TABLE IF NOT EXISTS bluebox.cache (
    cache_key TEXT PRIMARY KEY,
    cache_value JSONB NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL DEFAULT now() + interval '1 hour'
);

CREATE INDEX IF NOT EXISTS idx_cache_expires ON bluebox.cache (expires_at);

-- SET (upsert)
INSERT INTO bluebox.cache (cache_key, cache_value, expires_at)
VALUES ('film:550', '{"title":"Fight Club","rating":8.4}',
        now() + interval '24 hours')
ON CONFLICT (cache_key) DO UPDATE
SET cache_value = EXCLUDED.cache_value,
    expires_at = EXCLUDED.expires_at;

-- GET
SELECT cache_value FROM bluebox.cache
WHERE cache_key = 'film:550'
  AND expires_at > now();

-- Warm cache with popular films
INSERT INTO bluebox.cache (cache_key, cache_value)
SELECT
    'popular_film:' || f.film_id,
    jsonb_build_object(
        'title', f.title,
        'popularity', f.popularity,
        'rental_count', count(r.rental_id)
    )
FROM bluebox.film f
JOIN bluebox.inventory i USING (film_id)
JOIN bluebox.rental r USING (inventory_id)
GROUP BY f.film_id
ORDER BY count(r.rental_id) DESC
LIMIT 100
ON CONFLICT (cache_key) DO UPDATE
SET cache_value = EXCLUDED.cache_value;

-- Expire old entries
DELETE FROM bluebox.cache WHERE expires_at < now();

-- Cleanup
-- DROP TABLE bluebox.cache;

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 4: DOCUMENT STORE — JSONB
-- ─────────────────────────────────────────────────────────────────────────────

-- Multi-schema JSONB: different shapes in the same table
CREATE TABLE IF NOT EXISTS bluebox.api_events (
    id BIGSERIAL PRIMARY KEY,
    event_type TEXT,
    payload JSONB
);

INSERT INTO bluebox.api_events (event_type, payload) VALUES
('signup', '{"user": "jane", "plan": "pro", "referral": "google"}'),
('purchase', '{"user": "jane", "items": [{"sku": "DVD-001", "qty": 2}], "total": 9.99, "coupon": null}'),
('support', '{"user": "jane", "ticket_id": 4521, "tags": ["billing", "urgent"], "metadata": {"browser": "Chrome", "os": "macOS"}}');

-- Query nested structures
SELECT
    payload->>'user' AS username,
    payload->'items'->0->>'sku' AS first_item,
    payload->'metadata'->>'browser' AS browser,
    jsonb_array_length(payload->'tags') AS tag_count
FROM bluebox.api_events
WHERE payload ? 'tags';

-- Cleanup
-- DROP TABLE bluebox.api_events;

-- Query JSONB cast data
SELECT film_id,
    "cast"->0->>'name' AS lead_actor,
    "cast"->0->>'character' AS role
FROM staging.film_credits
LIMIT 5;

-- Containment search (uses GIN index)
SELECT film_id FROM staging.film_credits
WHERE "cast" @> '[{"name": "Tom Hanks"}]';

-- Expand JSONB arrays
SELECT film_id, crew->>'name' AS director, crew->>'job'
FROM staging.film_credits,
     jsonb_array_elements("crew") AS crew
WHERE crew->>'job' = 'Director'
LIMIT 10;

-- GIN index for fast containment
CREATE INDEX IF NOT EXISTS idx_credits_cast_gin
ON staging.film_credits USING GIN ("cast");

-- SQL/JSON Path (PG 12+)
SELECT film_id,
    jsonb_path_query_array(
        "cast",
        '$[*] ? (@.name like_regex "^Tom")'
    ) AS toms_in_cast
FROM staging.film_credits
WHERE jsonb_path_exists(
    "cast",
    '$[*] ? (@.name like_regex "^Tom")'
)
LIMIT 5;

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 5: SPATIAL DATA — PostGIS
-- ─────────────────────────────────────────────────────────────────────────────

-- Check PostGIS version
SELECT PostGIS_Full_Version();

-- See customer locations
SELECT full_name, ST_AsText(geog) AS location
FROM bluebox.customer
LIMIT 5;

-- Find nearest store to customer 42
SELECT s.store_id, s.street_name,
    round(ST_Distance(c.geog, s.geog)::numeric) AS distance_meters
FROM bluebox.customer c
CROSS JOIN bluebox.store s
WHERE c.customer_id = 42
ORDER BY c.geog <-> s.geog
LIMIT 3;

-- Customers within 5km of each store
SELECT s.store_id, s.street_name,
    count(c.customer_id) AS customers_in_range
FROM bluebox.store s
JOIN bluebox.customer c ON ST_DWithin(c.geog, s.geog, 5000)
GROUP BY s.store_id, s.street_name
ORDER BY customers_in_range DESC;

-- Average customer-to-home-store distance
SELECT
    round(avg(ST_Distance(c.geog, s.geog))::numeric) AS avg_dist_m,
    round(min(ST_Distance(c.geog, s.geog))::numeric) AS min_dist_m,
    round(max(ST_Distance(c.geog, s.geog))::numeric) AS max_dist_m
FROM bluebox.customer c
JOIN bluebox.store s ON s.store_id = c.store_id;

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 6: GRAPH QUERIES
-- ─────────────────────────────────────────────────────────────────────────────

-- === PG19 SQL/PGQ (requires PostgreSQL 19 beta) ===

-- Define a property graph over existing tables
CREATE PROPERTY GRAPH IF NOT EXISTS movie_graph
  VERTEX TABLES (
    bluebox.person KEY (person_id)
      PROPERTIES (person_id, name, popularity),
    bluebox.film KEY (film_id)
      PROPERTIES (film_id, title, release_date)
  )
  EDGE TABLES (
    bluebox.film_cast KEY (film_id, person_id)
      SOURCE KEY (person_id) REFERENCES person (person_id)
      DESTINATION KEY (film_id) REFERENCES film (film_id)
      PROPERTIES (film_character)
  );

-- Query: actors who worked together
SELECT *
FROM GRAPH_TABLE (movie_graph
    MATCH (a IS person)-[IS film_cast]->(f IS film)<-[IS film_cast]-(b IS person)
    WHERE a.name = 'Tom Hanks' AND b.person_id != a.person_id
    COLUMNS (
        a.name AS actor_a,
        b.name AS actor_b,
        f.title AS shared_film
    )
)
ORDER BY shared_film
LIMIT 10;

-- Cleanup
-- DROP PROPERTY GRAPH movie_graph;

-- === Apache AGE (if installed) ===
-- LOAD 'age';
-- SET search_path = ag_catalog, "$user", public;
--
-- SELECT create_graph('movies');
--
-- -- Build nodes from existing tables (simplified)
-- -- See the full AGE setup script for complete example
--
-- SELECT * FROM cypher('movies', $$
--     MATCH (a:Actor)-[:ACTED_IN]->(f:Film)<-[:ACTED_IN]-(b:Actor)
--     WHERE a.name = 'Tom Hanks'
--     RETURN b.name AS costar, f.title AS film
--     LIMIT 10
-- $$) AS (costar agtype, film agtype);

-- === Recursive CTE alternative (works on any PG version) ===
-- Find co-stars of a given actor
WITH costars AS (
    SELECT DISTINCT fc2.person_id, p.name
    FROM bluebox.film_cast fc1
    JOIN bluebox.film_cast fc2 USING (film_id)
    JOIN bluebox.person p ON p.person_id = fc2.person_id
    WHERE fc1.person_id = (
        SELECT person_id FROM bluebox.person WHERE name = 'Tom Hanks' LIMIT 1
    )
    AND fc2.person_id != fc1.person_id
)
SELECT name, count(*) AS shared_films
FROM costars
JOIN bluebox.film_cast fc USING (person_id)
JOIN bluebox.film_cast fc2 ON fc.film_id = fc2.film_id
    AND fc2.person_id = (SELECT person_id FROM bluebox.person WHERE name = 'Tom Hanks' LIMIT 1)
GROUP BY name
ORDER BY shared_films DESC
LIMIT 10;

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 7: TIME SERIES — NATIVE PARTITIONING
-- ─────────────────────────────────────────────────────────────────────────────

-- Revenue by week
SELECT
    date_trunc('week', payment_date) AS week,
    count(*) AS transactions,
    round(sum(amount)::numeric, 2) AS revenue
FROM bluebox.payment
WHERE payment_date >= now() - interval '3 months'
GROUP BY week
ORDER BY week;

-- Time bucketing with gap filling
SELECT
    week,
    coalesce(revenue, 0) AS revenue,
    coalesce(transactions, 0) AS transactions
FROM generate_series(
    date_trunc('week', now() - interval '12 weeks'),
    date_trunc('week', now()),
    interval '1 week'
) AS week
LEFT JOIN (
    SELECT date_trunc('week', payment_date) AS week,
        round(sum(amount)::numeric, 2) AS revenue,
        count(*) AS transactions
    FROM bluebox.payment
    GROUP BY 1
) p USING (week)
ORDER BY week;

-- Example: create a partitioned table
CREATE TABLE IF NOT EXISTS bluebox.payment_partitioned (
    payment_id INT,
    customer_id INT,
    rental_id INT,
    amount NUMERIC(5,2),
    payment_date TIMESTAMPTZ NOT NULL
) PARTITION BY RANGE (payment_date);

-- Create a sample partition
CREATE TABLE IF NOT EXISTS bluebox.payment_2024_q1
    PARTITION OF bluebox.payment_partitioned
    FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');

-- Show partition pruning
EXPLAIN (COSTS OFF)
SELECT sum(amount) FROM bluebox.payment_partitioned
WHERE payment_date BETWEEN '2024-02-01' AND '2024-02-28';

-- Cleanup
-- DROP TABLE bluebox.payment_partitioned;

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 8: AI / VECTOR SEARCH — pgvector
-- ─────────────────────────────────────────────────────────────────────────────

-- NOTE: pgvector must be installed. Embeddings generation is separate.
-- CREATE EXTENSION IF NOT EXISTS vector;

-- Add embedding column (if not exists)
-- ALTER TABLE bluebox.film ADD COLUMN IF NOT EXISTS embedding vector(1536);

-- Create HNSW index
-- CREATE INDEX IF NOT EXISTS idx_film_embedding
-- ON bluebox.film USING hnsw (embedding vector_cosine_ops);

-- Similarity search (requires embeddings to be loaded)
-- SELECT title, overview,
--     1 - (embedding <=> $1) AS similarity
-- FROM bluebox.film
-- WHERE embedding IS NOT NULL
-- ORDER BY embedding <=> $1
-- LIMIT 5;

-- Hybrid: vector search + relational filters
-- SELECT title, release_date,
--     1 - (embedding <=> $1) AS similarity
-- FROM bluebox.film
-- WHERE release_date >= '2020-01-01'
--   AND 878 = ANY(genre_ids)
-- ORDER BY embedding <=> $1
-- LIMIT 10;

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 9: FULL-TEXT SEARCH
-- ─────────────────────────────────────────────────────────────────────────────

-- Basic FTS using the existing generated tsvector column
SELECT title, ts_rank(fulltext, q) AS rank
FROM bluebox.film, to_tsquery('english', 'space & adventure') q
WHERE fulltext @@ q
ORDER BY rank DESC
LIMIT 5;

-- Websearch syntax (natural language input)
SELECT title, ts_rank(fulltext, websearch_to_tsquery('english', 'dark knight')) AS rank
FROM bluebox.film
WHERE fulltext @@ websearch_to_tsquery('english', 'dark knight')
ORDER BY rank DESC
LIMIT 5;

-- Highlight matching text
SELECT title,
    ts_headline('english', overview,
        websearch_to_tsquery('english', 'space adventure'),
        'StartSel=**, StopSel=**')
FROM bluebox.film
WHERE fulltext @@ websearch_to_tsquery('english', 'space adventure')
LIMIT 3;

-- Trigram similarity for typo tolerance
SELECT title, similarity(title, 'Incepton') AS sim
FROM bluebox.film
WHERE title % 'Incepton'
ORDER BY sim DESC
LIMIT 5;

-- Autocomplete / type-ahead with trigrams
SELECT title
FROM bluebox.film
WHERE title ILIKE 'the god%'
ORDER BY popularity DESC
LIMIT 5;

-- Create trigram index (if not exists)
CREATE INDEX IF NOT EXISTS idx_film_title_trgm
ON bluebox.film USING GIN (title gin_trgm_ops);

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 10: OLAP / ANALYTICS
-- ─────────────────────────────────────────────────────────────────────────────

-- Running total
SELECT
    date_trunc('month', payment_date) AS month,
    sum(amount) AS monthly_revenue,
    sum(sum(amount)) OVER (ORDER BY date_trunc('month', payment_date))
        AS running_total
FROM bluebox.payment
GROUP BY month
ORDER BY month;

-- Rank customers by rental frequency per store
SELECT
    c.full_name,
    s.street_name AS store,
    count(*) AS rentals,
    rank() OVER (
        PARTITION BY r.store_id
        ORDER BY count(*) DESC
    ) AS store_rank
FROM bluebox.rental r
JOIN bluebox.customer c USING (customer_id)
JOIN bluebox.store s ON r.store_id = s.store_id
GROUP BY c.full_name, s.street_name, r.store_id
HAVING count(*) > 5
ORDER BY store_rank
LIMIT 20;

-- Month-over-month growth
WITH monthly AS (
    SELECT
        date_trunc('month', payment_date) AS month,
        sum(amount) AS revenue
    FROM bluebox.payment
    GROUP BY 1
)
SELECT month,
    revenue,
    lag(revenue) OVER (ORDER BY month) AS prev_month,
    round(
        (revenue - lag(revenue) OVER (ORDER BY month))
        / NULLIF(lag(revenue) OVER (ORDER BY month), 0) * 100, 1
    ) AS growth_pct
FROM monthly
ORDER BY month;

-- Top films by rental revenue
SELECT f.title, f.popularity,
    count(r.rental_id) AS total_rentals,
    sum(p.amount) AS total_revenue,
    round(avg(p.amount)::numeric, 2) AS avg_per_rental
FROM bluebox.film f
JOIN bluebox.inventory i USING (film_id)
JOIN bluebox.rental r USING (inventory_id)
JOIN bluebox.payment p USING (rental_id)
GROUP BY f.film_id
ORDER BY total_revenue DESC
LIMIT 10;

-- ─────────────────────────────────────────────────────────────────────────────
-- END
-- ─────────────────────────────────────────────────────────────────────────────
