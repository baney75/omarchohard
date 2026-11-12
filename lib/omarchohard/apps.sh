# shellcheck shell=bash
# The app registry. One line per app:
#   id|Name|launch URL|comment|categories|mime types (;)|URL schemes (;)

OH_APPS_TABLE='word|Word|https://word.cloud.microsoft/|Write documents with Microsoft Word|Office;WordProcessor;|application/vnd.openxmlformats-officedocument.wordprocessingml.document;application/msword;application/vnd.openxmlformats-officedocument.wordprocessingml.template;application/vnd.ms-word.document.macroEnabled.12;application/vnd.ms-word.template.macroEnabled.12;application/msword-template;application/rtf;application/vnd.oasis.opendocument.text|ms-word
excel|Excel|https://excel.cloud.microsoft/|Work with spreadsheets in Microsoft Excel|Office;Spreadsheet;|application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;application/vnd.ms-excel;application/vnd.openxmlformats-officedocument.spreadsheetml.template;application/vnd.ms-excel.sheet.macroEnabled.12;application/vnd.ms-excel.sheet.binary.macroEnabled.12;application/vnd.ms-excel.template.macroEnabled.12;application/vnd.oasis.opendocument.spreadsheet;text/csv|ms-excel
powerpoint|PowerPoint|https://powerpoint.cloud.microsoft/|Build presentations with Microsoft PowerPoint|Office;Presentation;|application/vnd.openxmlformats-officedocument.presentationml.presentation;application/vnd.ms-powerpoint;application/vnd.openxmlformats-officedocument.presentationml.slideshow;application/vnd.openxmlformats-officedocument.presentationml.template;application/vnd.ms-powerpoint.presentation.macroEnabled.12;application/vnd.ms-powerpoint.slideshow.macroEnabled.12;application/vnd.ms-powerpoint.template.macroEnabled.12;application/vnd.oasis.opendocument.presentation|ms-powerpoint
outlook|Outlook|https://outlook.cloud.microsoft/mail/|Mail and calendar with Microsoft Outlook|Office;Email;Calendar;||mailto
onenote|OneNote|https://onenote.cloud.microsoft/|Take notes with Microsoft OneNote|Office;||onenote
teams|Teams|https://teams.cloud.microsoft/|Chat and meet with Microsoft Teams|Office;Chat;InstantMessaging;VideoConference;||msteams
onedrive|OneDrive|https://onedrive.cloud.microsoft/|Browse files in Microsoft OneDrive|Office;FileManager;||
m365|Microsoft 365|https://m365.cloud.microsoft/|Microsoft 365 home and Copilot|Office;||'

# File extension to app id, for files the MIME database names generically.
declare -gA OH_EXT_APP=(
  [docx]=word [doc]=word [docm]=word [dot]=word [dotx]=word [dotm]=word [rtf]=word [odt]=word
  [xlsx]=excel [xls]=excel [xlsm]=excel [xlsb]=excel [xlt]=excel [xltx]=excel [xltm]=excel [ods]=excel [csv]=excel
  [pptx]=powerpoint [ppt]=powerpoint [pptm]=powerpoint [pps]=powerpoint [ppsx]=powerpoint [ppsm]=powerpoint
  [pot]=powerpoint [potx]=powerpoint [potm]=powerpoint [odp]=powerpoint
  [one]=onenote
)

# File extension to the MIME type GIO (Files) gives it. Every type here is in
# its app's field 6, which also keeps types a past choice may have claimed.
declare -gA OH_EXT_MIME=(
  [doc]=application/msword
  [dot]=application/msword-template
  [docx]=application/vnd.openxmlformats-officedocument.wordprocessingml.document
  [docm]=application/vnd.ms-word.document.macroEnabled.12
  [dotx]=application/vnd.openxmlformats-officedocument.wordprocessingml.template
  [dotm]=application/vnd.ms-word.template.macroEnabled.12
  [xls]=application/vnd.ms-excel
  [xlt]=application/vnd.ms-excel
  [xlsx]=application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
  [xlsm]=application/vnd.ms-excel.sheet.macroEnabled.12
  [xlsb]=application/vnd.ms-excel.sheet.binary.macroEnabled.12
  [xltx]=application/vnd.openxmlformats-officedocument.spreadsheetml.template
  [xltm]=application/vnd.ms-excel.template.macroEnabled.12
  [ppt]=application/vnd.ms-powerpoint
  [pps]=application/vnd.ms-powerpoint
  [pot]=application/vnd.ms-powerpoint
  [pptx]=application/vnd.openxmlformats-officedocument.presentationml.presentation
  [pptm]=application/vnd.ms-powerpoint.presentation.macroEnabled.12
  [ppsx]=application/vnd.openxmlformats-officedocument.presentationml.slideshow
  [ppsm]=application/vnd.ms-powerpoint.slideshow.macroEnabled.12
  [potx]=application/vnd.openxmlformats-officedocument.presentationml.template
  [potm]=application/vnd.ms-powerpoint.template.macroEnabled.12
  [odt]=application/vnd.oasis.opendocument.text
  [ods]=application/vnd.oasis.opendocument.spreadsheet
  [odp]=application/vnd.oasis.opendocument.presentation
  [rtf]=application/rtf
  [csv]=text/csv
)

# Microsoft formats always open in Office; the other formats only when the
# config `files` names them.
OH_FILES_MS='doc docx docm dot dotx dotm xls xlsx xlsm xlsb xlt xltx xltm ppt pptx pptm pps ppsx ppsm pot potx potm'
OH_FILES_OTHER='odt ods odp rtf csv'

# Lookups run on every launch and double-click, so they stay in bash: no
# awk or cut process per field.
oh_app_ids() {
  local line
  while IFS= read -r line; do printf '%s\n' "${line%%|*}"; done <<<"$OH_APPS_TABLE"
}

oh_app_field() {
  local id=$1 n=$2 line
  local -a f
  while IFS= read -r line; do
    [[ ${line%%|*} == "$id" ]] || continue
    IFS='|' read -r -a f <<<"$line"
    printf '%s\n' "${f[n - 1]:-}"
    return 0
  done <<<"$OH_APPS_TABLE"
  return 1
}

oh_app_exists() { oh_app_field "$1" 1 >/dev/null; }
oh_app_name() { oh_app_field "$1" 2; }
oh_app_url() { oh_app_field "$1" 3; }
oh_app_comment() { oh_app_field "$1" 4; }
oh_app_categories() { oh_app_field "$1" 5; }
oh_app_mimes() { oh_app_field "$1" 6; }
oh_app_schemes() { oh_app_field "$1" 7; }

oh_app_desktop_id() { printf 'omarchohard-%s.desktop\n' "$1"; }

oh_app_require() {
  oh_app_exists "${1:-}" || oh_die "unknown app '${1:-}'. Apps: $(oh_app_ids | tr '\n' ' ')"
}

oh_app_for_file() {
  local file=$1 ext
  ext=${file##*.}
  ext=${ext,,}
  [[ $file == *.* && -n ${OH_EXT_APP[$ext]:-} ]] || return 1
  printf '%s\n' "${OH_EXT_APP[$ext]}"
}

# The apps the user chose (config `apps`: "all" or a comma list). Microsoft 365
# home is always kept, as it is the way to every other app and to Copilot.
oh_enabled_apps() {
  local want id
  want=,$(oh_config_get apps),
  want=${want// /}
  for id in $(oh_app_ids); do
    [[ $want == ,all, || $want == ,, || $want == *",$id,"* || $id == m365 ]] && printf '%s\n' "$id"
  done
  return 0
}

oh_app_enabled() { oh_enabled_apps | grep -qxF -- "$1"; }

# Normalize a user list ("Teams, word") to known ids in table order; "all"
# stays "all". Callers check the status, as oh_die in $(...) only ends the subshell.
oh_apps_parse() {
  local raw=${1,,} id out=''
  raw=${raw// /}
  if [[ $raw == all || -z $raw ]]; then
    echo all
    return 0
  fi
  for id in ${raw//,/ }; do
    oh_app_require "$id" || return 1
  done
  for id in $(oh_app_ids); do
    [[ ,$raw, == *",$id,"* ]] && out+=${out:+,}$id
  done
  printf '%s\n' "$out"
}

# Normalize a `files` value: microsoft, all, or other-format extensions in
# OH_FILES_OTHER order. A list of every other format is "all", an empty one
# "microsoft". Callers check the status, as with oh_apps_parse.
oh_files_parse() {
  local raw=${1,,} ext out=''
  raw=${raw// /}
  raw=${raw//./}
  case $raw in microsoft | '') echo microsoft && return 0 ;; all) echo all && return 0 ;; esac
  for ext in ${raw//,/ }; do
    [[ " $OH_FILES_OTHER " == *" $ext "* ]] && continue
    oh_die "unknown files value '$ext'. Use microsoft, all, or a comma list of: ${OH_FILES_OTHER// /, }"
  done
  for ext in $OH_FILES_OTHER; do
    [[ ,$raw, == *",$ext,"* ]] && out+=${out:+,}$ext
  done
  [[ $out == "${OH_FILES_OTHER// /,}" ]] && out=all
  printf '%s\n' "${out:-microsoft}"
}

# The other formats the config `files` turns on, one per line. Unknown
# words in a hand-edited config are skipped.
oh_files_other() {
  local want ext
  want=,$(oh_config_get files),
  want=${want// /}
  for ext in $OH_FILES_OTHER; do
    [[ $want == ,all, || $want == *",$ext,"* ]] && printf '%s\n' "$ext"
  done
  return 0
}

# "Microsoft Office files, .odt, .csv"
oh_files_label() {
  local ext out='Microsoft Office files'
  for ext in $(oh_files_other); do out+=", .$ext"; done
  printf '%s\n' "$out"
}

# The types an app claims under the config `files`, in table order.
oh_app_file_mimes() {
  local id=$1 ext mime want=';'
  local -a all=()
  for ext in $OH_FILES_MS $(oh_files_other); do
    [[ ${OH_EXT_APP[$ext]:-} == "$id" ]] && want+="${OH_EXT_MIME[$ext]};"
  done
  [[ -n $(oh_app_mimes "$id") ]] && IFS=';' read -r -a all <<<"$(oh_app_mimes "$id")"
  for mime in "${all[@]}"; do
    [[ $want == *";$mime;"* ]] && printf '%s\n' "$mime"
  done
  return 0
}
