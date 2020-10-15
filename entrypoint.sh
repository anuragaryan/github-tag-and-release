#!/bin/bash

set -o pipefail

# config
release_branches=${RELEASE_BRANCHES:-master}
source=${SOURCE:-.}
tag_context=${TAG_CONTEXT:-repo}
prefix=${PREFIX:-APP}

cd ${GITHUB_WORKSPACE}/${source}

echo "*** CONFIGURATION ***"
echo -e "\tRELEASE_BRANCHES: ${release_branches}"
echo -e "\tSOURCE: ${source}"
echo -e "\tTAG_CONTEXT: ${tag_context}"
echo -e "\tPREFIX: ${prefix}"

current_branch=$(git rev-parse --abbrev-ref HEAD)

pre_release="true"
IFS=',' read -ra branch <<< "$release_branches"
for b in "${branch[@]}"; do
    # If b is not a match for current_branch
    if [[ ! "${current_branch}" =~ $b ]]
    then
        echo "wrong branch, can only create tag for $release_branches"
        exit 0
    fi
done

# fetch tags
git fetch --tags

# get prefix that looks like a DH tag: SERVICE_NAME.YEAR.WEEK
tag_prefix="$prefix.`date +%y`.`date +%U`"

case "$tag_context" in
    *repo*) 
        tag=$(git for-each-ref --sort=-v:refname --format '%(refname)' | cut -d / -f 3- | grep -E "^$tag_prefix.[0-9]+$" | head -n1)
        ;;
    *branch*) 
        tag=$( git tag --list --merged HEAD --sort=-v:refname | grep -E "^$tag_prefix.[0-9]+$" | head -n1)
        ;;
    * ) echo "Unrecognised context"; exit 1;;
esac

# if there are none, start tags at INITIAL_VERSION which defaults to SERVICE_NAME.YEAR.WEEK.0
if [ -z "$tag" ]
then
    log=$(git log --pretty='%B')
    new_tag="$tag_prefix.0"
else
    log=$(git log $tag..HEAD --pretty='%B')
    release=${tag##*.}
    release=$((release+1)) # increment the release number
    new_tag="$tag_prefix.$release"

    # get current commit hash for last tag
    tag_commit=$(git rev-list -n 1 $tag)
fi

echo $log

# get current commit hash
commit=$(git rev-parse HEAD)

if [ "$tag_commit" == "$commit" ]; then
    echo "No new commits since previous tag. Skipping..."
    exit 0
fi

# create local git tag
git tag $new_tag

# push new tag ref to github
dt=$(date '+%Y-%m-%dT%H:%M:%SZ')
full_name=$GITHUB_REPOSITORY
git_refs_url=$(jq .repository.git_refs_url $GITHUB_EVENT_PATH | tr -d '"' | sed 's/{\/sha}//g')

echo $git_refs_url
echo "$dt: **pushing tag $new_tag to repo $full_name"

# Tag

git_refs_response=$(
curl -s -X POST $git_refs_url \
-H "Authorization: token $GITHUB_TOKEN" \
-d @- << EOF

{
  "ref": "refs/tags/$new_tag",
  "sha": "$commit"
}
EOF
)

git_ref_posted=$( echo "${git_refs_response}" | jq .ref | tr -d '"' )

echo "::debug::${git_refs_response}"
if [ "${git_ref_posted}" = "refs/tags/${new_tag}" ]; then
  exit 0
else
  echo "::error::Tag was not created properly."
  exit 1
fi

# Release

git_refs_url=$(jq .repository.git_refs_url $GITHUB_EVENT_PATH | tr -d '"' | sed 's/{\/releases}//g')
echo $git_refs_url

git_release_response=$(
curl -s -X POST $git_refs_url \
-H "Authorization: token $GITHUB_TOKEN" \
-d @- << EOF

{
    "tag_name": "$new_tag",
    "target_commitish": "master",
    "name": "$new_tag",
    "body": "$log",
    "draft": false,
    "prerelease": false
}
EOF
)

release_id="$(echo "${git_release_response}" | jq -r '.id')"
release_url="$(echo "${git_release_response}" | jq -r '.html_url')"

[[ "null" == "${release_id}" ]] && error "$(echo "${response}" | jq -c '{message:.message, errors:.errors}')"

echo "* GitHub release #${release_id} URL - ${release_url}" 1>&2