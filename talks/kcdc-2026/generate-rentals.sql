-- Generate 3 months of rental and payment history for demos.
-- Runs after schema + data are loaded (03-generate-rentals.sql).

DO $$
BEGIN
    RAISE NOTICE 'Generating rental history for 2024-Q1...';
END $$;

CALL bluebox.generate_rental_history(
    '2024-01-01'::timestamptz,
    '2024-03-31'::timestamptz
);

ANALYZE;
