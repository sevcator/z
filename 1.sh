#!/bin/sh
## SMS web interface on port 1118
## Minimal English UI, no URL token, SMS list/clear, USSD/call, UTF-16BE hex decode attempt

SMS_PORT="1118"

SMS_WEB_DIR="/tmp/sms_www"
SMS_CGI_DIR="/tmp/sms_www/cgi-bin"
SMS_CGI="/tmp/sms_www/cgi-bin/sms"
SMS_DEBUG_LOG="/tmp/sms_web_debug.log"
SMS_ACTION_RESULT="/tmp/sms_action_result"
SMS_IPTABLES_LOG="/tmp/sms_iptables_error.log"

log_sms_web() {
  if command -v logger >/dev/null 2>&1; then
    logger -t sms-web "$1"
  fi
  echo "`date '+%Y-%m-%d %H:%M:%S'` $1" >> "$SMS_DEBUG_LOG"
}

open_sms_port() {
  PORT="$1"

  if ! command -v iptables >/dev/null 2>&1; then
    log_sms_web "iptables not found"
    return
  fi

  while iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; do
    :
  done

  iptables -I INPUT 1 -p tcp --dport "$PORT" -j ACCEPT 2>>"$SMS_IPTABLES_LOG"

  if [ $? -eq 0 ]; then
    log_sms_web "firewall opened tcp port $PORT"
  else
    log_sms_web "firewall open failed for tcp port $PORT"
  fi
}

keep_sms_port_open() {
  while true; do
    open_sms_port "$SMS_PORT"

    netstat -ltn 2>/dev/null | grep ":$SMS_PORT " | while read line; do
      log_sms_web "listen: $line"
    done

    sleep 30
  done
}

log_sms_web "startup script started"

mkdir -p "$SMS_CGI_DIR"

cat > "$SMS_CGI" <<'EOF'
#!/bin/sh

DEBUG_LOG="/tmp/sms_web_debug.log"
ACTION_RESULT="/tmp/sms_action_result"

now() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_debug() {
  MSG="ip=${REMOTE_ADDR:-unknown} method=${REQUEST_METHOD:-unknown} $1"
  if command -v logger >/dev/null 2>&1; then
    logger -t sms-web "$MSG"
  fi
  echo "[$(now)] $MSG" >> "$DEBUG_LOG"
}

html_escape() {
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

url_decode() {
  printf "%b" "`printf '%s' "$1" | sed 's/+/ /g; s/%/\\\\x/g'`"
}

get_param() {
  NAME="$1"
  printf '%s' "$BODY" | tr '&' '\n' | sed -n "s/^$NAME=//p" | head -n 1 | while read V; do url_decode "$V"; done
}

utf16be_hex_to_html() {
  H=`printf '%s' "$1" | tr -d ' \r\n\t'`

  case "$H" in
    FEFF*|feff*)
      ;;
    *)
      return 1
      ;;
  esac

  echo "$H" | grep -q '^[0-9A-Fa-f][0-9A-Fa-f]*$' || return 1

  L=`printf '%s' "$H" | awk '{print length($0)}'`
  R=`expr "$L" % 4`

  if [ "$R" != "0" ]; then
    return 1
  fi

  printf '%s' "$H" | awk '
  {
    h=$0
    for (i=1; i<=length(h); i+=4) {
      c=substr(h,i,4)
      if (c=="FEFF" || c=="feff" || c=="0000") {
        continue
      }
      printf "&#x%s;", c
    }
  }'
}

print_decoded_if_possible() {
  TEXT="$1"

  DECODED=`utf16be_hex_to_html "$TEXT" 2>/dev/null`

  if [ -n "$DECODED" ]; then
    echo "<div><b>Decoded UTF-16BE:</b></div>"
    echo "<pre>$DECODED</pre>"
  fi
}

safe_ussd() {
  T="$1"

  if [ -z "$T" ]; then
    return 1
  fi

  echo "$T" | grep -q '^[0-9*#+]*$'
}

safe_call() {
  T="$1"

  if [ -z "$T" ]; then
    return 1
  fi

  echo "$T" | grep -q '^[0-9+]*$'
}

run_ussd() {
  CODE="$1"

  echo "[$(now)] USSD: $CODE" > "$ACTION_RESULT"

  if ! safe_ussd "$CODE"; then
    echo "Invalid USSD code" >> "$ACTION_RESULT"
    return
  fi

  if command -v microcom >/dev/null 2>&1; then
    echo "Command: microcom (AT+CUSD)" >> "$ACTION_RESULT"
    {
      echo "AT+CUSD=1,\"$CODE\",15"
      sleep 3
    } | microcom -t 5000 /dev/ttyUSB2 >> "$ACTION_RESULT" 2>&1
    return
  fi

  echo "No supported USSD command found: microcom" >> "$ACTION_RESULT"
}

run_call() {
  NUMBER="$1"

  echo "[$(now)] CALL: $NUMBER" > "$ACTION_RESULT"

  if ! safe_call "$NUMBER"; then
    echo "Invalid phone number" >> "$ACTION_RESULT"
    return
  fi

  if command -v microcom >/dev/null 2>&1; then
    echo "Command: microcom (ATD)" >> "$ACTION_RESULT"
    {
      echo "ATD$NUMBER;"
      sleep 2
    } | microcom -t 3000 /dev/ttyUSB2 >> "$ACTION_RESULT" 2>&1
    return
  fi

  echo "No supported call command found: microcom" >> "$ACTION_RESULT"
}

STATUS=""

if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
  LEN="${CONTENT_LENGTH:-0}"
  BODY=`dd bs=1 count="$LEN" 2>/dev/null`

  log_debug "post body=$BODY"

  ACTION=`get_param action`
  TARGET=`get_param target`

  case "$ACTION" in
    clear)
      DELETED=0

      for i in `sms list 2>/dev/null`; do
        sms delete "$i" 2>/dev/null
        DELETED=`expr "$DELETED" + 1`
      done

      STATUS="Deleted SMS: $DELETED"
      echo "[$(now)] $STATUS" > "$ACTION_RESULT"
      log_debug "$STATUS"
      ;;
    ussd)
      run_ussd "$TARGET"
      STATUS=`tail -n 1 "$ACTION_RESULT" 2>/dev/null`
      [ -n "$STATUS" ] || STATUS="USSD request processed"
      log_debug "ussd target=$TARGET"
      ;;
    call)
      run_call "$TARGET"
      STATUS="Call command sent"
      log_debug "call target=$TARGET"
      ;;
  esac
fi

log_debug "render page"

echo "Content-Type: text/html; charset=utf-8"
echo ""

cat <<HTML
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>SMS</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
body { font-family: Arial, sans-serif; margin: 16px; color: #111; }
input { padding: 6px; width: 220px; }
button { padding: 6px 10px; margin: 2px; }
pre { white-space: pre-wrap; word-break: break-word; border: 1px solid #ddd; padding: 8px; }
.box { border: 1px solid #ddd; padding: 10px; margin: 8px 0; }
.small { color: #666; font-size: 12px; }
</style>
</head>
<body>
<h3>Router SMS</h3>
<div class="small">Time: $(now)</div>
HTML

if [ -n "$STATUS" ]; then
  echo "<p><b>$STATUS</b></p>"
fi

cat <<HTML
<div class="box">
<form method="post">
<input name="target" placeholder="USSD code or phone number">
<button name="action" value="ussd" type="submit">Run USSD</button>
<button name="action" value="call" type="submit">Call</button>
</form>
</div>

<div class="box">
<form method="post">
<button name="action" value="clear" type="submit">Clear SMS</button>
<a href="/cgi-bin/sms">Refresh</a>
</form>
</div>
HTML

if [ -f "$ACTION_RESULT" ]; then
  echo "<div class=\"box\"><b>Last action</b><pre>"
  cat "$ACTION_RESULT" 2>&1 | html_escape
  echo "</pre></div>"
fi

IDS=`sms list 2>/dev/null`

if [ -z "$IDS" ]; then
  echo "<div class=\"box\">No SMS</div>"
else
  for i in $IDS; do
    RAW=`sms read "$i" 2>&1`
    MSG_LINE=`printf '%s\n' "$RAW" | sed -n '4p'`

    echo "<div class=\"box\">"
    echo "<b>SMS ID: `printf '%s' "$i" | html_escape`</b>"
    echo "<pre>"
    printf '%s\n' "$RAW" | html_escape
    echo "</pre>"

    print_decoded_if_possible "$MSG_LINE"

    printf '%s\n' "$RAW" | while read L; do
      print_decoded_if_possible "$L"
    done

    echo "</div>"
  done
fi

cat <<HTML
</body>
</html>
HTML
EOF

chmod +x "$SMS_CGI"

log_sms_web "cgi script created at $SMS_CGI"

sleep 10

busybox httpd -p 0.0.0.0:$SMS_PORT -h "$SMS_WEB_DIR"

log_sms_web "busybox httpd started on port $SMS_PORT"

open_sms_port "$SMS_PORT"

keep_sms_port_open &
