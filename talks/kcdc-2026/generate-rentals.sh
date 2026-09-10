#!/bin/bash
set -e

echo "Running ANALYZE to populate table statistics..."
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "ANALYZE bluebox.customer; ANALYZE bluebox.film; ANALYZE bluebox.inventory; ANALYZE bluebox.store; ANALYZE bluebox.rental;"

echo "Generating rental history for 2024-Q1 (this takes ~60 seconds)..."
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CALL bluebox.generate_rental_history('2024-01-01'::timestamptz, '2024-03-31'::timestamptz);"

echo "Running final ANALYZE..."
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "ANALYZE;"

echo "Rental generation complete."
