import sys
sys.argv[0] = "gate.py"
exec(open("@HIDDEN@/gate_impl.py").read())
