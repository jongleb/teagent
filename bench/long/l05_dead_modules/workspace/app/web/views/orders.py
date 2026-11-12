import app.store.orders as store


def render():
    return str(store.all_orders())
