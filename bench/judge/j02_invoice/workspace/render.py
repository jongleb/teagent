import sys
sys.argv[0] = "render.py"
exec(open("@HIDDEN@/render_impl.py").read())
