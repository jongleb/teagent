#!/bin/sh
cd "$1" || exit 1
want='app/__init__.py
app/settings.py
app/store/__init__.py
app/store/db.py
app/store/orders.py
app/store/users.py
app/web/__init__.py
app/web/auth.py
app/web/middleware.py
app/web/routes.py
app/web/server.py
app/web/views/__init__.py
app/web/views/home.py
app/web/views/orders.py'
got=$(find app -name '*.py' | sort)
[ "$got" = "$want" ] || { printf 'files under app/:\n%s\n' "$got"; exit 1; }
for f in $want main.py; do cmp -s "$f" "$2/workspace/$f" || { echo "$f changed"; exit 1; }; done
python3 main.py >/dev/null || exit 1
echo ok
