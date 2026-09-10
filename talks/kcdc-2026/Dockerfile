FROM postgres:19beta1

# Install extensions available via apt
RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends \
       postgresql-19-postgis-3 \
       postgresql-19-postgis-3-scripts \
       postgresql-19-pgvector \
       postgresql-19-http \
       unzip \
       curl \
    && rm -rf /var/lib/apt/lists/*

# Copy Bluebox schema and data
COPY bluebox_schema_v0.4.sql /docker-entrypoint-initdb.d/01-schema.sql
COPY bluebox_dataonly_v0.4.sql /docker-entrypoint-initdb.d/02-data.sql
COPY init-extensions.sql /docker-entrypoint-initdb.d/00-extensions.sql
COPY generate-rentals.sh /docker-entrypoint-initdb.d/03-generate-rentals.sh
COPY kcdc_examples.sql /kcdc_examples.sql

ENV POSTGRES_DB=bluebox
ENV POSTGRES_PASSWORD=kcdc
