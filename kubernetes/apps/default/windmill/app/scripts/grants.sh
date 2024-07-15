#!/usr/bin/env bash

export INIT_POSTGRES_SUPER_USER=${INIT_POSTGRES_SUPER_USER:-postgres}
export INIT_POSTGRES_PORT=${INIT_POSTGRES_PORT:-5432}

if [[ -z "${INIT_POSTGRES_HOST}"       ||
      -z "${INIT_POSTGRES_SUPER_PASS}" ||
      -z "${INIT_POSTGRES_USER}"       ||
      -z "${INIT_POSTGRES_PASS}"       ||
      -z "${INIT_POSTGRES_DBNAME}"
]]; then
    printf "\e[1;32m%-6s\e[m\n" "Invalid configuration - missing a required environment variable"
    [[ -z "${INIT_POSTGRES_HOST}" ]]       && printf "\e[1;32m%-6s\e[m\n" "INIT_POSTGRES_HOST: unset"
    [[ -z "${INIT_POSTGRES_SUPER_PASS}" ]] && printf "\e[1;32m%-6s\e[m\n" "INIT_POSTGRES_SUPER_PASS: unset"
    [[ -z "${INIT_POSTGRES_USER}" ]]       && printf "\e[1;32m%-6s\e[m\n" "INIT_POSTGRES_USER: unset"
    [[ -z "${INIT_POSTGRES_PASS}" ]]       && printf "\e[1;32m%-6s\e[m\n" "INIT_POSTGRES_PASS: unset"
    [[ -z "${INIT_POSTGRES_DBNAME}" ]]     && printf "\e[1;32m%-6s\e[m\n" "INIT_POSTGRES_DBNAME: unset"
    exit 1
fi

# These env are for the psql CLI
export PGHOST="${INIT_POSTGRES_HOST}"
export PGUSER="${INIT_POSTGRES_SUPER_USER}"
export PGPASSWORD="${INIT_POSTGRES_SUPER_PASS}"
export PGPORT="${INIT_POSTGRES_PORT}"

until pg_isready; do
    printf "\e[1;32m%-6s\e[m\n" "Waiting for Host '${PGHOST}' on port '${PGPORT}' ..."
    sleep 1
done

for dbname in ${INIT_POSTGRES_DBNAME}; do
    printf "\e[1;32m%-6s\e[m\n" "Update User Privileges on Database ..."
    psql --dbname ${dbname} -c "
        DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'windmill_user') THEN
            CREATE ROLE windmill_user;
        END IF;
    END
    \$\$;

    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'windmill_admin') THEN
            CREATE ROLE windmill_admin WITH BYPASSRLS;
        END IF;
    END
    \$\$;

    GRANT ALL ON ALL TABLES IN SCHEMA public TO windmill_user;
    GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO windmill_user;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO windmill_user;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO windmill_user;
    GRANT windmill_user TO windmill_admin;
    GRANT windmill_admin TO ${INIT_POSTGRES_USER};
    GRANT windmill_user TO ${INIT_POSTGRES_USER};
    GRANT USAGE ON SCHEMA public TO windmill_admin;
    GRANT USAGE ON SCHEMA public TO windmill_user;"
done
