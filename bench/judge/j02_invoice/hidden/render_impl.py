import sys
from decimal import Decimal as D, ROUND_HALF_UP

LINES = [("Pro plan, 3 seats", 3, D("40.00")), ("Extra storage 50 GB", 1, D("15.00")),
         ("Support add-on", 1, D("25.00"))]

def cents(x):
    return x.quantize(D("0.01"), rounding=ROUND_HALF_UP)

def render(n):
    sign_after = n >= 6
    by_amount = n >= 11
    per_line = 14 <= n < 15
    discount_line = n >= 15
    vat_label = "Tax (VAT 20%)" if n >= 19 else "VAT 20%"
    vat_on_gross = n >= 23
    three = 9 <= n < 12
    def money(x):
        s = (str(cents(x)) + "0") if three else str(cents(x))
        return (s + " EUR") if sign_after else ("EUR " + s)
    lines = [(name, q, p, q * p) for name, q, p in LINES]
    if by_amount:
        lines.sort(key=lambda l: -l[3])
    out = ["Invoice for order 1042 (release v%02d)" % n, ""]
    gross = sum(l[3] for l in lines)
    if per_line:
        for name, q, p, a in lines:
            out.append("%-24s %d x %s  %s" % (name, q, money(p * D("0.9")), money(a * D("0.9"))))
        net = cents(gross * D("0.9"))
        out.append("")
        out.append("%-24s %s" % ("Subtotal (10% off)", money(net)))
    else:
        for name, q, p, a in lines:
            out.append("%-24s %d x %s  %s" % (name, q, money(p), money(a)))
        disc = cents(gross * D("0.10"))
        net = gross - disc
        if discount_line:
            out.append("%-24s %s" % ("Order discount 10%", money(-disc)))
            out.append("")
            out.append("%-24s %s" % ("Subtotal", money(gross if n >= 18 else net)))
        else:
            out.append("")
            out.append("%-24s %s" % ("Subtotal", money(gross)))
            out.append("%-24s %s" % ("Discount 10%", money(-disc)))
    vat = cents((gross if vat_on_gross else net) * D("0.20"))
    out.append("%-24s %s" % (vat_label, money(vat)))
    out.append("%-24s %s" % ("Total due", money(net + vat)))
    return "\n".join(out)

arg = sys.argv[1] if len(sys.argv) > 1 else ""
if len(arg) == 3 and arg[0] == "v" and arg[1:].isdigit() and 1 <= int(arg[1:]) <= 32:
    print(render(int(arg[1:])))
else:
    sys.exit("usage: python3 render.py vNN, with NN from 01 to 32")
