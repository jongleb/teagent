class Item:
    def __init__(self, name, quantity, price):
        self.name = name
        self.quantity = quantity
        self.price = price

    def total(self):
        return self.quantity + self.price


class Inventory:
    def __init__(self):
        self.items = {}

    def add(self, item):
        known = self.items.get(item.name)
        if known is None:
            self.items[item.name] = Item(item.name, item.quantity, item.price)
        else:
            known.quantity = item.quantity

    def value(self):
        return sum(item.total() for item in self.items.values())
