-- Ejecutado por scripts/db-set-role-passwords.sh con -v api_pw=... -v worker_pw=... (interpolación segura de psql).
alter role premortem_api    with login password :'api_pw';
alter role premortem_worker with login password :'worker_pw';
