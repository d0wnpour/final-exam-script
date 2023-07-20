#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

if [[ "${BASH_TRACE:-0}" == "1" ]]; then
    set -o xtrace
fi

function dependency_checker() {
    if [ $1 -ne 5 ]; then
        echo "Usage: $2 CODE_REPO_URL DEV_BRANCH_NAME RELEASE_BRANCH_NAME HTML_REPO_URL HTML_BRANCH_NAME"
        exit 1
    fi

    local REQUIRED_DEPENDENCIES=("pip3" "pytest" "jq" "black" "pygmentize")

    for dependency in "${REQUIRED_DEPENDENCIES[@]}"; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            echo "Error: $dependency Not installed on you machine"
            exit 1
        fi
    done

    if ! pip3 freeze | grep -q "pytest-html"; then
        echo "Error: pytest=html Not installed on your machine"
        exit 1
    fi
}

dependency_checker $# $0

cd "$(dirname "$0")"

BRANCH_CODE_REPOSITORY_RELEASE="$3"
BRANCH_CODE_REPOSITORY_DEV="$2"
BRANCH_REPORT_REPOSITORY="$5"

get_repository_owner() {
    echo "$1" | cut -d':' -f2
}

get_repository_name() {
    echo "$1" | cut -d':' -f2
}

REPOSITORY_OWNER_USERNAME_CODE=$(get_repository_owner "$1" | cut -d'/' -f1)
REPOSITORY_OWNER_USERNAME_REPORT=$(get_repository_owner "$4" | cut -d'/' -f1 )

CODE_REPOSYTORY_NAME=$(get_repository_name "$1" | cut -d'/' -f2 |  cut -d'.' -f1)
REPORT_REPOSYTORY_NAME=$(get_repository_name "$4"| cut -d'/' -f2 |  cut -d'.' -f1)

CODE_REPOSITORY_PATH=$(mktemp --directory)
REPORT_REPOSITORY_PATH=$(mktemp --directory)
BLACK_OUTPUT_PATH=$(mktemp)
PYTEST_OUTPUT=0
BLACK_OUTPUT=0

function github_api_get_request() {
    curl --request GET \
        --header "Accept: application/vnd.github+json" \
        --header "Authorization: Bearer $GITHUB_PERSONAL_ACCESS_TOKEN" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --output "$2" \
        --silent \
        "$1"
    #--dump-header /dev/stderr \
}

function github_post_request() {
    curl --request POST \
        --header "Accept: application/vnd.github+json" \
        --header "Authorization: Bearer $GITHUB_PERSONAL_ACCESS_TOKEN" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --header "Content-Type: application/json" \
        --silent \
        --output "$3" \
        --data-binary "@$2" \
        "$1"
    #--dump-header /dev/stderr \
}

function jq_update() {
    local IO_PATH=$1
    local TEMP_PATH=$(mktemp)
    shift
    cat $IO_PATH | jq "$@" >$TEMP_PATH
    mv $TEMP_PATH $IO_PATH
}
LAST_COMMIT_HASH=''
git clone git@github.com:${REPOSITORY_OWNER_USERNAME_CODE}/${CODE_REPOSYTORY_NAME}.git $CODE_REPOSITORY_PATH

while true; do
    cd $CODE_REPOSITORY_PATH
    git switch $BRANCH_CODE_REPOSITORY_DEV
    git pull
    NEW_LAST_COMMIT_HASH=$(git rev-parse HEAD)
    AUTHOR_EMAIL=$(git log -n 1 --format="%ae" HEAD)
    if [ "$LAST_COMMIT_HASH" != "$NEW_LAST_COMMIT_HASH" ]; then
        NEW_HASHES=$(git log --reverse --pretty=format:%H $LAST_COMMIT_HASH..$NEW_LAST_COMMIT_HASH)
        for COMMIT_HASH in $NEW_HASHES; do
            PYTEST_REPORT_PATH=$(mktemp)
            BLACK_REPORT_PATH=$(mktemp)
            git checkout $COMMIT_HASH
            if pytest --verbose --html=$PYTEST_REPORT_PATH --self-contained-html; then
                PYTEST_OUTPUT=$?
                echo "PYTEST SUCCEEDED $PYTEST_OUTPUT"
            else
                PYTEST_OUTPUT=$?
                echo "PYTEST FAILED $PYTEST_OUTPUT"
            fi

            echo "\$PYTEST_OUTPUT = $PYTEST_OUTPUT \$BLACK_OUTPUT=$BLACK_OUTPUT"

            if black --check --diff *.py >$BLACK_OUTPUT_PATH; then
                BLACK_OUTPUT=$?
                echo "BLACK SUCCEEDED $BLACK_OUTPUT"
            else
                BLACK_OUTPUT=$?
                echo "BLACK FAILED $BLACK_OUTPUT"
                cat $BLACK_OUTPUT_PATH | pygmentize -l diff -f html -O full,style=solarized-light -o $BLACK_REPORT_PATH
            fi

            echo "\$PYTEST_OUTPUT = $PYTEST_OUTPUT \$BLACK_OUTPUT=$BLACK_OUTPUT"

            git clone git@github.com:${REPOSITORY_OWNER_USERNAME_REPORT}/${REPORT_REPOSYTORY_NAME}.git $REPORT_REPOSITORY_PATH

            pushd $REPORT_REPOSITORY_PATH

            git switch $BRANCH_REPORT_REPOSITORY
            REPORT_PATH="${COMMIT_HASH}-$(date +%s)"
            mkdir --parents $REPORT_PATH
            mv $PYTEST_REPORT_PATH "$REPORT_PATH/pytest.html"
            mv $BLACK_REPORT_PATH "$REPORT_PATH/black.html"
            git add $REPORT_PATH
            git commit -m "$COMMIT_HASH report."
            git push

            popd

            rm -rf $REPORT_REPOSITORY_PATH
            rm -rf $PYTEST_REPORT_PATH
            rm -rf $BLACK_REPORT_PATH

            if ((($PYTEST_OUTPUT != 0) || ($BLACK_OUTPUT != 0))); then
                AUTHOR_USERNAME=""
                RESPONSE_PATH=$(mktemp)
                github_api_get_request "https://api.github.com/search/users?q=$AUTHOR_EMAIL" $RESPONSE_PATH

                TOTAL_USER_COUNT=$(cat $RESPONSE_PATH | jq ".total_count")

                if [[ $TOTAL_USER_COUNT == 1 ]]; then
                    USER_JSON=$(cat $RESPONSE_PATH | jq ".items[0]")
                    AUTHOR_USERNAME=$(cat $RESPONSE_PATH | jq --raw-output ".items[0].login")
                fi

                REQUEST_PATH=$(mktemp)
                RESPONSE_PATH=$(mktemp)
                echo "{}" >$REQUEST_PATH

                BODY="Automatically generated message

"

                if (($PYTEST_OUTPUT != 0)); then
                    if (($BLACK_OUTPUT != 0)); then
                        TITLE="${COMMIT_HASH::7} failed unit and formatting tests."
                        BODY+="${COMMIT_HASH} failed unit and formatting tests.

"
                        jq_update $REQUEST_PATH '.labels = ["ci-pytest", "ci-black"]'
                    else
                        TITLE="${COMMIT_HASH::7} failed unit tests."
                        BODY+="${COMMIT_HASH} failed unit tests.

"
                        jq_update $REQUEST_PATH '.labels = ["ci-pytest"]'
                    fi
                else
                    TITLE="${COMMIT_HASH::7} failed formatting test."
                    BODY+="${COMMIT_HASH} failed formatting test.
"
                    jq_update $REQUEST_PATH '.labels = ["ci-black"]'
                fi

                BODY+="Pytest report: https://${REPOSITORY_OWNER_USERNAME_REPORT}.github.io/${REPORT_REPOSYTORY_NAME}/$REPORT_PATH/pytest.html

"
                BODY+="Black report: https://${REPOSITORY_OWNER_USERNAME_REPORT}.github.io/${REPORT_REPOSYTORY_NAME}/$REPORT_PATH/black.html

"

                jq_update $REQUEST_PATH --arg title "$TITLE" '.title = $title'
                jq_update $REQUEST_PATH --arg body "$BODY" '.body = $body'

                if [[ ! -z $AUTHOR_USERNAME ]]; then
                    jq_update $REQUEST_PATH --arg username "$AUTHOR_USERNAME" '.assignees = [$username]'
                fi

                github_post_request "https://api.github.com/repos/${REPOSITORY_OWNER_USERNAME_CODE}/${CODE_REPOSYTORY_NAME}/issues" $REQUEST_PATH $RESPONSE_PATH
                #cat $RESPONSE_PATH
                cat $RESPONSE_PATH | jq ".html_url"
                rm $RESPONSE_PATH
                rm $REQUEST_PATH
            else
                echo "EVERYTHING OK, BYE!"
                cd $CODE_REPOSITORY_PATH
                TAG=$BRANCH_CODE_REPOSITORY_DEV-ci-success
                if git rev-parse --verify --quiet $TAG >/dev/null; then
                    git push origin --delete $TAG
                fi

                COMMIT_HASH=$(git rev-parse HEAD)
                git tag -fa $TAG -m $TAG $COMMIT_HASH
                git push origin $TAG --force
            fi
        done
        LAST_COMMIT_HASH=$NEW_LAST_COMMIT_HASH
        echo "sleep for 15 secs"
    fi
    sleep 15
done
