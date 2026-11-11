# shellcheck shell=bash
# The app registry. One line per app:
#   id|Name|launch URL|comment|categories|mime types (;)|URL schemes (;)

OH_APPS_TABLE='word|Word|https://word.cloud.microsoft/|Write documents with Microsoft Word|Office;WordProcessor;|application/vnd.openxmlformats-officedocument.wordprocessingml.document;application/msword;application/vnd.openxmlformats-officedocument.wordprocessingml.template;application/vnd.ms-word.document.macroEnabled.12;application/vnd.ms-word.template.macroEnabled.12;application/rtf;application/vnd.oasis.opendocument.text|ms-word
excel|Excel|https://excel.cloud.microsoft/|Work with spreadsheets in Microsoft Excel|Office;Spreadsheet;|application/vnd.openxmlformats-officedocument.spreadsheetml.sheet;application/vnd.ms-excel;application/vnd.openxmlformats-officedocument.spreadsheetml.template;application/vnd.ms-excel.sheet.macroEnabled.12;application/vnd.ms-excel.sheet.binary.macroEnabled.12;application/vnd.oasis.opendocument.spreadsheet|ms-excel
powerpoint|PowerPoint|https://powerpoint.cloud.microsoft/|Build presentations with Microsoft PowerPoint|Office;Presentation;|application/vnd.openxmlformats-officedocument.presentationml.presentation;application/vnd.ms-powerpoint;application/vnd.openxmlformats-officedocument.presentationml.slideshow;application/vnd.openxmlformats-officedocument.presentationml.template;application/vnd.ms-powerpoint.presentation.macroEnabled.12;application/vnd.oasis.opendocument.presentation|ms-powerpoint
outlook|Outlook|https://outlook.cloud.microsoft/mail/|Mail and calendar with Microsoft Outlook|Office;Email;Calendar;||mailto
onenote|OneNote|https://onenote.cloud.microsoft/|Take notes with Microsoft OneNote|Office;||onenote
teams|Teams|https://teams.cloud.microsoft/|Chat and meet with Microsoft Teams|Office;Chat;InstantMessaging;VideoConference;||msteams
onedrive|OneDrive|https://onedrive.cloud.microsoft/|Browse files in Microsoft OneDrive|Office;FileManager;||
m365|Microsoft 365|https://m365.cloud.microsoft/|Microsoft 365 home and Copilot|Office;||'

# File extension to app id, for files the MIME database names generically.
declare -gA OH_EXT_APP=(
  [docx]=word [doc]=word [docm]=word [dotx]=word [dotm]=word [rtf]=word [odt]=word
  [xlsx]=excel [xls]=excel [xlsm]=excel [xlsb]=excel [xltx]=excel [ods]=excel
  [pptx]=powerpoint [ppt]=powerpoint [pptm]=powerpoint [ppsx]=powerpoint [potx]=powerpoint [odp]=powerpoint
  [one]=onenote
)

oh_app_ids() { cut -d'|' -f1 <<<"$OH_APPS_TABLE"; }

oh_app_field() {
  local id=$1 n=$2
  awk -F'|' -v id="$id" -v n="$n" '$1 == id { print $n; found = 1 } END { exit !found }' <<<"$OH_APPS_TABLE"
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
