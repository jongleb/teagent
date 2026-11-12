from inv.fmt import money, row


def report(inventory):
    items = sorted(inventory.items.values(), key=lambda item: item.name, reverse=True)
    lines = [row(item.name, item.quantity, item.total()) for item in items]
    lines.append("total " + money(inventory.value()))
    return "\n".join(lines)
