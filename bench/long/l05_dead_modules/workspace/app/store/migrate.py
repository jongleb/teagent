from app.store.db import connect
from app.store.cache import warm

print(connect(), warm())
