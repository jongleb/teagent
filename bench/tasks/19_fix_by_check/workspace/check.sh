if grep -q '^mode=strict$' app.conf; then
  echo "check passed"
  exit 0
else
  echo "check failed: app.conf must set mode=strict, found $(grep '^mode=' app.conf)"
  exit 1
fi
