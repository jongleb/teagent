def money(amount):
    return "{:.1f}".format(amount)


def row(name, quantity, amount):
    return "{:<10}{:>5}{:>10}".format(name, quantity, money(amount))
