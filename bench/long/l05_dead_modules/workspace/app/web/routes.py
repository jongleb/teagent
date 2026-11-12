from app.web.views import home, orders

ROUTES = {"/": home.render, "/orders": orders.render}
