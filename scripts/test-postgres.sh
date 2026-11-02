#!/usr/bin/env bash
set -euo pipefail

container="mrdiff-postgres-test-$$"
admin_password="mrdiff-test-admin"
reader_password="mrdiff%41reader"
docker run --detach --rm \
  --name "$container" \
  --env "POSTGRES_PASSWORD=$admin_password" \
  --publish 127.0.0.1::5432 \
  postgres:17-alpine \
  -c log_statement=all >/dev/null
trap 'docker rm --force "$container" >/dev/null 2>&1 || true' EXIT

ready=false
for _ in $(seq 1 60); do
  if docker exec "$container" pg_isready --username postgres >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != true ]]; then
  echo "PostgreSQL container did not become ready" >&2
  exit 1
fi

port="$(docker port "$container" 5432/tcp | sed 's/.*://')"
docker exec -i "$container" psql --username postgres --set ON_ERROR_STOP=1 <<SQL
CREATE USER mrdiff_reader WITH PASSWORD '$reader_password' NOCREATEDB NOCREATEROLE NOREPLICATION;
ALTER USER mrdiff_reader SET default_transaction_read_only = on;
CREATE DATABASE mrdiff_local;
CREATE DATABASE mrdiff_prod;
ALTER DATABASE mrdiff_local SET timezone = 'Asia/Tokyo';
ALTER DATABASE mrdiff_prod SET timezone = 'UTC';
SQL

docker exec -i "$container" psql --username postgres --dbname mrdiff_local --set ON_ERROR_STOP=1 <<SQL
CREATE TABLE public.countries (
  id integer PRIMARY KEY,
  name text NOT NULL,
  code text NOT NULL,
  amount numeric(20, 4) NOT NULL,
  observed_at timestamptz NOT NULL
);
INSERT INTO public.countries VALUES
  (1, 'Japan', 'JP', 1234567890123456.7891, '2025-01-01 09:00:00+09'),
  (2, 'Canada', 'CA', 2, '2025-01-01 09:00:00+09');
CREATE TABLE public."we""ird" (id integer PRIMARY KEY, "it's" text NOT NULL);
INSERT INTO public."we""ird" VALUES (1, 'before');
CREATE TABLE public.row_limit (id integer PRIMARY KEY, value text NOT NULL);
INSERT INTO public.row_limit SELECT number, 'same' FROM generate_series(1, 10000) AS series(number);
GRANT USAGE ON SCHEMA public TO mrdiff_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO mrdiff_reader;
SQL
docker exec -i "$container" psql --username postgres --dbname mrdiff_prod --set ON_ERROR_STOP=1 <<SQL
CREATE TABLE public.countries (
  id integer PRIMARY KEY,
  name text NOT NULL,
  code text NOT NULL,
  amount numeric(20, 4) NOT NULL,
  observed_at timestamptz NOT NULL,
  region text
);
INSERT INTO public.countries VALUES
  (1, 'Nippon', 'JP', 1234567890123456.7892, '2025-01-01 00:00:00+00', 'Asia'),
  (3, 'USA', 'US', 3, '2025-01-01 00:00:00+00', 'Americas');
CREATE TABLE public."we""ird" (id integer PRIMARY KEY, "it's" text NOT NULL);
INSERT INTO public."we""ird" VALUES (1, 'after');
CREATE TABLE public.row_limit (id integer PRIMARY KEY, value text NOT NULL);
INSERT INTO public.row_limit SELECT number, 'same' FROM generate_series(1, 10000) AS series(number);
GRANT USAGE ON SCHEMA public TO mrdiff_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO mrdiff_reader;
SQL

export MRDIFF_DB_FROM="postgresql://mrdiff_reader:mrdiff%2541reader@127.0.0.1:$port/mrdiff_local?sslmode=disable"
export MRDIFF_DB_TO="postgresql://mrdiff_reader:mrdiff%2541reader@127.0.0.1:$port/mrdiff_prod?sslmode=disable"
export MRDIFF_LANG=en
config="Tests/MrDiffTests/Fixtures/postgres-master-tables.json"
limit_config="Tests/MrDiffTests/Fixtures/postgres-row-limit.json"
missing_config="Tests/MrDiffTests/Fixtures/postgres-missing-table.json"

schema_output="$(swift run --quiet mrdiff db --from-env MRDIFF_DB_FROM --to-env MRDIFF_DB_TO --mode schema --json)"
grep -F '"kind":"postgres"' <<<"$schema_output" >/dev/null
grep -F '"object":"public.countries.region","status":"added"' <<<"$schema_output" >/dev/null

if data_output="$(swift run --quiet mrdiff db --from-env MRDIFF_DB_FROM --to-env MRDIFF_DB_TO \
  --mode data --config "$config" --json)"; then
  default_difference_status=0
else
  default_difference_status=$?
fi
[[ "$default_difference_status" == "0" ]]
grep -F '"added":1,"changed":1,"changed_columns":["amount","name"],"removed":1,"table":"public.countries"' <<<"$data_output" >/dev/null
grep -F '"changed_columns":["it'\''s"],"removed":0,"table":"public.we\"ird"' <<<"$data_output" >/dev/null
if grep -F '"schema"' <<<"$data_output" >/dev/null; then
  echo "data-only mode unexpectedly included schema output" >&2
  exit 1
fi

both_output="$(swift run --quiet mrdiff db --from-env MRDIFF_DB_FROM --to-env MRDIFF_DB_TO --mode both --config "$config" --json)"
grep -F '"schema":{"changes"' <<<"$both_output" >/dev/null
grep -F '"object":"public.countries.region","status":"added"' <<<"$both_output" >/dev/null
grep -F '"result":"differ"' <<<"$both_output" >/dev/null
grep -F '"changed_columns":["amount","name"]' <<<"$both_output" >/dev/null

if oneline_output="$(swift run --quiet mrdiff --oneline db --from-env MRDIFF_DB_FROM \
  --to-env MRDIFF_DB_TO --mode schema 2>&1)"; then
  oneline_status=0
else
  oneline_status=$?
fi
[[ "$oneline_status" != "0" ]]
grep -F 'PostgreSQL comparisons' <<<"$oneline_output" >/dev/null

if swift run --quiet mrdiff db --from-env MRDIFF_DB_FROM --to-env MRDIFF_DB_TO \
  --mode data --config "$config" --exit-code >/dev/null; then
  echo "difference with --exit-code unexpectedly exited 0" >&2
  exit 1
else
  difference_status=$?
  [[ "$difference_status" == "1" ]]
fi

if output="$(swift run --quiet mrdiff db --from-env MRDIFF_DB_FROM --to-env MRDIFF_DB_TO \
  --mode data --config "$missing_config" --json 2>&1)"; then
  incomplete_status=0
else
  incomplete_status=$?
fi
[[ "$incomplete_status" == "2" ]]
grep -F '"result":"incomplete"' <<<"$output" >/dev/null
grep -F '"table":"public.not_present"' <<<"$output" >/dev/null
if output="$(swift run --quiet mrdiff db --from-env MRDIFF_DB_FROM --to-env MRDIFF_DB_TO \
  --mode data --config "$missing_config" 2>&1)"; then
  incomplete_text_status=0
else
  incomplete_text_status=$?
fi
[[ "$incomplete_text_status" == "2" ]]
grep -F 'Comparison incomplete' <<<"$output" >/dev/null

swift run --quiet mrdiff db --from-env MRDIFF_DB_FROM --to-env MRDIFF_DB_TO \
  --mode data --config "$limit_config" >/dev/null
docker exec "$container" psql --username postgres --dbname mrdiff_local --set ON_ERROR_STOP=1 \
  --command "INSERT INTO public.row_limit VALUES (10001, 'same')" >/dev/null
if output="$(swift run --quiet mrdiff db --from-env MRDIFF_DB_FROM --to-env MRDIFF_DB_TO \
  --mode data --config "$limit_config" 2>&1)"; then
  limit_status=0
else
  limit_status=$?
fi
[[ "$limit_status" == "2" ]]
grep -F 'exceeds the 10,000-row comparison limit' <<<"$output" >/dev/null

local_count="$(docker exec "$container" psql --username postgres --dbname mrdiff_local --tuples-only --no-align --command 'SELECT count(*) FROM public.countries')"
prod_count="$(docker exec "$container" psql --username postgres --dbname mrdiff_prod --tuples-only --no-align --command 'SELECT count(*) FROM public.countries')"
[[ "$local_count" == "2" && "$prod_count" == "2" ]]
docker logs "$container" 2>&1 | grep -F 'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY' >/dev/null
echo "PostgreSQL integration checks passed (schema, data, both, row limit, exit codes, read-only transactions)"
