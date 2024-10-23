#!/usr/bin/env sh

# environment variables

CHAT_TERMINAL_SERVER_URL="http://localhost:16099"  # url of the chat-terminal-server
CHAT_TERMINAL_ENDPOINT=  # text completion endpoint, default is what specified in the server config file
CHAT_TERMINAL_MODEL=  # text completion model if the endpoint supports setting the model, default is what specified in the server config file
CHAT_TERMINAL_USE_BLACKLIST=false  # use blacklist for command, true to execute command by default except those matching CHAT_TERMINAL_BLACKLIST_PATTERN
CHAT_TERMINAL_BLACKLIST_PATTERN="\b(rm|sudo)\b"  # pattern to confirm before execution; patterns are matched using `grep -E`; use with CHAT_TERMINAL_USE_BLACKLIST
CHAT_TERMINAL_USE_REPLY=true  # send the output of command to the server to get a reply
CHAT_TERMINAL_USE_STREAMING=true  # stream the output
CHAT_TERMINAL_USE_CLARIFICATION=true  # ask for clarification when refusing a command

# internal variables

_MESSAGE_PREFIX="%"
_conversation_id=


# handy functions

_print_response() {
  echo -E "$1> $2"
}

_advance_read() {
  if [[ -n $BASH_VERSION ]]; then
    read -e "$@"
  elif [[ -n $ZSH_VERSION ]]; then
    vared -h -e "$@"
  else
    read "$@"
  fi
}

# APIs

_get_os_version() {
  if [ -f /etc/os-release ]; then
    # Linux
    echo $(. /etc/os-release && echo "$NAME $VERSION")
  elif command -v sw_vers >/dev/null 2>&1; then
    # macOS
    sw_vers | awk -F': ' '/ProductName|ProductVersion/ { printf "%s ", $2 }'
  elif [ "$(uname)" = "FreeBSD" ]; then
    # FreeBSD
    uname -rms
  elif [ "$(uname)" = "SunOS" ]; then
    # Solaris/Illumos
    cat /etc/release
  else
    # fallback
    echo Unix
  fi
}

_get_env() {
  local shell_name="${SHELL##*/}"
  local os_version=$(_get_os_version | tr -s '\n' ' ' | xargs)

  echo "{ \
    \"os\": \"$os_version\", \
    \"shell\": \"$shell_name\" \
  }"
}

_curl_server() {
  local url="$1"
  local data="$2"
  local data_memfile=
  local data_source="$data"
  local ret_code=0

  if [[ ${#data} -gt 10240 ]]; then
    # dump data to memory file to avoid overwhelming argument list
    data_memfile="$(mktemp /dev/shm/chat-terminal-curl-XXXXXX)"
    echo -nE "$data" >$data_memfile
    data_source="@""$data_memfile"
  fi

  curl -s --no-buffer \
    -X POST "${CHAT_TERMINAL_SERVER_URL}${url}" \
    -H "Content-Type: application/json" \
    -d "$data_source"
  ret_code=$?

  if [[ -n $data_memfile ]]; then
    rm $data_memfile
  fi

  return $ret_code
}

_init_conversation() {
  local data="{"
  if [[ -n "$CHAT_TERMINAL_ENDPOINT" ]]; then
    data+="\"endpoint\": \"$CHAT_TERMINAL_ENDPOINT\""
  fi
  if [[ -n "$CHAT_TERMINAL_MODEL" ]]; then
    data+="\"model_name\": \"$CHAT_TERMINAL_MODEL\""
  fi
  data+="}"

  _curl_server "/chat/${_conversation_id}/init" "$data"
}

_query_command() {
  local query="$1"
  local data="{ \
    \"message\": \"$query\", \
    \"stream\": $CHAT_TERMINAL_USE_STREAMING, \
    \"env\": $(_get_env)
  }"

  _curl_server "/chat/${_conversation_id}/query_command" "$data"
  return $?
}

_query_reply() {
  local executed="$1"
  local observation="$2"
  local data

  observation=$(echo -ne "$observation" | python3 -c "import sys, json; print(json.dumps(sys.stdin.read()))")

  data="{ \
    \"command_executed\": $executed, \
    \"message\": $(echo -E "$observation"), \
    \"stream\": $CHAT_TERMINAL_USE_STREAMING, \
    \"env\": $(_get_env)
  }"

  _curl_server "/chat/${_conversation_id}/query_reply" "$data"
  return $?
}

# core functions

_parse_error_from_result() {
  local result="$1"
  local error

  if [[ -z "$result" ]]; then
    error="server not online"
  else
    error=$(echo -E "$result" | jq '.error')
    if [[ "$error" == null ]]; then
      error=$result
    else
      error=$(echo -E "$error" | jq -r .)
    fi
  fi

  echo "$error"
}

_confirm_command_execution() {
  echo -n $_MESSAGE_PREFIX "Execute the command? (y/[N]) "
  if [[ -n "$BASH_VERSION" ]]; then
    read -n 1 choice
  elif [[ -n "$ZSH_VERSION" ]]; then
    read -k 1 choice
  else
    read choice
  fi
  echo

  if [[ "$choice" == 'y' || "$choice" == 'Y' ]]; then
    return 0
  else
    return 1
  fi
}

_process_response_stream() {
  local section_prompt="$1"
  local section_name="$2"
  local var_name="$3"
  local res=
  local hint_printed=false

  local first_error_result=
  local error=
  local section=
  local finished=
  local content=

  # process our stream
  while read -r line; do
    if [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*= ]]; then
      # pass on end results
      # normally end results won't appear here
      # but when an error occurs, they will show up here
      echo -E "$line" >&1
      continue
    fi

    error=$(echo -E "$line" | jq '.error')  # could be null, keep the string quoted
    section=$(echo -E "$line" | jq -r '.section')
    finished=$(echo -E "$line" | jq -r '.finished')
    IFS= read -rd '' content < <(echo -E "$line" | jq -r '.content')  # workaround for subshell trailing newlines trimming issue
    content=${content%$'\n'}

    if [[ "$error" != null ]]; then
      if [[ -z "$first_error_result" ]]; then
       first_error_result="$line"
      fi

      continue  # consume the reminding streams
    fi

    if [[ "$section" != "$section_name" ]]; then
      # pass on other streams
      echo -E "$line" >&1
      continue
    fi

    if ! $hint_printed; then
      # remove leading spaces and newlines
      IFS= read -rd '' content < <(echo -nE "$content" | sed 's/^[[:space:]]*//')
      IFS= read -rd '' content < <(echo -ne "$content" | sed '1,/[^[:space:]]/{/^$/d}')

      if [[ -z "$content" ]]; then
        if $finished; then
          echo $_MESSAGE_PREFIX "No command provided" >&3
          break
        fi
        continue
      fi

      echo -n "${section_prompt}> " >&3
      hint_printed=true
    fi

    res+="$content"
    echo -ne "$content" >&3

    if $finished; then
      break
    fi
  done
  if $hint_printed && [[ ! "$res" =~ $'\n'$ ]]; then
    echo >&3
  fi

  # pass on other streams
  while read -r line; do
    echo -E "$line" >&1
  done

  if [[ -n "$first_error_result" ]]; then
    # pass on errors
    echo -E "error=$first_error_result" >&1
    return 1
  fi

  # streams are all processed, now print the values
  # this will be preserved to the end result
  # this is a workaround for unsafe eval
  echo -E "$var_name=$res" >&1
}

_query_and_process_command() {
  local ret_code=0

  _query_command "$@" | \
    _process_response_stream "Thought" 'thinking' thinking | \
    _process_response_stream "Command" 'command' _command

  if [[ -n $BASH_VERSION ]]; then
    ret_code=${PIPESTATUS[0]}
  elif [[ -n $ZSH_VERSION ]]; then
    ret_code=${pipestatus[1]}
  fi

  return $ret_code
}

_query_and_process_reply() {
  local ret_code=0

  _query_reply "$@" | \
    _process_response_stream "Reply" 'reply' reply

  if [[ -n $BASH_VERSION ]]; then
    ret_code=${PIPESTATUS[0]}
  elif [[ -n $ZSH_VERSION ]]; then
    ret_code=${pipestatus[1]}
  fi

  return $ret_code
}

_chat_once() {
  local query=$1
  local result
  local thinking
  local _command
  local reply
  local exec_command
  local observation
  local line
  local end_result
  local ret_code
  local error

  if ! $CHAT_TERMINAL_USE_STREAMING; then
    result=$(_query_command "$query")
    _status=$(echo -E "$result" | jq -r ".status")
    if [[ $_status != "success" ]]; then
      error=$(_parse_error_from_result "$result")
      echo $_MESSAGE_PREFIX "Failed to generate command: $error"
      return 1
    fi

    thinking=$(echo -E "$result" | jq -r '.payload.thinking')
    _command=$(echo -E "$result" | jq -r '.payload.command')
    if [[ -n $thinking ]]; then
      _print_response "Thought" "$thinking"
    fi
    _print_response "Command" "$_command"
  else
    exec 3>&1
    end_result=$(_query_and_process_command "$query")
    ret_code=$?
    exec 3>&-

    if [[ $ret_code -ne 0 ]]; then
      error="server not online"
    else
      error=$(echo -E "$end_result" | grep "^error=" | sed 's/^error=//')
      if [[ -n "$error" ]]; then
        error=$(_parse_error_from_result "$error")
      fi
    fi

    if [[ -n "$error" ]]; then
      echo $_MESSAGE_PREFIX "Failed to query command: ${error}"
      return 1
    fi

    thinking=$(echo -E "$end_result" | grep "^thinking=" | sed 's/^thinking=//')
    _command=$(echo -E "$end_result" | grep "^_command=" | sed 's/^_command=//')
    if [[ "$_command" =~ ^\` && "$_command" =~ \`$ ]]; then
      _command=${_command:1:-1}
    fi
  fi

  exec_command=false
  if [[ ${#_command} -gt 0 ]]; then
    if [[ "$CHAT_TERMINAL_USE_BLACKLIST" == "true" ]]; then
      echo -E "$_command" | grep -qE "$CHAT_TERMINAL_BLACKLIST_PATTERN"
      if [[ $? -ne 0 ]]; then
        exec_command=true
      else
        _confirm_command_execution
        if [[ $? -eq 0 ]]; then
          exec_command=true
        fi
      fi
    else
      _confirm_command_execution
      if [[ $? -eq 0 ]]; then
        exec_command=true
      fi
    fi
  fi

  if $exec_command; then
    # workaround to avoid pipe and subshell to
    # ensure execution in current shell
    # use /dev/shm to avoid wearing the disk
    if $CHAT_TERMINAL_USE_REPLY; then
      memfile=$(mktemp /dev/shm/chat-terminal-XXXXXX)
      if [[ -n $BASH_VERSION ]]; then
        { tail -n +1 -f $memfile & } 2>/dev/null
      elif [[ -n $ZSH_VERSION ]]; then
        (tail -n +1 -f $memfile ) &!
      else
        (tail -n +1 -f $memfile) &
      fi
      display_job=$!
    fi

    if [[ -n $BASH_VERSION ]]; then
      history -s "$_command"
    elif [[ -n $ZSH_VERSION ]]; then
      print -s "$_command"
    else
      history -s "$_command"
    fi

    if $CHAT_TERMINAL_USE_REPLY; then
      eval "$_command" 1>$memfile 2>&1
    else
      eval "$_command"
    fi

    if $CHAT_TERMINAL_USE_REPLY; then
      sleep 1  # wait for tail to display all contents
      if [[ -n $BASH_VERSION ]]; then
        { kill $display_job && wait $display_job; } 2>/dev/null
      elif [[ -n $ZSH_VERSION ]]; then
        kill $display_job
      fi
      observation=$(cat $memfile)
      rm $memfile
    fi

    echo $_MESSAGE_PREFIX "Command finished"
  fi

  if $CHAT_TERMINAL_USE_REPLY; then
    if $CHAT_TERMINAL_USE_CLARIFICATION && ! $exec_command && [[ ${#_command} -gt 0 ]]; then
      _advance_read -p "Clarification: " observation
    fi

    if ! $CHAT_TERMINAL_USE_STREAMING; then
      result=$(_query_reply "$exec_command" "$observation")
      _status=$(echo -E "$result" | jq -r ".status")
      if [[ $_status != "success" ]]; then
        error=$(_parse_error_from_result "$result")
        echo $_MESSAGE_PREFIX "Failed to generate reply: $result"
        return 1
      fi

      reply=$(echo -E "$result" | jq -r '.payload.reply')
      _print_response "Reply" "$reply"
    else
      exec 3>&1
      end_result=$(_query_and_process_reply "$exec_command" "$observation")
      ret_code=$?
      exec 3>&-

      if [[ $ret_code -ne 0 ]]; then
        error="server not online"
      else
        error=$(echo -E "$end_result" | grep "^error=" | sed 's/^error=//')
        if [[ -n "$error" ]]; then
          error=$(_parse_error_from_result "$error")
        fi
      fi

      if [[ -n "$error" ]]; then
        echo $_MESSAGE_PREFIX "Failed to query reply: ${error}"
        return 1
      fi

      reply=$(echo -E "$end_result" | grep "^reply=" | sed 's/^reply=//')
    fi
  fi
}

chat-terminal-reset() {
  _conversation_id=
}

chat-terminal() {
  local query="$@"
  local result
  local _status
  local error
  local ret_code

  if [[ -z "$_conversation_id" ]]; then
    if [[ -n "$CHAT_TERMINAL_ENDPOINT" ]]; then
      echo $_MESSAGE_PREFIX "Using endpoint: $CHAT_TERMINAL_ENDPOINT"
    fi

    # generate a UUID as conversation ID
    _conversation_id=$(uuidgen)
    result=$(_init_conversation)
    _status=$(echo -E "$result" | jq -r ".status")
    if [[ $_status != "success" ]]; then
      error=$(_parse_error_from_result "$result")
      echo $_MESSAGE_PREFIX "Failed to initialize converstaion: ${error}"
      _conversation_id=
      return 1
    fi
    echo $_MESSAGE_PREFIX "Initialized conversation: $_conversation_id"
  fi

  if [[ -n "$query" ]]; then
    _chat_once "$query"
  else
    while true; do
      query=  # clear variable
      _advance_read -p "> " query
      if [[ $? -eq 1 ]]; then
        # EOF
        break
      fi
      if [[ -n $query ]]; then
        _chat_once "$query"
        ret_code=$?
        if [[ $ret_code -ne 0 ]]; then
          return $ret_code
        fi
      fi
    done
  fi
}
