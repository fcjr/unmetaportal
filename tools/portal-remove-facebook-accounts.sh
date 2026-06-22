#!/system/bin/sh
# Remove Facebook Portal account records via AccountManager as the Facebook
# authenticator UID. This avoids direct SQLite edits.
set -eu

PACKAGE=com.facebook.alohaservices.alohausers
STATUS_FILE=/data/local/tmp/portal-remove-facebook-accounts-status
OUT_FILE=/data/local/tmp/portal-remove-facebook-accounts-out
PAYLOAD=/data/local/tmp/portal-remove-facebook-accounts-payload.sh
TRIGGER_PACKAGE=com.android.settings
PACKAGE_LIST=$(pm list packages -U)
UID_LINE=$(echo "$PACKAGE_LIST" | sed -n "s/^package:$PACKAGE uid://p")

test -n "$UID_LINE" || {
  echo "Could not find UID for $PACKAGE" >&2
  exit 1
}

rm -f "$STATUS_FILE" "$OUT_FILE" "$PAYLOAD"
touch "$STATUS_FILE" "$OUT_FILE"
chmod a+w "$STATUS_FILE" "$OUT_FILE"

cat >"$PAYLOAD" <<PAYLOAD_HEAD
#!/system/bin/sh
{
  echo "== payload id =="
  id
  echo "== remove calls =="
PAYLOAD_HEAD

dumpsys account |
  sed -n 's/^    Account {name=\([^,]*\), type=\(com\.facebook\.aloha\.[^}]*\)}$/\1|\2/p' |
  while IFS='|' read -r name type; do
    printf "  service call account 14 i32 1 s16 '%s' s16 '%s'\n" "$name" "$type" >>"$PAYLOAD"
  done

cat >>"$PAYLOAD" <<'PAYLOAD_TAIL'
} > /data/local/tmp/portal-remove-facebook-accounts-out 2>&1
echo done > /data/local/tmp/portal-remove-facebook-accounts-status
PAYLOAD_TAIL
chmod a+rx "$PAYLOAD"

settings put global hidden_api_blacklist_exemptions "
7
--runtime-args
--setuid=$UID_LINE
--setgid=$UID_LINE
--runtime-flags=1
--seinfo=default
--invoke-with
f() { /system/bin/sh $PAYLOAD; }; f"

am force-stop "$TRIGGER_PACKAGE" >/dev/null 2>&1 || true
am start -n "$TRIGGER_PACKAGE/.Settings" >/dev/null 2>&1 || true
sleep 2
settings delete global hidden_api_blacklist_exemptions >/dev/null 2>&1 || true

echo "UID=$UID_LINE"
echo "STATUS=$(cat "$STATUS_FILE" 2>/dev/null)"
echo "----- OUTPUT -----"
cat "$OUT_FILE" 2>/dev/null

test "$(cat "$STATUS_FILE" 2>/dev/null)" = "done"
