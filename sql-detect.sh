#!/bin/bash

# SQLが追加されたと思われるPRをチャットツールに通知する
function send_notifications() {
    ORA_DETECT_ROOM_ID=""

    # Slack移行後はSlackAPIにcurlする実装に変更
    if [ -e $TARGET_PR_URLS ]; then
        message="[info][title]OracleへのSQLが修正、追加された可能性があります[/title]`cat ${TARGET_PR_URLS}`[/info]"
        curl -s -X POST -H "X-ChatWorkToken: ${CW_API_TOKEN}" \
        -d "body=${message}" "https://api.chatwork.com/v2/rooms/${ORA_DETECT_ROOM_ID}/messages" > /dev/null
        rm $TARGET_PR_URLS
    else
        message="[info][title]OracleへのSQLが修正、追加されてないです[/title]対応不要です[/info]"
        curl -s -X POST -H "X-ChatWorkToken: ${CW_API_TOKEN}" \
        -d "body=${message}" "https://api.chatwork.com/v2/rooms/${ORA_DETECT_ROOM_ID}/messages" > /dev/null
    fi
}

# OracleのSQLだと思われるものを取得
function get_match_pattern() {
    local match_pattern

    match_pattern=$(grep -iE 'select|insert|update|delete|first|take|find|chunk|value|where|save' ${TARGET_FILES_MODIFIED})
    echo $match_pattern
}

# 対象ファイルのみのdiffをTARGET_FILES_DIFFにまとめる
function get_diff_from_target_files() {
    for i in $( seq 0 $(($len_lines_list - 1)) ); do
        # ファイルの拡張子を取得
        is_extension=$(sed -n "${lines_list[$i]}"p ${ALL_FILES_DIFF} | grep -E "\.+")
        if [ ! "$is_extension" ]; then
            continue
        fi
        extension=$(sed -n "${lines_list[$i]}"p ${ALL_FILES_DIFF} | sed -r -e "s/^.+\.([a-z]{1,})$/\1/g")

        # specファイルを除く
        is_spec=$(sed -n "${lines_list[$i]}"p ${ALL_FILES_DIFF} | grep "_spec.rb")
        if [ "$is_spec" ]; then
            continue
        fi

        # SQLが記載されることがないファイルを除外
        removed_extensions=("yml" "yaml" "html" "css" "scss" "js" "md" "xml" "conf" "twig")
        if `echo ${removed_extensions[@]} | grep -q "$extension"` ; then
            continue
        fi

        # 変更ファイルの最後のファイルだけ個別の処理してdiffを1ファイルにまとめる
        if [ $i = $((len_lines_list-1)) ]; then
            sed -n "${lines_list[$i]}","$(cat ${ALL_FILES_DIFF} | wc -l)"p $ALL_FILES_DIFF >> $TARGET_FILES_DIFF
            break
        fi
        # 対象ファイルのみのdiffを1ファイルにまとめる
        sed -n "${lines_list[$i]}","$((lines_list[$i+1]-1))"p $ALL_FILES_DIFF >> $TARGET_FILES_DIFF
    done
}

function usage_exit() {
    echo "Usage: $0 [-l ログファイル] [-r リポジトリ一覧ファイル]" 1>&2
    exit 1
}


TARGET_FILES_DIFF=target_files_diff.txt
TARGET_PR_URLS=target_pr_urls.txt
ALL_FILES_DIFF=all_files_diff.txt
TARGET_FILES_MODIFIED=target_files_modified.txt
ERROR_LOG=

while getopts r:l: OPT
do
  case $OPT in
    r) REPOS=$OPTARG ;;
    l) ERROR_LOG=$OPTARG ;;
    \?) usage_exit ;;
  esac
done
shift $(($OPTIND - 1))

# ログにタイムスタンプを付与
exec 2> >(
  while read -r l; 
  do 
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $l";
  done >> $ERROR_LOG
)


# リポジトリごとにOracleへのSQLが追加修正されたかを検知する
# ディレクトリ名は適宜変更
dirname="/Users/${USER}/projects/sql-detect"
filename=`basename ${REPOS}`

for repo in `cat ${dirname}/${filename}` ; do
    all_prs=$(curl -s -H "Accept: application/vnd.github.v3+json" -H "Authorization: token ${GITHUB_TOKEN}" \
    "https://api.github.com/repos/FumiakiTono/${repo}/pulls?state=open&sort=updated&direction=desc")
    len=$(echo $all_prs | jq length)
    diff_urls=()

    # 1リポジトリの中から更新が入ったPRを取得する
    for i in $( seq 0 $(($len - 1)) ); do
        pr=$(echo $all_prs | jq .[$i])
        author=$(echo $pr | jq .user.login | sed -e 's/"//g')

        # 一部のメンバーは除外する
        removed_authors=("FumiakiTono")
        if `echo ${removed_authors[@]} | grep -q "$author"` ; then
            continue
        fi

        # 1日前(朝9時〜朝9時)に更新が入ったPRのみに絞る
        updated_day=$(echo $pr | jq .updated_at | sed -e 's/T.*Z//g' -e 's/"//g')
        # if [ $updated_day = `date +"%Y-%m-%d"` ]; then
        if [ $updated_day = `date -j -v-1d +"%Y-%m-%d"` ]; then
            diff_url=$(echo $pr | jq .html_url | sed -e 's/"//g')
            diff_urls+=($diff_url)
        fi
    done

    # 更新が入ったPRから変更内容を取得し、OracleへのSQLが追加修正されたかを検知する
    for url in "${diff_urls[@]}"; do
        # github cliを使って更新が入ったPRから全ファイルのdiffを取得する
        gh pr diff $url > $ALL_FILES_DIFF
        lines=$(grep -n "diff --git" ${ALL_FILES_DIFF} | sed -r -e "s/(^[0-9]{1,}).+/\1/g")
        lines_list=(${lines// / })
        len_lines_list=${#lines_list[@]}
        touch $TARGET_FILES_DIFF $TARGET_FILES_MODIFIED

        get_diff_from_target_files 

        grep -aE "^\+{1}" $TARGET_FILES_DIFF > $TARGET_FILES_MODIFIED
        match_pattern=`get_match_pattern`

        # SQLが追加されたと思われるPRを1ファイルにまとめる
        if [ "$match_pattern" ]; then
            echo $url >> $TARGET_PR_URLS
        fi

        rm $TARGET_FILES_DIFF $ALL_FILES_DIFF $TARGET_FILES_MODIFIED
    done
done

send_notifications
