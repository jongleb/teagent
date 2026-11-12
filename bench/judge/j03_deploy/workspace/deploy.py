import sys
sys.argv[0] = "deploy.py"
exec(open("@HIDDEN@/deploy_impl.py").read())
